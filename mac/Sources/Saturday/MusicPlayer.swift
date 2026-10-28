import AppKit

enum MusicAction: String {
    case pause, resume, next, previous, nowPlaying
}

/// Plays music by name and controls playback in Spotify or Apple Music.
///
/// Finding the song: the brain turns what the user said into a clean "title artist" query (fixing mishearings),
/// then Apple's free iTunes Search API confirms the real song, preferring originals over remixes and covers.
/// Playing it: with Spotify Web API credentials (optional, free) the exact track starts in the Spotify app;
/// otherwise Spotify opens with that song at the top of the search, or Apple Music shows it.
@MainActor
enum MusicPlayer {
    struct Song {
        var title: String
        var artist: String
        var appleURL: URL?
        var display: String { artist.isEmpty ? title : "\(title) by \(artist)" }
    }

    static var spotifyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    // MARK: - Play

    /// `service` is "spotify", "apple_music", "youtube", or "any".
    static func play(_ query: String, service: String) async -> (String, Bool) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["", "music", "some music", "something", "a song", "songs", "my music", "anything"]
        if generic.contains(cleaned.lowercased()) {
            return resumeMusic()
        }

        let song = await resolve(cleaned)
        let search = song.map { "\($0.title) \($0.artist)" } ?? cleaned
        let label = song?.display ?? cleaned

