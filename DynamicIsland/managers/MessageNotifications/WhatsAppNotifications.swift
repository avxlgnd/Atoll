//
//  WhatsAppNotifications.swift
//  DynamicIsland
//
//  Shows incoming WhatsApp messages in the notch by watching WhatsApp's own local database
//  (ChatStorage.sqlite). Read-only; needs Full Disk Access. WhatsApp's database format is not
//  documented, so the reader checks which columns exist and reports "unrecognised" instead of guessing.
//

import AppKit
import Combine
import Defaults
import Foundation
import SQLite3

enum WhatsAppDatabaseError: Error {
    case notFound
    case accessDenied
    case unrecognized(String)
    case queryFailed(String)
}

final class WhatsAppDatabaseReader {
    private var db: OpaquePointer?
    private(set) var path: String?
    private var columns: [String: Set<String>] = [:]

    deinit {
        if let db { sqlite3_close(db) }
    }

    static func candidatePaths() -> [String] {
        let home = NSHomeDirectory()
        var paths = ["\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Group Containers") {
            for entry in entries where entry.localizedCaseInsensitiveContains("whatsapp") {
                let candidate = "\(home)/Library/Group Containers/\(entry)/ChatStorage.sqlite"
                if !paths.contains(candidate) { paths.append(candidate) }
            }
        }
        paths.append("\(home)/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Application Support/WhatsApp/ChatStorage.sqlite")
        return paths
    }

    func open() throws {
        if db != nil { return }
        guard let found = Self.candidatePaths().first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw WhatsAppDatabaseError.notFound
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(found, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw WhatsAppDatabaseError.accessDenied
        }
        sqlite3_busy_timeout(handle, 300)
        db = handle
        path = found

        do {
            for table in ["ZWAMESSAGE", "ZWACHATSESSION", "ZWAGROUPMEMBER", "ZWAMEDIAITEM"] {
                columns[table] = try tableColumns(table)
            }
        } catch {
            sqlite3_close(handle)
            db = nil
            throw WhatsAppDatabaseError.accessDenied
        }

        let message = columns["ZWAMESSAGE"] ?? []
        for required in ["Z_PK", "ZTEXT", "ZISFROMME", "ZCHATSESSION"] where !message.contains(required) {
            sqlite3_close(handle)
            db = nil
            throw WhatsAppDatabaseError.unrecognized("missing column \(required)")
        }
    }

    func latestPK() throws -> Int64 {
        var result: Int64 = 0
        try query("SELECT IFNULL(MAX(Z_PK), 0) FROM ZWAMESSAGE") { stmt in
            result = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    func newMessages(after pk: Int64) throws -> [IncomingMessage] {
        let m = columns["ZWAMESSAGE"] ?? []
        let c = columns["ZWACHATSESSION"] ?? []
        let g = columns["ZWAGROUPMEMBER"] ?? []
        let mi = columns["ZWAMEDIAITEM"] ?? []

        func pick(_ set: Set<String>, _ prefix: String, _ name: String) -> String {
            set.contains(name) ? "\(prefix).\(name)" : "NULL"
        }

        let hasChat = !c.isEmpty && c.contains("Z_PK")
        let hasGroup = !g.isEmpty && g.contains("Z_PK") && m.contains("ZGROUPMEMBER")
        let hasMedia = !mi.isEmpty && mi.contains("Z_PK") && m.contains("ZMEDIAITEM")

        var sql = """
        SELECT m.Z_PK, m.ZTEXT, \(pick(m, "m", "ZMESSAGETYPE")), \(pick(m, "m", "ZPUSHNAME")), \(pick(m, "m", "ZMESSAGEDATE")),
               \(hasChat ? pick(c, "c", "ZCONTACTJID") : "NULL"), \(hasChat ? pick(c, "c", "ZPARTNERNAME") : "NULL"),
               \(hasGroup ? pick(g, "gm", "ZCONTACTNAME") : "NULL"), \(hasGroup ? pick(g, "gm", "ZMEMBERJID") : "NULL"),
               \(hasMedia ? pick(mi, "mi", "ZMEDIALOCALPATH") : "NULL")
        FROM ZWAMESSAGE m
        """
        if hasChat { sql += "\nLEFT JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION" }
        if hasGroup { sql += "\nLEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER" }
        if hasMedia { sql += "\nLEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM" }
        sql += "\nWHERE m.Z_PK > ?1 AND m.ZISFROMME = 0 ORDER BY m.Z_PK ASC LIMIT 25"

        var messages: [IncomingMessage] = []
        let baseDirectory = path.map { ($0 as NSString).deletingLastPathComponent } ?? ""

        try query(sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, pk)
        }, row: { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            var text = Self.text(stmt, 1) ?? ""
            let type = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? -1 : Int(sqlite3_column_int(stmt, 2))
            let pushName = Self.text(stmt, 3)
            let rawDate = sqlite3_column_double(stmt, 4)
            let chatJID = Self.text(stmt, 5)
            let partnerName = Self.text(stmt, 6)
            let memberName = Self.text(stmt, 7)
            let memberJID = Self.text(stmt, 8)
            let mediaPath = Self.text(stmt, 9)

            let isGroup = chatJID?.hasSuffix("@g.us") ?? false
            var thumbnail: NSImage?

            if text.isEmpty {
                switch type {
                case 1: text = "Photo"
                case 2: text = "Video"
                case 3: text = "Voice message"
                case 4: text = "Contact"
                case 5: text = "Location"
                case 8: text = "Document"
                case 15: text = "Sticker"
                default: return // system messages and anything else without text
                }
            }
            if type == 1, let mediaPath {
                thumbnail = MessagesDatabaseReader.thumbnail(atPath: baseDirectory + "/Message/" + mediaPath)
                    ?? MessagesDatabaseReader.thumbnail(atPath: mediaPath)
            }

            let phone = (isGroup ? memberJID : chatJID)?.split(separator: "@").first.map(String.init) ?? "WhatsApp"
            let title = partnerName?.isEmpty == false ? partnerName! : (chatJID?.split(separator: "@").first.map(String.init) ?? "WhatsApp")
            let sender: String = {
                if isGroup { return memberName?.isEmpty == false ? memberName! : (pushName?.isEmpty == false ? pushName! : phone) }
                return partnerName?.isEmpty == false ? partnerName! : (pushName?.isEmpty == false ? pushName! : phone)
            }()

            messages.append(IncomingMessage(
                id: id,
                chatGUID: "wa:" + (chatJID ?? "unknown"),
                chatName: isGroup ? title : nil,
                isGroup: isGroup,
                senderID: phone,
                senderName: sender,
                senderPhoto: nil,
                text: text,
                date: Date(timeIntervalSinceReferenceDate: rawDate),
                service: "WhatsApp",
                thumbnail: thumbnail,
                source: .whatsApp
            ))
        })
        return messages
    }

