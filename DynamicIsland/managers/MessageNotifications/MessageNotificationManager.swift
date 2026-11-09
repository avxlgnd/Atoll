//
//  MessageNotificationManager.swift
//  DynamicIsland
//
//  Watches the Messages database for new incoming messages and feeds the banner.
//

import AppKit
import Combine
import Defaults
import Foundation

/// Reads whether a Focus (Do Not Disturb, Work, Sleep...) is currently on, from the system's own
/// Focus database. Needs Full Disk Access, which the Messages feature already needs.
/// This is an undocumented file, so a macOS update could change it; "can't tell" is reported then.
enum FocusStatusReader {
    static var assertionsPath: String {
        NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
    }

    /// nil means "can't tell" (file unreadable or in a format we don't recognise).
    static func isFocusActive() -> Bool? {
        guard let data = FileManager.default.contents(atPath: assertionsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return nil }
        for entry in entries {
            if let records = entry["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return true
            }
        }
        return false
    }
}

enum MessageNotificationStatus: Equatable {
    case disabled
    case starting
    case running
    case needsFullDiskAccess
    case failed(String)

    var description: String {
        switch self {
        case .disabled: return "Off"
        case .starting: return "Starting…"
        case .running: return "Listening for new messages"
        case .needsFullDiskAccess: return "Waiting for Full Disk Access"
        case let .failed(reason): return "Problem: \(reason)"
        }
    }
}

final class MessageNotificationManager: ObservableObject {
    static let shared = MessageNotificationManager()

    @Published private(set) var status: MessageNotificationStatus = .disabled
    @Published private(set) var focusDescription: String = ""
    private var wasFocusActive = false

    private let queue = DispatchQueue(label: "atoll.messages.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reader: MessagesDatabaseReader?
    private var lastRowID: Int64 = 0
    private var retryWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isEnabled = false
    private var healer: NotificationSelfHealing?
    private var consecutiveFailures = 0

    /// Hooks the manager up to its setting. Call once at launch.
    func configure() {
        Publishers.CombineLatest(
            Defaults.publisher(.notchNotificationsMaster).map { $0.newValue },
            Defaults.publisher(.messageNotificationsEnabled).map { $0.newValue }
        )
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isEnabled = enabled
                if enabled { self.start() } else { self.stop() }
            }
            .store(in: &cancellables)

        healer = NotificationSelfHealing(
            onSystemEvent: { [weak self] in self?.restart() },
            healthCheck: { [weak self] in self?.ensureRunning() }
        )
    }

    /// Rebuilds the watcher (after wake or unlock).
    private func restart() {
        guard isEnabled else { return }
        retryWork?.cancel()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.reader = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.start()
        }
    }

    /// Called every 10 seconds: if it should be running but is not, start it again.
    private func ensureRunning() {
        guard isEnabled else { return }
        if status != .running && status != .starting {
            start()
        }
    }

    private func start() {
        guard timer == nil else { return }
        retryWork?.cancel()
        status = .starting
        MessageContactResolver.shared.requestAccessIfNeeded()

        queue.async { [weak self] in
            guard let self else { return }
            let reader = MessagesDatabaseReader()
            do {
                try reader.open()
                let last = try reader.latestRowID()
                self.reader = reader
                self.lastRowID = last
                self.beginTimer()
                NotificationBackgroundActivity.acquire("messages")
                DispatchQueue.main.async { self.status = .running }
            } catch MessagesDatabaseError.accessDenied {
                DispatchQueue.main.async {
                    self.status = .needsFullDiskAccess
                    self.scheduleRetry()
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .failed("\(error)")
                    self.scheduleRetry()
                }
            }
        }
    }

    private func stop() {
        retryWork?.cancel()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.reader = nil
        }
        NotificationBackgroundActivity.release("messages")
        status = .disabled
    }

    /// Lets the permission be granted without toggling the setting off and on again.
    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            self.start()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Polling (runs on `queue`)

    private func beginTimer() {
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = source
        source.resume()
    }

    private func poll() {
        guard let reader else { return }
        do {
            var messages = try reader.newMessages(after: lastRowID)
            // Advance past everything we looked at, even rows we chose not to show.
            if let newest = try? reader.latestRowID(), newest > lastRowID {
                lastRowID = newest
            }

            // While a Focus (Do Not Disturb...) is on, new messages are not shown (and not shown later either).
            let focusActive: Bool? = Defaults[.respectFocusMode] ? FocusStatusReader.isFocusActive() : false
            publishFocus(focusActive)
            if focusActive == true { messages.removeAll() }

            for index in messages.indices {
                let resolved = MessageContactResolver.shared.resolve(messages[index].senderID)
                if let name = resolved.name { messages[index].senderName = name }
                messages[index].senderPhoto = resolved.photo
            }

            let tracked = trackedIDsSnapshot()
            let states = try reader.readStates(for: tracked)
            let nowRead = Set(states.filter { $0.value }.map { $0.key })

            consecutiveFailures = 0
            guard !messages.isEmpty || !nowRead.isEmpty else { return }
            let batch = messages
            DispatchQueue.main.async {
                if !nowRead.isEmpty { MessageBannerModel.shared.remove(readIDs: nowRead) }
                if !batch.isEmpty { MessageBannerModel.shared.add(batch) }
            }
        } catch MessagesDatabaseError.accessDenied {
            DispatchQueue.main.async { [weak self] in
                self?.status = .needsFullDiskAccess
                self?.restartAfterFailure()
            }
        } catch {
            // Occasional failures (the database being busy) are retried on the next tick. If it keeps
            // failing, the connection has gone stale (for example after sleep): reconnect.
            consecutiveFailures += 1
            if consecutiveFailures >= 5 {
                consecutiveFailures = 0
                DispatchQueue.main.async { [weak self] in
                    self?.restartAfterFailure()
                }
            }
        }
    }

    private func publishFocus(_ active: Bool?) {
        let text: String
        if !Defaults[.respectFocusMode] {
            text = "Not following Focus"
        } else if let active {
            text = active ? "A Focus is on: notifications are silenced" : "No Focus is on"
        } else {
            text = "Can't tell (Focus status unreadable)"
        }
        let nowActive = active == true
        let justTurnedOn = nowActive && !wasFocusActive
        wasFocusActive = nowActive
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.focusDescription != text { self.focusDescription = text }
            if justTurnedOn { MessageBannerModel.shared.dismissAll() }
        }
    }

    private func restartAfterFailure() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.reader = nil
        }
        scheduleRetry()
    }

    // MARK: - Tracking the messages currently on screen

    private let trackedLock = NSLock()
    private var trackedIDs: [Int64] = []

    func updateTracked(_ ids: [Int64]) {
        trackedLock.lock()
        trackedIDs = ids
        trackedLock.unlock()
    }

    private func trackedIDsSnapshot() -> [Int64] {
        trackedLock.lock()
        defer { trackedLock.unlock() }
        return trackedIDs
    }
}
