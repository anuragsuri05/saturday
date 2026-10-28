import AppKit

/// Simple Mac commands Saturday handles on-device, instantly, with no account or model needed.
enum LocalCommand {
    case openApp(String)
    case openURL(URL)
    case volume(Int)
    case mute(Bool)
    case webSearch(String)
    case remember(String)
    case forget(String)
    case listMemories
    case music(MusicAction)
    case darkMode(Bool)
}

@MainActor
enum LocalCommands {
    private static let volumePattern = try! Regex(#"(?:set |turn |change )?(?:the )?(?:volume|sound)(?: level)? (?:to |at )?(\d{1,3})(?: ?%| percent)?"#)
    private static let domainPattern = try! Regex(#"[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?"#)

    static func match(_ text: String) -> LocalCommand? {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, "?!.".contains(last) { t.removeLast() }
        for filler in ["hey saturday, ", "hey saturday ", "saturday, ", "please ", "can you ", "could you "] where t.hasPrefix(filler) {
            t.removeFirst(filler.count)
        }

        switch t {
        case "mute", "mute the volume", "mute the sound": return .mute(true)
        case "unmute", "unmute the volume", "unmute the sound": return .mute(false)
        case "what do you remember about me", "what do you know about me", "show my memories", "what have you remembered":
            return .listMemories
        case "turn on dark mode", "dark mode", "dark mode on", "switch to dark mode", "enable dark mode", "turn off light mode":
            return .darkMode(true)
        case "turn off dark mode", "light mode", "light mode on", "switch to light mode", "enable light mode", "disable dark mode":
            return .darkMode(false)
        case "pause", "pause music", "pause the music", "pause the song", "stop music", "stop the music", "stop the song":
            return .music(.pause)
        case "resume", "resume music", "resume the music", "continue the music", "unpause", "play music", "play some music", "play my music":
            return .music(.resume)
        case "next", "next song", "next track", "skip", "skip this", "skip this song", "skip song", "play the next song":
            return .music(.next)
        case "previous song", "previous track", "last song", "go back a song", "play the previous song":
            return .music(.previous)
        case "what's playing", "what is playing", "what song is this", "what's this song", "which song is this":
            return .music(.nowPlaying)
        default: break
        }

        for prefix in ["remember that ", "remember my ", "remember i ", "note that i "] where t.hasPrefix(prefix) {
            // Keep the user's capitalization (names, places) from the original text.
            var fact = text.range(of: prefix, options: .caseInsensitive).map { String(text[$0.upperBound...]) }
                ?? String(t.dropFirst(prefix.count))
            fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix == "remember my " { fact = "User's " + fact }
            if prefix == "remember i " || prefix == "note that i " { fact = "User " + fact }
            return .remember(fact)
        }
        for prefix in ["forget that ", "forget about ", "forget "] where t.hasPrefix(prefix) && t.count > prefix.count + 2 {
            return .forget(String(t.dropFirst(prefix.count)))
        }

        if let match = t.wholeMatch(of: volumePattern), let level = Int(match.output[1].substring ?? "") {
            return .volume(min(level, 100))
        }

        for prefix in ["search the web for ", "search google for ", "google ", "search for "] where t.hasPrefix(prefix) {
            let query = String(t.dropFirst(prefix.count))
            if !query.isEmpty { return .webSearch(query) }
        }

        for prefix in ["open ", "launch ", "start "] where t.hasPrefix(prefix) {
            var target = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("the ") { target.removeFirst(4) }
            if target.hasSuffix(" app") { target.removeLast(4) }
            if let url = website(target) { return .openURL(url) }
            if let app = installedApp(named: target) { return .openApp(app) }
        }
        return nil
    }

    static func run(_ command: LocalCommand) -> String {
        switch command {
        case .openApp(let name):
            let (message, failed) = MacTools.openApp(name)
            return failed ? message : "Opening \(name)."
        case .openURL(let url):
            return NSWorkspace.shared.open(url) ? "Opening \(url.host ?? url.absoluteString)." : "I couldn't open \(url.absoluteString)."
        case .volume(let level):
            let (message, failed) = MacTools.appleScript("set volume output volume \(level)", success: "")
            return failed ? message : "Volume set to \(level)%."
        case .mute(let on):
            let (message, failed) = MacTools.appleScript("set volume \(on ? "with" : "without") output muted", success: "")
            return failed ? message : (on ? "Muted." : "Unmuted.")
        case .webSearch(let query):
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            NSWorkspace.shared.open(components.url!)
            return "Searching the web for “\(query)”."
        case .remember(let fact):
            MemoryStore.shared.add(fact)
            return "Got it. I'll remember that."
        case .forget(let query):
            let removed = MemoryStore.shared.forget(matching: query)
            return removed > 0 ? "Done, I've forgotten that." : "I didn't have anything saved about that."
        case .darkMode(let on):
            let (message, failed) = MacTools.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)", success: "")
            return failed ? message : (on ? "Dark mode is on." : "Light mode is on.")
        case .music(let action):
            return MusicPlayer.control(action).0
        case .listMemories:
            let items = MemoryStore.shared.items
            guard !items.isEmpty else { return "I haven't saved anything about you yet. Tell me things like “remember that I'm vegetarian”." }
            return "Here's what I remember about you.\n\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
        }
    }

    /// "apple.com" or "https://…" → URL. Plain words aren't treated as websites.
    private static func website(_ target: String) -> URL? {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return URL(string: target) }
        guard !target.contains(" "), target.wholeMatch(of: domainPattern) != nil else { return nil }
        return URL(string: "https://" + target)
    }

    static var installedAppNames: [String] { appNames }

    private static var appNames: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", "\(home)/Applications"]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }
    }()

    private static func installedApp(named target: String) -> String? {
        appNames.first { $0.lowercased() == target }
    }
}
