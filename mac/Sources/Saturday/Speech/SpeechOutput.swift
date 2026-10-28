import AVFoundation
import Foundation

enum VoiceEngine: String, CaseIterable, Identifiable {
    case gptLive, auto, local, gemini, elevenLabs, apple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .gptLive: "GPT-Live voice agent (OpenAI key)"
        case .local: "Natural offline voice (free, runs on this Mac)"
        case .auto: "Best available"
        case .gemini: "Natural studio voice (Gemini key)"
        case .elevenLabs: "Ultra-real voice (ElevenLabs key)"
        case .apple: "Offline voice (built into macOS)"
        }
    }
}

/// How Saturday sounds and talks. Sets the delivery style for the voice and the tone of the writing.
enum VoicePersonality: String, CaseIterable, Identifiable {
    case cool, warm, energetic, calm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cool: "Cool"
        case .warm: "Warm"
        case .energetic: "Energetic"
        case .calm: "Calm"
        }
    }

    var blurb: String {
        switch self {
        case .cool: "Smooth, confident, a little witty"
        case .warm: "Kind and friendly, like a good friend"
        case .energetic: "Bright, upbeat, full of life"
        case .calm: "Soft, steady and soothing"
        }
    }

    var symbol: String {
        switch self {
        case .cool: "sunglasses.fill"
        case .warm: "sun.max.fill"
        case .energetic: "bolt.fill"
        case .calm: "leaf.fill"
        }
    }

    /// Delivery direction for the text-to-speech model.
    var ttsStyle: String {
        switch self {
        case .cool: "relaxed, smooth and confident, with a hint of playful charm, natural conversational pacing"
        case .warm: "warm, kind and friendly, smiling while talking, natural conversational pacing"
        case .energetic: "upbeat, bright and enthusiastic, lively pacing"
        case .calm: "calm, soothing and measured, gentle unhurried pacing"
        }
    }

    var promptTone: String {
        switch self {
        case .cool: "Personality: cool, confident and quick-witted, like a sharp friend who has it handled. Light, dry humor when it fits; never cheesy or over the top."
        case .warm: "Personality: warm, kind and encouraging, like a thoughtful friend who's glad to help."
        case .energetic: "Personality: upbeat and enthusiastic, with genuine energy, but still concise."
        case .calm: "Personality: calm, gentle and reassuring. Unhurried, clear and soothing."
        }
    }

    /// The Gemini voice that suits this personality best.
    var suggestedVoice: String {
        switch self {
        case .cool: "Algieba"
        case .warm: "Sulafat"
        case .energetic: "Puck"
        case .calm: "Vindemiatrix"
        }
    }

    var sample: String {
        switch self {
        case .cool: "Hey, I'm Saturday. Tell me what you need, and consider it handled."
        case .warm: "Hi there, I'm Saturday. I'm really glad you're here. What can I do for you?"
        case .energetic: "Hey hey! I'm Saturday, and I'm ready to go. What are we doing today?"
        case .calm: "Hello. I'm Saturday. Take your time, and tell me how I can help."
        }
    }
}

