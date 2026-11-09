//
//  NotificationCenterDatabase.swift
//  DynamicIsland
//
//  macOS keeps a record of the notifications it receives (the list in Notification Center), even
//  when the on-screen banner is switched off. For a WhatsApp message that record contains exactly the
//  lines macOS would show: the sender (for example "~Rayan Salman"), the group, and the message.
//  Read-only; needs Full Disk Access.
//

import Foundation
import SQLite3

enum NotificationCenterDatabase {
    private struct Entry {
        let title: String?
        let subtitle: String?
        let body: String?
    }

    /// Looks for a recent WhatsApp notification with this message text and returns its names.
    /// Retries for a moment, since the record can be written a little after WhatsApp's own database.
    static func names(forBody body: String, isGroup: Bool, attempts: Int = 5) -> NotificationBannerLookup.Names? {
        let target = NotificationBannerLookup.normalize(body)
        guard target.count >= 3 else { return nil }

        for attempt in 0..<max(attempts, 1) {
            for entry in recentWhatsAppEntries() {
                guard let entryBody = entry.body,
                      NotificationBannerLookup.matches(NotificationBannerLookup.normalize(entryBody), target)
                else { continue }

                let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let subtitle = entry.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                if isGroup {
                    // Group notifications: title = sender, subtitle = group name.
                    if let title, !title.isEmpty {
                        return NotificationBannerLookup.Names(sender: title, title: subtitle?.isEmpty == false ? subtitle : nil)
                    }
                } else if let title, !title.isEmpty {
                    return NotificationBannerLookup.Names(sender: title, title: nil)
                }
            }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: 0.5) }
        }
        return nil
    }

    // MARK: - Reading the database

    private static func candidatePaths() -> [String] {
        var paths = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        // Older macOS versions keep it under the per-user temporary area: .../T/ -> .../0/
        let temp = (NSTemporaryDirectory() as NSString).deletingLastPathComponent
        let base = (temp as NSString).deletingLastPathComponent
        paths.append(base + "/0/com.apple.notificationcenter/db2/db")
        return paths
    }

    private static func recentWhatsAppEntries(limit: Int = 12) -> [Entry] {
        guard let path = candidatePaths().first(where: { FileManager.default.fileExists(atPath: $0) }) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        let sql = """
        SELECT r.data FROM record r
        JOIN app a ON a.app_id = r.app_id
        WHERE a.identifier LIKE '%whatsapp%'
        ORDER BY r.rec_id DESC LIMIT \(limit)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var entries: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0 else { continue }
            let data = Data(bytes: bytes, count: count)
            if let entry = parse(data) { entries.append(entry) }
        }
        return entries
    }

    /// The stored notification is a property list; its "req" part holds titl / subt / body.
    private static func parse(_ data: Data) -> Entry? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let request = (plist["req"] as? [String: Any]) ?? plist
        let title = request["titl"] as? String
        let subtitle = request["subt"] as? String
        let body = request["body"] as? String
        guard title != nil || body != nil else { return nil }
        return Entry(title: title, subtitle: subtitle, body: body)
    }
}