        let choice = service.lowercased() == "any" || service.isEmpty ? SettingsStore.shared.musicApp : service.lowercased()
        switch choice {
        case "youtube":
            return await openYouTube(search, label: label)
        case "spotify" where spotifyInstalled:
            return await playSpotify(search, label: label)
        default:
            return await playAppleMusic(song, search: search, label: label)
        }
    }

    /// Finds the real song with the iTunes Search API, preferring the original version.
    static func resolve(_ query: String) async -> Song? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]],
              !results.isEmpty
        else { return nil }

        let best = results.enumerated().max { score($0.element, query: query, rank: $0.offset) < score($1.element, query: query, rank: $1.offset) }
        guard let item = best?.element, let title = item["trackName"] as? String else { return nil }
        let artist = item["artistName"] as? String ?? ""
        return Song(title: cleanTitle(title), artist: artist, appleURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)))
    }

    /// Higher is better: matching words, the store's own ranking, and no unwanted versions.
    static func score(_ item: [String: Any], query: String, rank: Int) -> Double {
        let title = (item["trackName"] as? String ?? "").lowercased()
        let artist = (item["artistName"] as? String ?? "").lowercased()
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let haystack = Set((title + " " + artist).split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var score = Double(words.intersection(haystack).count) * 2 - Double(rank) * 0.3
        let unwantedVersions = ["remix", "mix", "live", "instrumental", "karaoke", "cover", "reprise", "acoustic", "lofi",
                                "lo-fi", "slowed", "sped", "reverb", "version", "unplugged", "vocals only", "only", "8d", "edit", "flip"]
        // Skip a penalty when the user asked for that kind of version ("remix" also covers "mix").
        for unwanted in unwantedVersions where title.contains(unwanted) && !words.contains(where: { $0.contains(unwanted) }) {
            score -= 3
        }
        return score
    }

    /// "Kesariya (From \"Brahmastra\")" → "Kesariya" for cleaner searching and speaking.
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[](from|feat\.?|ft\.?)[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Spotify

    private static func playSpotify(_ search: String, label: String) async -> (String, Bool) {
        let settings = SettingsStore.shared
        if settings.hasSpotifyAPI, let uri = try? await SpotifyAPI.trackURI(for: search) {
            await ensureRunning(bundleID: "com.spotify.client")
            let (message, failed) = MacTools.appleScript("tell application \"Spotify\" to play track \"\(uri)\"", success: "")
            if !failed { return ("Playing \(label) on Spotify.", false) }
            return ("Spotify couldn't start it: \(message)", true)
        }
        // Without the Spotify API, show the exact song at the top of Spotify's search.
        let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? search
        guard let url = URL(string: "spotify:search:\(encoded)") else { return ("Couldn't open Spotify.", true) }
        NSWorkspace.shared.open(url)
        return ("\(label) is up in Spotify: it's the top result, just press play. (To have it start by itself, add Spotify in Settings → Accounts.)", false)
    }

    // MARK: - Apple Music and YouTube

    private static func playAppleMusic(_ song: Song?, search: String, label: String) async -> (String, Bool) {
        guard let song else { return await openYouTube(search, label: label) }
        let title = escape(song.title)

        // 1. A song in the user's library plays directly.
        let library = """
        tell application "Music"
            set matches to (every track of library playlist 1 whose name contains "\(title)")
            if matches is {} then return "none"
            play item 1 of matches
            return "ok"
        end tell
        """
        let (result, failed) = MacTools.appleScript(library, success: "ok")
        if !failed, result == "ok" { return ("Playing \(label) in Apple Music.", false) }

        // 2. From the Apple Music catalog: open the song in the Music app, then start it.
        guard let web = song.appleURL, let url = URL(string: web.absoluteString.replacingOccurrences(of: "https://", with: "music://")) else {
            return await openYouTube(search, label: label)
        }
        NSWorkspace.shared.open(url)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if await nowPlaying(contains: song.title) { return ("Playing \(label) in Apple Music.", false) }
        // The song's row is highlighted on the page: Return plays it; failing that, double-click the row.
        _ = await UIControl.pressKeys("return", appName: "Music")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if await nowPlaying(contains: song.title) { return ("Playing \(label) in Apple Music.", false) }
        if await UIControl.activateItem(appName: "Music", containing: song.title) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await nowPlaying(contains: song.title) { return ("Playing \(label) in Apple Music.", false) }
        }
        return ("\(label) is open in Apple Music. I couldn't start it by myself (playing catalog songs needs an Apple Music subscription), so press play.", false)
    }

    /// Whether Apple Music is playing a track whose name contains `title`.
    private static func nowPlaying(contains title: String) async -> Bool {
        let script = """
        tell application "Music"
            if player state is playing then return name of current track
            return ""
        end tell
        """
        let (name, failed) = MacTools.appleScript(script, success: "")
        let short = title.lowercased().prefix(12)
        return !failed && name.lowercased().contains(short)
    }

    /// Opens the song itself on YouTube Music, so it starts playing; falls back to the search page.
    private static func openYouTube(_ search: String, label: String) async -> (String, Bool) {
        if let id = await topYouTubeVideo(search), let url = URL(string: "https://music.youtube.com/watch?v=\(id)") {
            NSWorkspace.shared.open(url)
            return ("Playing \(label) on YouTube Music.", false)
        }
        var components = URLComponents(string: "https://music.youtube.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: search)]
        NSWorkspace.shared.open(components.url!)
        return ("\(label) is up on YouTube Music: it's the top result, just press play.", false)
    }

    /// The best video in YouTube's search results for `search`: the original song from an official channel,
    /// not a fan edit, live recording or jukebox.
    private static func topYouTubeVideo(_ search: String) async -> String? {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: search)]
        var request = URLRequest(url: components.url!, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data, as: UTF8.self) as NSString

        let pattern = #""videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})".{0,4000}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)".{0,4000}?"ownerText":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let matches = regex.matches(in: html as String, range: NSRange(location: 0, length: html.length)).prefix(10)
        let videos = matches.enumerated().map { rank, match -> (id: String, score: Double) in
            let title = html.substring(with: match.range(at: 2))
            let channel = html.substring(with: match.range(at: 3))
            var score = Self.score(["trackName": title, "artistName": channel], query: search, rank: rank)
            let lower = (title + " " + channel).lowercased()
            let junk = ["fan made", "jukebox", "nonstop", "non stop", "bts", "#shorts", "reaction", "teaser", "status", "ringtone", "mashup"]
            score -= Double(junk.filter(lower.contains).count) * 3
            let labels = ["t-series", "sony music", "zee music", "think music", "saregama", "tips official", "yrf", "vevo",
                          "- topic", "official", "speed records", "times music", "aditya music", "universal music", "warner"]
            if labels.contains(where: channel.lowercased().contains) { score += 2 }
            return (html.substring(with: match.range(at: 1)), score)
        }
        return videos.max { $0.score < $1.score }?.id
    }

    // MARK: - Controls

    /// Which player to control: one that's running, preferring Spotify.
    private static var activePlayer: String? {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if running.contains("com.spotify.client") { return "Spotify" }
        if running.contains("com.apple.Music") { return "Music" }
        return nil
    }

    static func control(_ action: MusicAction) -> (String, Bool) {
        guard let player = activePlayer else {
            return action == .resume ? resumeMusic() : ("Nothing's playing right now.", false)
        }
        let script: String
        let done: String
        switch action {
        case .pause:
            script = "tell application \"\(player)\" to pause"
            done = "Paused."
        case .resume:
            script = "tell application \"\(player)\" to play"
            done = "Playing."
        case .next:
            script = "tell application \"\(player)\" to next track"
            done = "Skipped."
        case .previous:
            script = "tell application \"\(player)\" to previous track"
            done = "Going back."
        case .nowPlaying:
            script = """
            tell application "\(player)"
                if player state is playing then return (name of current track) & " by " & (artist of current track)
                return ""
            end tell
            """
            done = ""
        }
        let (output, failed) = MacTools.appleScript(script, success: done)
        if failed { return (output, true) }
        if action == .nowPlaying { return (output.isEmpty ? "Nothing's playing right now." : "That's \(output).", false) }
        return (done, false)
    }

    /// "Play music" with no song: resume what was playing, otherwise shuffle the library in the preferred app.
    private static func resumeMusic() -> (String, Bool) {
        let preferred = SettingsStore.shared.musicApp == "spotify" && spotifyInstalled ? "Spotify" : "Music"
        let player = activePlayer ?? preferred
        if player == "Spotify" {
            let (output, failed) = MacTools.appleScript("tell application \"Spotify\" to play", success: "")
            return failed ? (output, true) : ("Playing your music in Spotify.", false)
        }
        let script = """
        tell application "Music"
            if player state is paused then
                play
                return "resumed"
            end if
            if (count of tracks of library playlist 1) = 0 then return "empty"
            set shuffle enabled to true
            play library playlist 1
            return "shuffled"
        end tell
        """
        let (output, failed) = MacTools.appleScript(script, success: "")
        if failed { return (output, true) }
        switch output {
        case "resumed": return ("Resuming your music.", false)
        case "empty":
            NSWorkspace.shared.open(URL(string: "music://music.apple.com/browse")!)
            return ("Your Apple Music library is empty, so I opened Apple Music. Tell me a song or artist and I'll play it.", false)
        default: return ("Shuffling your Apple Music library.", false)
        }
    }

    private static func ensureRunning(bundleID: String) async {
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Give the app a moment to finish launching before it accepts commands.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Spotify Web API search with app credentials (client credentials flow), used only to find a track's ID.
@MainActor
enum SpotifyAPI {
    private static var token: (value: String, expires: Date)?

    static func trackURI(for query: String) async throws -> String? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "market", value: Locale.current.region?.identifier ?? "US"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let tracks = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tracks"] as? [String: Any]
        return ((tracks?["items"] as? [[String: Any]])?.first)?["uri"] as? String
    }

    private static func accessToken() async throws -> String {
        if let token, token.expires > Date() { return token.value }
        let settings = SettingsStore.shared
        let credentials = Data("\(settings.spotifyClientID):\(settings.spotifyClientSecret)".utf8).base64EncodedString()
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = object?["access_token"] as? String else { throw AuthError("Spotify rejected the credentials.") }
        let lifetime = (object?["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        token = (value, Date().addingTimeInterval(lifetime - 60))
        return value
    }
}
