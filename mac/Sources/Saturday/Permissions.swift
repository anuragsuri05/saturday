import AppKit
import ApplicationServices
import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI

/// Every macOS permission Saturday uses, asked for together once at the start so nothing interrupts later.
/// macOS never lets an app grant itself these, so the ones that live in System Settings (Accessibility,
/// Screen Recording, Full Disk Access) open the right page and are detected the moment they're switched on.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, speech, accessibility, screen, automation, fullDisk
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .speech: "Speech Recognition"
            case .accessibility: "Accessibility"
            case .screen: "Screen Recording"
            case .automation: "App Control"
            case .fullDisk: "Full Disk Access"
            }
        }

        var detail: String {
            switch self {
            case .microphone: "Hear you when you talk"
            case .speech: "Understand every word you say"
            case .accessibility: "Click, type and use any app for you"
            case .screen: "See what's on your screen"
            case .automation: "Control Music, Chrome, Safari, Finder and more"
            case .fullDisk: "Find and read any file you ask about"
            }
        }

        var symbol: String {
            switch self {
            case .microphone: "mic.fill"
            case .speech: "waveform"
            case .accessibility: "hand.tap.fill"
            case .screen: "eye.fill"
            case .automation: "app.connected.to.app.below.fill"
            case .fullDisk: "externaldrive.fill"
            }
        }

        var settingsURL: URL {
            let pane = switch self {
            case .microphone: "Privacy_Microphone"
            case .speech: "Privacy_SpeechRecognition"
            case .accessibility: "Privacy_Accessibility"
            case .screen: "Privacy_ScreenCapture"
            case .automation: "Privacy_Automation"
            case .fullDisk: "Privacy_AllFiles"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }

        /// Full Disk Access is a bonus; the rest are what "do anything" needs.
        var essential: Bool { self != .fullDisk }
    }

    enum Status { case granted, missing, denied }

    /// Apps Saturday drives with Apple Events. Ones that aren't running are opened in the background just long
    /// enough to ask, then closed again.
    private static let automationTargets: [(bundleID: String, launch: Bool)] = [
        ("com.apple.systemevents", true), ("com.apple.finder", true), ("com.apple.Music", true),
        ("com.google.Chrome", true), ("com.apple.Safari", true), ("com.spotify.client", true),
        ("com.brave.Browser", true), ("com.microsoft.edgemac", true), ("company.thebrowser.Browser", true),
        ("com.apple.Notes", true), ("com.apple.reminders", true), ("com.apple.iCal", true),
        ("com.apple.mail", false), ("com.apple.MobileSMS", false), ("com.apple.systempreferences", false),
    ]

    @Published private(set) var statuses: [Kind: Status] = [:]
    @Published private(set) var isGranting = false
    /// Which permission the guided setup is waiting on, so the UI can point at it.
    @Published private(set) var waitingFor: Kind?

    private var timer: Timer?
    private var watchUntil = Date.distantPast
    private var setupWindow: NSWindow?

    private init() { refresh() }

    var allEssentialGranted: Bool { Kind.allCases.filter(\.essential).allSatisfy { statuses[$0] == .granted } }
    var grantedCount: Int { statuses.values.filter { $0 == .granted }.count }

    func status(_ kind: Kind) -> Status { statuses[kind] ?? .missing }

    // MARK: - Checking

    func refresh() {
        var next: [Kind: Status] = [:]
        next[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .missing
        }
        next[.speech] = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .missing
        }
        next[.accessibility] = AXIsProcessTrusted() ? .granted : .missing
        next[.screen] = CGPreflightScreenCaptureAccess() || screenConfirmed ? .granted : .missing
        next[.automation] = automationStatus()
        next[.fullDisk] = Self.hasFullDiskAccess ? .granted : .missing
        if next != statuses {
            statuses = next
            UserDefaults.standard.set(Kind.allCases.map { "\($0.rawValue)=\(next[$0].map { "\($0)" } ?? "?")" }.joined(separator: " "),
                                      forKey: "permissions.check")
        }
        if next[.screen] != .granted, screenAsked { checkScreenLive() }
    }

    /// macOS only updates CGPreflightScreenCaptureAccess for a running app after a relaunch, but asking for the
    /// list of windows succeeds the moment the switch is on, so use that to notice it straight away.
    private var screenConfirmed = false
    /// Only check after the user has been asked, since asking for the window list can itself pop up the prompt.
    private var screenAsked = false
    private var checkingScreen = false

    private func checkScreenLive() {
        guard !checkingScreen, !screenConfirmed else { return }
        checkingScreen = true
        Task {
            let granted = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil
            checkingScreen = false
            if granted {
                screenConfirmed = true
                refresh()
            }
        }
    }

    /// A switch left over from an earlier build of Saturday shows as on in System Settings but doesn't apply to this
    /// one, and macOS won't ask again while it exists. Clearing Saturday's own entry makes a fresh, working one.
    private var repaired: Set<Kind> = []

    private func clearStaleEntry(_ kind: Kind) async {
        let service: String
        switch kind {
        case .accessibility: service = "Accessibility"
        case .screen: service = "ScreenCapture"
        case .fullDisk: service = "SystemPolicyAllFiles"
        default: return
        }
        guard status(kind) != .granted, !repaired.contains(kind),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        repaired.insert(kind)
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }.value
    }

    /// Granted once System Events and every app Saturday asks for up front has said yes (apps that aren't
    /// running can't be checked, so they don't count against it).
    private func automationStatus() -> Status {
        var anyDenied = false
        var anyMissing = false
        var codes: [String] = []
        for target in Self.automationTargets where target.launch && Self.isInstalled(target.bundleID) {
            let code = Self.automationPermission(target.bundleID, ask: false)
            codes.append("\(target.bundleID.split(separator: ".").last ?? "")=\(code)")
            switch code {
            case noErr, OSStatus(procNotFound): continue
            case OSStatus(errAEEventNotPermitted): anyDenied = true
            default: anyMissing = true
            }
        }
        UserDefaults.standard.set(codes.joined(separator: " "), forKey: "permissions.automation")
        return anyDenied ? .denied : anyMissing ? .missing : .granted
    }

    private static var hasFullDiskAccess: Bool {
        let protected = ["/Library/Application Support/com.apple.TCC/TCC.db",
                         NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
        return protected.contains { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            try? handle.close()
            return true
        }
    }

    private static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Asks macOS whether Saturday may send Apple Events to an app; with `ask`, shows the one-time prompt.
    /// Blocks while the prompt is up, so call it off the main thread when asking.
    nonisolated private static func automationPermission(_ bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    // MARK: - Asking

    /// Asks for everything in one go: the pop-up permissions first, then each System Settings switch,
    /// moving on by itself as soon as each one is turned on.
    func grantAll() async {
        guard !isGranting else { return }
        isGranting = true
        startWatching()
        defer {
            isGranting = false
            waitingFor = nil
            refresh()
        }

        if status(.microphone) == .missing {
            waitingFor = .microphone
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if status(.speech) == .missing {
            waitingFor = .speech
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        refresh()

        waitingFor = .automation
        await askForAutomation()
        refresh()

        if status(.accessibility) != .granted {
            waitingFor = .accessibility
            await clearStaleEntry(.accessibility)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSWorkspace.shared.open(Kind.accessibility.settingsURL)
            await waitUntilGranted(.accessibility, timeout: 120)
        }
        if status(.screen) != .granted {
            waitingFor = .screen
            await clearStaleEntry(.screen)
            screenAsked = true
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(Kind.screen.settingsURL) }
            await waitUntilGranted(.screen, timeout: 60)
        }
        // Bring Saturday back to the front once System Settings has done its job.
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// Asks for one permission on its own (from its row's button).
    func request(_ kind: Kind) async {
        switch kind {
        case .microphone where status(kind) == .missing:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech where status(kind) == .missing:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .automation where status(kind) == .missing:
            await askForAutomation()
        case .screen:
            await clearStaleEntry(kind)
            screenAsked = true
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(kind.settingsURL) }
        case .accessibility:
            await clearStaleEntry(kind)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(kind.settingsURL) }
        default:
            await clearStaleEntry(kind)
            NSWorkspace.shared.open(kind.settingsURL)
        }
        startWatching()
        refresh()
    }

    private func askForAutomation() async {
        for target in Self.automationTargets where Self.isInstalled(target.bundleID) {
            let bundleID = target.bundleID
            let current = await Task.detached { Self.automationPermission(bundleID, ask: false) }.value
            guard current != noErr, current != OSStatus(errAEEventNotPermitted) else { continue }

            var launched: NSRunningApplication?
            if current == OSStatus(procNotFound) {
                guard target.launch, let app = await launchHidden(bundleID) else { continue }
                launched = app
            }
            _ = await Task.detached { Self.automationPermission(bundleID, ask: true) }.value
            // Close what Saturday opened just to ask (System Events and Finder keep running as usual).
            if let launched, !["com.apple.systemevents", "com.apple.finder"].contains(bundleID) {
                launched.terminate()
            }
        }
    }

    private func launchHidden(_ bundleID: String) async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return nil }
        // Apple Events need the app to have finished launching.
        for _ in 0..<40 where !app.isFinishedLaunching { try? await Task.sleep(for: .milliseconds(150)) }
        try? await Task.sleep(for: .milliseconds(400))
        return app
    }

    private func waitUntilGranted(_ kind: Kind, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, status(kind) != .granted, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
        }
    }

    /// Re-checks every second while something is pending, so switches flipped in System Settings show up at once.
    func startWatching() {
        watchUntil = Date().addingTimeInterval(600)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                let settled = self.allEssentialGranted && (self.status(.fullDisk) == .granted || self.setupWindow?.isVisible != true)
                if !self.isGranting && (settled || Date() > self.watchUntil) { self.stopWatching() }
            }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Setup window

    /// The "allow everything" window, shown at launch until the essentials are on, and whenever a task needs one.
    func showSetup() {
        refresh()
        if setupWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PermissionsSetupView(permissions: self) { [weak self] in
                self?.setupWindow?.close()
            }))
            window.title = "Set up Saturday"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            setupWindow = window
        }
        startWatching()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}
