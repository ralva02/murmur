import Foundation
import Testing
@testable import MurmurCore

@Test func pipelineExpandsSnippetsStripsEnterAndCleans() async throws {
    let transport = StubTransport { req in
        // Echo the user content uppercased to prove the LLM stage ran on processed text.
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        let user = msgs.last!["content"] as! String
        let json = try JSONSerialization.data(withJSONObject: ["message": ["content": user.uppercased()]])
        return (json, 200)
    }
    let pipeline = DictationPipeline(
        cleanup: OllamaCleanupProvider(
            client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m"),
        snippets: [Snippet(triggerPhrase: "my email address", body: "x@y.z")!],
        dictionary: [], styles: [], cleanupEnabled: true, pressEnterEnabled: true)
    let out = await pipeline.process(rawTranscript: "my email address press enter", context: .empty)
    #expect(out.textToInsert == "X@Y.Z")
    #expect(out.pressEnter)
    #expect(out.rawText == "my email address press enter")
}

@Test func pipelineSoleEnterInsertsNothing() async {
    let pipeline = DictationPipeline(
        cleanup: PassthroughCleanupProvider(),
        snippets: [], dictionary: [], styles: [], cleanupEnabled: false, pressEnterEnabled: true)
    let out = await pipeline.process(rawTranscript: "press enter", context: .empty)
    #expect(out.textToInsert.isEmpty)
    #expect(out.pressEnter)
}

@Test func pipelineRespectsPressEnterDisabled() async {
    let pipeline = DictationPipeline(
        cleanup: PassthroughCleanupProvider(),
        snippets: [], dictionary: [], styles: [], cleanupEnabled: false, pressEnterEnabled: false)
    let out = await pipeline.process(rawTranscript: "hello press enter", context: .empty)
    #expect(out.textToInsert == "hello press enter")
    #expect(!out.pressEnter)
}

@Test func pipelinePicksStyleForAppCategory() async throws {
    let transport = StubTransport { req in
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let msgs = body["messages"] as! [[String: Any]]
        let system = msgs.first!["content"] as! String
        #expect(system.contains("casual and brief"))
        return (Data(#"{"message":{"content":"hi"},"done":true}"#.utf8), 200)
    }
    let pipeline = DictationPipeline(
        cleanup: OllamaCleanupProvider(
            client: OllamaClient(baseURL: URL(string: "http://x")!, transport: transport), model: "m"),
        snippets: [], dictionary: [], styles: Style.defaults,
        cleanupEnabled: true, pressEnterEnabled: true)
    let out = await pipeline.process(rawTranscript: "hi",
        context: ContextPayload(appCategory: .chat))
    #expect(out.textToInsert == "hi")
}
