import AppKit

/// Actions Claude can take on the Mac. Anything open-ended goes through AppleScript, which the user approves first.
@MainActor
enum MacTools {
    static var definitions: [[String: Any]] {
        [
            tool("open_app", "Open or bring to front a Mac application by name, e.g. \"Safari\", \"Notes\", \"Spotify\".",
                 ["name": string("Application name as shown in /Applications")]),
            tool("open_url", "Open a URL with its default handler (https:, mailto:, maps:, etc.). Use for websites and web searches.",
                 ["url": string("Full URL including the scheme")]),
            tool("set_volume", "Set the Mac's output volume.",
                 ["level": ["type": "integer", "description": "Volume from 0 (mute) to 100"]]),
            tool("get_clipboard", "Read the text currently on the clipboard.", [:]),
            tool("set_clipboard", "Put text on the clipboard.",
                 ["text": string("Text to copy")]),
            tool("play_music", "Play a song, artist or album in Spotify or Apple Music. Put the real title and artist the user most likely meant in query (fix misheard names using what you know, e.g. \"Kesariya Arijit Singh\"). For \"play some music\" with no title, use an empty query.",
                 ["query": string("Song title and artist, e.g. \"Tum Hi Ho Arijit Singh\", or an artist name"),
                  "service": string("\"spotify\", \"apple_music\", \"youtube\", or \"any\" (use any unless the user named one)")]),
            tool("music_control", "Pause, resume, skip to the next or previous track, or say what's playing.",
                 ["action": string("One of: pause, resume, next, previous, nowPlaying")]),
            tool("list_apps", "List the apps that are running and which one is in front.", [:]),
            tool("see_app", "Look at an app's front window: lists its controls as numbered items ([3] button \"Play\") plus visible text. Opens the app if needed. Use this before clicking or typing in any app, and again afterwards to check the result.",
                 ["app": string("App name, e.g. \"Music\", \"Finder\", \"System Settings\", \"WhatsApp\"")]),
            tool("click", "Click a numbered control from the latest see_app result.",
                 ["id": ["type": "integer", "description": "The control's number from see_app"],
                  "double": ["type": "boolean", "description": "Double-click (e.g. to open or play a list row)"]]),
            tool("type_text", "Type text into a control from see_app (or wherever the cursor is), optionally pressing Return after.",
                 ["text": string("The text to type"),
                  "id": ["type": "integer", "description": "Control number from see_app, or 0 for wherever the cursor is"],
                  "submit": ["type": "boolean", "description": "Press Return after typing"]]),
            tool("press_keys", "Press a keyboard shortcut, e.g. \"cmd+t\", \"cmd+shift+n\", \"space\", \"return\", \"escape\".",
                 ["keys": string("The shortcut"),
                  "app": string("App to bring to the front first, or empty for the current app")]),
            tool("choose_menu", "Choose a menu-bar item in an app, e.g. path \"File > New Window\".",
                 ["app": string("App name"), "path": string("Menu path separated by >")]),
            tool("browser_tabs", "List the open tabs (title and address) in a web browser.",
                 ["browser": string("\"Google Chrome\", \"Safari\", \"Brave\", \"Edge\", \"Arc\", or \"any\" for the one in use")]),
            tool("browser_read", "Read the current tab in a web browser: its title, address and page text. Use for questions about the page the user is on.",
                 ["browser": string("Browser name, or \"any\"")]),
            tool("browser_open", "Open a web address in a browser, in a new tab or the current one.",
                 ["url": string("The address"), "browser": string("Browser name, or \"any\""),
                  "new_tab": ["type": "boolean", "description": "Open in a new tab"]]),
            tool("browser_switch_tab", "Switch to a tab listed by browser_tabs.",
                 ["browser": string("Browser name, or \"any\""),
                  "window": ["type": "integer", "description": "Window number from browser_tabs"],
                  "tab": ["type": "integer", "description": "Tab number from browser_tabs"]]),
            tool("browser_close_tab", "Close a tab listed by browser_tabs.",
                 ["browser": string("Browser name, or \"any\""),
                  "window": ["type": "integer", "description": "Window number"],
                  "tab": ["type": "integer", "description": "Tab number"]]),
            tool("remember", "Save a lasting fact or preference about the user so future answers are personalized.",
                 ["fact": string("The fact in third person, e.g. \"Lives in Pune\" or \"Prefers metric units\"")]),
            tool("run_applescript",
                 "Run AppleScript to control Mac apps (Music, Notes, Reminders, Calendar, Mail, Finder, System Events) " +
                 "for anything the other tools can't do. Scripts that delete, send, or run shell commands are shown to the user for approval first.",
                 ["script": string("The AppleScript source"),
                  "summary": string("One plain sentence, shown to the user, describing what the script will do")]),
        ]
    }

