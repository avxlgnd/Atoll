//
//  NotificationBannerLookup.swift
//  DynamicIsland
//
//  WhatsApp's database does not always contain the name macOS shows on its notification banner
//  (for example "~Rayan Salman" for someone who is not in your contacts). When the database has no
//  usable name, this reads the names off the banner macOS itself shows, through the Accessibility API.
//

import AppKit
import ApplicationServices
import Foundation

enum NotificationBannerLookup {
    struct Names {
        var sender: String?
        var title: String?
    }

    /// Looks for a macOS notification banner whose text is `body` and returns the names around it.
    /// Tries a few times, since the banner and the database row can appear a moment apart.
    static func names(forBody body: String, isGroup: Bool, attempts: Int = 4) -> Names? {
        guard AXIsProcessTrusted(), normalize(body).count >= 3 else { return nil }
        for attempt in 0..<max(attempts, 1) {
            if let found = lookup(body: body, isGroup: isGroup) { return found }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.35) }
        }
        return nil
    }

    // MARK: - Lookup

    private static func lookup(body: String, isGroup: Bool) -> Names? {
        let target = normalize(body)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var elements = children(root, kAXWindowsAttribute) ?? []
            elements += children(root, kAXChildrenAttribute) ?? []

            var texts: [(element: AXUIElement, value: String)] = []
            var budget = 600
            for element in elements {
                collectTexts(element, depth: 0, budget: &budget, into: &texts)
            }

            for candidate in texts where matches(normalize(candidate.value), target) {
                // Climb until the surrounding element holds the other lines of the same banner.
                var current: AXUIElement? = candidate.element
                for _ in 0..<5 {
                    guard let parent = current.flatMap({ parentOf($0) }) else { break }
                    var siblings: [(element: AXUIElement, value: String)] = []
                    var siblingBudget = 80
                    collectTexts(parent, depth: 0, budget: &siblingBudget, into: &siblings)
                    if siblings.count >= 2 {
                        return extract(from: siblings.map { $0.value }, body: body, isGroup: isGroup)
                    }
                    current = parent
                }
            }
        }
        return nil
    }

    /// The lines of a banner are: [sender,] [group,] message, with a time or the app name sometimes mixed in.
    private static func extract(from values: [String], body: String, isGroup: Bool) -> Names? {
        let target = normalize(body)
        let lines = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                if lower == "now" || lower == "just now" || lower == "whatsapp" { return false }
                if lower.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return false }
                return !matches(normalize(line), target)
            }
        guard let first = lines.first else { return nil }
        if isGroup {
            return Names(sender: first, title: lines.count >= 2 ? lines[1] : nil)
        }
        return Names(sender: first, title: nil)
    }

    private static func matches(_ a: String, _ b: String) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        if a == b { return true }
        // Banners shorten long messages, so compare the start of both.
        let length = min(25, min(a.count, b.count))
        return a.prefix(length) == b.prefix(length) || a.contains(b) || b.contains(a)
    }

    /// Lowercased, without leading emoji or punctuation ("💜 Sent a sticker" -> "sent a sticker").
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = lowered.drop { !($0.isLetter || $0.isNumber) }
        return String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Accessibility helpers

    private static func collectTexts(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int,
        into texts: inout [(element: AXUIElement, value: String)]
    ) {
        guard depth <= 12, budget > 0 else { return }
        budget -= 1
        if string(element, kAXRoleAttribute) == "AXStaticText",
           let value = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute),
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            texts.append((element, value))
        }
        for child in (children(element, kAXChildrenAttribute) ?? []).prefix(40) {
            collectTexts(child, depth: depth + 1, budget: &budget, into: &texts)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func parentOf(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