/// Speaks replies in a natural voice while they're still being written.
/// - ElevenLabs: one continuous stream per reply, fed sentence by sentence, so intonation flows.
/// - Gemini: the first sentence is voiced immediately, then longer phrases, each delivered in the reply's tone.
/// - Every clip has its dead air trimmed and soft fades, with a breath-length pause between phrases.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var level: CGFloat = 0

    private enum Job {
        case pcm(AsyncThrowingStream<Data, Error>, fallbackText: String, source: PhraseSource)
        case live(ElevenLabsLive)
        case apple(String)
    }

    private enum ActiveVoice { case gemini(String), elevenLabs(String), local, apple }
    private enum PhraseSource { case gemini, local }

    private let settings = SettingsStore.shared
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let synthesizer = AVSpeechSynthesizer()

    private var splitter = SentenceSplitter(summaryOnly: true, groupTarget: 300)
    private var jobs: AsyncStream<Job>.Continuation?
    private var scheduler: Task<Void, Never>?
    private var live: ElevenLabsLive?
    private var liveQueued = false
    private var generation = 0
    private var queuedJobs = 0
    private var pendingBuffers = 0
    private var appleSpeaking = false
    private var appleContinuation: CheckedContinuation<Void, Never>?
    private var geminiFailed = false
    private var localFailed = false
    private var elevenFailed = false

    /// If the newest ElevenLabs model isn't available on this account, later replies use this one instead.
    private var elevenModelOverride: String?

    /// A breath-length pause between separately generated phrases.
    private let phraseGap: Double = 0.16

    override init() {
        super.init()
        synthesizer.delegate = self
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        Self.installMeter(on: engine.mainMixerNode) { [weak self] level in
            Task { @MainActor in self?.meter(level) }
        }
    }

    // MARK: - Public

    /// Whether the current voice can perform cues like <laugh>, so the models may write them.
    var supportsCues: Bool {
        switch activeVoice {
        case .gemini: return true
        case .elevenLabs: return ElevenLabsLive.isDialogueModel(elevenModel)
        case .local, .apple: return false
        }
    }

    /// Starts a new spoken reply. `summaryOnly` speaks just the opening answer and leaves details on screen.
    func begin(summaryOnly: Bool) {
        stop()
        geminiFailed = false
        localFailed = false
        let voice = activeVoice
        if case .elevenLabs(let key) = voice {
            // Connect now so the socket is ready by the time the first sentence is written.
            live = ElevenLabsLive(key: key, voiceID: settings.elevenVoiceID, model: elevenModel, stability: stability)
            splitter = SentenceSplitter(summaryOnly: summaryOnly, groupTarget: 1)
        } else if case .local = voice {
            // Shorter phrases keep the on-device voice ahead of playback.
            splitter = SentenceSplitter(summaryOnly: summaryOnly, groupTarget: 160)
        } else {
            splitter = SentenceSplitter(summaryOnly: summaryOnly, groupTarget: 300)
        }
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation
        let current = generation
        scheduler = Task { [weak self] in
            for await job in stream {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                await self.play(job)
                guard self.generation == current else { return }
                self.queuedJobs -= 1
                self.refresh()
            }
        }
    }

    func feed(_ delta: String) {
        for chunk in splitter.push(delta) { enqueue(chunk) }
    }

    func finish() {
        for chunk in splitter.flush() { enqueue(chunk) }
        if let live {
            if liveQueued { live.finish() } else { live.cancel() }
        }
        jobs?.finish()
    }

    func speak(_ text: String, summaryOnly: Bool = false) {
        begin(summaryOnly: summaryOnly)
        feed(text)
        finish()
    }

    func stop() {
        generation += 1
        scheduler?.cancel()
        scheduler = nil
        jobs?.finish()
        jobs = nil
        live?.cancel()
        live = nil
        liveQueued = false
        player.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        appleSpeaking = false
        appleContinuation?.resume()
        appleContinuation = nil
        queuedJobs = 0
        pendingBuffers = 0
        refresh()
    }

    // MARK: - Choosing a voice

    private var activeVoice: ActiveVoice {
        let eleven = settings.elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.voiceEngine {
        case .elevenLabs where !eleven.isEmpty && !elevenFailed, .auto where !eleven.isEmpty && !elevenFailed:
            return .elevenLabs(eleven)
        default:
            return phraseVoice
        }
    }

    /// The voice for phrase-by-phrase speech: Gemini if there's a key, then the free on-device voice,
    /// then the built-in Mac voice as a last resort.
    private var phraseVoice: ActiveVoice {
        let gemini = settings.key(for: .gemini)
        let localUsable = !localFailed && LocalVoice.shared.isReady
        switch settings.voiceEngine {
        case .apple:
            return .apple
        case .local:
            return localUsable ? .local : .apple
        default:
            if !gemini.isEmpty && !geminiFailed { return .gemini(gemini) }
            return localUsable ? .local : .apple
        }
    }

    /// The offline voice's speaking rate for each personality.
    private var localSpeed: Float {
        // Supertonic's natural pace is a little slow at 1.0; its own example uses 1.25.
        let base: Float = settings.localModel == .supertonic ? 1.15 : 1.0
        return base * personalityPace
    }

    private var personalityPace: Float {
        switch settings.voicePersonality {
        case .cool: 1.0
        case .warm: 0.97
        case .energetic: 1.08
        case .calm: 0.92
        }
    }

    private var elevenModel: String { elevenModelOverride ?? settings.elevenModel }

    private var stability: Double {
        switch settings.voicePersonality {
        case .cool: 0.4
        case .warm: 0.45
        case .energetic: 0.3
        case .calm: 0.6
        }
    }

    /// Delivery direction for Gemini: the personality, plus this reply's emotional tone.
    private var geminiStyle: String {
        var style = settings.voicePersonality.ttsStyle
        if let tone = splitter.tone, !tone.isEmpty { style += "; for this reply, sound \(tone)" }
        return style + "; speak like a real person in conversation, with natural breaths and emphasis"
    }

    // MARK: - Queue

    private func enqueue(_ text: String) {
        guard let jobs else { return }
        if let live, !elevenFailed {
            if !liveQueued {
                liveQueued = true
                queuedJobs += 1
                jobs.yield(.live(live))
            }
            live.speak(text, tone: splitter.tone)
            refresh()
            return
        }
        let plain = SpeechText.removingCues(text)
        guard !plain.isEmpty else { return }
        queuedJobs += 1
        refresh()
        jobs.yield(phraseJob(text, plain: plain))
    }

    private func phraseJob(_ text: String, plain: String) -> Job {
        switch phraseVoice {
        case .gemini(let key):
            let stream = GeminiTTS.stream(text: text, key: key, model: settings.geminiTTSModel,
                                          voice: settings.geminiVoice, style: geminiStyle)
            return .pcm(stream, fallbackText: plain, source: .gemini)
        case .local:
            let stream = NeuralVoiceEngine.shared.stream(text: plain, model: settings.localModel, speaker: settings.localSpeaker, speed: localSpeed)
            return .pcm(stream, fallbackText: plain, source: .local)
        case .elevenLabs, .apple:
            return .apple(plain)
        }
    }

    private func play(_ job: Job) async {
        switch job {
        case .live(let session):
            let gotAudio = await playPCM(session.audio)
            if !gotAudio, !Task.isCancelled {
                // ElevenLabs didn't answer: retry later replies on the v3 model, and say this one another way.
                if session.model == "eleven_v4_turbo", elevenModelOverride == nil {
                    elevenModelOverride = "eleven_v3_conversational"
                } else {
                    elevenFailed = true
                }
                live = nil
                await speakFallback(session.sentText)
            }
        case .pcm(let stream, let fallbackText, let source):
            let gotAudio = await playPCM(stream)
            if !gotAudio, !Task.isCancelled {
                // That voice failed: use the next one in line for this phrase and the rest of the reply.
                switch source {
                case .gemini: geminiFailed = true
                case .local: localFailed = true
                }
                await speakFallback(fallbackText)
            }
        case .apple(let text):
            await waitUntilDrained()
            await speakWithApple(text)
        }
    }

    private func speakFallback(_ text: String) async {
        guard !text.isEmpty else { return }
        while !Task.isCancelled {
            let job = phraseJob(text, plain: SpeechText.removingCues(text))
            guard case .pcm(let stream, _, let source) = job else { break }
            if await playPCM(stream) { return }
            switch source {
            case .gemini: geminiFailed = true
            case .local: localFailed = true
            }
        }
        await waitUntilDrained()
        await speakWithApple(SpeechText.removingCues(text))
    }

    /// Plays one stream of 24 kHz 16-bit PCM, trimming leading and trailing silence. Returns whether any audio played.
    private func playPCM(_ stream: AsyncThrowingStream<Data, Error>) async -> Bool {
        var shaper = PCMShaper()
        var gotAudio = false
        do {
            for try await chunk in stream {
                let samples = shaper.push(chunk)
                if !samples.isEmpty {
                    schedule(samples)
                    gotAudio = true
                }
            }
        } catch {
            if !gotAudio { return false }
        }
        guard !Task.isCancelled else { return gotAudio }
        let tail = shaper.finish()
        if !tail.isEmpty {
            schedule(tail)
            gotAudio = true
        }
        if gotAudio { schedule([Float](repeating: 0, count: Int(phraseGap * 24000))) }
        return gotAudio
    }

    private func schedule(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        pendingBuffers += 1
        refresh()
        let current = generation
        Self.schedule(buffer, on: player) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.pendingBuffers -= 1
                self.refresh()
            }
        }
    }

    private func waitUntilDrained() async {
        while pendingBuffers > 0 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func speakWithApple(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAppleVoice
        switch settings.voicePersonality {
        case .cool: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02; utterance.pitchMultiplier = 0.95
        case .warm: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
        case .energetic: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1; utterance.pitchMultiplier = 1.06
        case .calm: utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92; utterance.pitchMultiplier = 0.97
        }
        utterance.postUtteranceDelay = 0.05
        await withCheckedContinuation { continuation in
            appleContinuation = continuation
            appleSpeaking = true
            refresh()
            synthesizer.speak(utterance)
        }
    }

    private func appleFinished() {
        appleSpeaking = false
        appleContinuation?.resume()
        appleContinuation = nil
        refresh()
    }

    private func refresh() {
        let speaking = queuedJobs > 0 || pendingBuffers > 0 || appleSpeaking
        if speaking != isSpeaking { isSpeaking = speaking }
        if !speaking { level = 0 } else if appleSpeaking { level = 0.35 }
    }

    private func meter(_ value: CGFloat) {
        guard pendingBuffers > 0 else { return }
        level = value
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.appleFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.appleFinished() }
    }

    // MARK: - Apple voices

    /// The most natural installed voice for the user's language: Premium, then Enhanced, then default.
    static var bestAppleVoice: AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            let quality = switch voice.quality {
            case .premium: 30
            case .enhanced: 20
            default: 10
            }
            return quality + (voice.language == language ? 1 : 0)
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    static var hasNaturalAppleVoice: Bool {
        guard let voice = bestAppleVoice else { return false }
        return voice.quality == .premium || voice.quality == .enhanced
    }

    // MARK: - Audio thread helpers

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode, done: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    nonisolated private static func installMeter(on mixer: AVAudioMixerNode, level: @escaping @Sendable (CGFloat) -> Void) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: mixer.outputFormat(forBus: 0)) { buffer, _ in
            level(AudioLevel.rms(buffer))
        }
    }
}

