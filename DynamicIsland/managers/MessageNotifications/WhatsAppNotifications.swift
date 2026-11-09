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
            for table in ["ZWAMESSAGE", "ZWACHATSESSION", "ZWAGROUPMEMBER", "ZWAMEDIAITEM", "ZWAPROFILEPUSHNAME"] {
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

    private struct QueryPlan {
        let sql: String
        /// Extra columns that may hold a person's name (they are not always where one expects them).
        let extraNameExpressions: [String]
    }

    /// Fixed columns: 0 id, 1 text, 2 type, 3 push name, 4 date, 5 chat jid, 6 partner name,
    /// 7 member contact name, 8 member jid, 9 media path, 10 profile push name,
    /// 11 chat session id, 12 from jid, then the extra name columns.
    private func queryPlan(whereClause: String, order: String, limit: Int) -> QueryPlan {
        let m = columns["ZWAMESSAGE"] ?? []
        let c = columns["ZWACHATSESSION"] ?? []
        let g = columns["ZWAGROUPMEMBER"] ?? []
        let mi = columns["ZWAMEDIAITEM"] ?? []
        let pn = columns["ZWAPROFILEPUSHNAME"] ?? []

        func pick(_ set: Set<String>, _ prefix: String, _ name: String) -> String {
            set.contains(name) ? "\(prefix).\(name)" : "NULL"
        }

        let hasChat = !c.isEmpty && c.contains("Z_PK")
        let hasGroup = !g.isEmpty && g.contains("Z_PK") && m.contains("ZGROUPMEMBER")
        let hasMedia = !mi.isEmpty && mi.contains("Z_PK") && m.contains("ZMEDIAITEM")
        let hasPushNames = hasChat && pn.contains("ZJID") && pn.contains("ZPUSHNAME")

        var extras: [String] = []
        if hasGroup {
            for name in g.sorted() where name.contains("NAME") && name != "ZCONTACTNAME" { extras.append("gm.\(name)") }
        }
        if hasPushNames {
            for name in pn.sorted() where name.contains("NAME") && name != "ZPUSHNAME" { extras.append("pn.\(name)") }
        }

        var select = """
        SELECT m.Z_PK, m.ZTEXT, \(pick(m, "m", "ZMESSAGETYPE")), \(pick(m, "m", "ZPUSHNAME")), \(pick(m, "m", "ZMESSAGEDATE")),
               \(hasChat ? pick(c, "c", "ZCONTACTJID") : "NULL"), \(hasChat ? pick(c, "c", "ZPARTNERNAME") : "NULL"),
               \(hasGroup ? pick(g, "gm", "ZCONTACTNAME") : "NULL"), \(hasGroup ? pick(g, "gm", "ZMEMBERJID") : "NULL"),
               \(hasMedia ? pick(mi, "mi", "ZMEDIALOCALPATH") : "NULL"),
               \(hasPushNames ? "pn.ZPUSHNAME" : "NULL"),
               \(pick(m, "m", "ZCHATSESSION")), \(pick(m, "m", "ZFROMJID"))
        """
        for expression in extras { select += ", \(expression)" }

        var sql = select + "\nFROM ZWAMESSAGE m"
        if hasChat { sql += "\nLEFT JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION" }
        if hasGroup { sql += "\nLEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER" }
        if hasMedia { sql += "\nLEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM" }
        if hasPushNames {
            let sender = hasGroup ? "COALESCE(gm.ZMEMBERJID, c.ZCONTACTJID)" : "c.ZCONTACTJID"
            sql += "\nLEFT JOIN ZWAPROFILEPUSHNAME pn ON pn.ZJID = \(sender)"
        }
        sql += "\nWHERE \(whereClause) ORDER BY \(order) LIMIT \(limit)"
        return QueryPlan(sql: sql, extraNameExpressions: extras)
    }

    func newMessages(after pk: Int64) throws -> [IncomingMessage] {
        let plan = queryPlan(whereClause: "m.Z_PK > ?1 AND m.ZISFROMME = 0", order: "m.Z_PK ASC", limit: 25)

        var messages: [IncomingMessage] = []
        let baseDirectory = path.map { ($0 as NSString).deletingLastPathComponent } ?? ""

        try query(plan.sql, bind: { stmt in
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
            let profilePush = Self.text(stmt, 10)
            let sessionPK: Int64? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 11)
            let fromJID = Self.text(stmt, 12)
            let extraNames = (0..<plan.extraNameExpressions.count).map { Self.text(stmt, Int32(13 + $0)) }

            // Status updates are not messages.
            if chatJID == "status@broadcast" || fromJID == "status@broadcast" { return }

            let isGroup = chatJID?.hasSuffix("@g.us") ?? false
            var thumbnail: NSImage?

            if text.isEmpty {
                switch type {
                case 1: text = "📷 Photo"
                case 2: text = "🎥 Video"
                case 3: text = "🎤 Voice message"
                case 4: text = "👤 Contact"
                case 5: text = "📍 Location"
                case 8: text = "📄 Document"
                case 15: text = "Sent a sticker"
                default: return // system messages and anything else without text
                }
            }
            if type == 1, let mediaPath {
                thumbnail = MessagesDatabaseReader.thumbnail(atPath: baseDirectory + "/Message/" + mediaPath)
                    ?? MessagesDatabaseReader.thumbnail(atPath: mediaPath)
            }

            // Some columns hold encoded identifiers instead of names; those are skipped.
            func clean(_ value: String?) -> String? {
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty, !Self.looksLikeEncodedID(trimmed),
                      !trimmed.allSatisfy({ $0.isNumber || $0 == "+" || $0 == " " })
                else { return nil }
                return trimmed
            }

            let senderJID = isGroup ? (memberJID ?? fromJID) : (chatJID ?? fromJID)
            // People who are not in your contacts are shown like WhatsApp itself does: ~Their Name
            let pushed = (clean(profilePush) ?? clean(pushName) ?? extraNames.compactMap(clean).first).map { "~" + $0 }
            let fallbackLabel = Self.label(forJID: senderJID, isGroupMember: isGroup)

            let title = clean(partnerName) ?? (isGroup ? "Group" : (pushed ?? fallbackLabel))
            let sender: String = isGroup
                ? (clean(memberName) ?? extraNames.compactMap(clean).first ?? pushed ?? fallbackLabel)
                : (clean(partnerName) ?? pushed ?? fallbackLabel)

            // Messages without a chat attached are grouped by who sent them, never lumped together.
            let chatKey = chatJID ?? fromJID ?? sessionPK.map { "session-\($0)" } ?? "unknown"

            messages.append(IncomingMessage(
                id: id,
                chatGUID: "wa:" + chatKey,
                chatName: isGroup ? title : nil,
                isGroup: isGroup,
                senderID: senderJID?.split(separator: "@").first.map(String.init) ?? "WhatsApp",
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

    /// A readable stand-in when WhatsApp has no name for someone: their phone number,
    /// or a plain label for the anonymous "@lid" ids newer WhatsApp versions use.
    static func label(forJID jid: String?, isGroupMember: Bool) -> String {
        guard let jid else { return isGroupMember ? "Group member" : "WhatsApp" }
        if jid.hasSuffix("@lid") { return isGroupMember ? "Group member" : "WhatsApp contact" }
        let number = jid.split(separator: "@").first.map(String.init) ?? ""
        if number.count >= 7, number.allSatisfy({ $0.isNumber }) { return "+" + number }
        return isGroupMember ? "Group member" : "WhatsApp"
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
            for table in ["ZWAMESSAGE", "ZWACHATSESSION", "ZWAGROUPMEMBER", "ZWAMEDIAITEM", "ZWAPROFILEPUSHNAME"] {
                let names = (reader.columns[table] ?? []).sorted().joined(separator: ", ")
                out += "\(table): \(names.isEmpty ? "(missing)" : names)\n"
            }
            out += "Latest message id: \((try? reader.latestPK()) ?? -1)\n"
            out += reader.maskedSamples()
        } catch {
            out += "\nCould not open: \(error)\n"
        }
        return out
    }

    /// True for values such as "EAA=" or "CIyCqNcGIABIAZABAPABAtgCg7KD9JHslwM=": encoded data, not a name.
    static func looksLikeEncodedID(_ value: String) -> Bool {
        guard value.count >= 3, !value.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Names never end in "=" or contain "+" or "/", encoded data often does.
        if value.hasSuffix("=") || value.contains("+") || value.contains("/") { return true }
        return value.count >= 20 && value.contains { $0.isNumber }
    }

    /// The last few incoming messages with every name and id masked (letters become a/A, digits 9),
    /// so the shape of the data can be checked without revealing it.
    func maskedSamples() -> String {
        let plan = queryPlan(whereClause: "m.ZISFROMME = 0", order: "m.Z_PK DESC", limit: 3)
        var out = "\nSample incoming messages (masked):\n"
        let extraLabels = plan.extraNameExpressions
        do {
            var index = 0
            try query(plan.sql, row: { stmt in
                index += 1
                let type = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? "nil" : String(sqlite3_column_int(stmt, 2))
                out += "#\(index) type=\(type)\n"
                let fields: [(String, Int32)] = [
                    ("m.ZPUSHNAME", 3), ("c.ZCONTACTJID", 5), ("c.ZPARTNERNAME", 6),
                    ("gm.ZCONTACTNAME", 7), ("gm.ZMEMBERJID", 8), ("pn.ZPUSHNAME", 10), ("m.ZFROMJID", 12)
                ]
                for (label, column) in fields {
                    out += "  \(label): \(Self.mask(Self.text(stmt, column)))\n"
                }
                for (offset, label) in extraLabels.enumerated() {
                    out += "  \(label): \(Self.mask(Self.text(stmt, Int32(13 + offset))))\n"
                }
            })
        } catch {
            out += "  (could not read samples: \(error))\n"
        }
        return out
    }

    private static func mask(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        func shape(_ text: Substring) -> String {
            String(text.map { character -> Character in
                if character.isNumber { return "9" }
                if character.isLetter { return character.isUppercase ? "A" : "a" }
                return character
            })
        }
        var result = shape(parts[0])
        if parts.count > 1 { result += "@" + parts[1] }
        return "\(result) (\(value.count) chars)"
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
    private var isListening = false
    private var healer: NotificationSelfHealing?
    private var consecutiveFailures = 0

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

        healer = NotificationSelfHealing(
            onSystemEvent: { [weak self] in self?.restart() },
            healthCheck: { [weak self] in self?.ensureRunning() }
        )
    }

    /// Rebuilds the watcher (after wake or unlock), reopening WhatsApp's database.
    private func restart() {
        guard isEnabled else { return }
        retryWork?.cancel()
        isListening = false
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
        guard isEnabled, !isListening else { return }
        start()
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
                NotificationBackgroundActivity.acquire("whatsapp")
                DispatchQueue.main.async { self.isListening = true }
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
        isListening = false
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.reader = nil
        }
        NotificationBackgroundActivity.release("whatsapp")
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
            var messages = try reader.newMessages(after: lastPK)
            if let newest = try? reader.latestPK(), newest > lastPK {
                lastPK = newest
            }

            // Same rule as for Messages: nothing is shown while a Focus is on.
            let focusActive: Bool? = Defaults[.respectFocusMode] ? FocusStatusReader.isFocusActive() : false
            if focusActive == true { messages.removeAll() }

            // When the database has no usable name, read it off the banner macOS shows.
            let placeholders: Set<String> = ["Group member", "WhatsApp contact", "WhatsApp"]
            for index in messages.indices {
                let sender = messages[index].senderName
                guard placeholders.contains(sender) || sender.hasPrefix("+") else { continue }
                // First macOS's stored notification (works with the banner switched off), then the banner itself.
                let found = NotificationCenterDatabase.names(forBody: messages[index].text, isGroup: messages[index].isGroup)
                    ?? NotificationBannerLookup.names(forBody: messages[index].text, isGroup: messages[index].isGroup)
                if let names = found {
                    if let name = names.sender { messages[index].senderName = name }
                    if let title = names.title, messages[index].chatName == "Group" { messages[index].chatName = title }
                }
            }

            consecutiveFailures = 0
            guard !messages.isEmpty else { return }
            let batch = messages
            DispatchQueue.main.async {
                MessageBannerModel.shared.add(batch)
            }
        } catch {
            // Occasional failures are retried on the next tick. If it keeps failing, WhatsApp has
            // probably replaced its database file (for example after it restarted): reconnect.
            consecutiveFailures += 1
            if consecutiveFailures >= 5 {
                consecutiveFailures = 0
                DispatchQueue.main.async { [weak self] in
                    self?.setStatus("Reconnecting…")
                    self?.restart()
                }
            }
        }
    }
}