    // MARK: - Diagnostics

    /// A description of what was found (no message contents), for troubleshooting.
    static func diagnosticReport() -> String {
        var out = "WhatsApp database check\n"
        for path in candidatePaths() {
            let exists = FileManager.default.fileExists(atPath: path)
            out += "\(path): \(exists ? "exists" : "not found")\n"
        }
        let reader = WhatsAppDatabaseReader()
        do {
            try reader.open()
            out += "\nOpened: \(reader.path ?? "?")\n"
            for table in ["ZWAMESSAGE", "ZWACHATSESSION", "ZWAGROUPMEMBER", "ZWAMEDIAITEM"] {
                let names = (reader.columns[table] ?? []).sorted().joined(separator: ", ")
                out += "\(table): \(names.isEmpty ? "(missing)" : names)\n"
            }
            out += "Latest message id: \((try? reader.latestPK()) ?? -1)\n"
        } catch {
            out += "\nCould not open: \(error)\n"
        }
        return out
    }

    // MARK: - SQLite helpers

    private func tableColumns(_ table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { stmt in
            if let name = Self.text(stmt, 1) { names.insert(name) }
        }
        return names
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void
    ) throws {
        guard let db else { throw WhatsAppDatabaseError.accessDenied }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WhatsAppDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
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
                throw WhatsAppDatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}

final class WhatsAppNotificationManager: ObservableObject {
    static let shared = WhatsAppNotificationManager()

    @Published private(set) var statusText = "Off"

    private let queue = DispatchQueue(label: "atoll.whatsapp.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var reader: WhatsAppDatabaseReader?
    private var lastPK: Int64 = 0
    private var retryWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var isEnabled = false

    func configure() {
        Publishers.CombineLatest(
            Defaults.publisher(.notchNotificationsMaster).map { $0.newValue },
            Defaults.publisher(.whatsAppNotificationsEnabled).map { $0.newValue }
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
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            if self?.statusText != text { self?.statusText = text }
        }
    }

    private func start() {
        guard timer == nil else { return }
        retryWork?.cancel()
        setStatus("Starting…")

        queue.async { [weak self] in
            guard let self else { return }
            let reader = WhatsAppDatabaseReader()
            do {
                try reader.open()
                let last = try reader.latestPK()
                self.reader = reader
                self.lastPK = last
                self.beginTimer()
                self.setStatus("Listening for new messages")
            } catch WhatsAppDatabaseError.notFound {
                self.setStatus("WhatsApp's database was not found. Allow Full Disk Access, and make sure the WhatsApp Mac app is installed and signed in.")
                self.scheduleRetry()
            } catch WhatsAppDatabaseError.accessDenied {
                self.setStatus("Waiting for Full Disk Access")
                self.scheduleRetry()
            } catch WhatsAppDatabaseError.unrecognized(let reason) {
                self.setStatus("WhatsApp's database format is not recognised (\(reason))")
                self.scheduleRetry(after: 30)
            } catch {
                self.setStatus("Problem: \(error)")
                self.scheduleRetry()
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
        setStatus("Off")
    }

    private func scheduleRetry(after seconds: TimeInterval = 5) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            self.start()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

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
            var messages = try reader.newMessages(after: lastPK)
            if let newest = try? reader.latestPK(), newest > lastPK {
                lastPK = newest
            }

            // Same rule as for Messages: nothing is shown while a Focus is on.
            let focusActive: Bool? = Defaults[.respectFocusMode] ? FocusStatusReader.isFocusActive() : false
            if focusActive == true { messages.removeAll() }

            guard !messages.isEmpty else { return }
            let batch = messages
            DispatchQueue.main.async {
                MessageBannerModel.shared.add(batch)
            }
        } catch {
            // Transient failures (the database being busy) are retried on the next tick.
        }
    }
}