/// Cleans up a stream of 24 kHz 16-bit PCM so clips join like natural speech: drops the silence
/// TTS services pad at the start and end, and fades the edges so there are no clicks.
struct PCMShaper {
    private static let threshold: Float = 0.006

    private var leftover: UInt8?
    private var started = false
    /// Trailing silence held back until we know whether more sound follows (a pause) or the clip ends.
    private var silence: [Float] = []

    mutating func push(_ data: Data) -> [Float] {
        var samples = convert(data)
        if !started {
            guard let onset = samples.firstIndex(where: { abs($0) > Self.threshold }) else { return [] }
            samples.removeFirst(max(0, onset - 240)) // keep 10 ms before the first sound
            Self.fade(&samples, in: true, length: 120)
            started = true
        }
        let pending = silence + samples
        guard let lastSound = pending.lastIndex(where: { abs($0) > Self.threshold }) else {
            silence = pending
            return []
        }
        silence = Array(pending[(lastSound + 1)...])
        return Array(pending[...lastSound])
    }

    /// The end of the clip: keeps 50 ms of the trailing silence, faded out, and drops the rest.
    mutating func finish() -> [Float] {
        var out = Array(silence.prefix(1200))
        silence = []
        Self.fade(&out, in: false, length: out.count)
        return out
    }

