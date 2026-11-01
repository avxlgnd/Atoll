//
//  CallBannerMonitor.swift
//  DynamicIsland
//
//  Shows incoming iPhone and FaceTime calls in the notch with Answer / Decline.
//
//  macOS has no public way to see a ringing call, so this watches the call banner macOS itself
//  puts on screen (through the Accessibility API) and presses that banner's buttons for you.
//  Because it copies the real banner, it follows your Focus rules automatically: a call that
//  Do Not Disturb silences never produces a banner to copy.
//  Needs the Accessibility permission.
//

import AppKit
import ApplicationServices
import Combine
import Defaults

struct IncomingCall {
    let key: String
    let name: String
    let kindLabel: String
    let isFaceTime: Bool
    let accept: AXUIElement
    let decline: AXUIElement

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.filter { $0.isLetter }
        return String(letters).uppercased()
    }
}

final class CallBannerMonitor: ObservableObject {
    static let shared = CallBannerMonitor()

    @Published private(set) var statusText = "Off"
    @Published private(set) var lastDetection = ""

    private let queue = DispatchQueue(label: "atoll.calls.scan", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var missingScans = 0
    private var reportedKey: String?

    func configure() {
        Publishers.CombineLatest3(
            Defaults.publisher(.notchNotificationsMaster).map { $0.newValue },
            Defaults.publisher(.phoneCallsInNotch).map { $0.newValue },
            Defaults.publisher(.faceTimeCallsInNotch).map { $0.newValue }
        )
        .map { master, phone, faceTime in master && (phone || faceTime) }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] enabled in
            if enabled { self?.start() } else { self?.stop() }
        }
        .store(in: &cancellables)
    }

    /// Asks macOS for the Accessibility permission (shows the system prompt).
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            if self?.statusText != text { self?.statusText = text }
        }
    }

    private func start() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now() + 0.5, repeating: 0.5)
            source.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = source
            source.resume()
        }
        setStatus("Starting…")
    }

    private func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.reportedKey = nil
        }
        DispatchQueue.main.async {
            MessageBannerModel.shared.updateCall(nil)
        }
        setStatus("Off")
    }

    // MARK: - Scanning (runs on `queue`)

    private func tick() {
        guard AXIsProcessTrusted() else {
            setStatus("Needs the Accessibility permission")
            return
        }
        setStatus("Watching for calls")

        var call = scan()
        if let found = call {
            if found.isFaceTime && !Defaults[.faceTimeCallsInNotch] { call = nil }
            if !found.isFaceTime && !Defaults[.phoneCallsInNotch] { call = nil }
        }

        if let call {
            missingScans = 0
            reportedKey = call.key
            DispatchQueue.main.async {
                MessageBannerModel.shared.updateCall(call)
            }
        } else if reportedKey != nil {
            missingScans += 1
            if missingScans >= 3 {
                reportedKey = nil
                missingScans = 0
                DispatchQueue.main.async {
                    MessageBannerModel.shared.updateCall(nil)
                }
            }
        }
    }

    private func scan() -> IncomingCall? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return nil
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axChildren(root, kAXWindowsAttribute), !windows.isEmpty else { return nil }
        for window in windows {
            if let call = findCall(in: window, depth: 0) { return call }
        }
        return nil
    }

    /// Looks for the smallest element that contains both an "accept" and a "decline" button.
    private func findCall(in element: AXUIElement, depth: Int) -> IncomingCall? {
        guard depth <= 14 else { return nil }
        for child in (axChildren(element, kAXChildrenAttribute) ?? []).prefix(40) {
            if let found = findCall(in: child, depth: depth + 1) { return found }
        }

        var buttons: [(label: String, element: AXUIElement)] = []
        var texts: [String] = []
        collect(element, depth: 0, buttons: &buttons, texts: &texts)

        guard let accept = buttons.first(where: { Self.isAccept($0.label) }),
              let decline = buttons.first(where: { Self.isDecline($0.label) })
        else { return nil }

        let joined = texts.joined(separator: " | ")
        DispatchQueue.main.async { [weak self] in
            self?.lastDetection = joined
        }

        let lower = joined.lowercased()
        let isFaceTime = lower.contains("facetime")
        let kind: String
        if isFaceTime {
            kind = lower.contains("audio") ? "FaceTime Audio" : "FaceTime"
        } else {
            kind = "iPhone"
        }

        let generic: Set<String> = ["facetime", "facetime audio", "facetime video", "iphone", "phone", "mobile", "incoming call", "call", "now", "accept", "decline"]
        let name = texts.first(where: { !generic.contains($0.lowercased()) && !$0.isEmpty }) ?? "Unknown caller"

        return IncomingCall(
            key: "\(kind)-\(name)",
            name: name,
            kindLabel: kind,
            isFaceTime: isFaceTime,
            accept: accept.element,
            decline: decline.element
        )
    }

    private func collect(
        _ element: AXUIElement,
        depth: Int,
        buttons: inout [(label: String, element: AXUIElement)],
        texts: inout [String]
    ) {
        guard depth <= 10 else { return }
        let role = axString(element, kAXRoleAttribute) ?? ""
        if role == kAXButtonRole as String {
            let label = [
                axString(element, kAXTitleAttribute),
                axString(element, kAXDescriptionAttribute),
                axString(element, kAXIdentifierAttribute),
                axString(element, kAXHelpAttribute)
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            buttons.append((label, element))
        } else if role == kAXStaticTextRole as String {
            if let value = axString(element, kAXValueAttribute) ?? axString(element, kAXTitleAttribute),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                texts.append(value)
            }
        }
        for child in (axChildren(element, kAXChildrenAttribute) ?? []).prefix(40) {
            collect(child, depth: depth + 1, buttons: &buttons, texts: &texts)
        }
    }

    private static func isAccept(_ label: String) -> Bool {
        label.contains("accept") || label.contains("answer")
    }

    private static func isDecline(_ label: String) -> Bool {
        label.contains("decline") || label.contains("reject")
    }

    // MARK: - Accessibility helpers

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func axChildren(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
