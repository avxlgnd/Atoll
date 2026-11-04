//
//  MessageBannerView.swift
//  DynamicIsland
//
//  The banner that drops out of the notch / island when a message arrives:
//  a compact card, a list for several conversations, and an inline reply field.
//

import AppKit
import SwiftUI

/// The banner content without any background. It is drawn inside the notch / island itself
/// (which provides the black surface and shape), or wrapped by `MessageBannerView` in a panel.
struct MessageBannerContent: View {
    @ObservedObject var model: MessageBannerModel
    var topInset: CGFloat
    var reportsHeight = false
    @FocusState private var replyFocused: Bool

    var body: some View {
        content
            .padding(.top, topInset)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
            .frame(width: MessageBannerModel.cardWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(heightReader)
            .onHover { model.isHovering = $0 }
    }

    @ViewBuilder
    private var heightReader: some View {
        if reportsHeight {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { report(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in report(height) }
            }
        }
    }

    private func report(_ height: CGFloat) {
        Task { @MainActor in
            if abs(model.measuredHeight - height) > 0.5 {
                model.measuredHeight = height
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let call = model.activeCall {
            callView(call)
        } else if let guid = model.replyingTo, let convo = model.conversation(guid) {
            replyView(convo)
        } else if model.conversations.count == 1, let convo = model.conversations.first {
            row(convo, large: true)
        } else {
            VStack(spacing: 12) {
                ForEach(model.conversations) { convo in
                    row(convo, large: false)
                    if convo.id != model.conversations.last?.id {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func row(_ convo: BannerConversation, large: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MessageAvatar(convo: convo, size: large ? 50 : 44)

            VStack(alignment: .leading, spacing: 3) {
                if convo.source == .whatsApp, convo.isGroup, let latest = convo.latest {
                    Text(latest.senderName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(convo.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let latest = convo.latest {
                    Text(convo.displayText(for: latest))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .lineLimit(large ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.openApp(for: convo.source) }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    if convo.messages.count > 1 {
                        Text("\(convo.messages.count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Color.red, in: Circle())
                    }
                    Text(timeText(convo.latest?.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                HStack(spacing: 8) {
                    if let thumbnail = convo.latest?.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Button {
                        if convo.canReply {
                            model.beginReply(to: convo.id)
                        } else {
                            model.openApp(for: convo.source)
                        }
                    } label: {
                        Image(systemName: convo.canReply ? "arrowshape.turn.up.left.fill" : "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Calls

    private func callView(_ call: IncomingCall) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.66), Color(white: 0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if call.initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text(call.initials)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())

                Image(systemName: call.isFaceTime ? "video.fill" : "phone.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Color.green, in: Circle())
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(call.kindLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(call.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                model.declineCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.96, green: 0.27, blue: 0.22), in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                model.answerCall()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.2, green: 0.78, blue: 0.35), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Reply

    private func replyView(_ convo: BannerConversation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MessageAvatar(convo: convo, size: 44)
                Text(convo.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(timeText(convo.latest?.date))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(convo.messages.suffix(2)) { message in
                    VStack(alignment: .leading, spacing: 6) {
                        if let thumbnail = message.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 150, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        if message.text != "Image" || message.thumbnail == nil {
                            Text(convo.displayText(for: message))
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.cancelReply()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)

                TextField("Message", text: $model.replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($replyFocused)
                    .onSubmit { model.sendReply() }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))

                Button {
                    model.sendReply()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            // Give the panel a moment to become the key window before asking for focus.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                replyFocused = true
            }
        }
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "now" }
        if Date().timeIntervalSince(date) < 90 { return "now" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The banner in its own panel (used when "inside the notch" is turned off).
struct MessageBannerView: View {
    @ObservedObject var model: MessageBannerModel

    private var shape: AnyShape {
        if model.isIsland {
            return AnyShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        }
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 32,
            bottomTrailingRadius: 32,
            topTrailingRadius: 0,
            style: .continuous
        ))
    }

    var body: some View {
        MessageBannerContent(model: model, topInset: model.topInset)
            .background(Color.black)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .padding(.horizontal, 14)
            .padding(.bottom, 26)
            .offset(y: model.isVisible ? 0 : -300)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: model.isVisible)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.replyingTo)
    }
}

struct MessageAvatar: View {
    let convo: BannerConversation
    var size: CGFloat = 48

    var body: some View {
        if convo.source == .whatsApp, let icon = WhatsAppAppIcon.image {
            // Like the macOS banner: WhatsApp's own app icon.
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            standardAvatar
        }
    }

    private var standardAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            avatar
                .frame(width: size, height: size)
                .clipShape(Circle())

            Image(systemName: convo.source == .whatsApp ? "phone.bubble.fill" : "message.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(convo.source == .whatsApp ? Color(red: 0.15, green: 0.8, blue: 0.4) : Color.green, in: Circle())
                .overlay(Circle().stroke(Color.black, lineWidth: 2))
                .offset(x: 4, y: 4)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let data = convo.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.66), Color(white: 0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if convo.isGroup {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                } else if convo.initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(convo.initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// WhatsApp's app icon, looked up from the installed app.
enum WhatsAppAppIcon {
    static let image: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()
}