    private mutating func convert(_ data: Data) -> [Float] {
        var bytes = [UInt8](data)
        if let leftover {
            bytes.insert(leftover, at: 0)
            self.leftover = nil
        }
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        var samples = [Float](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            samples[i] = Float(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8)) / 32768
        }
        return samples
    }

    private static func fade(_ samples: inout [Float], in fadeIn: Bool, length: Int) {
        let n = min(length, samples.count)
        guard n > 0 else { return }
        for i in 0..<n {
            let gain = Float(i) / Float(n)
            if fadeIn { samples[i] *= gain } else { samples[samples.count - 1 - i] *= gain }
        }
    }
}

// MARK: - Cloud voices

/// Gemini text-to-speech over the Interactions API, streamed as 24 kHz 16-bit PCM.
enum GeminiTTS {
    static let voices: [(name: String, style: String)] = [
        ("Sulafat", "Warm"), ("Achird", "Friendly"), ("Vindemiatrix", "Gentle"), ("Aoede", "Breezy"),
        ("Callirrhoe", "Easy-going"), ("Umbriel", "Easy-going"), ("Zubenelgenubi", "Casual"), ("Despina", "Smooth"),
        ("Algieba", "Smooth"), ("Achernar", "Soft"), ("Enceladus", "Breathy"), ("Iapetus", "Clear"),
        ("Erinome", "Clear"), ("Schedar", "Even"), ("Sadaltager", "Knowledgeable"), ("Charon", "Informative"),
        ("Rasalgethi", "Informative"), ("Puck", "Upbeat"), ("Laomedeia", "Upbeat"), ("Sadachbia", "Lively"),
        ("Zephyr", "Bright"), ("Autonoe", "Bright"), ("Leda", "Youthful"), ("Fenrir", "Excitable"),
        ("Kore", "Firm"), ("Orus", "Firm"), ("Alnilam", "Firm"), ("Gacrux", "Mature"),
        ("Pulcherrima", "Forward"), ("Algenib", "Gravelly"),
    ]

