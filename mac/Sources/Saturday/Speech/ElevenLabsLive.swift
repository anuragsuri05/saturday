import Foundation

/// One continuous ElevenLabs voice stream for a whole reply. Text is sent as it's written and audio comes
/// back as one flowing performance, so intonation carries across sentences like a person talking.
/// Eleven v3/v4 models use the dialogue socket (the most expressive voices, with [laughs]-style audio tags);
/// other models use the text-to-speech socket.
@MainActor
final class ElevenLabsLive {
    static let models: [(id: String, label: String)] = [
        ("eleven_v4_turbo", "Eleven v4 Turbo (newest, most human)"),
        ("eleven_v3_conversational", "Eleven v3 Conversational (very expressive)"),
        ("eleven_flash_v2_5", "Flash v2.5 (fastest)"),
    ]

    /// A few well-known ElevenLabs voices. Any voice ID from the Voice Library also works.
    static let voices: [(id: String, name: String)] = [
        ("21m00Tcm4TlvDq8ikWAM", "Rachel · calm, warm"),
        ("EXAVITQu4vr4xnSDxMaL", "Bella · soft, friendly"),
        ("MF3mGyEYCl7XYWbV9V6O", "Elli · young, bright"),
        ("AZnzlk1XvdvUeBnXmlld", "Domi · strong, confident"),
        ("pNInz6obpgDQGcFmaJgB", "Adam · deep, steady"),
        ("ErXwobaYiN019PkySvjV", "Antoni · smooth, warm"),
        ("TxGEqnHWrfWFTfGW9XCX", "Josh · young, relaxed"),
        ("yoZ06aMxZJJ28mfd3POQ", "Sam · raspy, cool"),
    ]

    static func isDialogueModel(_ model: String) -> Bool {
        model.hasPrefix("eleven_v3") || model.hasPrefix("eleven_v4")
    }

    let audio: AsyncThrowingStream<Data, Error>
    let model: String
    private(set) var sentText = ""

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let socket: URLSessionWebSocketTask
    private let voiceID: String
    private let dialogue: Bool
    private var sentAny = false
    private var closing = false
    private var gotAudio = false
    private var ended = false

    init(key: String, voiceID: String, model: String, stability: Double) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.audio = stream
        self.continuation = continuation
        self.model = model
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dialogue = Self.isDialogueModel(model)

        let path = dialogue ? "/v1/text-to-dialogue/stream-input" : "/v1/text-to-speech/\(self.voiceID)/stream-input"
        var components = URLComponents(string: "wss://api.elevenlabs.io" + path)!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "output_format", value: "pcm_24000"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()

        if dialogue {
            send(["voices": [self.voiceID], "voice_settings": ["stability": stability]])
        } else {
            let settings: [String: Any] = ["stability": stability, "similarity_boost": 0.8, "style": 0.35, "use_speaker_boost": true]
            send(["text": " ", "voice_settings": settings, "generation_config": ["chunk_length_schedule": [50, 120, 200, 260]]])
        }
        Task { await receive() }
    }

    /// Adds the next piece of the reply. `tone` (first piece only) sets the emotion for the delivery.
    func speak(_ text: String, tone: String?) {
        guard !ended else { return }
        var spoken = Self.performable(text, dialogue: dialogue)
        if dialogue, !sentAny, let tone, !tone.isEmpty { spoken = "[\(tone)] " + spoken }
        guard !spoken.isEmpty else { return }
        sentText += (sentText.isEmpty ? "" : " ") + SpeechText.removingCues(text)
        if dialogue {
            send(["inputs": [["text": spoken + " ", "voice_id": voiceID]]])
        } else {
            send(["text": spoken + " "])
        }
        if !sentAny {
            // Start talking right away instead of waiting for the server's text buffer to fill.
            sentAny = true
            send(dialogue ? ["flush": true] : ["text": " ", "flush": true])
        }
    }

    func finish() {
        guard !ended, !closing else { return }
        closing = true
        if !sentAny {
            cancel()
            return
        }
        send(dialogue ? ["close_socket": true] : ["text": ""])
    }

    func cancel() {
        guard !ended else { return }
        ended = true
        socket.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    // MARK: - Socket

    private func receive() async {
        do {
            while !ended {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

                if let encoded = object["audio"] as? String, let pcm = Data(base64Encoded: encoded), !pcm.isEmpty {
                    gotAudio = true
                    continuation.yield(pcm)
                } else if object["audio"] == nil, let problem = Self.errorMessage(object) {
                    throw APIError.badResponse(problem)
                }
                if object["isFinal"] as? Bool == true || object["is_final"] as? Bool == true { break }
            }
            end(nil)
        } catch {
            // The server closes the socket after the final audio; that's a normal ending.
            end(closing && gotAudio ? nil : error)
        }
    }

    private func end(_ error: Error?) {
        guard !ended else { return }
        ended = true
        socket.cancel(with: .normalClosure, reason: nil)
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.end(error) }
        }
    }

    private static func errorMessage(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? "ElevenLabs error" }
        if let error = object["error"] as? String { return object["message"] as? String ?? error }
        if object["code"] != nil, let message = object["message"] as? String { return message }
        return nil
    }

    /// Turns Saturday's voice cues into ElevenLabs audio tags (v3/v4), or removes them for other models.
    static func performable(_ text: String, dialogue: Bool) -> String {
        guard dialogue else { return SpeechText.removingCues(text) }
        return text
            .replacingOccurrences(of: "<laugh>", with: "[laughs]")
            .replacingOccurrences(of: "<sigh>", with: "[sighs]")
            .replacingOccurrences(of: "<gasp>", with: "[gasps]")
            .replacingOccurrences(of: "<short pause>", with: "…")
            .replacingOccurrences(of: "<long pause>", with: "… …")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
