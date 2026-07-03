import Foundation

public struct AnthropicError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case invalidKey
        case rateLimited
        case refused
        case truncated
        case http(Int)
    }
    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Minimal Messages API client for summarization (no Swift SDK exists).
/// Mirrors OllamaClient's injectable-transport shape. The caller supplies the
/// API key (the app reads it from the Keychain — MurmurCore never does).
public struct AnthropicClient: Sendable {
    public let apiKey: String
    public let model: String
    let transport: HTTPTransport

    public init(
        apiKey: String,
        model: String = "claude-opus-4-8",
        transport: HTTPTransport = URLSessionTransport(timeout: 300)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    /// Single-turn completion. Adaptive thinking; NO sampling parameters —
    /// temperature/top_p/top_k return 400 on Opus 4.8-class models.
    public func complete(system: String, user: String, maxTokens: Int = 8192) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "thinking": ["type": "adaptive"],
        ] as [String: Any])

        let (data, status) = try await transport.send(request)
        switch status {
        case 200:
            break
        case 401:
            throw AnthropicError(kind: .invalidKey, message: "Invalid Claude API key — check Settings.")
        case 429:
            throw AnthropicError(kind: .rateLimited, message: "Claude is rate-limiting requests — try again shortly.")
        default:
            throw AnthropicError(kind: .http(status), message: "Claude returned HTTP \(status).")
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" {
            throw AnthropicError(kind: .refused, message: "Claude declined to process this recording.")
        }
        let text = response.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if response.stop_reason == "max_tokens" {
            throw AnthropicError(kind: .truncated, message: "Summary was truncated — try a more focused template.")
        }
        guard !text.isEmpty else {
            throw AnthropicError(kind: .http(200), message: "Claude returned an empty response.")
        }
        return text
    }
}
