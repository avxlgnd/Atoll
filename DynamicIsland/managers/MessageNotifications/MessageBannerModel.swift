//
//  MessageBannerModel.swift
//  DynamicIsland
//
//  State behind the Messages banner that drops out of the notch / island.
//

import AppKit
import Foundation
import SwiftUI

struct BannerConversation: Identifiable {
    let id: String // chat GUID
    var title: String
    var isGroup: Bool
    var avatarData: Data?
    var messages: [IncomingMessage]

    var latest: IncomingMessage? { messages.last }

    var initials: String {
        let words = title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.filter { $0.isLetter }
        return String(letters).uppercased()
    }

    /// For group chats the text is prefixed with the sender's first name.
    func displayText(for message: IncomingMessage) -> String {
        guard isGroup else { return message.text }
        let first = message.senderName.split(separator: " ").first.map(String.init) ?? message.senderName
        return "\(first): \(message.text)"
    }
}

final class MessageBannerModel: ObservableObject {
    static let shared = MessageBannerModel()
    static let cardWidth: CGFloat = 420

    @Published var conversations: [BannerConversation] = [] {
        didSet { MessageNotificationManager.shared.updateTracked(trackedIDs) }
    }
    @Published var replyingTo: String?
    @Published var replyText = ""
    @Published var isVisible = false
    @Published var isIsland = false
    @Published var topInset: CGFloat = 16
    @Published var isHovering = false {
        didSet {
            if oldValue != isHovering, !isHovering { scheduleDismiss(after: 3) }
        }
    }

    private var dismissWork: DispatchWorkItem?

    var trackedIDs: [Int64] {
        conversations.flatMap { $0.messages.map(\.id) }
    }

    func conversation(_ id: String) -> BannerConversation? {
        conversations.first { $0.id == id }
    }

    // MARK: - Incoming

    func add(_ incoming: [IncomingMessage]) {
        guard !incoming.isEmpty else { return }
        for message in incoming {
            let title = message.chatName ?? (message.isGroup ? "Group" : message.senderName)
            if let index = conversations.firstIndex(where: { $0.id == message.chatGUID }) {
                var convo = conversations.remove(at: index)
                convo.messages.append(message)
                convo.messages = Array(convo.messages.suffix(6))
                if convo.avatarData == nil { convo.avatarData = message.senderPhoto }
                conversations.insert(convo, at: 0)
            } else {
                conversations.insert(BannerConversation(
                    id: message.chatGUID,
                    title: title,
                    isGroup: message.isGroup,
                    avatarData: message.isGroup ? nil : message.senderPhoto,
                    messages: [message]
                ), at: 0)
            }
        }
        conversations = Array(conversations.prefix(4))
        Task { @MainActor in
            MessageBannerWindowManager.shared.show()
        }
        scheduleDismiss()
    }

    /// Messages that were read somewhere else (for example on the iPhone) disappear from the banner.
    func remove(readIDs: Set<Int64>) {
        guard !readIDs.isEmpty else { return }
        for index in conversations.indices {
            conversations[index].messages.removeAll { readIDs.contains($0.id) }
        }
        conversations.removeAll { $0.messages.isEmpty }
        if let replying = replyingTo, conversation(replying) == nil { replyingTo = nil }
        if conversations.isEmpty { dismissAll() }
    }

    // MARK: - Reply

    func beginReply(to chatGUID: String) {
        dismissWork?.cancel()
        replyText = ""
        replyingTo = chatGUID
        Task { @MainActor in
            MessageBannerWindowManager.shared.makeKey()
        }
    }

    func cancelReply() {
        replyingTo = nil
        replyText = ""
        scheduleDismiss(after: 3)
    }

    func sendReply() {
        guard let guid = replyingTo else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        MessageSender.send(text: text, toChatGUID: guid)
        conversations.removeAll { $0.id == guid }
        replyingTo = nil
        replyText = ""
        if conversations.isEmpty { dismissAll() } else { scheduleDismiss(after: 4) }
    }

    func openMessagesApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
        dismissAll()
    }

    // MARK: - Dismiss

    func scheduleDismiss(after seconds: TimeInterval = 7) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, self.replyingTo == nil else { return }
            self.dismissAll()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissAll() {
        dismissWork?.cancel()
        withAnimation(.easeIn(duration: 0.28)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.conversations = []
            self.replyingTo = nil
            self.replyText = ""
            self.isHovering = false
            Task { @MainActor in
                MessageBannerWindowManager.shared.hide()
            }
        }
    }
}

/// Sends a reply through the Messages app (needs the Automation permission the first time).
enum MessageSender {
    static func send(text: String, toChatGUID guid: String) {
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        let source = """
        tell application "Messages"
            set targetChat to a reference to chat id "\(escape(guid))"
            send "\(escape(text))" to targetChat
        end tell
        """
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                print("MessageSender: AppleScript failed: \(error)")
            }
        }
    }
}
