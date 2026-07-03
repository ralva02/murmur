import Foundation

// MARK: - Transport (injectable for tests)

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

// MARK: - Ollama API client

public struct OllamaError: Error, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct OllamaClient: Sendable {
    public let baseURL: URL
    let transport: HTTPTransport

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    public func chat(model: String, system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "options": ["temperature": 0],
            "keep_alive": "30m",
        ] as [String: Any])

        let (data, status) = try await transport.send(request)
        guard status == 200 else {
            throw OllamaError(message: "Ollama returned HTTP \(status)")
        }
        let content = try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        return Self.stripFences(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads the model and primes the prompt-prefix cache while the user is
    /// still speaking, so the real request only pays for generation.
    public func prewarm(model: String, system: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": system]],
            "stream": false,
            "options": ["num_predict": 1],
            "keep_alive": "30m",
        ] as [String: Any])
        _ = try? await transport.send(request)
    }

    public func isAlive() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        let result = try? await transport.send(request)
        return result?.1 == 200
    }

    /// Small models sometimes wrap output in markdown fences despite instructions.
    static func stripFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        t = String(t.dropFirst(3))
        if let newline = t.firstIndex(of: "\n"), t[t.startIndex..<newline].allSatisfy({ !$0.isWhitespace }) {
            t = String(t[t.index(after: newline)...])
        }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
