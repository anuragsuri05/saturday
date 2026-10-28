import Foundation
import Security

enum Keychain {
    private static let service = "com.saturday.assistant"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    // API keys live in the Keychain, never in UserDefaults.
    @Published var anthropicKey: String { didSet { Keychain.set(anthropicKey, account: "anthropic") } }
    @Published var openAIKey: String { didSet { Keychain.set(openAIKey, account: "openai") } }
    @Published var geminiKey: String { didSet { Keychain.set(geminiKey, account: "gemini") } }

    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    @Published var claudeFastModel: String { didSet { defaults.set(claudeFastModel, forKey: "claudeFastModel") } }
    @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    @Published var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }

    @Published var claudeGeniusModel: String { didSet { defaults.set(claudeGeniusModel, forKey: "claudeGeniusModel") } }
    @Published var geminiFastModel: String { didSet { defaults.set(geminiFastModel, forKey: "geminiFastModel") } }
    /// Sends the hardest questions to Claude Fable 5.1 (most capable, slower and pricier).
    @Published var geniusMode: Bool { didSet { defaults.set(geniusMode, forKey: "geniusMode") } }

    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    @Published var speakFullAnswer: Bool { didSet { defaults.set(speakFullAnswer, forKey: "speakFullAnswer") } }
    @Published var voiceEngine: VoiceEngine { didSet { defaults.set(voiceEngine.rawValue, forKey: "voiceEngine") } }
    @Published var voicePersonality: VoicePersonality { didSet { defaults.set(voicePersonality.rawValue, forKey: "voicePersonality") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var geminiVoice: String { didSet { defaults.set(geminiVoice, forKey: "geminiVoice") } }
    @Published var geminiTTSModel: String { didSet { defaults.set(geminiTTSModel, forKey: "geminiTTSModel") } }
    @Published var elevenLabsKey: String { didSet { Keychain.set(elevenLabsKey, account: "elevenlabs") } }
    /// Optional Spotify Web API app credentials, used only to find exact tracks so they start playing by themselves.
    @Published var spotifyClientID: String { didSet { defaults.set(spotifyClientID, forKey: "spotifyClientID") } }
    @Published var spotifyClientSecret: String { didSet { Keychain.set(spotifyClientSecret, account: "spotify") } }
    var hasSpotifyAPI: Bool { !spotifyClientID.isEmpty && !spotifyClientSecret.isEmpty }
    /// Where "play music" plays: "apple_music", "spotify" or "youtube".
    @Published var musicApp: String { didSet { defaults.set(musicApp, forKey: "musicApp") } }
    @Published var elevenVoiceID: String { didSet { defaults.set(elevenVoiceID, forKey: "elevenVoiceID") } }
    @Published var elevenModel: String { didSet { defaults.set(elevenModel, forKey: "elevenModel") } }
    @Published var liveVoice: String { didSet { defaults.set(liveVoice, forKey: "liveVoice") } }
    /// Which Kokoro voice the free offline voice uses.
    /// Which free on-device voice model to use, and the chosen speaker for each model.
    @Published var localModel: NeuralVoiceModel { didSet { defaults.set(localModel.rawValue, forKey: "localModel") } }
    @Published var supertonicSpeaker: Int { didSet { defaults.set(supertonicSpeaker, forKey: "supertonicSpeaker") } }
    @Published var kokoroSpeaker: Int { didSet { defaults.set(kokoroSpeaker, forKey: "kokoroSpeaker") } }

    var localSpeaker: Int32 { Int32(localModel == .kokoro ? kokoroSpeaker : supertonicSpeaker) }

    /// Whether OpenAI accepted the ChatGPT login for GPT-Live voice (nil until checked).
    @Published var livePlanAccepted: Bool? {
        didSet { defaults.set(livePlanAccepted.map { $0 ? "yes" : "no" }, forKey: "livePlanAccepted") }
    }
    @Published var livePlanReason: String { didSet { defaults.set(livePlanReason, forKey: "livePlanReason") } }

    /// GPT-Live runs the spoken conversation, through an OpenAI API key or the ChatGPT login if OpenAI allows it.
    var usesLiveVoice: Bool {
        guard voiceEngine == .gptLive else { return false }
        if !key(for: .openai).isEmpty { return true }
        return ChatGPTAccount.shared.planEnabled && livePlanAccepted != false
    }
    /// After Saturday answers a spoken question, keep listening for a follow-up, like a real conversation.
    @Published var conversationMode: Bool { didSet { defaults.set(conversationMode, forKey: "conversationMode") } }

    @Published var extraTrigger: ExtraTrigger { didSet { defaults.set(extraTrigger.rawValue, forKey: "extraTrigger") } }
    @Published var autoListen: Bool { didSet { defaults.set(autoListen, forKey: "autoListen") } }
    @Published var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "autoHide") } }
    /// Confirm before clicks or scripts that could be hard to undo (sending, deleting, paying). Everything else runs without asking.
    @Published var askBeforeRisky: Bool { didSet { defaults.set(askBeforeRisky, forKey: "askBeforeRisky") } }
    /// The one-time "allow everything" setup has been shown.
    @Published var permissionsSetUp: Bool { didSet { defaults.set(permissionsSetUp, forKey: "permissionsSetUp") } }
    @Published var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: "useScreenContext") } }
    /// Recognize speech only on this Mac (more private, less accurate on Intel Macs).
    @Published var privateSpeech: Bool { didSet { defaults.set(privateSpeech, forKey: "privateSpeech") } }
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }

    private init() {
        let env = ProcessInfo.processInfo.environment
        anthropicKey = Keychain.get("anthropic") ?? env["ANTHROPIC_API_KEY"] ?? ""
        openAIKey = Keychain.get("openai") ?? env["OPENAI_API_KEY"] ?? ""
        geminiKey = Keychain.get("gemini") ?? env["GEMINI_API_KEY"] ?? ""

        claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-opus-5-5"
        claudeFastModel = defaults.string(forKey: "claudeFastModel") ?? "claude-haiku-5-5"
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-6.1-terra"
        geminiModel = defaults.string(forKey: "geminiModel") ?? "gemini-4-argon"

        claudeGeniusModel = defaults.string(forKey: "claudeGeniusModel") ?? "claude-fable-5-1"
        geminiFastModel = defaults.string(forKey: "geminiFastModel") ?? "gemini-3.7-flash"
        geniusMode = defaults.bool(forKey: "geniusMode")

        speakReplies = defaults.bool(forKey: "speakReplies")
        speakFullAnswer = defaults.bool(forKey: "speakFullAnswer")
        voiceEngine = VoiceEngine(rawValue: defaults.string(forKey: "voiceEngine") ?? "") ?? .auto
        voicePersonality = VoicePersonality(rawValue: defaults.string(forKey: "voicePersonality") ?? "") ?? .cool
        onboarded = defaults.bool(forKey: "onboarded")
        geminiVoice = defaults.string(forKey: "geminiVoice") ?? VoicePersonality.cool.suggestedVoice
        geminiTTSModel = defaults.string(forKey: "geminiTTSModel") ?? "gemini-3.8-flash-tts"
        elevenLabsKey = Keychain.get("elevenlabs") ?? env["ELEVENLABS_API_KEY"] ?? ""
        spotifyClientID = defaults.string(forKey: "spotifyClientID") ?? ""
        musicApp = defaults.string(forKey: "musicApp") ?? "apple_music"
        spotifyClientSecret = Keychain.get("spotify") ?? ""
        elevenVoiceID = defaults.string(forKey: "elevenVoiceID") ?? "21m00Tcm4TlvDq8ikWAM"
        elevenModel = defaults.string(forKey: "elevenModel") ?? "eleven_v4_turbo"
        liveVoice = defaults.string(forKey: "liveVoice") ?? "marin"
        localModel = NeuralVoiceModel(rawValue: defaults.string(forKey: "localModel") ?? "") ?? .recommended
        supertonicSpeaker = defaults.object(forKey: "supertonicSpeaker") as? Int ?? Int(NeuralVoiceModel.supertonic.defaultVoice)
        kokoroSpeaker = defaults.object(forKey: "kokoroSpeaker") as? Int ?? Int(NeuralVoiceModel.kokoro.defaultVoice)
        livePlanAccepted = defaults.string(forKey: "livePlanAccepted").map { $0 == "yes" }
        livePlanReason = defaults.string(forKey: "livePlanReason") ?? ""
        conversationMode = defaults.object(forKey: "conversationMode") as? Bool ?? true

        extraTrigger = ExtraTrigger(rawValue: defaults.string(forKey: "extraTrigger") ?? "") ?? .none
        autoListen = defaults.object(forKey: "autoListen") as? Bool ?? true
        autoHide = defaults.object(forKey: "autoHide") as? Bool ?? true
        askBeforeRisky = defaults.object(forKey: "askBeforeRisky") as? Bool ?? true
        permissionsSetUp = defaults.bool(forKey: "permissionsSetUp")
        useScreenContext = defaults.object(forKey: "useScreenContext") as? Bool ?? true
        privateSpeech = defaults.bool(forKey: "privateSpeech")
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
    }

    func key(for provider: Provider) -> String {
        let raw = switch provider {
        case .claude: anthropicKey
        case .openai: openAIKey
        case .gemini: geminiKey
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAvailable(_ provider: Provider) -> Bool {
        provider == .openai && ChatGPTAccount.shared.planEnabled || !key(for: provider).isEmpty
    }

    var hasAnyProvider: Bool { Provider.allCases.contains(where: isAvailable) }

    /// ChatGPT sign-in is used before an API key, so the user's plan pays when it can.
    var openAIAuth: OpenAIAuth {
        ChatGPTAccount.shared.planEnabled ? .chatGPTPlan : .apiKey(key(for: .openai))
    }
}

/// Saves the conversation to ~/Library/Application Support/Saturday/history.json.
enum History {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saturday", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    static func save(_ messages: [ChatMessage]) {
        guard let data = try? JSONEncoder().encode(Array(messages.suffix(200))) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
