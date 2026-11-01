//
//  MessageBannerWindowManager.swift
//  DynamicIsland
//
//  Hosts the Messages banner in its own small, top-centered panel above the notch window.
//

import AppKit
import Combine
import SwiftUI

final class MessageBannerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MessageBannerWindowManager {
    static let shared = MessageBannerWindowManager()

    private var panel: MessageBannerPanel?
    private var hosting: NSHostingView<MessageBannerView>?
    private var cancellable: AnyCancellable?

    // MARK: - Show / hide

    func show() {
        let model = MessageBannerModel.shared
        applyStyle(to: model)
        if panel == nil { createPanel() }

        resizeToFit()
        panel?.orderFrontRegardless()
        // The first layout pass happens after the panel is shown; fit again once it has.
        DispatchQueue.main.async { [weak self] in
            self?.resizeToFit()
            model.isVisible = true
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Lets the reply field receive typing without bringing the whole app forward.
    func makeKey() {
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func targetScreen() -> NSScreen? {
        let name = DynamicIslandViewCoordinator.shared.selectedScreen
        return NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func applyStyle(to model: MessageBannerModel) {
        guard let screen = targetScreen() else { return }
        let name = screen.localizedName
        let island = shouldUseDynamicIslandMode(for: name)
        model.isIsland = island
        // Notch style: text starts below the notch. Island style: a floating card with even padding.
        model.topInset = island ? 18 : getClosedNotchSize(screen: name).height + 8
    }

    func resizeToFit() {
        guard let panel, let hosting, let screen = targetScreen() else { return }
        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 100 || size.height < 40 {
            size = CGSize(width: MessageBannerModel.cardWidth + 28, height: 160)
        }

        let island = MessageBannerModel.shared.isIsland
        let topGap: CGFloat = island ? dynamicIslandTopOffset + 6 : 0
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: (screen.frame.maxY - size.height - topGap).rounded(),
            width: size.width.rounded(.up),
            height: size.height.rounded(.up)
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func createPanel() {
        let panel = MessageBannerPanel(
            contentRect: NSRect(x: 0, y: 0, width: MessageBannerModel.cardWidth + 28, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: MessageBannerView(model: MessageBannerModel.shared))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting

        // Keep the panel the size of its content as the banner changes (reply field, more messages...).
        cancellable = MessageBannerModel.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeToFit() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self?.resizeToFit() }
        }
    }
}
