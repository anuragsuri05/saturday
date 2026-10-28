import AVFoundation
import Foundation

/// Saturday's voice through OpenAI GPT-Live: a full-duplex speech model that listens and talks at the
/// same time, so the user can interrupt it like a person. GPT-Live runs the spoken conversation and hands
/// real work (questions, the screen, memory, Mac actions) to Saturday's own brain via client delegation.
/// Docs: https://developers.openai.com/api/docs/guides/live
@MainActor
final class LiveVoice: ObservableObject {
    static let voices = [
        "marin", "cedar", "alloy", "ash", "ballad", "beacon", "bossa", "brise", "cinder", "coral", "delta",
        "echo", "flitz", "gleam", "harema", "juni", "meridian", "nira", "noeul", "nuri", "quartz", "ripple",
        "sage", "shida",
    ]

    @Published private(set) var isActive = false
    @Published private(set) var isUserSpeaking = false
    @Published private(set) var isAssistantSpeaking = false
    @Published private(set) var level: CGFloat = 0
    /// What the user has said in the current turn.
    @Published private(set) var userTranscript = ""

    var onStarted: (@MainActor () -> Void)?
    var onUserText: (@MainActor (String) -> Void)?
    var onAssistantText: (@MainActor (String) -> Void)?
    var onDelegation: (@MainActor (String) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onEnded: (@MainActor () -> Void)?

    private var socket: URLSessionWebSocketTask?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var streamer: MicStreamer?
    private var engineReady = false
    private var echoCancelled = false
    private var started = false
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var userTurnEnded = true
    private var interruptChars = 0
    private var busy = false
    private var eventNumber = 0
    private var idleTimer: Timer?
    private var userSpeechTimer: Timer?
    private var closeFallback: DispatchWorkItem?

    /// Ends the session after this long with nobody talking, since GPT-Live is billed per minute.
    private let idleTimeout: TimeInterval = 25

    // MARK: - Checking whether a credential can use GPT-Live

    enum ProbeResult: Equatable {
        case accepted
        case rejected(String)
    }

    /// Opens a GPT-Live session without audio and closes it straight away, to find out whether this
    /// credential (an API key or a ChatGPT plan token) is allowed to use the voice agent.
    static func probe(bearer: String) async -> ProbeResult {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let start: [String: Any] = [
            "type": "session.start", "event_id": "saturday_probe",
            "session": ["model": "gpt-live-1", "delegation": ["type": "client"]] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: start), let text = String(data: data, encoding: .utf8) else {
            return .rejected("couldn't build the request")
        }

        return await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask {
                do {
                    try await socket.send(.string(text))
                    while true {
                        guard case .string(let reply) = try await socket.receive(),
                              let event = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
                        else { continue }
                        switch event["type"] as? String {
                        case "session.started":
                            try? await socket.send(.string("{\"type\":\"session.close\",\"event_id\":\"saturday_probe_close\"}"))
                            return .accepted
                        case "error":
                            let error = event["error"] as? [String: Any]
                            let code = error?["code"] as? String ?? "error"
                            return .rejected("\(code): \(error?["message"] as? String ?? "no details")")
                        case "session.closed":
                            return .rejected("the session was closed immediately")
                        default:
                            continue
                        }
                    }
                } catch {
                    if let http = socket.response as? HTTPURLResponse {
                        return .rejected("HTTP \(http.statusCode) when connecting")
                    }
                    return .rejected(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .rejected("no answer within 10 seconds")
        }
    }

    // MARK: - Session

    func start(apiKey: String, instructions: String, history: [Turn], voice: String) async {
        guard !isActive else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            onError?("Saturday needs Microphone access. Turn it on in System Settings → Privacy & Security → Microphone.")
            return
        }
        isActive = true
        started = false
        userTranscript = ""
        userTurnEnded = true

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        var session: [String: Any] = [
            "model": "gpt-live-1",
            "instructions": instructions,
            "audio": ["format": ["type": "audio/pcm", "rate": 24000], "output": ["voice": voice]] as [String: Any],
            "delegation": ["type": "client"],
        ]
        let items = Self.historyItems(history)
        if !items.isEmpty { session["input"] = items }
        send(["type": "session.start", "event_id": nextEventID(), "session": session])

        Task { await receive(on: socket) }
        resetIdleTimer()
    }

    /// Gracefully ends the conversation.
    func close() {
        guard isActive else { return }
        if started {
            send(["type": "session.close", "event_id": nextEventID()])
            let fallback = DispatchWorkItem { [weak self] in self?.teardown() }
            closeFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fallback)
        } else {
            teardown()
        }
    }

    /// Sends the brain's result for GPT-Live to say in its own words.
    func deliver(_ result: String, delegationID: String) {
        guard started else { return }
        send([
            "type": "session.commentary.append", "event_id": nextEventID(),
            "delegation_id": delegationID, "content": String(result.prefix(1500)),
        ])
        resetIdleTimer()
    }

    /// Background facts GPT-Live can use without saying them right away.
    func addContext(_ text: String, delegationID: String? = nil) {
        guard started else { return }
        send([
            "type": "session.thinking.append", "event_id": nextEventID(),
            "delegation_id": delegationID ?? NSNull(), "content": String(text.prefix(1500)),
        ])
    }

    /// The user pressed the shortcut while Saturday was talking: stop and listen.
    func yieldToUser() {
        flushPlayback()
        guard started else { return }
        send([
            "type": "session.instructions.append", "event_id": nextEventID(), "delegation_id": NSNull(),
            "content": "The user wants to speak. Stop talking right away and listen.",
        ])
    }

    /// Saturday's brain is working on a delegated task, so the session shouldn't time out.
    func setBusy(_ value: Bool) {
        busy = value
        resetIdleTimer()
    }

    // MARK: - Events

    private func receive(on socket: URLSessionWebSocketTask) async {
        do {
            while self.socket === socket {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                else { continue }
                handle(event)
            }
        } catch {
            if isActive {
                if !started { onError?(Self.describe(error)) }
                teardown()
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.started":
            started = true
            startAudio()
            onStarted?()
        case "session.output_audio.delta":
            if let encoded = event["delta"] as? String, let pcm = Data(base64Encoded: encoded) { play(pcm) }
        case "session.output_transcript.delta":
            interruptChars = 0
            userTurnEnded = true
            if let delta = event["delta"] as? String { onAssistantText?(delta) }
            resetIdleTimer()
        case "session.input_transcript.delta":
            guard let delta = event["delta"] as? String else { return }
            if userTurnEnded {
                userTranscript = ""
                userTurnEnded = false
            }
            userTranscript += delta
            markUserSpeaking()
            // Barge-in: if the user really starts talking over Saturday, stop the queued audio.
            interruptChars += delta.count
            if isAssistantSpeaking && interruptChars > 12 { flushPlayback() }
            onUserText?(delta)
            resetIdleTimer()
        case "session.delegation.created":
            if let delegation = event["delegation"] as? [String: Any],
               delegation["target"] as? String == "client",
               let id = delegation["id"] as? String {
                onDelegation?(id)
            }
            resetIdleTimer()
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The voice session had a problem."
            onError?(message)
            if !started { teardown() }
        case "session.closed":
            teardown()
        default:
            break
        }
    }

    // MARK: - Audio

    private func startAudio() {
        guard !engineReady else { return }
        let input = engine.inputNode
        do {
            // Echo cancellation, so Saturday doesn't hear its own voice and interrupt itself.
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            echoCancelled = true
        } catch {
            echoCancelled = false
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let socket else {
            onError?("No microphone found.")
            close()
            return
        }
        let streamer = MicStreamer(input: format, socket: socket) { [weak self] level in
            Task { @MainActor in
                guard let self, !self.isAssistantSpeaking else { return }
                self.level = level
            }
        }
        guard let streamer else {
            onError?("Couldn't read the microphone.")
            close()
            return
        }
        self.streamer = streamer
        Self.installTap(on: input, streamer: streamer)
        engine.prepare()
        do {
            try engine.start()
            player.play()
            engineReady = true
        } catch {
            input.removeTap(onBus: 0)
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            close()
        }
    }

    private func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard engineReady, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                let value = Float(Int16(bitPattern: UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8)) / 32768
                samples[i] = value
                sum += value * value
            }
        }
        level = CGFloat(min(1, sqrt(sum / Float(frames)) * 10))
        if !player.isPlaying { player.play() }
        pendingBuffers += 1
        setAssistantSpeaking(true)
        // Without echo cancellation, mute the mic while Saturday talks so it doesn't hear itself.
        if !echoCancelled { send(["type": "session.input_audio.mute", "event_id": nextEventID()]) }
        let generation = playbackGeneration
        Self.schedule(buffer, on: player) { [weak self] in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers <= 0 { self.playbackFinished() }
            }
        }
        resetIdleTimer()
    }

    private func flushPlayback() {
        playbackGeneration += 1
        player.stop()
        player.play()
        pendingBuffers = 0
        playbackFinished()
    }

    private func playbackFinished() {
        pendingBuffers = 0
        setAssistantSpeaking(false)
        level = 0
        if !echoCancelled, started { send(["type": "session.input_audio.unmute", "event_id": nextEventID()]) }
        resetIdleTimer()
    }

    private func setAssistantSpeaking(_ value: Bool) {
        if isAssistantSpeaking != value { isAssistantSpeaking = value }
    }

    private func markUserSpeaking() {
        if !isUserSpeaking { isUserSpeaking = true }
        userSpeechTimer?.invalidate()
        userSpeechTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.isUserSpeaking = false }
        }
    }

    // MARK: - Lifecycle helpers

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        guard isActive else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if self.busy || self.isAssistantSpeaking || self.isUserSpeaking {
                    self.resetIdleTimer()
                } else {
                    self.close()
                }
            }
        }
    }

    private func teardown() {
        guard isActive else { return }
        closeFallback?.cancel()
        idleTimer?.invalidate()
        userSpeechTimer?.invalidate()
        if engineReady {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            engineReady = false
        }
        streamer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isActive = false
        started = false
        busy = false
        isUserSpeaking = false
        setAssistantSpeaking(false)
        level = 0
        onEnded?()
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { _ in }
    }

    private func nextEventID() -> String {
        eventNumber += 1
        return "saturday_\(eventNumber)"
    }

    /// Recent conversation as GPT-Live's initial text history (one text part per message, kept short).
    private static func historyItems(_ history: [Turn]) -> [[String: Any]] {
        history.suffix(12).compactMap { turn in
            let text = String(DisplayText.clean(turn.text).prefix(1200))
            guard !text.isEmpty else { return nil }
            let part: [String: Any] = turn.role == .user ? ["type": "input_text", "text": text] : ["type": "output_text", "text": text]
            return ["type": "message", "role": turn.role.rawValue, "content": [part]]
        }
    }

    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("401") || text.lowercased().contains("bad response") {
            return "The voice agent couldn't connect. Check your OpenAI API key in Settings → Accounts."
        }
        return "The voice agent couldn't connect: \(text)"
    }

    // MARK: - Audio thread helpers

    nonisolated private static func installTap(on input: AVAudioInputNode, streamer: MicStreamer) {
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2400, format: input.outputFormat(forBus: 0)) { buffer, _ in
            streamer.process(buffer)
        }
    }

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode, done: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }
}

/// Converts microphone audio to 24 kHz mono PCM16 and streams it to GPT-Live. Runs on the audio thread.
final class MicStreamer: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private let socket: URLSessionWebSocketTask
    private let level: @Sendable (CGFloat) -> Void

    init?(input: AVAudioFormat, socket: URLSessionWebSocketTask, level: @escaping @Sendable (CGFloat) -> Void) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.socket = socket
        self.level = level
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        level(AudioLevel.rms(buffer))
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000 / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
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
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
        let audio = Data(bytes: samples, count: Int(converted.frameLength) * 2).base64EncodedString()
        socket.send(.string("{\"type\":\"session.input_audio.append\",\"audio\":\"\(audio)\"}")) { _ in }
    }
}
