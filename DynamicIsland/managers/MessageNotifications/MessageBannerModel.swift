//
//  MessageBannerModel.swift
//  DynamicIsland
//
//  State behind the Messages banner that drops out of the notch / island.
//

import AppKit
import ApplicationServices
import Defaults
import Foundation
import SwiftUI

struct BannerConversation: Identifiable {
    let id: String // chat GUID
    var title: String
    var isGroup: Bool
    var avatarData: Data?
    var messages: [IncomingMessage]
    var source: MessageSource = .messages

    var latest: IncomingMessage? { messages.last }

    /// Replies are sent through the Messages app; other apps can only be opened.
    var canReply: Bool { source == .messages }

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
    @Published var activeCall: IncomingCall?
    @Published var replyingTo: String?
    @Published var replyText = ""
    @Published var isVisible = false
    /// Height of the banner content when it is shown inside the notch (measured by the view).
    @Published var measuredHeight: CGFloat = 130
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

    /// True while there is anything to show (a call, or one or more conversations).
    var hasContent: Bool {
        activeCall != nil || !conversations.isEmpty
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
                    messages: [message],
                    source: message.source
                ), at: 0)
            }
        }
        conversations = Array(conversations.prefix(4))
        presentBanner()
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
        if conversations.isEmpty && activeCall == nil { dismissAll() }
    }

    // MARK: - Calls

    /// Called by the call monitor: a ringing call (nil when the call banner is gone).
    func updateCall(_ call: IncomingCall?) {
        if let call {
            let isNew = activeCall?.key != call.key
            activeCall = call
            if isNew {
                dismissWork?.cancel()
                replyingTo = nil
                presentBanner()
            }
        } else if activeCall != nil {
            activeCall = nil
            if conversations.isEmpty { dismissAll() } else { scheduleDismiss(after: 4) }
        }
    }

    func answerCall() {
        guard let call = activeCall else { return }
        AXUIElementPerformAction(call.accept, kAXPressAction as CFString)
        finishCall()
    }

    func declineCall() {
        guard let call = activeCall else { return }
        AXUIElementPerformAction(call.decline, kAXPressAction as CFString)
        finishCall()
    }

    private func finishCall() {
        activeCall = nil
        if conversations.isEmpty { dismissAll() }
    }

    /// Shows the banner inside the notch / island (it grows out of it), or in its own panel.
    private func presentBanner() {
        if Defaults[.messageBannerInNotch] {
            isVisible = true
            DynamicIslandViewCoordinator.shared.toggleExpandingView(
                status: true,
                type: .messages,
                autoHideDuration: 3600 // dismissal is handled here
            )
        } else {
            Task { @MainActor in
                MessageBannerWindowManager.shared.show()
            }
        }
    }

    // MARK: - Reply

    func beginReply(to chatGUID: String) {
        dismissWork?.cancel()
        replyText = ""
        replyingTo = chatGUID
        Task { @MainActor in
            if Defaults[.messageBannerInNotch] {
                // The reply field lives in the notch window, which has to become the key window to take typing.
                AppDelegate.shared?.focusNotchWindowForTyping()
            } else {
                MessageBannerWindowManager.shared.makeKey()
            }
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

    func openApp(for source: MessageSource) {
        switch source {
        case .messages:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
        case .whatsApp:
            if let url = URL(string: "whatsapp://") { NSWorkspace.shared.open(url) }
        }
        dismissAll()
    }

    // MARK: - Dismiss

    func scheduleDismiss(after seconds: TimeInterval = 7) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, self.replyingTo == nil, self.activeCall == nil else { return }
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
        if Defaults[.messageBannerInNotch] {
            DynamicIslandViewCoordinator.shared.toggleExpandingView(status: false, type: .messages)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.conversations = []
            self.activeCall = nil
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
