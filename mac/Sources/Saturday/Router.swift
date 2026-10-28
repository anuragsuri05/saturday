import Foundation

struct Route {
    enum Kind { case local, chat, agent, council }

    var kind: Kind
    var provider: Provider
    var model: String
    var effort = "medium"
    var grounded = false
    var reason: String
    var command: LocalCommand?

    /// A Saturday-branded tag for the answer card. Which model answered is never shown.
    var label: String {
        switch kind {
        case .local: return "Done on your Mac"
        case .council: return "Deep Think"
        case .agent: return grounded ? "Searched the web" : "Done on your Mac"
        case .chat:
            if grounded { return "Searched the web" }
            switch reason {
            case "quick answer": return "Quick answer"
            case "deep reasoning", "genius mode": return "Deep thinking"
            case "creative": return "Creative"
            case "your screen": return "Looked at your screen"
            case "your selection": return "Read your selection"
            default: return "Saturday"
            }
        }
    }

    var statusText: String {
        switch kind {
        case .local: "On it…"
        case .council: "Thinking really hard…"
        case .agent: grounded ? "Searching the web…" : "Working on your Mac…"
        case .chat: grounded ? "Searching the web…" : "Thinking…"
        }
    }
}

/// Picks the best model for each request with quick keyword checks, so routing adds no extra API call.
/// Each kind of request has a preference order, and Saturday uses the first provider you've connected.
@MainActor
enum Router {
    private static let macActionPrefixes = ["open ", "launch ", "quit ", "close ", "play ", "pause ", "mute", "unmute", "set a timer", "set an alarm"]
    private static let macActionPhrases = [
        "volume", "dark mode", "light mode", "clipboard", "remind me", "reminder", "new note", "create a note",
        "add a note", "on my mac", "next song", "previous song", "empty the trash", "send an email", "send email",
        "calendar event", "add to my calendar", "set a timer", "in finder", "copy this", "paste", "my calendar",
        "my reminders", "music app", "spotify",
    ]
    private static let realtimePhrases = [
        "today", "tonight", "tomorrow", "yesterday", "latest", "news", "weather", "forecast", "price of", "stock",
        "score", "right now", "currently", "this week", "this month", "who won", "election", "release date",
        "near me", "trending", "2026", "2027", "live ", "open now", "flight", "traffic",
    ]
    private static let deepPhrases = [
        "code", "function", "bug", "debug", "error", "swift", "python", "javascript", "typescript", "kotlin", "java",
        "sql", "regex", "algorithm", "refactor", "prove", "proof", "math", "equation", "calculate", "analy",
        "explain why", "step by step", "strategy", "business plan", "architecture", "compare", "pros and cons",
        "essay", "research", "contract", "legal", "review my", "summarize", "plan my", "optimize", "design a",
    ]
    private static let creativePhrases = [
        "story", "poem", "lyrics", "song about", "joke", "brainstorm", "ideas for", "slogan", "caption", "tweet",
        "instagram", "name for", "names for", "recipe", "image prompt", "roleplay", "role play",
    ]
    /// Requests to operate apps or the browser.
    private static let controlPhrases = [
        "chrome", "safari", "browser", "tabs", "this tab", "the tab", "new tab", "close tab",
        "click", "in the app", "button", "menu bar", "system settings", "turn on", "turn off", "finder", "whatsapp", "messages", "notes", "reminders", "calendar", "mail ",
        "this page", "the page", "this website", "this article",
    ]

    private static let screenPhrases = [
        "on my screen", "on the screen", "my screen", "what am i looking at", "what's this", "what is this",
        "explain this", "summarize this", "this page", "this error", "this code", "this email", "this message",
        "reply to this", "read this", "what does this", "translate this", "this image", "this chart", "this website",
        "this document", "this article", "fix this", "here on", "see this", "look at this",
    ]

    private static func has(_ text: String, _ phrases: [String]) -> Bool { phrases.contains(where: text.contains) }

