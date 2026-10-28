import AVFoundation
import Speech

/// Apple's newer on-device speech model (macOS 26 SpeechAnalyzer + SpeechTranscriber): far more accurate than
/// the classic recognizer, especially with accents and names. Fed the same microphone buffers, it reports
/// live partial text, final text, and alternative readings for Saturday's brain to choose between.
@available(macOS 26.0, *)
final class ModernTranscription: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var resultsTask: Task<(String, [String]), Never>?
    private let lock = NSLock()

    /// Text finalized so far, the current partial text, and alternative readings of finalized segments.
    private var finalized = ""
    private var volatile = ""
    private var alternativeSegments: [String] = []

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
        self.input = input
    }

    /// The locale the new model supports for this Mac's language (e.g. en-IN), if any.
    static func locale() async -> Locale? {
        if let local = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return local }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    /// Whether the model for this language is already on the Mac.
    static func isReady() async -> Bool {
        guard SpeechTranscriber.isAvailable, let locale = await locale() else { return false }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [probe]) == .installed
    }

    /// Downloads Apple's speech model for this language if needed (one time, done by macOS).
    static func prepare() async {
        guard SpeechTranscriber.isAvailable, let locale = await locale() else { return }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }
    }

    /// Starts a transcription session. `onUpdate` receives the full text so far whenever it changes.
    static func start(vocabulary: [String], onUpdate: @escaping @Sendable (String) -> Void) async throws -> ModernTranscription {
        guard let locale = await locale() else { throw AuthError("This language isn't supported by the new speech model.") }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
            attributeOptions: []
        )
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AuthError("The speech model has no compatible audio format.")
        }
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let session = ModernTranscription(analyzer: analyzer, transcriber: transcriber, format: format, input: continuation)
        session.resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    session.lock.withLock {
                        if result.isFinal {
                            session.finalized += text
                            session.volatile = ""
                            let alternative = result.alternatives.dropFirst().first.map { String($0.characters) }
                            session.alternativeSegments.append(alternative ?? text)
                        } else {
                            session.volatile = text
                        }
                    }
                    onUpdate(session.currentText)
                }
            } catch {
                // The session ended; whatever was recognized is kept.
            }
            return session.lock.withLock {
                let main = (session.finalized + session.volatile).trimmingCharacters(in: .whitespacesAndNewlines)
                let alternative = session.alternativeSegments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                return (main, alternative.isEmpty || alternative == main ? [] : [alternative])
            }
        }
        try await analyzer.start(inputSequence: stream)
        return session
    }

    var currentText: String {
        lock.withLock { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Called from the microphone tap: converts to the model's format and queues the audio.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Ends the audio and waits for the final text plus any alternative reading.
    func finish() async -> (text: String, alternatives: [String]) {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await resultsTask?.value ?? (currentText, [])
    }

    func cancel() {
        input.finish()
        resultsTask?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// Words Saturday expects to hear (app names, things it remembers about the user), given to the recognizer
/// so names come out right.
@MainActor
enum SpeechVocabulary {
    static var words: [String] {
        var words = ["Saturday", "Spotify", "YouTube", "Apple Music", "WhatsApp", "ChatGPT"]
        words += LocalCommands.installedAppNames.filter { $0.count > 2 }.prefix(60)
        for item in MemoryStore.shared.items {
            words += item.text.split(separator: " ").map(String.init).filter { $0.count > 2 && $0.first?.isUppercase == true }
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.prefix(100).map { $0 }
    }
}
