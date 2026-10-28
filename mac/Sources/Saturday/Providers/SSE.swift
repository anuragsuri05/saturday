import Foundation

/// Server-sent-events plumbing shared by all three providers.
enum SSE {
    /// Wraps a producer that pushes text deltas into a cancellable stream.
    static func textStream(
        _ produce: @escaping @Sendable (_ yield: @escaping @Sendable (String) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await produce { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields the payload of every `data:` line until the server closes the stream or sends `[DONE]`.
    static func dataLines(for request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 8000 { break }
                        }
                        if body.contains("subscription_sharing_usage_limit_exceeded") { throw APIError.usageLimit }
                        throw APIError.http(http.statusCode, errorMessage(body))
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }

    static func json(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonRequest(url: URL, headers: [String: String], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Pulls the message out of an Anthropic, OpenAI or Google error body (`error.message` or `detail`).
    static func errorMessage(_ body: String) -> String {
        let data = Data(body.utf8)
        var object = try? JSONSerialization.jsonObject(with: data)
        if let array = object as? [Any] { object = array.first }
        if let dict = object as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let detail = dict["detail"] as? String { return detail }
        }
        return body.isEmpty ? "No details from server." : String(body.prefix(500))
    }
}
