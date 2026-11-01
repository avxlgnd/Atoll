//
//  MessagesDatabaseReader.swift
//  DynamicIsland
//
//  Reads incoming messages from the Messages database (~/Library/Messages/chat.db).
//  Needs the Full Disk Access permission. The database is only ever opened read-only.
//

import AppKit
import Foundation
import ImageIO
import SQLite3

struct IncomingMessage: Identifiable {
    let id: Int64
    let chatGUID: String
    let chatName: String?
    let isGroup: Bool
    let senderID: String
    var senderName: String
    var senderPhoto: Data?
    let text: String
    let date: Date
    let service: String
    var thumbnail: NSImage?
}

enum MessagesDatabaseError: Error {
    case accessDenied
    case openFailed(Int32)
    case queryFailed(String)
}

final class MessagesDatabaseReader {
    private var db: OpaquePointer?

    static var databasePath: String {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func open() throws {
        if db != nil { return }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(Self.databasePath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            if rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM {
                throw MessagesDatabaseError.accessDenied
            }
            throw MessagesDatabaseError.openFailed(rc)
        }
        sqlite3_busy_timeout(handle, 300)
        db = handle

        // Opening can succeed while the first query is still refused without Full Disk Access.
        do {
            _ = try latestRowID()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw MessagesDatabaseError.accessDenied
        }
    }

    func latestRowID() throws -> Int64 {
        var result: Int64 = 0
        try query("SELECT IFNULL(MAX(ROWID), 0) FROM message") { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    /// Unread, incoming, plain messages with a ROWID greater than `rowID`.
    func newMessages(after rowID: Int64) throws -> [IncomingMessage] {
        var rows: [(id: Int64, text: String?, body: Data?, date: Int64, isRead: Bool, handle: String?, guid: String?, name: String?, style: Int32, service: String?, hasAttachments: Bool)] = []

        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_read, h.id, c.guid, c.display_name, c.style, m.service, m.cache_has_attachments
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join j ON j.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = j.chat_id
        WHERE m.ROWID > ?1 AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.ROWID ASC
        LIMIT 25
        """
        try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, rowID)
        }, row: { stmt in
            let body: Data? = {
                guard let bytes = sqlite3_column_blob(stmt, 2) else { return nil }
                let count = Int(sqlite3_column_bytes(stmt, 2))
                return count > 0 ? Data(bytes: bytes, count: count) : nil
            }()
            rows.append((
                id: sqlite3_column_int64(stmt, 0),
                text: Self.text(stmt, 1),
                body: body,
                date: sqlite3_column_int64(stmt, 3),
                isRead: sqlite3_column_int(stmt, 4) != 0,
                handle: Self.text(stmt, 5),
                guid: Self.text(stmt, 6),
                name: Self.text(stmt, 7),
                style: sqlite3_column_int(stmt, 8),
                service: Self.text(stmt, 9),
                hasAttachments: sqlite3_column_int(stmt, 10) != 0
            ))
        })

        var messages: [IncomingMessage] = []
        for row in rows where !row.isRead {
            guard let guid = row.guid else { continue }

            var text = row.text ?? ""
            if text.isEmpty, let body = row.body {
                text = Self.decodeAttributedBody(body) ?? ""
            }
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

            var thumbnail: NSImage?
            if row.hasAttachments {
                thumbnail = try firstImageThumbnail(forMessage: row.id)
                if text.isEmpty { text = thumbnail != nil ? "Image" : "Attachment" }
            }
            if text.isEmpty { continue }

            let handle = row.handle ?? "Unknown"
            let name = row.name.flatMap { $0.isEmpty ? nil : $0 }
            messages.append(IncomingMessage(
                id: row.id,
                chatGUID: guid,
                chatName: name,
                isGroup: row.style == 43,
                senderID: handle,
                senderName: handle,
                senderPhoto: nil,
                text: text,
                date: Self.date(fromMessageDate: row.date),
                service: row.service ?? "iMessage",
                thumbnail: thumbnail
            ))
        }
        return messages
    }

    /// Which of the given messages have been read since (for example on the iPhone).
    func readStates(for ids: [Int64]) throws -> [Int64: Bool] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.map(String.init).joined(separator: ",")
        var result: [Int64: Bool] = [:]
        try query("SELECT ROWID, is_read FROM message WHERE ROWID IN (\(list))") { stmt in
            result[sqlite3_column_int64(stmt, 0)] = sqlite3_column_int(stmt, 1) != 0
        }
        return result
    }

    // MARK: - Helpers

    private func firstImageThumbnail(forMessage id: Int64) throws -> NSImage? {
        var path: String?
        let sql = """
        SELECT a.filename FROM message_attachment_join j
        JOIN attachment a ON a.ROWID = j.attachment_id
        WHERE j.message_id = ?1 AND a.mime_type LIKE 'image/%' AND a.filename IS NOT NULL
        LIMIT 1
        """
        try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }, row: { stmt in
            path = Self.text(stmt, 0)
        })
        guard let path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void
    ) throws {
        guard let db else { throw MessagesDatabaseError.accessDenied }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MessagesDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                row(stmt)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw MessagesDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    /// Messages stores dates as nanoseconds (newer systems) or seconds (older) since 2001-01-01.
    private static func date(fromMessageDate raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Newer macOS versions keep the message text only inside the `attributedBody` blob
    /// (an archived NSAttributedString). The plain string follows the "NSString" marker.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count + 6 else { return nil }

        var start: Int?
        var i = 0
        while i <= bytes.count - marker.count {
            if bytes[i] == marker[0], Array(bytes[i..<(i + marker.count)]) == marker {
                start = i
                break
            }
            i += 1
        }
        guard let start else { return nil }

        var index = start + marker.count + 5 // skip the class information that follows the marker
        guard index < bytes.count else { return nil }

        var length = Int(bytes[index])
        index += 1
        if length == 0x81 {
            guard index + 1 < bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        } else if length == 0x82 {
            guard index + 3 < bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8) | (Int(bytes[index + 2]) << 16) | (Int(bytes[index + 3]) << 24)
            index += 4
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(data: Data(bytes[index..<(index + length)]), encoding: .utf8)
    }
}