    static func stream(text: String, key: String, model: String, voice: String, style: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let annotation: [String: Any] = ["type": "speech_metadata", "style": style]
                    let part: [String: Any] = ["type": "text", "text": text, "annotations": [annotation]]
                    let input: [String: Any] = ["type": "user_input", "content": [part]]
                    let body: [String: Any] = [
                        "model": model,
                        "input": [input],
                        "response_format": ["type": "audio", "mime_type": "audio/l16", "sample_rate": 24000] as [String: Any],
                        "generation_config": ["speech_config": [["voice": voice]]],
                        "stream": true,
                    ]
                    let request = try SSE.jsonRequest(
                        url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
                        headers: ["x-goog-api-key": key], body: body
                    )
                    for try await payload in SSE.dataLines(for: request) {
                        guard let event = SSE.json(payload) else { continue }
                        if let error = event["error"] as? [String: Any] {
                            throw APIError.badResponse(error["message"] as? String ?? "Gemini voice error.")
                        }
                        if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "audio",
                           let encoded = delta["data"] as? String, let audio = Data(base64Encoded: encoded) {
                            continuation.yield(audio)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Sentence splitting

/// Turns streamed reply text into speakable chunks. The first sentence goes out right away so Saturday
/// starts talking fast; after that, sentences are grouped up to `groupTarget` characters. Reads the hidden
/// <tone> tag at the start, and skips code blocks and <remember> tags. In summary mode it stops at the
/// first blank line, so only the opening answer is spoken.
struct SentenceSplitter {
    let summaryOnly: Bool
    let groupTarget: Int
    /// The emotional tone the model chose for this reply, e.g. "excited" or "gently sympathetic".
    private(set) var tone: String?

    private var buffer = ""
    private var group = ""
    private var inCode = false
    private var spokeAny = false
    private var toneResolved = false
    /// Set once a <remember> tag starts: everything after it is never spoken.
    private var muted = false
    private(set) var done = false

    init(summaryOnly: Bool, groupTarget: Int) {
        self.summaryOnly = summaryOnly
        self.groupTarget = groupTarget
    }

    mutating func push(_ delta: String) -> [String] {
        guard !done else { return [] }
        if !muted { buffer += delta }
        if !muted, let tag = buffer.range(of: "<remember") {
            buffer = String(buffer[..<tag.lowerBound])
            muted = true
        }
        guard resolveTone() else { return [] }
        var out: [String] = []
        while !done, let piece = nextPiece() {
            add(piece.text, to: &out)
            if piece.boundary || piece.endsSummary { emitGroup(into: &out) }
            if piece.endsSummary { done = true }
        }
        return out
    }

    mutating func flush() -> [String] {
        var out: [String] = []
        toneResolved = true
        if !done && !inCode {
            var rest = buffer
            if let lt = rest.lastIndex(of: "<"), "<remember".hasPrefix(rest[lt...]) { rest = String(rest[..<lt]) }
            add(rest, to: &out)
        }
        buffer = ""
        emitGroup(into: &out)
        done = true
        return out
    }

    /// Pulls a leading <tone>…</tone> off the reply. Returns false while it may still be arriving.
    private mutating func resolveTone() -> Bool {
        guard !toneResolved else { return true }
        let trimmed = String(buffer.drop { $0.isWhitespace })
        if trimmed.hasPrefix("<tone>") {
            guard let close = trimmed.range(of: "</tone>") else { return false }
            tone = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(trimmed[close.upperBound...])
            toneResolved = true
            return true
        }
        if trimmed.isEmpty || "<tone>".hasPrefix(trimmed) { return false }
        toneResolved = true
        return true
    }

    private mutating func add(_ sentence: String, to out: inout [String]) {
        let clean = SpeechText.clean(sentence)
        guard !clean.isEmpty else { return }
        group += group.isEmpty ? clean : " " + clean
        if !spokeAny || group.count >= groupTarget { emitGroup(into: &out) }
    }

    private mutating func emitGroup(into out: inout [String]) {
        guard !group.isEmpty else { return }
        out.append(group)
        group = ""
        spokeAny = true
    }

    private struct Piece {
        var text: String
        var endsSummary = false
        var boundary = false
    }

    private mutating func nextPiece() -> Piece? {
        while true {
            if inCode {
                guard let close = buffer.range(of: "```") else {
                    buffer = String(buffer.suffix(2))
                    return nil
                }
                buffer = String(buffer[close.upperBound...])
                inCode = false
                continue
            }

            let fence = buffer.range(of: "```")?.lowerBound
            let paragraph = buffer.range(of: "\n\n")?.lowerBound
            var sentenceEnd: String.Index?
            var index = buffer.startIndex
            while index < buffer.endIndex {
                let char = buffer[index]
                let next = buffer.index(after: index)
                if char == "\n" { sentenceEnd = next; break }
                if ".!?…".contains(char), next < buffer.endIndex, buffer[next].isWhitespace { sentenceEnd = next; break }
                index = next
            }

            guard let first = [fence, paragraph, sentenceEnd].compactMap({ $0 }).min() else { return nil }

            if first == fence {
                let before = String(buffer[..<first])
                if summaryOnly {
                    buffer = ""
                    return Piece(text: before, endsSummary: true)
                }
                buffer = String(buffer[buffer.index(first, offsetBy: 3)...])
                inCode = true
                return Piece(text: before, boundary: true)
            }
            if first == paragraph && first != sentenceEnd {
                let before = String(buffer[..<first])
                buffer = String(buffer[buffer.index(first, offsetBy: 2)...])
                let hasContent = spokeAny || !group.isEmpty || !SpeechText.clean(before).isEmpty
                return Piece(text: before, endsSummary: summaryOnly && hasContent, boundary: true)
            }
            let sentence = String(buffer[..<first])
            buffer = String(buffer[first...])
            // A blank line right after this sentence ends the paragraph (and the spoken summary).
            let trimmed = buffer.drop { $0 == " " }
            if trimmed.hasPrefix("\n") {
                buffer = String(trimmed.dropFirst())
                return Piece(text: sentence, endsSummary: summaryOnly, boundary: true)
            }
            return Piece(text: sentence)
        }
    }
}

enum SpeechText {
    /// Sound cues the natural voice can perform. Other voices drop them.
    static let cues = ["<laugh>", "<short pause>", "<long pause>", "<sigh>", "<gasp>"]

    /// Strips Markdown and tags so the voice reads clean prose. Keeps sound cues.
    static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<(?!(?:laugh|short pause|long pause|sigh|gasp)>)[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*(#{1,6}|>|[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingCues(_ text: String) -> String {
        var s = text
        for cue in cues { s = s.replacingOccurrences(of: cue, with: " ") }
        return s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
