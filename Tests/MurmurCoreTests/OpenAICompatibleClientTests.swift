import Foundation
import Testing
@testable import MurmurCore

private final class CapTransport: HTTPTransport, @unchecked Sendable {
    let response: (Data, Int)
    private let lock = NSLock()
    private var _reqs: [URLRequest] = []
    init(response: (Data, Int)) { self.response = response }
    var requests: [URLRequest] { lock.withLock { _reqs } }
    func send(_ r: URLRequest) async throws -> (Data, Int) { lock.withLock { _reqs.append(r) }; return response }
}

private func chatBody(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
}

@Test func openAIRequestShapeAndBearer() async throws {
    let t = CapTransport(response: (chatBody("hi"), 200))
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:1234/v1")!,
                                        model: "mlx-model", apiKey: "sk-x", transport: t)
    let out = try await client.chat(system: "s", user: "u")
    #expect(out == "hi")
    let req = t.requests[0]
    #expect(req.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "mlx-model")
    let msgs = body["messages"] as! [[String: String]]
    #expect(msgs[0]["role"] == "system")
}

@Test func openAINoBearerWhenNoKey() async throws {
    let t = CapTransport(response: (chatBody("hi"), 200))
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m", transport: t)
    _ = try await client.chat(system: "s", user: "u")
    #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func openAIThrowsOnNon200() async {
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m",
                                        transport: CapTransport(response: (Data("{}".utf8), 500)))
    await #expect(throws: OllamaError.self) { _ = try await client.chat(system: "s", user: "u") }
}

@Test func lmStudioProviderRoutes() async throws {
    let provider = LMStudioSummaryProvider(
        client: OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m",
                                       transport: CapTransport(response: (chatBody("## Overview\nx"), 200))))
    let out = try await provider.summarize(transcript: "t", template: .auto)
    #expect(out == "## Overview\nx")
}
