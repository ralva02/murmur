import Foundation
import Testing
@testable import MurmurCore

struct StubTransport: HTTPTransport {
    var handler: @Sendable (URLRequest) async throws -> (Data, Int)
    func send(_ req: URLRequest) async throws -> (Data, Int) { try await handler(req) }
}

@Test func chatParsesMessageContent() async throws {
    let transport = StubTransport { req in
        #expect(req.url?.path == "/api/chat")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "gemma4:e4b")
        #expect(body["stream"] as? Bool == false)
        let options = body["options"] as! [String: Any]
        #expect((options["temperature"] as! NSNumber).doubleValue == 0)
        let msgs = body["messages"] as! [[String: Any]]
        #expect(msgs.first?["role"] as? String == "system")
        #expect(msgs.last?["content"] as? String == "raw")
        let json = #"{"message":{"role":"assistant","content":"Let's meet Friday."},"done":true}"#
        return (Data(json.utf8), 200)
    }
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!, transport: transport)
    let out = try await client.chat(model: "gemma4:e4b", system: "sys", user: "raw")
    #expect(out == "Let's meet Friday.")
}

@Test func chatStripsCodeFences() async throws {
    let transport = StubTransport { _ in
        (Data(#"{"message":{"content":"```\nhello there\n```"},"done":true}"#.utf8), 200)
    }
    let client = OllamaClient(baseURL: URL(string: "http://x")!, transport: transport)
    let out = try await client.chat(model: "m", system: "s", user: "u")
    #expect(out == "hello there")
}

@Test func chatThrowsOnHTTPError() async {
    let transport = StubTransport { _ in (Data("nope".utf8), 500) }
    let client = OllamaClient(baseURL: URL(string: "http://x")!, transport: transport)
    await #expect(throws: (any Error).self) {
        _ = try await client.chat(model: "m", system: "s", user: "u")
    }
}

@Test func cleanupFallsBackToRawOnTransportError() async {
    let transport = StubTransport { _ in throw URLError(.cannotConnectToHost) }
    let provider = OllamaCleanupProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m")
    let out = await provider.cleanup(rawTranscript: "raw words", context: .empty, dictionary: [], style: nil)
    #expect(out.text == "raw words")
    #expect(out.usedFallback)
}

@Test func cleanupGuardsAgainstRunawayOutput() async {
    let spam = String(repeating: "spam ", count: 200)
    let transport = StubTransport { _ in
        (Data("{\"message\":{\"content\":\"\(spam)\"},\"done\":true}".utf8), 200)
    }
    let provider = OllamaCleanupProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m")
    let out = await provider.cleanup(rawTranscript: "short input", context: .empty, dictionary: [], style: nil)
    #expect(out.text == "short input")
    #expect(out.usedFallback)
}

@Test func cleanupGuardsAgainstEmptyOutput() async {
    let transport = StubTransport { _ in
        (Data(#"{"message":{"content":"  "},"done":true}"#.utf8), 200)
    }
    let provider = OllamaCleanupProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m")
    let out = await provider.cleanup(rawTranscript: "not empty", context: .empty, dictionary: [], style: nil)
    #expect(out.text == "not empty")
    #expect(out.usedFallback)
}

@Test func cleanupReturnsModelOutputWhenSane() async {
    let transport = StubTransport { _ in
        (Data(#"{"message":{"content":"Let's meet Friday."},"done":true}"#.utf8), 200)
    }
    let provider = OllamaCleanupProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m")
    let out = await provider.cleanup(rawTranscript: "um lets meet tuesday wait no friday",
                                     context: .empty, dictionary: [], style: nil)
    #expect(out.text == "Let's meet Friday.")
    #expect(!out.usedFallback)
}

@Test func passthroughReturnsRaw() async {
    let out = await PassthroughCleanupProvider().cleanup(
        rawTranscript: "as spoken", context: .empty, dictionary: [], style: nil)
    #expect(out.text == "as spoken")
    #expect(out.usedFallback)
}
