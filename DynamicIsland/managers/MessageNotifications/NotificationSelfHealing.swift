//
//  NotificationSelfHealing.swift
//  DynamicIsland
//
//  Keeps the message and call watchers alive: restarts them after the Mac wakes or the screen
//  unlocks, checks regularly that they are still running, and stops macOS from throttling them
//  (App Nap) while they have a job to do.
//

import AppKit
import Foundation

final class NotificationSelfHealing {
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?

    /// - Parameters:
    ///   - onSystemEvent: called after wake, unlock or a user-session change: rebuild everything.
    ///   - healthCheck: called every 10 seconds: restart if the watcher should be running but is not.
    init(onSystemEvent: @escaping () -> Void, healthCheck: @escaping () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { _ in onSystemEvent() }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let unlocked = distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in onSystemEvent() }
        observers.append((distributed, unlocked))

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in healthCheck() }
    }

    deinit {
        timer?.invalidate()
        for entry in observers { entry.center.removeObserver(entry.token) }
    }
}

/// Holds one "this app is busy" token while any watcher is running, so macOS does not put Atoll
/// into App Nap (which slows timers to a crawl, for example while the screen is locked).
enum NotificationBackgroundActivity {
    private static let lock = NSLock()
    private static var users = Set<String>()
    private static var token: NSObjectProtocol?

    static func acquire(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        users.insert(name)
        if token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Watching for messages and calls"
            )
        }
    }

    static func release(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        users.remove(name)
        if users.isEmpty, let current = token {
            ProcessInfo.processInfo.endActivity(current)
            token = nil
        }
    }
}
