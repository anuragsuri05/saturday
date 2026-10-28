import Foundation

/// How a ChatGPT request is paid for.
enum OpenAIAuth: Sendable {
    /// The user's ChatGPT plan through Sign in with ChatGPT.
    case chatGPTPlan
    case apiKey(String)
}

/// OpenAI Responses API with streaming. The same request shape works for both plan sign-in and API keys
/// (plan usage requires `store: false`, `stream: true`, and no sampling or token-limit fields).
enum OpenAIClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static func stream(auth: OpenAIAuth, model: String, system: String, history: [Turn], webSearch: Bool = false) -> AsyncThrowingStream<String, Error> {
        SSE.textStream { yield in
            let token: String
            switch auth {
            case .chatGPTPlan:
                token = try await ChatGPTAccount.currentAccessToken()
            case .apiKey(let key):
                guard !key.isEmpty else { throw APIError.missingKey(.openai) }
                token = key
            }

            func consume(webSearch: Bool) async throws {
                var body: [String: Any] = [
                    "model": model,
                    "instructions": system,
                    "input": history.map(input),
                    "store": false,
                    "stream": true,
                ]
                if webSearch { body["tools"] = [["type": "web_search"]] }
                let req = try SSE.jsonRequest(url: endpoint, headers: ["Authorization": "Bearer \(token)"], body: body)

                var finished = false
                for try await payload in SSE.dataLines(for: req) {
                    guard let event = SSE.json(payload) else { continue }
                    switch event["type"] as? String {
                    case "response.output_text.delta":
                        if let delta = event["delta"] as? String { yield(delta) }
                    case "response.completed", "response.incomplete":
                        finished = true
                    case "response.failed":
                        let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                        throw failure(code: error?["code"] as? String, message: error?["message"] as? String)
                    case "error":
                        throw failure(code: event["code"] as? String, message: event["message"] as? String)
                    default:
                        break
                    }
                }
                if !finished { throw APIError.badResponse("The reply was cut off. Please try again.") }
            }

            do {
                try await consume(webSearch: webSearch)
            } catch APIError.http(let status, _) where webSearch && (status == 400 || status == 403) {
                // Web search isn't available for every account or model; answer without it.
                try await consume(webSearch: false)
            }
        }
    }

    private static func input(_ turn: Turn) -> [String: Any] {
        guard !turn.images.isEmpty else { return ["role": turn.role.rawValue, "content": turn.text] }
        var content: [[String: Any]] = [["type": "input_text", "text": turn.text]]
        content += turn.images.map { ["type": "input_image", "image_url": "data:image/jpeg;base64,\($0.base64EncodedString())"] }
        return ["role": turn.role.rawValue, "content": content]
    }

    private static func failure(code: String?, message: String?) -> APIError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .usageLimit
        case "subscription_sharing_user_not_eligible":
            return .badResponse("This account can't be used with Saturday. Reconnect or add another account in Settings → Accounts.")
        default:
            return .badResponse(message ?? "Saturday couldn't finish that reply\(code.map { " (\($0))" } ?? "").")
        }
    }
}
