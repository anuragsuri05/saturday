import Foundation

/// Mac actions for ChatGPT and Gemini. They call tools by writing a <tool> tag, which works on every
/// provider and sign-in type (Claude uses native tool calling instead).
@MainActor
enum TextAgent {
    /// Tools whose output is already a complete answer for the user.
    private static let selfDescribingTools: Set<String> = ["play_music", "music_control"]

    static var toolPrompt: String {
        let tools = MacTools.definitions.map { tool -> String in
            let name = tool["name"] as? String ?? ""
            let description = tool["description"] as? String ?? ""
            let schema = tool["input_schema"] as? [String: Any]
            let properties = (schema?["properties"] as? [String: [String: Any]]) ?? [:]
            let params = properties.keys.sorted().map { key in
                "\(key) (\(properties[key]?["type"] as? String ?? "string")): \(properties[key]?["description"] as? String ?? "")"
            }
            return "- \(name): \(description)" + (params.isEmpty ? "" : "\n  Parameters: " + params.joined(separator: "; "))
        }.joined(separator: "\n")

        return """


        Tools. To use one, reply with only the tag below: no preamble like "One moment" or "I'll check", \
        and stop right after the closing tag:
        <tool>{"name": "TOOL_NAME", "input": {...}}</tool>
        You'll get the result in a <tool_result> message. Then use another tool or give your final answer as normal text. \
        Use one tool at a time, and never claim you did something unless a tool result confirms it.

        \(tools)
        """
    }

    static func run(
        history: [Turn],
        system: String,
        step: ([Turn], String) -> AsyncThrowingStream<String, Error>,
        onStatus: (String) -> Void
    ) async throws -> String {
        var turns = history
        let prompt = system + toolPrompt
        // App control takes several look-act-check steps.
        for _ in 0..<16 {
            try Task.checkCancellation()
            let full = try await SSE.collect(step(turns, prompt))
            guard let call = toolCall(in: full) else { return full }
            // Anything after the tool call is the model guessing the outcome before the tool ran; drop it.
            let reply = full.range(of: "</tool>").map { String(full[..<$0.upperBound]) } ?? full
            onStatus(MacTools.statusText(for: call.name))
            let (output, isError) = await MacTools.run(call.name, input: call.input)
            // Music results already say exactly what happened, so skip a second model call.
            if !isError, Self.selfDescribingTools.contains(call.name) { return output }
            turns.append(Turn(role: .assistant, text: reply))
            turns.append(Turn(role: .user, text: "<tool_result name=\"\(call.name)\" error=\"\(isError)\">\n\(output)\n</tool_result>"))
        }
        throw APIError.badResponse("Saturday stopped after too many steps. Try a simpler request.")
    }

    private static func toolCall(in reply: String) -> (name: String, input: [String: Any])? {
        guard let start = reply.range(of: "<tool>"),
              let end = reply.range(of: "</tool>", range: start.upperBound..<reply.endIndex)
        else { return nil }
        let json = reply[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = SSE.json(json), let name = object["name"] as? String else { return nil }
        return (name, object["input"] as? [String: Any] ?? [:])
    }
}