    static func statusText(for tool: String) -> String {
        switch tool {
        case "open_app": "Opening an app…"
        case "open_url": "Opening a link…"
        case "set_volume": "Changing the volume…"
        case "get_clipboard", "set_clipboard": "Using the clipboard…"
        case "remember": "Remembering that…"
        case "see_app", "list_apps": "Looking at the app…"
        case "click", "type_text", "press_keys", "choose_menu": "Working in the app…"
        case "browser_tabs", "browser_read": "Reading your browser…"
        case "browser_open", "browser_switch_tab", "browser_close_tab": "Using your browser…"
        case "play_music": "Finding that song…"
        case "music_control": "On it…"
        case "run_applescript": "Working on your Mac…"
        default: "Working…"
        }
    }

    /// Returns the tool output and whether it is an error.
    static func run(_ name: String, input: [String: Any]) async -> (String, Bool) {
        switch name {
        case "open_app":
            guard let app = input["name"] as? String, !app.isEmpty else { return ("Missing app name.", true) }
            return openApp(app)

        case "open_url":
            guard let raw = input["url"] as? String, let url = URL(string: raw), url.scheme != nil else {
                return ("That is not a valid URL.", true)
            }
            return NSWorkspace.shared.open(url) ? ("Opened \(raw).", false) : ("Couldn't open \(raw).", true)

        case "set_volume":
            let level = max(0, min(100, input["level"] as? Int ?? 50))
            return appleScript("set volume output volume \(level)", success: "Volume set to \(level)%.")

        case "get_clipboard":
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            return (text.isEmpty ? "The clipboard has no text." : String(text.prefix(20000)), false)

        case "set_clipboard":
            let text = input["text"] as? String ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ("Copied to the clipboard.", false)

        case "play_music":
            return await MusicPlayer.play(input["query"] as? String ?? "", service: input["service"] as? String ?? "any")

        case "music_control":
            guard let action = MusicAction(rawValue: input["action"] as? String ?? "") else { return ("Unknown music action.", true) }
            return MusicPlayer.control(action)

        case "list_apps":
            return (UIControl.runningApps(), false)
        case "see_app":
            return await UIControl.snapshot(appName: input["app"] as? String ?? "")
        case "click":
            return await UIControl.click(id: Self.int(input["id"]), double: input["double"] as? Bool ?? false)
        case "type_text":
            let id = Self.int(input["id"])
            return await UIControl.type(input["text"] as? String ?? "", into: id == 0 ? nil : id, submit: input["submit"] as? Bool ?? false)
        case "press_keys":
            return await UIControl.pressKeys(input["keys"] as? String ?? "", appName: input["app"] as? String)
        case "choose_menu":
            return await UIControl.clickMenu(appName: input["app"] as? String ?? "", path: input["path"] as? String ?? "")
        case "browser_tabs":
            return BrowserControl.tabs(input["browser"] as? String)
        case "browser_read":
            return await BrowserControl.readPage(input["browser"] as? String)
        case "browser_open":
            return BrowserControl.open(input["url"] as? String ?? "", in: input["browser"] as? String, newTab: input["new_tab"] as? Bool ?? true)
        case "browser_switch_tab":
            return BrowserControl.switchTab(window: max(1, Self.int(input["window"])), tab: max(1, Self.int(input["tab"])), in: input["browser"] as? String)
        case "browser_close_tab":
            return BrowserControl.closeTab(window: max(1, Self.int(input["window"])), tab: max(1, Self.int(input["tab"])), in: input["browser"] as? String)

        case "remember":
            guard let fact = input["fact"] as? String, !fact.isEmpty else { return ("Missing fact.", true) }
            MemoryStore.shared.add(fact)
            return ("Saved.", false)

        case "run_applescript":
            guard let script = input["script"] as? String, !script.isEmpty else { return ("Missing script.", true) }
            let summary = input["summary"] as? String ?? "Run an AppleScript."
            guard !needsConfirmation(script) || confirm(summary: summary, script: script) else {
                return ("The user declined to run this script. Don't retry it; ask what they want instead.", true)
            }
            return appleScript(script, success: "Done.")

        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": Array(properties.keys),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func openApp(_ name: String) -> (String, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("Couldn't open \(name): \(error.localizedDescription)", true)
        }
        if process.terminationStatus == 0 { return ("Opened \(name).", false) }
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ("Couldn't open \(name). \(message)", true)
    }

    static func appleScript(_ source: String, success: String) -> (String, Bool) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return ("AppleScript failed: \(error[NSAppleScript.errorMessage] ?? error)", true)
        }
        if let output = result?.stringValue, !output.isEmpty { return (output, false) }
        return (success, false)
    }

    /// Numbers can arrive as Int or Double from JSON.
    static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 0
    }

    /// Words in a script that mean it could do something hard to undo.
    private static let riskyScriptWords = ["delete", "do shell script", "empty trash", "send", "remove", "erase",
                                           "shut down", "restart", "log out", "move to trash", "purchase", "password"]

    /// Everyday scripts run straight away; only ones that could delete, send, or run shell commands are confirmed.
    static func needsConfirmation(_ script: String) -> Bool {
        guard SettingsStore.shared.askBeforeRisky else { return false }
        let lower = script.lowercased()
        return riskyScriptWords.contains(where: lower.contains)
    }

    static func confirm(summary: String, script: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Saturday wants to do something on your Mac"
        alert.informativeText = "\(summary)\n\n\(script.prefix(1500))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
