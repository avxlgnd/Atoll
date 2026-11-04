//
//  MessagesCallsSettings.swift
//  DynamicIsland
//
//  Settings for messages and calls shown in the notch / island.
//

import AppKit
import Defaults
import SwiftUI

struct MessagesCallsSettings: View {
    @Default(.notchNotificationsMaster) private var master
    @Default(.messageNotificationsEnabled) private var messagesEnabled
    @Default(.whatsAppNotificationsEnabled) private var whatsAppEnabled
    @Default(.phoneCallsInNotch) private var phoneCalls
    @Default(.faceTimeCallsInNotch) private var faceTimeCalls

    @ObservedObject private var messageManager = MessageNotificationManager.shared
    @ObservedObject private var whatsAppManager = WhatsAppNotificationManager.shared
    @ObservedObject private var callMonitor = CallBannerMonitor.shared

    @State private var toolMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show messages and calls in the notch", isOn: $master)
            } footer: {
                Text("The master switch for everything on this page. Banners grow out of the notch (or the Dynamic Island) and macOS's own notifications keep working alongside them. Everything is read on this Mac; nothing is sent anywhere.")
            }

            Section {
                Toggle("Messages (iMessage and SMS)", isOn: $messagesEnabled)
                Toggle("WhatsApp", isOn: $whatsAppEnabled)
                Toggle("iPhone calls (through your Mac)", isOn: $phoneCalls)
                Toggle("FaceTime calls", isOn: $faceTimeCalls)
            } header: {
                Text("Show notifications from")
            } footer: {
                Text("Messages can be answered from the notch. WhatsApp messages can only be opened (WhatsApp has no way to send for you). Calls have Answer and Decline buttons. Turning a source on asks for the permissions it needs.")
            }
            .disabled(!master)

            if master {
                Section {
                    if messagesEnabled {
                        statusRow("Messages", messageManager.status.description)
                    }
                    if whatsAppEnabled {
                        statusRow("WhatsApp", whatsAppManager.statusText)
                    }
                    if phoneCalls || faceTimeCalls {
                        statusRow("Calls", callMonitor.statusText)
                        if !callMonitor.lastScan.isEmpty {
                            statusRow("Last scan", callMonitor.lastScan)
                        }
                        if !callMonitor.lastDetection.isEmpty {
                            statusRow("Last call banner", callMonitor.lastDetection)
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Open Full Disk Access settings") {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                        }
                        Button("Open Accessibility settings") {
                            CallBannerMonitor.requestAccessibility()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                } header: {
                    Text("Status & permissions")
                } footer: {
                    Text("Messages and WhatsApp need Full Disk Access (they read the apps' local databases). Calls need Accessibility (Atoll watches macOS's call banner and presses its Answer and Decline buttons). Contacts and Automation permissions are asked for the first time they are used. After allowing a permission it can take a few seconds to start.")
                }

                Section {
                    Defaults.Toggle(key: .messageBannerInNotch) {
                        Text("Grow banners out of the notch (instead of a separate window)")
                    }
                    Defaults.Toggle(key: .respectFocusMode) {
                        Text("Stay quiet during Focus / Do Not Disturb")
                    }
                    HStack {
                        Text("Focus")
                        Spacer()
                        Text(messageManager.focusDescription.isEmpty ? "Checking…" : messageManager.focusDescription)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("While a Focus is on, messages are silenced completely (the exceptions you set in that Focus are not applied yet). Calls follow your Focus automatically, because macOS only shows a call banner when your Focus allows it. Muted chats are not detected yet.")
                }

                Section {
                    Button("Show a test message") {
                        MessageBannerModel.shared.add([
                            IncomingMessage(
                                id: Int64.random(in: 1_000_000_000...2_000_000_000),
                                chatGUID: "atoll-test-chat",
                                chatName: nil,
                                isGroup: false,
                                senderID: "+15555550123",
                                senderName: "Jamie Chen",
                                senderPhoto: nil,
                                text: "Launch plan is in the shared folder. Ship it! Let me know when you've had a look, I'm around all afternoon.",
                                date: Date(),
                                service: "iMessage",
                                thumbnail: nil
                            )
                        ])
                    }

                    Button("Capture notification layout (15 second countdown)") {
                        NotificationDiagnostics.shared.start { _, message in
                            toolMessage = message
                        }
                    }

                    Button("Copy a WhatsApp database report") {
                        let report = WhatsAppDatabaseReader.diagnosticReport()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        toolMessage = "WhatsApp database report copied to the clipboard (it lists file locations and column names only, no messages)."
                    }

                    if let toolMessage {
                        Text(toolMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("The notification layout capture records how banners look to macOS, so support for an app or a call can be adjusted to your macOS version. Click it, then within 15 seconds receive a WhatsApp message or a call. It saves a text file in ~/Library/Logs/Atoll and copies it to the clipboard, and beeps when it starts and finishes.")
                }
            }
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
