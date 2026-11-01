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

    private let queue = DispatchQueue(label: "atoll.messages.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reader: MessagesDatabaseReader?
    private var lastRowID: Int64 = 0
    private var retryWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isEnabled = false

    /// Hooks the manager up to its setting. Call once at launch.
    func configure() {
        Defaults.publisher(.messageNotificationsEnabled)
            .map { $0.newValue }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.isEnabled = enabled
                if enabled { self.start() } else { self.stop() }
            }
            .store(in: &cancellables)
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
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1.0)
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

            for index in messages.indices {
                let resolved = MessageContactResolver.shared.resolve(messages[index].senderID)
                if let name = resolved.name { messages[index].senderName = name }
                messages[index].senderPhoto = resolved.photo
            }

            let tracked = trackedIDsSnapshot()
            let states = try reader.readStates(for: tracked)
            let nowRead = Set(states.filter { $0.value }.map { $0.key })

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
            // Transient failures (for example the database being busy) are retried on the next tick.
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
