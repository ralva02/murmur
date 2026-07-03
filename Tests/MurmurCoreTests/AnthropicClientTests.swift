import Foundation
import Testing
@testable import MurmurCore

private final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let response: (Data, Int)
    init(response: (Data, Int)) { self.response = response }
    var requests: [URLRequest] { lock.withLock { _requests } }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { _requests.append(request) }
        return response
    }
}

private func okBody(text: String, stopReason: String = "end_turn") -> Data {
    let json: [String: Any] = [
        "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
        "stop_reason": stopReason,
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

@Test func requestShapeIsCorrect() async throws {
    let transport = CapturingTransport(response: (okBody(text: "Hi."), 200))
    let client = AnthropicClient(apiKey: "sk-test", model: "claude-opus-4-8", transport: transport)
    _ = try await client.complete(system: "sys", user: "usr")

    let request = transport.requests[0]
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "claude-opus-4-8")
    #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect(body["temperature"] == nil)   // sampling params 400 on Opus 4.8
    #expect(body["top_p"] == nil)
    #expect(body["system"] as? String == "sys")
}

@Test func extractsTextSkippingThinkingBlocks() async throws {
    let client = AnthropicClient(apiKey: "k", transport: CapturingTransport(response: (okBody(text: "Summary."), 200)))
    let out = try await client.complete(system: "s", user: "u")
    #expect(out == "Summary.")
}

@Test func mapsErrorStatuses() async {
    let cases: [(Int, AnthropicError.Kind)] = [
        (401, .invalidKey), (429, .rateLimited), (500, .http(500)),
    ]
    for (status, kind) in cases {
        let client = AnthropicClient(apiKey: "k", transport: CapturingTransport(response: (Data("{}".utf8), status)))
        do {
            _ = try await client.complete(system: "s", user: "u")
            Issue.record("expected throw for status \(status)")
        } catch let error as AnthropicError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("wrong error type for status \(status)")
        }
    }
}

@Test func surfacesRefusalAndTruncation() async {
    let refused = AnthropicClient(apiKey: "k",
        transport: CapturingTransport(response: (okBody(text: "", stopReason: "refusal"), 200)))
    do {
        _ = try await refused.complete(system: "s", user: "u")
        Issue.record("expected refusal throw")
    } catch let error as AnthropicError {
        #expect(error.kind == .refused)
    } catch { Issue.record("wrong error type") }

    let truncated = AnthropicClient(apiKey: "k",
        transport: CapturingTransport(response: (okBody(text: "partial", stopReason: "max_tokens"), 200)))
    do {
        _ = try await truncated.complete(system: "s", user: "u")
        Issue.record("expected truncation throw")
    } catch let error as AnthropicError {
        #expect(error.kind == .truncated)
    } catch { Issue.record("wrong error type") }
}
