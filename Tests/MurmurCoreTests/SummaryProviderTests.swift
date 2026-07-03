import Foundation
import Testing
@testable import MurmurCore

private struct FixedTransport: HTTPTransport {
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) { (body, 200) }
}

@Test func ollamaProviderRoutesThroughChat() async throws {
    let chatBody = try JSONSerialization.data(withJSONObject: ["message": ["content": "## Overview\nhi"]])
    let provider = OllamaSummaryProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: FixedTransport(body: chatBody)),
        model: "gemma4:e4b")
    let out = try await provider.summarize(transcript: "hello", template: .auto)
    #expect(out == "## Overview\nhi")
}

@Test func claudeProviderRoutesThroughComplete() async throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "content": [["type": "text", "text": "## Overview\nhi"]],
        "stop_reason": "end_turn",
    ])
    let provider = ClaudeSummaryProvider(
        client: AnthropicClient(apiKey: "k", transport: FixedTransport(body: body)))
    let out = try await provider.summarize(transcript: "hello", template: .meeting)
    #expect(out == "## Overview\nhi")
}
