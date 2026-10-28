import AppKit
import Combine
import SwiftUI

@main
enum SaturdayMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// The full chat history window, opened from the menu bar or the overlay.
final class ChatWindow: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        self.contentView = contentView
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let assistant = Assistant()
    private let settings = SettingsStore.shared
    private var overlay: OverlayController?
    private var triggers: TriggerManager?
    private var statusItem: NSStatusItem?
    private var chatWindow: ChatWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()
        setUpStatusItem()

        let overlay = OverlayController(assistant: assistant)
        overlay.openChat = { [weak self] in self?.showChat() }
        self.overlay = overlay

        let triggers = TriggerManager { [weak self] in self?.summon() }
        triggers.setExtra(settings.extraTrigger)
        self.triggers = triggers
        settings.$extraTrigger.dropFirst()
            .sink { [weak triggers] extra in triggers?.setExtra(extra) }
            .store(in: &cancellables)

        Task { [assistant] in
            await ChatGPTAccount.shared.loadModels()
            await assistant.checkLiveVoiceWithChatGPT()
            await BrainCheck.runIfRequested()
        }
        setUpOfflineVoice()
        if #available(macOS 26.0, *) {
            // Apple's newer, more accurate speech model for this language (a one-time download by macOS).
            Task.detached(priority: .utility) { await ModernTranscription.prepare() }
        }
        if !settings.onboarded {
            showOnboarding()
        } else if !settings.hasAnyProvider {
            openSettings()
        } else if !settings.permissionsSetUp && !Permissions.shared.allEssentialGranted {
            // Ask for everything once at the start, so Saturday never has to stop and ask mid-task.
            Permissions.shared.showSetup()
        }
        Permissions.shared.$statuses
            .sink { [settings] _ in
                if Permissions.shared.allEssentialGranted && !settings.permissionsSetUp { settings.permissionsSetUp = true }
            }
            .store(in: &cancellables)
    }

    /// The free on-device voice: load it if it's installed, or fetch it once if Saturday has no other natural voice.
    private func setUpOfflineVoice() {
        if LocalVoice.shared.isReady {
            NeuralVoiceEngine.shared.prewarm(settings.localModel)
            Task { await VoiceCheck.run() }
        } else if settings.key(for: .gemini).isEmpty && settings.elevenLabsKey.isEmpty && settings.voiceEngine != .apple {
            LocalVoice.shared.install()
        }
    }

    private func previewVoice() {
        assistant.speaker.speak(settings.voicePersonality.sample)
    }

    private func showOnboarding() {
        let view = OnboardingView(
            settings: settings, account: .shared,
            preview: { [weak self] in self?.previewVoice() },
            openSettings: { [weak self] in self?.openSettings() },
            finish: { [weak self] in
                guard let self else { return }
                self.settings.onboarded = true
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.summon() }
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Saturday"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        summon()
        return true
    }

    /// The shortcut: bring Saturday in from the right and start listening. Pressing it again while
    /// Saturday is showing finishes listening or starts a follow-up.
    @objc func summon() {
        guard let overlay else { return }
        if overlay.isVisible {
            assistant.triggerAgain()
            return
        }
        assistant.captureContext()
        overlay.show()
        if settings.autoListen { assistant.startListening() }
    }

    @objc func showChat() {
        if chatWindow == nil {
            let root = ChatView(assistant: assistant, settings: settings, listener: assistant.listener, account: .shared) { [weak self] in
                self?.openSettings()
            }
            chatWindow = ChatWindow(contentView: NSHostingView(rootView: root))
        }
        NSApp.activate(ignoringOtherApps: true)
        chatWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func newChat() {
        assistant.newChat()
        showChat()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings, account: .shared, memory: .shared,
                testVoice: { [weak self] in self?.previewVoice() },
                retryLivePlan: { [weak self] in
                    guard let assistant = self?.assistant else { return }
                    Task { await assistant.checkLiveVoiceWithChatGPT(force: true) }
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Saturday Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Saturday")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask Saturday (⌥Space)", action: #selector(summon), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Chat History", action: #selector(showChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Saturday", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Menu-bar apps have no menu bar of their own, so add one to make ⌘C, ⌘V, ⌘N, ⌘, and ⌘Q work.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "n").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Saturday", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Saturday", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        NSApp.mainMenu = main
    }
}
