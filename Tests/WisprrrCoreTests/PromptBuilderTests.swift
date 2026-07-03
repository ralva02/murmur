import Testing
@testable import WisprrrCore

@Test func cleanupPromptContainsContractAndConditioning() {
    let ctx = ContextPayload(
        appBundleId: "com.apple.mail", appName: "Mail", appCategory: .email,
        nearbyText: "Hi Raul,", properNouns: ["Anaïs Kowalczyk"],
        recentChatMessages: [], isSecureField: false)
    let p = PromptBuilder.cleanupPrompt(
        rawTranscript: "um so lets meet tuesday wait no friday",
        context: ctx,
        dictionary: [DictionaryEntry(term: "Wisprrr")],
        style: Style(appCategory: .email, tone: "warm and professional"))
    #expect(p.system.contains("smallest edits"))
    #expect(p.system.contains("Never add facts"))
    #expect(p.system.contains("Wisprrr"))
    #expect(p.system.contains("warm and professional"))
    #expect(p.system.contains("Anaïs Kowalczyk"))
    #expect(p.user.contains("lets meet tuesday"))
}

@Test func cleanupPromptOmitsEmptySections() {
    let p = PromptBuilder.cleanupPrompt(
        rawTranscript: "hello", context: .empty, dictionary: [], style: nil)
    #expect(!p.system.contains("Dictionary"))
    #expect(!p.system.contains("Tone"))
    #expect(p.user == "hello")
}

@Test func codeCategoryPreservesCasing() {
    let ctx = ContextPayload(appCategory: .code)
    let p = PromptBuilder.cleanupPrompt(rawTranscript: "set user id to nil",
        context: ctx, dictionary: [], style: nil)
    #expect(p.system.contains("camelCase"))
}

@Test func commandPromptIncludesSelectionAndInstruction() {
    let p = PromptBuilder.commandPrompt(instruction: "make this more concise", selection: "some long text")
    #expect(p.user.contains("some long text"))
    #expect(p.user.contains("make this more concise"))
    #expect(p.system.contains("Return only the rewritten text"))
}
