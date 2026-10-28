import CSherpa
import Foundation

/// The free on-device neural voice models Saturday can use.
enum NeuralVoiceModel: String, CaseIterable, Identifiable, Sendable {
    /// Supertonic 3 (MIT code, OpenRAIL-M model): built for speed on ordinary processors.
    case supertonic
    /// Kokoro v1.0 (Apache-2.0): very natural, best on Apple Silicon.
    case kokoro

    var id: String { rawValue }

    /// Supertonic on Intel Macs (where Kokoro can't keep up with speech), Kokoro on Apple Silicon.
    static var recommended: NeuralVoiceModel {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("arm64") ? .kokoro : .supertonic
    }

    var label: String {
        switch self {
        case .supertonic: "Supertonic · fast on any Mac"
        case .kokoro: "Kokoro · richest voice, best on Apple Silicon"
        }
    }

    var downloadSize: String {
        switch self {
        case .supertonic: "about 150 MB"
        case .kokoro: "about 150 MB"
        }
    }

    fileprivate var archiveURL: URL {
        switch self {
        case .supertonic: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2")!
        case .kokoro: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2")!
        }
    }

    fileprivate var archiveFolder: String {
        switch self {
        case .supertonic: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11"
        case .kokoro: "kokoro-int8-multi-lang-v1_0"
        }
    }

    /// Files kept from the archive (the rest is other languages or unused precision).
    fileprivate var files: [String] {
        switch self {
        case .supertonic:
            ["duration_predictor.int8.onnx", "text_encoder.int8.onnx", "vector_estimator.int8.onnx", "vocoder.int8.onnx",
             "tts.json", "unicode_indexer.bin", "voice.bin", "LICENSE"]
        case .kokoro:
            ["model.int8.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt", "LICENSE"]
        }
    }

    /// Voices with their speaker IDs in the model.
    var voices: [(id: Int32, label: String)] {
        switch self {
        case .supertonic:
            (0..<5).map { (Int32($0), "Female \($0 + 1)") } + (0..<5).map { (Int32($0 + 5), "Male \($0 + 1)") }
        case .kokoro:
            [(3, "Heart · warm, the most natural (US)"), (2, "Bella · bright and friendly (US)"),
             (6, "Nicole · soft, close-up (US)"), (9, "Sarah · calm, clear (US)"), (7, "Nova · confident (US)"),
             (10, "Sky · light, youthful (US)"), (16, "Michael · relaxed, warm (US)"), (14, "Fenrir · deep, confident (US)"),
             (18, "Puck · upbeat (US)"), (11, "Adam · steady (US)"), (12, "Echo · smooth (US)"),
             (21, "Emma · polished (UK)"), (22, "Isabella · warm (UK)"), (26, "George · classic (UK)"),
             (25, "Fable · storyteller (UK)"), (27, "Lewis · calm (UK)")]
        }
    }

    var defaultVoice: Int32 { self == .kokoro ? 3 : 0 }
}

/// Saturday's free, human-like voice that runs entirely on this Mac through the sherpa-onnx engine.
/// No account, no key, no internet once it's downloaded.
@MainActor
final class LocalVoice: ObservableObject {
    static let shared = LocalVoice()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    var isReady: Bool { state == .ready }
    var model: NeuralVoiceModel { SettingsStore.shared.localModel }

    private static let engineURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-universal2-shared-lib.tar.bz2")!
    private var installTask: Task<Void, Never>?

    private init() {
        LocalVoiceFiles.migrateOldLayout()
        refresh()
    }

    /// Re-reads what's installed for the selected model.
    func refresh() {
        guard installTask == nil else { return }
        state = LocalVoiceFiles.installed(model) ? .ready : .notInstalled
    }

