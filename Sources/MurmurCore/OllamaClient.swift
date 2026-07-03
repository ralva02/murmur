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

// MARK: - Line-streaming transport (NDJSON endpoints; injectable for tests)

public protocol LineStreamingTransport: Sendable {
    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error>
}

public struct URLSessionLineTransport: LineStreamingTransport {
    public init() {}
    public func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw OllamaError(message: "Ollama returned HTTP \(status)") }
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One NDJSON line of /api/pull progress.
public struct PullEvent: Sendable, Equatable, Decodable {
    public let status: String?
    public let completed: Int64?
    public let total: Int64?
    public let error: String?

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
    public var isSuccess: Bool { status == "success" }
}

// MARK: - Ollama API client

public struct OllamaError: Error, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

public struct OllamaClient: Sendable {
    public let baseURL: URL
    let transport: HTTPTransport
    /// Called after each chat with server-side timing ("prefill=…"), for
    /// latency diagnostics.
    let onMetrics: (@Sendable (String) -> Void)?

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(),
                onMetrics: (@Sendable (String) -> Void)? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.onMetrics = onMetrics
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
        let total_duration: Int64?
        let load_duration: Int64?
        let prompt_eval_count: Int?
        let prompt_eval_duration: Int64?
        let eval_count: Int?
        let eval_duration: Int64?

        var metrics: String {
            func ms(_ ns: Int64?) -> String { ns.map { "\($0 / 1_000_000)ms" } ?? "?" }
            return "total=\(ms(total_duration)) load=\(ms(load_duration)) "
                + "prefill=\(prompt_eval_count ?? -1)tok/\(ms(prompt_eval_duration)) "
                + "gen=\(eval_count ?? -1)tok/\(ms(eval_duration))"
        }
    }

    public func chat(model: String, system: String, user: String) async throws -> String {
        // "think": false — reasoning models (gemma4, qwen…) otherwise burn
        // seconds of hidden thinking tokens on a job that needs none; cleanup
        // is minimal-edit smoothing, not problem solving.
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "options": ["temperature": 0],
            "keep_alive": "30m",
            "think": false,
        ]

        var (data, status) = try await send(payload, to: "api/chat")
        if status != 200 {
            // Some models reject the think parameter outright — retry bare.
            payload.removeValue(forKey: "think")
            (data, status) = try await send(payload, to: "api/chat")
        }
        guard status == 200 else {
            throw OllamaError(message: "Ollama returned HTTP \(status)")
        }
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        onMetrics?(response.metrics)
        return Self.stripFences(response.message.content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads the model and primes the prompt-prefix cache while the user is
    /// still speaking, so the real request only pays for generation.
    public func prewarm(model: String, system: String) async {
        var payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]],
            "stream": false,
            "options": ["num_predict": 1],
            "keep_alive": "30m",
            "think": false,
        ]
        if let result = try? await send(payload, to: "api/chat"), result.1 != 200 {
            payload.removeValue(forKey: "think")
            _ = try? await send(payload, to: "api/chat")
        }
    }

    private func send(_ payload: [String: Any], to path: String) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await transport.send(request)
    }

    public func isAlive() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        let result = try? await transport.send(request)
        return result?.1 == 200
    }

    static func parsePullLine(_ line: String) -> PullEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(PullEvent.self, from: Data(trimmed.utf8))
    }

    /// Downloads a model, reporting each progress event. Throws on transport
    /// failure or an Ollama-reported error. Cancellable via task cancellation.
    public func pull(
        model: String,
        transport: LineStreamingTransport = URLSessionLineTransport(),
        onEvent: @escaping @Sendable (PullEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        for try await line in transport.lines(request) {
            try Task.checkCancellation()
            guard let event = Self.parsePullLine(line) else { continue }
            if let message = event.error { throw OllamaError(message: message) }
            onEvent(event)
        }
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
