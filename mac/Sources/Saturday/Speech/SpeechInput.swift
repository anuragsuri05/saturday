import AVFoundation
import Speech

/// Listens to the microphone and transcribes speech, on-device when the Mac supports it (faster and private).
///
/// Deciding when the user has finished is done like a person would: it waits until the voice itself has
/// gone quiet (not just the recognizer), waits longer when the sentence is clearly unfinished ("…and", "…to the"),
/// and keeps listening if the recognizer ends a segment while the user is still talking.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0

    /// The final text, plus other plausible readings of it (for the brain to resolve names and songs).
    var onFinished: (@MainActor (String, [String]) -> Void)?
    var onCancelled: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let feed = RequestFeed()
    private var task: SFSpeechRecognitionTask?
    private var permissionsGranted = false

    /// Text from earlier recognition segments in this utterance, plus the live partial for the current one.
    private var committed = ""
    private var partial = ""
    /// Second-best readings from the classic recognizer.
    private var legacyAlternatives: [String] = []
    /// The new macOS 26 speech model session, when it's in use (type-erased for older macOS).
    private var modern: AnyObject?

    // Endpointing state.
    private var endpointTimer: Timer?
    private var startedAt = Date()
    private var lastVoice = Date.distantPast
    private var lastTextChange = Date()
    private var heardVoice = false
    private var noiseFloor: CGFloat = 0.03
    private var waitForSpeech: TimeInterval = 7
    /// Recognition segments started for this utterance (guards against a recognizer that keeps failing).
    private var segments = 0

    /// The longest single request Saturday will listen to.
    private let maxDuration: TimeInterval = 60

    /// Words that mean the sentence isn't finished yet.
    private static let continuationWords: Set<String> = [
        "and", "or", "but", "so", "because", "the", "a", "an", "to", "of", "for", "with", "in", "on", "at", "from",
        "about", "my", "your", "is", "are", "was", "if", "um", "uh", "er", "hmm", "than", "into", "by", "as",
        "between", "around", "near", "can", "could", "would", "should", "will",
    ]

    /// Starts listening. Gives up after `waitForSpeech` seconds if the user doesn't say anything.
    func start(waitForSpeech: TimeInterval = 7) async {
        guard !isListening else { return }
        if !permissionsGranted {
            guard await Self.speechAuthorized() else {
                onError?("Saturday needs Speech Recognition access. Turn it on in System Settings → Privacy & Security → Speech Recognition.")
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                onError?("Saturday needs Microphone access. Turn it on in System Settings → Privacy & Security → Microphone.")
                return
            }
            permissionsGranted = true
        }
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return
        }

        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).sampleRate > 0 else {
            onError?("No microphone found.")
            return
        }
        // Capture from the first moment; audio is held until a recognizer is attached so no words are lost.
        feed.startBuffering()
        Self.installTap(on: input, feed: feed) { [weak self] level in
            Task { @MainActor in self?.heard(level) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        committed = ""
        partial = ""
        legacyAlternatives = []
        transcript = ""
        heardVoice = false
        segments = 0
        startedAt = Date()
        lastTextChange = Date()
        lastVoice = .distantPast
        noiseFloor = 0.03
        self.waitForSpeech = waitForSpeech
        isListening = true
        if await !startModernRecognition() {
            beginSegment(with: recognizer)
        }

        endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkEndpoint() }
        }
    }

    func stop(send: Bool) {
        guard isListening else { return }
        isListening = false
        endpointTimer?.invalidate()
        endpointTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        feed.current?.endAudio()
        feed.current = nil
        feed.detachSink()
        task?.cancel()
        task = nil
        level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""

        if #available(macOS 26.0, *), let session = modern as? ModernTranscription {
            modern = nil
            guard send, !text.isEmpty || heardVoice else {
                session.cancel()
                onCancelled?()
                return
            }
            // Let the new model finish its last words; it's usually more accurate than the live text.
            Task {
                let result = await session.finish()
                let final = result.text.isEmpty ? text : result.text
                if final.isEmpty { onCancelled?() } else { onFinished?(final, result.alternatives) }
            }
            return
        }
        let alternatives = legacyAlternatives.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        if send, !text.isEmpty { onFinished?(text, alternatives) } else { onCancelled?() }
    }

    /// Uses Apple's newer speech model when this Mac has it (macOS 26+, model downloaded). Returns false otherwise.
    private func startModernRecognition() async -> Bool {
        guard #available(macOS 26.0, *), await ModernTranscription.isReady() else { return false }
        do {
            let session = try await ModernTranscription.start(vocabulary: SpeechVocabulary.words) { [weak self] text in
                Task { @MainActor in self?.modernHeard(text) }
            }
            guard isListening else {
                session.cancel()
                return true
            }
            modern = session
            feed.attachSink { session.append($0) }
            return true
        } catch {
            return false
        }
    }

    private func modernHeard(_ text: String) {
        guard isListening, modern != nil, text != partial else { return }
        noteTextChange(from: partial, to: text)
        partial = text
        transcript = text
    }

    // MARK: - Recognition

    /// Starts a recognition segment. The recognizer sometimes ends a segment on its own after a pause;
    /// when that happens mid-sentence, a new segment continues the same utterance.
    private func beginSegment(with recognizer: SFSpeechRecognizer) {
        segments += 1
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = SpeechVocabulary.words
        // Apple's online recognizer is noticeably more accurate (names, accents) than the on-device one on
        // older Macs; users who prefer privacy can keep speech on the Mac.
        request.requiresOnDeviceRecognition = SettingsStore.shared.privateSpeech && recognizer.supportsOnDeviceRecognition
        feed.current = request
        feed.attachSink { request.append($0) }

        task = Self.recognize(with: recognizer, request: request) { [weak self] text, alternatives, isFinal, failed in
            Task { @MainActor in
                self?.legacyAlternatives = alternatives
                self?.recognized(text, isFinal: isFinal, failed: failed, request: request)
            }
        }
    }

    private func recognized(_ text: String?, isFinal: Bool, failed: Bool, request: SFSpeechAudioBufferRecognitionRequest) {
        guard isListening, feed.current === request else { return }
        if let text, text != partial {
            noteTextChange(from: partial, to: text)
            partial = text
            transcript = [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard isFinal || failed else { return }

        // The recognizer closed this segment. Keep what it heard and keep listening for the rest.
        if !partial.isEmpty { committed = transcript }
        partial = ""
        if failed && committed.isEmpty && !heardVoice {
            stop(send: false)
            return
        }
        if let recognizer, recognizer.isAvailable, segments < 12 {
            beginSegment(with: recognizer)
        } else {
            stop(send: true)
        }
    }

    // MARK: - Knowing when the user is done

    /// Tracks the microphone level and the room's background noise, to tell real speech from silence.
    private func heard(_ value: CGFloat) {
        guard isListening else { return }
        level = value
        if value < noiseFloor {
            noiseFloor = noiseFloor * 0.8 + value * 0.2
        } else {
            // Learn steady background sound (fans, music) fairly quickly so it isn't mistaken for speech.
            noiseFloor += (value - noiseFloor) * 0.02
        }
        let speechThreshold = max(noiseFloor * 3.2, 0.14)
        if value > speechThreshold {
            lastVoice = Date()
            heardVoice = true
        }
    }

    private func checkEndpoint() {
        guard isListening else { return }
        let now = Date()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if now.timeIntervalSince(startedAt) > maxDuration {
            stop(send: true)
            return
        }
        if text.isEmpty {
            // Nothing recognized yet: give up if nobody spoke; allow extra time if someone is talking.
            let limit = heardVoice ? waitForSpeech + 5 : waitForSpeech
            if now.timeIntervalSince(startedAt) > limit { stop(send: heardVoice) }
            return
        }

        // Finished when no new words have arrived for the pause, and the mic has gone quiet too. Words are what
        // count: if the words stopped but there's still sound (noise, music, a breath), stop soon after anyway.
        let pause = pauseNeeded(after: text)
        let wordsStopped = now.timeIntervalSince(lastTextChange)
        let quiet = now.timeIntervalSince(max(lastVoice, lastTextChange))
        if quiet >= pause || wordsStopped >= pause + 0.6 {
            stop(send: true)
        }
    }

    /// Counts only real new words: the recognizer often re-punctuates or recases the text a moment after the user
    /// stops, and those revisions shouldn't keep Saturday waiting.
    private func noteTextChange(from old: String, to new: String) {
        func words(_ text: String) -> [Substring] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }
        if words(old) != words(new) { lastTextChange = Date() }
    }

    /// How long a pause must be before Saturday treats the request as finished.
    private func pauseNeeded(after text: String) -> TimeInterval {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard let lastRaw = words.last else { return 1.3 }
        let last = lastRaw.trimmingCharacters(in: .punctuationCharacters)
        // "…and", "…to the", "um": clearly mid-thought.
        if Self.continuationWords.contains(last) { return 2.0 }
        // Very short so far ("Saturday", "Hey"): the real request usually follows.
        if words.count <= 2 { return 1.5 }
        // A question or exclamation usually ends the turn.
        if text.hasSuffix("?") || text.hasSuffix("!") { return 0.8 }
        if text.hasSuffix(".") { return 1.0 }
        return 1.2
    }

    // MARK: - Audio thread helpers

    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        feed: RequestFeed,
        level: @escaping @Sendable (CGFloat) -> Void
    ) {
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            feed.deliver(buffer)
            level(AudioLevel.rms(buffer))
        }
    }

    nonisolated private static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, [String], Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let alternatives = result?.transcriptions.dropFirst().prefix(2).map(\.formattedString) ?? []
            handler(result?.bestTranscription.formattedString, alternatives, result?.isFinal ?? false, error != nil)
        }
    }
}

