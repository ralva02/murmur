import Foundation

/// Chat-completions client for any OpenAI-compatible local server
/// (LM Studio, llama.cpp, vLLM, LiteLLM). Reuses OllamaError for parity.
public struct OpenAICompatibleClient: Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    let transport: HTTPTransport

    public init(
        baseURL: URL, model: String, apiKey: String? = nil,
        transport: HTTPTransport = URLSessionTransport(timeout: 300)
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    public func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "temperature": 0,
        ] as [String: Any])

        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw OllamaError(message: "LM Studio returned HTTP \(status)") }
        let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        return OllamaClient.stripFences(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
