//
//  NotificationDiagnostics.swift
//  DynamicIsland
//
//  Records what macOS notification banners (WhatsApp messages, incoming calls...) look like to
//  the Accessibility API, so support for them can be built against what is really on screen.
//  Nothing is sent anywhere: the report is saved to ~/Library/Logs/Atoll and copied to the clipboard.
//

import AppKit
import ApplicationServices

final class NotificationDiagnostics {
    static let shared = NotificationDiagnostics()

    private(set) var isRunning = false

    /// Waits `delay` seconds (so you can trigger a notification or a call), then records the screen.
    func start(delay: TimeInterval = 15, completion: @escaping (URL?, String) -> Void) {
        guard !isRunning else { return }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            completion(nil, "Accessibility permission is needed. Allow Atoll in System Settings → Privacy & Security → Accessibility, then try again.")
            return
        }

        isRunning = true
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let report = self.buildReport()
            NSSound.beep()
            self.isRunning = false

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(report, forType: .string)

            if let url = self.save(report) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                completion(url, "Saved and copied to the clipboard.")
            } else {
                completion(nil, "Copied to the clipboard (saving the file failed).")
            }
        }
    }

    // MARK: - Report

    private func buildReport() -> String {
        var out = "Atoll notification diagnostics\n"
        out += "Date: \(Date())\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"

        out += "== On-screen windows (notification-related) ==\n"
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for window in list {
                let owner = window[kCGWindowOwnerName as String] as? String ?? ""
                let name = window[kCGWindowName as String] as? String ?? ""
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let interesting = ["NotificationCenter", "UserNotificationCenter", "WhatsApp", "FaceTime", "Phone", "Messages"]
                    .contains { owner.localizedCaseInsensitiveContains($0) }
                if interesting || layer >= 20 {
                    out += "owner=\"\(owner)\" name=\"\(name)\" layer=\(layer) bounds=\(bounds)\n"
                }
            }
        }

        let targets = [
            "com.apple.notificationcenterui",
            "com.apple.FaceTime",
            "net.whatsapp.WhatsApp",
            "desktop.WhatsApp"
        ]
        for bundleID in targets {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                out += "\n== Accessibility tree: \(bundleID) (pid \(app.processIdentifier)) ==\n"
                let element = AXUIElementCreateApplication(app.processIdentifier)
                if let windows = children(of: element, attribute: kAXWindowsAttribute), !windows.isEmpty {
                    for window in windows.prefix(12) {
                        dump(window, depth: 0, maxDepth: 14, into: &out)
                    }
                } else {
                    out += "(no windows visible to Accessibility)\n"
                }
            }
        }
        return out
    }

    private func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, into out: inout String) {
        var line = String(repeating: "  ", count: depth)
        line += stringValue(element, kAXRoleAttribute) ?? "?"
        for (label, key) in [
            ("subrole", kAXSubroleAttribute),
            ("title", kAXTitleAttribute),
            ("desc", kAXDescriptionAttribute),
            ("value", kAXValueAttribute),
            ("id", kAXIdentifierAttribute),
            ("help", kAXHelpAttribute)
        ] {
            if let value = stringValue(element, key), !value.isEmpty {
                line += " \(label)=\"\(value.prefix(160))\""
            }
        }
        if let frame = frame(of: element) {
            line += " frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))"
        }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String], !actions.isEmpty {
            line += " actions=\(actions.joined(separator: ","))"
        }
        out += line + "\n"

        guard depth < maxDepth, let kids = children(of: element, attribute: kAXChildrenAttribute) else { return }
        for kid in kids.prefix(60) {
            dump(kid, depth: depth + 1, maxDepth: maxDepth, into: &out)
        }
    }

    // MARK: - Accessibility helpers

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func children(of element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    // MARK: - Saving

    private func save(_ report: String) -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Atoll")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = folder.appendingPathComponent("NotificationDiagnostics-\(formatter.string(from: Date())).txt")
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
