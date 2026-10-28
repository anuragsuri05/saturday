import AppKit
import Combine
import SwiftUI

/// A borderless panel along the right edge of the screen. It doesn't take focus from the app you're in,
/// so Saturday can see what you were doing.
final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class OverlayController {
    let state = OverlayState()
    var openChat: () -> Void = {}

    private let panel = OverlayPanel()
    private let assistant: Assistant
    private let settings = SettingsStore.shared
    private var clickMonitor: Any?
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { state.visible }

    init(assistant: Assistant) {
        self.assistant = assistant
        let view = OverlayView(
            state: state, assistant: assistant, listener: assistant.listener, speaker: assistant.speaker, live: assistant.live,
            onClose: { [weak self] in self?.hide() },
            onOpenChat: { [weak self] in
                self?.hide()
                self?.openChat()
            },
            onHover: { [weak self] inside in
                self?.hovering = inside
                self?.scheduleAutoHide()
            }
        )
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.hide() }

        // Hide a few seconds after Saturday has finished answering and speaking.
        assistant.$phase.combineLatest(assistant.speaker.$isSpeaking, assistant.live.$isActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleAutoHide() }
            .store(in: &cancellables)
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let width: CGFloat = 480
        panel.setFrame(NSRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        state.appearID = UUID()
        state.mounted = true
        // Let the contents appear off-screen first so the slide-in animates.
        DispatchQueue.main.async { [weak self] in self?.state.visible = true }
        hideWork?.cancel()
        installClickMonitor()
    }

    func hide() {
        guard state.visible else { return }
        state.visible = false
        hideWork?.cancel()
        removeClickMonitor()
        assistant.dismissed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.state.visible else { return }
            self.panel.orderOut(nil)
            self.state.mounted = false
        }
    }

    private func scheduleAutoHide() {
        hideWork?.cancel()
        guard state.visible, settings.autoHide, !hovering, !assistant.speaker.isSpeaking, !assistant.live.isActive else { return }
        let delay: TimeInterval
        switch assistant.phase {
        case .done: delay = 12
        case .idle: delay = 6
        default: return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.assistant.speaker.isSpeaking, !self.assistant.live.isActive else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clicking anywhere outside Saturday dismisses it, like Siri.
    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
