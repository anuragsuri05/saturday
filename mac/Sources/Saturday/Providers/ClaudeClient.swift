import Foundation

/// Anthropic Messages API over raw HTTP (there is no official Swift SDK).
enum ClaudeClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Models that accept server-side refusal fallbacks (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
    ]

    private static func supportsEffort(_ model: String) -> Bool { !model.contains("haiku-4-5") }

    private static func message(_ turn: Turn) -> [String: Any] {
        guard !turn.images.isEmpty else { return ["role": turn.role.rawValue, "content": turn.text] }
        var blocks: [[String: Any]] = turn.images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]]
        }
        blocks.append(["type": "text", "text": turn.text])
        return ["role": turn.role.rawValue, "content": blocks]
    }

    private static func request(key: String, model: String, body: [String: Any], fallbacks: Bool) throws -> URLRequest {
        var body = body
        var headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        if fallbacks {
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            body["fallbacks"] = "default"
        }
        return try SSE.jsonRequest(url: endpoint, headers: headers, body: body)
    }

    private static func isFallbackRejection(_ error: Error) -> Bool {
        if case APIError.http(400, let message) = error { return message.lowercased().contains("fallback") }
        return false
    }

    static func stream(key: String, model: String, system: String, history: [Turn], effort: String) -> AsyncThrowingStream<String, Error> {
        SSE.textStream { yield in
            guard !key.isEmpty else { throw APIError.missingKey(.claude) }
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 64000,
                "stream": true,
                "system": system,
                "messages": history.map(message),
            ]
            if supportsEffort(model) { body["output_config"] = ["effort": effort] }

            func consume(fallbacks: Bool) async throws {
                let req = try request(key: key, model: model, body: body, fallbacks: fallbacks)
                for try await payload in SSE.dataLines(for: req) {
                    guard let event = SSE.json(payload) else { continue }
                    switch event["type"] as? String {
                    case "content_block_delta":
                        if let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            yield(text)
                        }
                    case "message_delta":
                        if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                            throw APIError.refusal
                        }
                    case "error":
                        let error = event["error"] as? [String: Any]
                        throw APIError.badResponse(error?["message"] as? String ?? "Claude stream error.")
                    default:
                        break
                    }
                }
            }

            let fallbacks = fallbackModels.contains(model)
            do {
                try await consume(fallbacks: fallbacks)
            } catch where fallbacks && isFallbackRejection(error) {
                try await consume(fallbacks: false)
            }
        }
    }

    /// Tool-use loop for Mac actions: Claude calls MacTools (and server-side web search) until it is done.
    @MainActor
    static func runAgent(
        key: String, model: String, system: String, history: [Turn], effort: String,
        onStatus: (String) -> Void
    ) async throws -> String {
        guard !key.isEmpty else { throw APIError.missingKey(.claude) }
        var messages: [[String: Any]] = history.map(message)
        let tools = MacTools.definitions + [["type": "web_search_20260209", "name": "web_search", "max_uses": 5]]
        var fallbacks = fallbackModels.contains(model)

        for _ in 0..<16 {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "messages": messages,
                "tools": tools,
            ]
            if supportsEffort(model) { body["output_config"] = ["effort": effort] }

            let data: Data
            do {
                let req = try request(key: key, model: model, body: body, fallbacks: fallbacks)
                let (responseData, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw APIError.http(http.statusCode, SSE.errorMessage(String(decoding: responseData, as: UTF8.self)))
                }
                data = responseData
            } catch where fallbacks && isFallbackRejection(error) {
                fallbacks = false
                continue
            }

            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let content = object["content"] as? [[String: Any]]
            else { throw APIError.badResponse("Unexpected response from Claude.") }

            let stopReason = object["stop_reason"] as? String
            if stopReason == "refusal" { throw APIError.refusal }

            // Send the assistant content back unchanged (including thinking blocks) on the next turn.
            messages.append(["role": "assistant", "content": content])
            let text = content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()

            switch stopReason {
            case "tool_use":
                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    onStatus(MacTools.statusText(for: name))
                    let (output, isError) = await MacTools.run(name, input: block["input"] as? [String: Any] ?? [:])
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": block["id"] as? String ?? "",
                        "content": output,
                        "is_error": isError,
                    ])
                }
                // All results for this turn go back in a single user message.
                messages.append(["role": "user", "content": results])
            case "pause_turn":
                continue
            default:
                return text
            }
        }
        throw APIError.badResponse("Saturday stopped after too many steps. Try a simpler request.")
    }
}
