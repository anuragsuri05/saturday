import Foundation

/// Gemini API (generativelanguage) with streaming and optional Google Search grounding.
enum GeminiClient {
    static func stream(key: String, model: String, system: String, history: [Turn], grounded: Bool) -> AsyncThrowingStream<String, Error> {
        SSE.textStream { yield in
            guard !key.isEmpty else { throw APIError.missingKey(.gemini) }
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": history.map { turn -> [String: Any] in
                    var parts: [[String: Any]] = turn.images.map {
                        ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]]
                    }
                    parts.append(["text": turn.text])
                    return ["role": turn.role == .user ? "user" : "model", "parts": parts]
                },
            ]
            if grounded { body["tools"] = [["google_search": [String: Any]()]] }
            let req = try SSE.jsonRequest(url: url, headers: ["x-goog-api-key": key], body: body)

            var produced = false
            for try await payload in SSE.dataLines(for: req) {
                guard let event = SSE.json(payload) else { continue }
                if let error = event["error"] as? [String: Any] {
                    throw APIError.badResponse(error["message"] as? String ?? "Gemini stream error.")
                }
                guard let candidate = (event["candidates"] as? [[String: Any]])?.first else { continue }
                let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts where part["thought"] as? Bool != true {
                    if let text = part["text"] as? String {
                        produced = true
                        yield(text)
                    }
                }
                if let reason = candidate["finishReason"] as? String,
                   ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST"].contains(reason), !produced {
                    throw APIError.refusal
                }
            }
        }
    }
}
