import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, openai, gemini

    var id: String { rawValue }
    var order: Int { Provider.allCases.firstIndex(of: self) ?? 0 }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "ChatGPT"
        case .gemini: "Gemini"
        }
    }
}

/// How Saturday thinks. `auto` ("Smart") routes each request; `council` ("Deep Think") asks every
/// connected model and merges the answers. The single-provider modes live in Advanced settings.
enum Mode: String, CaseIterable, Identifiable {
    case auto, claude, openai, gemini, council

    static let everyday: [Mode] = [.auto, .council]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Smart"
        case .council: "Deep Think"
        case .claude: "Claude only"
        case .openai: "ChatGPT only"
        case .gemini: "Gemini only"
        }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var engine: String?
    var isError = false
    var date = Date()
    /// The reply was paid for with the user's ChatGPT plan (OpenAI asks apps to say so near the composer).
    var usedPlan: Bool?
}

/// One message as sent to a provider. `images` are JPEGs (screenshots) attached to a user turn.
struct Turn: Sendable {
    let role: ChatMessage.Role
    let text: String
    var images: [Data] = []
}

enum APIError: LocalizedError {
    case missingKey(Provider)
    case http(Int, String)
    case refusal
    case usageLimit
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Saturday isn't connected to that service yet. Open Settings → Accounts."
        case .http(401, _), .http(403, _):
            "One of your connected accounts was rejected. Check Settings → Accounts."
        case .http(429, let message):
            "Rate limited or out of credit: \(message)"
        case .http(let code, let message):
            "Error \(code): \(message)"
        case .refusal:
            "The model declined to answer this request."
        case .usageLimit:
            "You've reached the ChatGPT plan usage limit for Saturday. [Manage usage](https://chatgpt.com/settings/usage)"
        case .badResponse(let message):
            message
        }
    }
}