/// Routes microphone buffers to whichever recognizer is active. Until one is attached, audio is held
/// (up to a few seconds) so the first words aren't lost while a recognizer starts.
final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var pending: [AVAudioPCMBuffer] = []
    private var buffering = false

    var current: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { request } }
        set { lock.withLock { request = newValue } }
    }

    func startBuffering() {
        lock.withLock {
            pending = []
            buffering = true
            sink = nil
        }
    }

    /// Connects a recognizer and hands it any audio captured so far.
    func attachSink(_ newSink: @escaping (AVAudioPCMBuffer) -> Void) {
        let held: [AVAudioPCMBuffer] = lock.withLock {
            sink = newSink
            buffering = false
            defer { pending = [] }
            return pending
        }
        held.forEach(newSink)
    }

    func detachSink() {
        lock.withLock {
            sink = nil
            buffering = false
            pending = []
        }
    }

    /// Called on the audio thread for every microphone buffer.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        let target: ((AVAudioPCMBuffer) -> Void)? = lock.withLock {
            if let sink { return sink }
            if buffering, pending.count < 300, let copy = Self.copy(buffer) { pending.append(copy) }
            return nil
        }
        target?(buffer)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
            return copy
        }
        return nil
    }
}

enum AudioLevel {
    /// A 0–1 loudness value for driving the orb animation and detecting speech.
    static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var n = 0
        for i in stride(from: 0, to: count, by: 4) {
            sum += samples[i] * samples[i]
            n += 1
        }
        return CGFloat(min(1, sqrt(sum / Float(max(n, 1))) * 10))
    }
}
