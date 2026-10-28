import AppKit
import ApplicationServices

/// Lets Saturday see and operate any app through the macOS Accessibility API (the same one VoiceOver uses):
/// list a window's controls, press buttons, type, choose menu items and press keyboard shortcuts.
/// Requires Accessibility permission for Saturday.
@MainActor
enum UIControl {
    /// Elements from the latest snapshot, so the model can refer to them by number.
    private static var elements: [Int: AXUIElement] = [:]
    private static var snapshotApp: pid_t = 0

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXSearchField", "AXComboBox", "AXLink", "AXTab", "AXSlider", "AXIncrementor", "AXRow", "AXCell",
        "AXDisclosureTriangle", "AXSegmentedControl",
    ]

    /// Words that mean a click could do something hard to undo; those clicks are confirmed first.
    private static let riskyWords = ["delete", "remove", "erase", "send", "buy", "pay", "purchase", "order", "subscribe",
                                     "empty trash", "format", "uninstall", "transfer", "confirm payment", "sign out", "log out"]

    static var permissionMessage: String {
        "Saturday needs Accessibility access to control other apps. Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
    }

    // MARK: - Finding apps

    /// A running app by name, launching it if needed.
    static func app(named name: String) async -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        func find() -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased() == wanted || $0.bundleIdentifier?.lowercased() == wanted
            } ?? NSWorkspace.shared.runningApplications.first {
                ($0.localizedName?.lowercased().contains(wanted) ?? false) && $0.activationPolicy == .regular
            }
        }
        if let running = find() { return running }
        guard MacTools.openApp(name).1 == false else { return nil }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let running = find() { return running }
        }
        return nil
    }

    static func runningApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        return "Frontmost: \(front)\nRunning: " + apps.joined(separator: ", ")
    }

    // MARK: - Seeing a window

    /// Lists the front window's controls (numbered) and visible text, for the model to act on.
    static func snapshot(appName: String) async -> (String, Bool) {
        guard AXIsProcessTrusted() else {
            Permissions.shared.showSetup()
            return (permissionMessage, true)
        }
        guard let app = await app(named: appName) else { return ("Couldn't find or open \(appName).", true) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(root, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement })
                ?? (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first
        else { return ("\(app.localizedName ?? appName) has no open window.", false) }

        elements = [:]
        snapshotApp = app.processIdentifier
        var controls: [String] = []
        var texts: [String] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 2500, controls.count < 180 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            let label = self.label(of: element)
            if actionableRoles.contains(role), !(label.isEmpty && role == "AXCell") {
                let id = elements.count + 1
                elements[id] = element
                var line = "[\(id)] \(role.dropFirst(2).lowercased())"
                if !label.isEmpty { line += " \"\(label.prefix(80))\"" }
                if let value = string(element, kAXValueAttribute), !value.isEmpty, value != label,
                   ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXCheckBox", "AXSlider"].contains(role) {
                    line += " = \"\(value.prefix(60))\""
                }
                controls.append(line)
            } else if role == "AXStaticText", !label.isEmpty, texts.count < 80 {
                texts.append(String(label.prefix(120)))
            }
            if depth < 30, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }

        let title = string(window, kAXTitleAttribute) ?? ""
        var out = "\(app.localizedName ?? appName) — window \"\(title)\"\nControls:\n" + (controls.isEmpty ? "(none found)" : controls.joined(separator: "\n"))
        if !texts.isEmpty { out += "\nVisible text:\n" + texts.joined(separator: "\n") }
        return (out, false)
    }

    // MARK: - Acting

    /// Presses a control from the latest snapshot. Risky-looking controls ask the user first.
    static func click(id: Int, double: Bool) async -> (String, Bool) {
        guard let element = elements[id] else { return ("No control [\(id)] in the latest snapshot. Take a new snapshot first.", true) }
        let label = self.label(of: element)
        if SettingsStore.shared.askBeforeRisky, riskyWords.contains(where: { label.lowercased().contains($0) }),
           !MacTools.confirm(summary: "Click “\(label)” in \(appName(snapshotApp))?", script: "This might be hard to undo.") {
            return ("The user declined that click.", true)
        }
        NSRunningApplication(processIdentifier: snapshotApp)?.activate()
        let role = string(element, kAXRoleAttribute) ?? ""
        if !double, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return ("Clicked \(label.isEmpty ? "[\(id)]" : "“\(label)”").", false)
        }
        // Rows, cells and anything without a press action: click (or double-click) its center.
        guard let center = center(of: element) else { return ("Couldn't click that control.", true) }
        mouseClick(at: center, count: double || role == "AXRow" || role == "AXCell" ? 2 : 1)
        return ("Clicked \(label.isEmpty ? "[\(id)]" : "“\(label)”").", false)
    }

    /// Types text, optionally into a control from the snapshot, optionally pressing Return afterwards.
    static func type(_ text: String, into id: Int?, submit: Bool) async -> (String, Bool) {
        guard AXIsProcessTrusted() else { return (permissionMessage, true) }
        if let id {
            guard let element = elements[id] else { return ("No control [\(id)] in the latest snapshot.", true) }
            NSRunningApplication(processIdentifier: snapshotApp)?.activate()
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        typeText(text)
        if submit { press(keyCode: 36, flags: []) }
        return ("Typed it\(submit ? " and pressed Return" : "").", false)
    }

    /// Presses a shortcut such as "cmd+t", "return", "cmd+shift+n" or "space", optionally in a given app.
    static func pressKeys(_ combo: String, appName: String?) async -> (String, Bool) {
        guard AXIsProcessTrusted() else { return (permissionMessage, true) }
        if let appName, !appName.isEmpty, let app = await app(named: appName) {
            app.activate()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "option", "opt", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return ("I don't know the key in “\(combo)”.", true) }
        press(keyCode: key, flags: flags)
        return ("Pressed \(combo).", false)
    }

    /// Chooses a menu item by path, e.g. "File > New Window", without opening the menu on screen.
    static func clickMenu(appName: String, path: String) async -> (String, Bool) {
        guard AXIsProcessTrusted() else { return (permissionMessage, true) }
        guard let app = await app(named: appName) else { return ("Couldn't find \(appName).", true) }
        let names = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let bar = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) else {
            return ("\(appName) has no menu bar.", true)
        }
        var current = bar as! AXUIElement
        for (index, name) in names.enumerated() {
            var children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? []
            // A menu bar item holds its menu as a single child.
            if children.count == 1, string(children[0], kAXRoleAttribute) == "AXMenu" {
                children = attribute(children[0], kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            guard let match = children.first(where: { (string($0, kAXTitleAttribute) ?? "").lowercased() == name })
                    ?? children.first(where: { (string($0, kAXTitleAttribute) ?? "").lowercased().hasPrefix(name) })
            else { return ("No menu item “\(name)” in \(appName).", true) }
            if index == names.count - 1 {
                app.activate()
                return AXUIElementPerformAction(match, kAXPressAction as CFString) == .success
                    ? ("Chose \(path) in \(appName).", false) : ("Couldn't choose \(path).", true)
            }
            current = match
        }
        return ("Empty menu path.", true)
    }

    /// The visible text of an app's front window (used to read pages and documents).
    static func windowText(appName: String, limit: Int = 15000) async -> String? {
        guard AXIsProcessTrusted(), let app = await app(named: appName) else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(root, kAXFocusedWindowAttribute) else { return nil }
        var text = ""
        var queue: [AXUIElement] = [window as! AXUIElement]
        var visited = 0
        while !queue.isEmpty, visited < 6000, text.count < limit {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == "AXStaticText", let value = string(element, kAXValueAttribute), !value.isEmpty {
                text += value + "\n"
            }
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    /// Finds a list row, cell or button whose text contains `text` in an app's front window and double-clicks it
    /// (how you start a song or open an item in most apps). Returns whether one was found.
    static func activateItem(appName: String, containing text: String) async -> Bool {
        guard AXIsProcessTrusted(), let app = await app(named: appName) else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(root, kAXFocusedWindowAttribute) else { return false }
        let wanted = text.lowercased()
        var queue: [AXUIElement] = [window as! AXUIElement]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if ["AXRow", "AXCell", "AXButton"].contains(role), label(of: element).lowercased().contains(wanted),
               let point = center(of: element) {
                app.activate()
                try? await Task.sleep(nanoseconds: 150_000_000)
                mouseClick(at: point, count: 2)
                return true
            }
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return false
    }

    // MARK: - Low-level helpers

    private static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func label(of element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
            if let value = string(element, name)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        if string(element, kAXRoleAttribute) == "AXStaticText" || string(element, kAXRoleAttribute) == "AXCell" ||
            string(element, kAXRoleAttribute) == "AXRow" {
            if let value = string(element, kAXValueAttribute), !value.isEmpty { return value }
            // Rows and cells take their label from the text inside them.
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let inner = children.prefix(4).compactMap { string($0, kAXValueAttribute) ?? string($0, kAXTitleAttribute) }
            return inner.joined(separator: " · ")
        }
        return ""
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        guard let positionValue = attribute(element, kAXPositionAttribute), let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private static func mouseClick(at point: CGPoint, count: Int) {
        for click in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func press(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func typeText(_ text: String) {
        for chunk in text.chunked(into: 16) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.post(tap: .cghidEventTap)
            }
            usleep(8000)
        }
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "forwarddelete": 117, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "[": 33, "]": 30,
            "-": 27, "=": 24, "`": 50,
        ]
        let letters: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
            ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29), ("o", 31), ("u", 32), ("i", 34), ("p", 35),
            ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (name, code) in letters { map[name] = code }
        return map
    }()
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if current.count == size {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