    /// Downloads the voice engine (once) and the selected model, then unpacks them.
    func install() {
        guard installTask == nil, !LocalVoiceFiles.installed(model) else { return refresh() }
        let model = self.model
        installTask = Task {
            defer { installTask = nil }
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("saturday-voice-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: work) }

                let needsEngine = !LocalVoiceFiles.engineInstalled
                state = .downloading(0)
                var engineArchive: URL?
                if needsEngine {
                    engineArchive = try await Downloader.download(Self.engineURL, to: work.appendingPathComponent("engine.tar.bz2")) { [weak self] p in
                        self?.state = .downloading(p * 0.12)
                    }
                }
                let start = needsEngine ? 0.12 : 0
                let modelArchive = try await Downloader.download(model.archiveURL, to: work.appendingPathComponent("model.tar.bz2")) { [weak self] p in
                    self?.state = .downloading(start + p * (1 - start))
                }

                state = .installing
                try await Self.unpack(engine: engineArchive, model: modelArchive, for: model, in: work)
                guard LocalVoiceFiles.installed(model) else { throw AuthError("The download was incomplete. Please try again.") }
                state = .ready
                NeuralVoiceEngine.shared.prewarm(model)
                await VoiceCheck.checkOfflineVoice()
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func remove() {
        NeuralVoiceEngine.shared.unload()
        try? FileManager.default.removeItem(at: LocalVoiceFiles.modelFolder(model))
        state = .notInstalled
    }

    /// Extracts the archives off the main thread and keeps only what the voice needs.
    nonisolated private static func unpack(engine: URL?, model archive: URL, for model: NeuralVoiceModel, in work: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if let engine {
                try run("/usr/bin/tar", ["-xjf", engine.path, "-C", work.path])
                let engineDir = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("sherpa-onnx-v") && $0.hasDirectoryPath }
                guard let engineDir else { throw AuthError("The voice engine archive looked wrong.") }
                let lib = LocalVoiceFiles.libFolder
                try? fm.removeItem(at: lib)
                try fm.createDirectory(at: lib, withIntermediateDirectories: true)
                for name in ["libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"] {
                    try fm.moveItem(at: engineDir.appendingPathComponent("lib/\(name)"), to: lib.appendingPathComponent(name))
                }
            }

            try run("/usr/bin/tar", ["-xjf", archive.path, "-C", work.path])
            let source = work.appendingPathComponent(model.archiveFolder)
            let target = LocalVoiceFiles.modelFolder(model)
            try? fm.removeItem(at: target)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in model.files where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
                try fm.moveItem(at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
        }.value
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw AuthError("Unpacking the voice failed (\(process.terminationStatus)).") }
    }
}

/// The loaded neural voice. Generation runs on one background queue, one phrase at a time,
/// so the next phrase is synthesized while the current one plays.
final class NeuralVoiceEngine: @unchecked Sendable {
    static let shared = NeuralVoiceEngine()

    private let queue = DispatchQueue(label: "com.saturday.neural-voice", qos: .userInitiated)
    private var tts: OpaquePointer?
    private var loadedModel: NeuralVoiceModel?
    private var sampleRate: Int32 = 24000
    private var loadError: String?

    /// Loads the model in the background so the first reply doesn't wait for it.
    func prewarm(_ model: NeuralVoiceModel) {
        queue.async { _ = self.load(model) }
    }

    func unload() {
        queue.sync { self.release() }
    }

    /// Speaks `text` and returns it as 24 kHz 16-bit PCM (one chunk per phrase).
    func stream(text: String, model: NeuralVoiceModel, speaker: Int32, speed: Float) -> AsyncThrowingStream<Data, Error> {
        let spoken = SpokenText.normalize(text)
        return AsyncThrowingStream { continuation in
            queue.async {
                guard let tts = self.load(model) else {
                    continuation.finish(throwing: AuthError(self.loadError ?? "The offline voice isn't available."))
                    return
                }
                var count: Int32 = 0
                let samples: UnsafeMutablePointer<Float>? = spoken.withCString { text in
                    switch model {
                    case .supertonic:
                        // 8 flow steps: the quality/speed balance sherpa-onnx's own example uses.
                        return "{\"lang\": \"en\"}".withCString { extra in
                            saturday_tts_generate_ex(tts, text, speaker, speed, 8, extra, &count)
                        }
                    case .kokoro:
                        return saturday_tts_generate(tts, text, speaker, speed, &count)
                    }
                }
                guard let samples, count > 0 else {
                    continuation.finish(throwing: AuthError("The offline voice couldn't say that."))
                    return
                }
                defer { saturday_tts_free_samples(samples) }
                continuation.yield(Self.pcm16(UnsafeBufferPointer(start: samples, count: Int(count)), from: self.sampleRate))
                continuation.finish()
            }
        }
    }

    /// Must be called on `queue`.
    private func load(_ model: NeuralVoiceModel) -> OpaquePointer? {
        if let tts, loadedModel == model { return tts }
        release()
        guard LocalVoiceFiles.installed(model) else {
            loadError = "The offline voice isn't downloaded yet."
            return nil
        }
        var error = [CChar](repeating: 0, count: 512)
        let dir = LocalVoiceFiles.modelFolder(model).path
        let lib = LocalVoiceFiles.libFolder.path
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
        let handle: OpaquePointer?
        switch model {
        case .supertonic:
            handle = saturday_tts_create_supertonic(lib, dir, threads, &error, Int32(error.count))
        case .kokoro:
            handle = saturday_tts_create(lib, "\(dir)/model.int8.onnx", "\(dir)/voices.bin", "\(dir)/tokens.txt",
                                         "\(dir)/lexicon-us-en.txt", "en-us", threads, &error, Int32(error.count))
        }
        guard let handle else {
            loadError = String(cString: error)
            return nil
        }
        tts = handle
        loadedModel = model
        sampleRate = saturday_tts_sample_rate(handle)
        return handle
    }

