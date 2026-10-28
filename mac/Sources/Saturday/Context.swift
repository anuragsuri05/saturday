import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What the user was doing when they summoned Saturday, so "this" and "here" mean something.
struct ScreenContext {
    var appName: String?
    var appIcon: NSImage?
    var windowTitle: String?
    var selectedText: String?
}

@MainActor
enum ContextReader {
    /// Reads the frontmost app, and (with Accessibility access) its window title and selected text.
    static func capture() -> ScreenContext {
        var context = ScreenContext()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return context }
        context.appName = app.localizedName
        context.appIcon = app.icon
        guard AXIsProcessTrusted() else { return context }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        if let window = attribute(element, kAXFocusedWindowAttribute) {
            context.windowTitle = stringAttribute(window as! AXUIElement, kAXTitleAttribute)
        }
        if let focused = attribute(element, kAXFocusedUIElementAttribute),
           let selection = stringAttribute(focused as! AXUIElement, kAXSelectedTextAttribute),
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.selectedText = String(selection.prefix(12000))
        }
        return context
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// A JPEG of the display under the mouse, without Saturday's own windows; nil without Screen Recording access.
    /// Tries the capture directly, since macOS's preflight check stays "no" until a relaunch after access is granted.
    static func screenshot() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mouse = NSEvent.mouseLocation
            let screenID = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else { return nil }
            let saturday = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: saturday, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1, 1600 / Double(display.width))
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        } catch {
            return nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
}

/// Opens connections to the AI services when Saturday is summoned, so the first request skips the TLS handshake.
@MainActor
enum Prewarm {
    private static var last = Date.distantPast

    static func run(_ settings: SettingsStore) {
        guard Date().timeIntervalSince(last) > 45 else { return }
        last = Date()
        var hosts: [String] = []
        if settings.isAvailable(.claude) { hosts.append("https://api.anthropic.com/v1/messages") }
        if settings.isAvailable(.openai) { hosts.append("https://api.openai.com/v1/responses") }
        if settings.isAvailable(.gemini) { hosts.append("https://generativelanguage.googleapis.com/v1beta/models") }
        if !settings.elevenLabsKey.isEmpty { hosts.append("https://api.elevenlabs.io/v1/models") }
        for host in hosts {
            var request = URLRequest(url: URL(string: host)!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request).resume()
        }
    }
}