    static func isMacAction(_ t: String) -> Bool {
        let request = withoutPreamble(t)
        return macActionPrefixes.contains(where: request.hasPrefix) || has(t, macActionPhrases)
            || t.range(of: actionPattern, options: .regularExpression) != nil
    }

    /// Asking Saturday to *do* something, wherever it appears in the sentence.
    private static let actionPattern = #"\b(open|launch|play|replay|search for|search|look up|go to|navigate to|click|tap|scroll|pause|resume|skip|quit|close|switch to|start playing|stop the music|turn up|turn down|show me my|check my|read my|look at my|send a|send an|download|install|bookmark)\b|\b(apple music|youtube|yt music|spotify|music app|whatsapp)\b"#

    /// "Can you please open…", "Hey Saturday, play…", "I want you to…" → "open…", "play…".
    static func withoutPreamble(_ t: String) -> String {
        t.replacingOccurrences(
            of: #"^((hey|hi|hello|ok|okay|yo|so|now|alright|and)\b[\s,]*)*(saturday\b[\s,]*)?((can|could|would|will) you\s+(please\s+)?|please\s+|i want you to\s+|i need you to\s+|go ahead and\s+|just\s+|kindly\s+)*"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }

    static func isRealtime(_ t: String) -> Bool { has(t, realtimePhrases) }

    /// Whether the request is about what's on screen, so Saturday should attach a screenshot.
    static func needsScreen(_ text: String) -> Bool { has(text.lowercased(), screenPhrases) }

    static func route(_ text: String, mode: Mode, settings s: SettingsStore, hasSelection: Bool) -> Route {
        if let command = LocalCommands.match(text) {
            return Route(kind: .local, provider: .claude, model: "", reason: "on-device", command: command)
        }
        let t = text.lowercased()
        let aboutScreen = needsScreen(t) || (hasSelection && t.contains("this"))

        switch mode {
        case .claude, .openai, .gemini:
            let p: Provider = mode == .claude ? .claude : mode == .openai ? .openai : .gemini
            if isMacAction(t) { return agent(p, s) }
            return make(p, s, reason: "chosen", effort: aboutScreen || has(t, deepPhrases) ? "high" : "medium",
                        grounded: p != .claude && isRealtime(t))
        case .council:
            return Route(kind: .council, provider: .claude, model: s.claudeModel, reason: "deep think")
        case .auto:
            break
        }

        if isMacAction(t) || has(t, controlPhrases), let p = first([.claude, .openai, .gemini], s) {
            return agent(p, s)
        }
        if aboutScreen, let p = first([.claude, .openai, .gemini], s) {
            return make(p, s, reason: hasSelection ? "your selection" : "your screen", effort: "high")
        }
        if isRealtime(t) {
            if s.isAvailable(.gemini) { return make(.gemini, s, reason: "live web info", grounded: true) }
            if s.isAvailable(.claude) {
                var route = agent(.claude, s)
                route.reason = "live web search"
                route.effort = "medium"
                route.grounded = true
                return route
            }
            if s.isAvailable(.openai) { return make(.openai, s, reason: "live web info", grounded: true) }
        }
        if has(t, deepPhrases), let p = first([.claude, .openai, .gemini], s) {
            return make(p, s, reason: s.geniusMode && p == .claude ? "genius mode" : "deep reasoning", effort: "high", genius: true)
        }
        if has(t, creativePhrases), let p = first([.openai, .claude, .gemini], s) {
            return make(p, s, reason: "creative")
        }
        let words = t.split(whereSeparator: \.isWhitespace).count
        if words <= 8 && !t.contains("\n"), let p = first([.claude, .gemini, .openai], s) {
            return make(p, s, reason: "quick answer", effort: "low", fast: true)
        }
        let p = first([.claude, .openai, .gemini], s) ?? .claude
        return make(p, s, reason: "general")
    }

    /// A plain chat route for one provider, used by the council and fallbacks.
    static func chatRoute(for provider: Provider, settings: SettingsStore, text: String) -> Route {
        make(provider, settings, reason: "chosen", effort: "high", grounded: provider != .claude && isRealtime(text.lowercased()))
    }

    /// Another provider to try once if the first one fails.
    static func alternative(to route: Route, settings: SettingsStore, text: String) -> Route? {
        guard route.kind != .council, route.kind != .local else { return nil }
        let next = Provider.allCases.first { $0 != route.provider && settings.isAvailable($0) }
        return next.map { route.kind == .agent ? agent($0, settings) : chatRoute(for: $0, settings: settings, text: text) }
    }

    private static func first(_ order: [Provider], _ s: SettingsStore) -> Provider? {
        order.first(where: s.isAvailable)
    }

    static func agent(_ p: Provider, _ s: SettingsStore) -> Route {
        Route(kind: .agent, provider: p, model: model(p, s), effort: "low", reason: "Mac action")
    }

    private static func model(_ p: Provider, _ s: SettingsStore, fast: Bool = false, genius: Bool = false) -> String {
        switch p {
        case .claude: genius && s.geniusMode ? s.claudeGeniusModel : fast ? s.claudeFastModel : s.claudeModel
        case .openai: s.openAIModel
        case .gemini: fast ? s.geminiFastModel : s.geminiModel
        }
    }

    private static func make(
        _ p: Provider, _ s: SettingsStore, reason: String, effort: String = "medium",
        grounded: Bool = false, fast: Bool = false, genius: Bool = false
    ) -> Route {
        Route(kind: .chat, provider: p, model: model(p, s, fast: fast, genius: genius), effort: effort, grounded: grounded, reason: reason)
    }
}

enum Prompts {
    /// The reply a chat model gives instead of an answer when the request is really something to do on the Mac.
    static let actionMarker = "[[ACT]]"

    /// Added to chat (non-tool) requests, so a misrouted action is handed to the Mac agent instead of refused.
    static let actionHandoff = """

    If the user is asking you to do something on their Mac or in an app or website (open, play, search in an app, \
    click, type, control music, read their browser or screen, send something), don't answer and never say you can't: \
    reply with exactly \(actionMarker) and nothing else, and Saturday will do it with its Mac tools.
    """

    static func system(
        context: ScreenContext, memories: [MemoryItem], spoken: Bool,
        personality: VoicePersonality, speaking: Bool, voiceCues: Bool
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var prompt = """
        You are Saturday, the user's personal AI assistant on their Mac. You are Saturday: speak as Saturday, \
        not as any underlying AI product. Don't bring up which company or model powers you. If the user sincerely \
        asks, say Saturday runs on several leading AI models and picks the best one for each request.

        \(personality.promptTone)

        How to be excellent:
        - Think it through before answering. Be accurate, specific and genuinely useful: concrete answers, numbers, \
        names, steps and examples beat generalities.
        - Tailor everything to this user using what you know about them (below). Use it naturally; don't announce \
        that you remembered something unless they ask.
        - When the request says "this", "here" or refers to the screen, use the context below: the app they're in, \
        selected text, or the attached screenshot.
        - If a request is ambiguous, make the most sensible assumption and state it in a few words rather than \
        asking, unless a wrong guess would be costly.
        - Anticipate the obvious next need and cover it briefly (for example, the command to run or the link to open).
        - Be honest about uncertainty. Never invent facts, sources, links or quotes.

        Reply format:
        - Open with the direct answer in one or two short sentences of plain text, with no Markdown. This part is \
        read aloud, so write it the way a real person talks: contractions, natural rhythm, varied openings, no \
        stiff phrases like "Certainly!" or "As an AI". Spell out things that read badly aloud (say "about 5 dollars", \
        not "~$5").
        - If more detail helps, add a blank line and then the details in Markdown: short paragraphs, bullet lists, \
        numbered steps, code blocks. Use headings only in long answers.
        - Keep the length proportional to the question. Simple questions get one or two sentences.

        Memory: when the user tells you a lasting fact or preference about themselves (name, city, job, family, \
        diet, tastes, how they like answers), add it at the very end of your reply as \
        <remember>short fact in third person</remember>, one tag per fact. Don't use it for one-off requests.

        Current date and time: \(formatter.string(from: Date())) (\(TimeZone.current.identifier)). \
        Locale: \(Locale.current.identifier).
        """

        if spoken {
            prompt += "\nThe user spoke this request, so speech-to-text may have misheard a word; read it charitably."
        }
        if speaking {
            prompt += """


            Your reply will be spoken aloud by your voice. Start the reply with a hidden tone tag saying how a \
            thoughtful person would say it, in one to three words, for example <tone>warm</tone>, \
            <tone>excited</tone>, <tone>gently sympathetic</tone>, <tone>playful</tone>, <tone>calm and clear</tone> \
            or <tone>curious</tone>. Match the moment: good news sounds happy, bad news sounds gentle, facts sound \
            relaxed and confident. Then write the spoken opening like natural speech: short sentences, the odd \
            "so", "well" or "honestly" where a person would say it, and emphasis through word choice rather than \
            symbols. Never mention the tag.
            """
        }
        if voiceCues {
            prompt += "\nYour voice can perform the sound cues <laugh>, <short pause> and <sigh>. In the spoken " +
                "opening only, you may use at most one, and only where a person genuinely would (a <laugh> at " +
                "something funny, a <short pause> before a surprise). Most replies need none."
        }
        if let app = context.appName {
            prompt += "\n\nThe user is currently in \(app)"
            if let title = context.windowTitle, !title.isEmpty { prompt += ", window \"\(title)\"" }
            prompt += "."
        }
        if let selection = context.selectedText {
            prompt += "\n\nText the user has selected:\n<selection>\n\(selection)\n</selection>"
        }
        if !memories.isEmpty {
            prompt += "\n\nWhat you know about the user:\n" + memories.map { "- \($0.text)" }.joined(separator: "\n")
        }
        return prompt
    }

    /// Conversation instructions for GPT-Live, which speaks for Saturday and hands real work to Saturday's brain.
    static func live(personality: VoicePersonality, memories: [MemoryItem], context: ScreenContext) -> String {
        var prompt = """
        You are Saturday, the user's personal voice assistant on their Mac. You are Saturday; never say which \
        company or model powers you. If sincerely asked, say Saturday runs on several leading AI models.
        \(personality.promptTone)
        Talk like a real person in a relaxed conversation: natural rhythm, contractions, short sentences, warmth. \
        Keep replies brief unless the user asks for more.

        Backchannel policy: Use light, natural backchannels such as "mm-hm" only while the user explains something longer.

        Interruption policy: When the user interrupts, stop speaking right away, even mid-sentence, and listen. \
        Respond to their latest request; don't resume an answer they've replaced. If they say stop or wait, stop at once.

        Delegation policy:
        Backend tools:
        - Saturday's brain: accurate answers with careful reasoning and live web search; sees the user's screen, \
        the app they're in and any selected text; remembers facts about the user; and controls the Mac (opens apps \
        and websites, plays music, adds reminders, notes and calendar events, changes volume, uses the clipboard).

        Generate <|SpawnThinking|> when:
        - The user asks a factual question, wants current information (news, weather, prices, scores, times), or \
        asks anything you aren't certain about.
        - The user mentions their screen, "this", a selection, a file, a page or an email.
        - The user asks you to do something on the Mac, or to remember or forget something.
        - The request needs careful reasoning, math, writing, code, advice or planning.
        - A correction changes work already requested.

        Do not generate <|SpawnThinking|> when:
        - The user greets you, makes small talk, thanks you, or asks you to repeat or shorten a result already given.
        - You need a brief clarification to understand the request.

        Generate <|SpawnThinking|> before giving an answer that depends on backend work. Do not guess the result \
        while waiting. When the result arrives, say it conversationally and briefly. The full details also appear \
        on the user's screen, so don't read out long lists, code or links; summarize and mention the details are on screen.
        """
        if !memories.isEmpty {
            prompt += "\n\nWhat you know about the user:\n" + memories.suffix(40).map { "- \($0.text)" }.joined(separator: "\n")
        }
        if let app = context.appName {
            prompt += "\n\nThe user is currently in \(app)."
        }
        return prompt
    }

    /// Tells the brain what else speech recognition might have heard, so it can fix misheard names and songs.
    static func speechAlternatives(heard: String, alsoHeard: [String]) -> String {
        let others = alsoHeard.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(heard) != .orderedSame }
        guard !others.isEmpty else { return "" }
        return """


        Speech recognition heard the request as: "\(heard)". It could also have been: \(others.map { "\"\($0)\"" }.joined(separator: " or ")). \
        Use whichever reading makes the most sense. For names, songs, artists, films and places, prefer the real, \
        well-known name the user most likely meant over a literal reading of a mishearing (for example "case area" is \
        likely the song "Kesariya").
        """
    }

    /// Instructions for Saturday's brain when it answers for GPT-Live.
    static let liveBackendAddendum = """


    You are answering on behalf of Saturday's voice, which will say your answer aloud in its own words. \
    The request comes from a live voice transcript, so it may contain mistakes or unfinished phrases; use the \
    conversation to interpret it. Lead with the facts the voice should say, then any details for the screen.
    """

    static let agentAddendum = """


    You can operate this Mac like a person sitting at it:
    - Music: play_music plays songs (fix misheard titles first) and music_control pauses, skips or says what's playing. \
    "Open Apple Music / YouTube Music / Spotify and search for <song>" or "find <song> in <app>" means play_music \
    with that service ("apple_music", "youtube", "spotify"); misheard app names like "Whitey music" mean YouTube \
    Music. Never ask the user to confirm a song or artist: pick the most likely match and play it.
    - Browsers: browser_tabs, browser_read (read the page the user is on), browser_open, browser_switch_tab, browser_close_tab.
    - Any app: see_app shows an app's controls as numbered items, then click, type_text, press_keys and choose_menu \
    act on them. Work step by step: look, act, then look again to check it worked before saying it's done. \
    Prefer menus and keyboard shortcuts you know when they're reliable.
    - Also: open apps and URLs, change the volume, read and set the clipboard, remember facts about the user, \
    and run AppleScript for scriptable apps like Notes, Reminders, Calendar, Mail and Finder (the user approves each script).
    You really do have full control of this Mac through these tools, so never say you can't access or \
    control an app: look at it with see_app (or the browser tools) and act. Don't ask what the user means \
    when a sensible default exists: "check my Chrome" or "what am I reading" means read the active tab with \
    browser_read and summarize it (mentioning how many tabs are open if useful).
    If a request is a question rather than an action, just answer it. Ask before anything irreversible \
    (sending, deleting, buying). After acting, confirm in one short sentence what you did. If a tool says a \
    permission is missing, tell the user exactly which setting to turn on.
    """

    static func councilSynthesis(question: String, answers: [(Provider, String)]) -> String {
        let drafts = answers.enumerated().map { "<draft number=\"\($0.offset + 1)\">\n\($0.element.1)\n</draft>" }
            .joined(separator: "\n\n")
        return """
        The user asked: \(question)

        Here are independent drafts of an answer:

        \(drafts)

        Write the single best answer for the user. Combine the strongest points, fix any mistakes, \
        and settle any disagreements (mention a disagreement only if it matters to the user). \
        Follow the reply format from your instructions. Reply directly to the user as Saturday. \
        Never mention the drafts, this process, or any AI model.
        """
    }
}