    private func release() {
        if let tts { saturday_tts_destroy(tts) }
        tts = nil
        loadedModel = nil
        loadError = nil
    }

    /// Float samples → 24 kHz little-endian PCM16, resampling linearly if the model uses another rate.
    private static func pcm16(_ samples: UnsafeBufferPointer<Float>, from rate: Int32) -> Data {
        let ratio = Double(rate) / 24000
        let count = rate == 24000 ? samples.count : Int(Double(samples.count) / ratio)
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let value: Float
                if rate == 24000 {
                    value = samples[i]
                } else {
                    let position = Double(i) * ratio
                    let index = min(Int(position), samples.count - 1)
                    let next = min(index + 1, samples.count - 1)
                    let t = Float(position - Double(index))
                    value = samples[index] * (1 - t) + samples[next] * t
                }
                out[i] = Int16(max(-1, min(1, value)) * 32767).littleEndian
            }
        }
        return data
    }
}

/// File locations, readable from any thread.
enum LocalVoiceFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saturday/Voices", isDirectory: true)
    }
    static var libFolder: URL { root.appendingPathComponent("engine/lib", isDirectory: true) }
    static func modelFolder(_ model: NeuralVoiceModel) -> URL { root.appendingPathComponent(model.rawValue, isDirectory: true) }

    static var engineInstalled: Bool {
        FileManager.default.fileExists(atPath: libFolder.appendingPathComponent("libsherpa-onnx-c-api.dylib").path)
    }

    static func installed(_ model: NeuralVoiceModel) -> Bool {
        engineInstalled && model.files.filter { $0 != "LICENSE" && !$0.hasPrefix("lexicon-gb") }.allSatisfy {
            FileManager.default.fileExists(atPath: modelFolder(model).appendingPathComponent($0).path)
        }
    }

    /// The first version kept the engine and Kokoro under Voices/kokoro/{lib,model}.
    static func migrateOldLayout() {
        let fm = FileManager.default
        let old = root.appendingPathComponent("kokoro", isDirectory: true)
        guard fm.fileExists(atPath: old.appendingPathComponent("lib").path) else { return }
        try? fm.createDirectory(at: libFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !engineInstalled { try? fm.moveItem(at: old.appendingPathComponent("lib"), to: libFolder) }
        let staging = root.appendingPathComponent("kokoro-model-\(UUID().uuidString)")
        try? fm.moveItem(at: old.appendingPathComponent("model"), to: staging)
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: staging, to: modelFolder(.kokoro))
    }
}

/// Rewrites text so a dictionary-based voice reads it well: numbers, money, percentages and symbols become words.
enum SpokenText {
    static func normalize(_ text: String) -> String {
        var s = SpeechText.removingCues(text)
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = replace(#"\$(\d+)\.(\d{2})\b"#, in: s) { groups in
            let cents = Int(groups[2]) ?? 0
            return cents == 0 ? "\(words(groups[1])) dollars" : "\(words(groups[1])) dollars and \(words(groups[2])) cents"
        }
        s = replace(#"\$(\d+(?:,\d{3})*)"#, in: s) { "\(words($0[1].replacingOccurrences(of: ",", with: ""))) dollars" }
        // Years are said in pairs: "twenty twenty six", "nineteen ninety".
        s = replace(#"\b(19|20)(\d{2})\b(?![.,]\d)"#, in: s) { groups in
            let tail = Int(groups[2]) ?? 0
            if tail == 0 { return groups[1] == "20" ? "two thousand" : "nineteen hundred" }
            if tail < 10 { return "\(words(groups[1])) oh \(words(groups[2]))" }
            return "\(words(groups[1])) \(words(groups[2]))"
        }
        s = replace(#"(\d+(?:\.\d+)?)\s?%"#, in: s) { "\(words($0[1])) percent" }
        s = replace(#"(\d{1,2}):(\d{2})"#, in: s) { groups in
            if groups[2] == "00" { return "\(words(groups[1])) o'clock" }
            return groups[2].hasPrefix("0") ? "\(words(groups[1])) oh \(words(groups[2]))" : "\(words(groups[1])) \(words(groups[2]))"
        }
        s = replace(#"\d+(?:[.,]\d+)*"#, in: s) { words($0[0].replacingOccurrences(of: ",", with: "")) }
        return s
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static func words(_ number: String) -> String {
        guard let value = Double(number) else { return number }
        return formatter.string(from: NSNumber(value: value))?.replacingOccurrences(of: "-", with: " ") ?? number
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: transform(groups))
            }
        }
        return result
    }
}

/// Downloads a file with progress.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(destination: URL, progress: @escaping @MainActor (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let downloader = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let report = progress
        Task { @MainActor in report(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AuthError("Download failed (HTTP \(http.statusCode)).")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
