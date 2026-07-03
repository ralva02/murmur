import Testing
@testable import MurmurCore

@Test func pressEnterAtEndIsStrippedAndFlagged() {
    let r = TranscriptProcessor.extractPressEnter(from: "send the report today press enter")
    #expect(r.text == "send the report today")
    #expect(r.pressEnter)
}

@Test func pressEnterWithTrailingPunctuation() {
    let r = TranscriptProcessor.extractPressEnter(from: "Ship it. Press enter.")
    #expect(r.text == "Ship it.")
    #expect(r.pressEnter)
}

@Test func pressEnterMidSentenceStaysLiteral() {
    let r = TranscriptProcessor.extractPressEnter(from: "when I press enter it submits the form")
    #expect(r.text == "when I press enter it submits the form")
    #expect(!r.pressEnter)
}

@Test func pressEnterAsSoleContent() {
    let r = TranscriptProcessor.extractPressEnter(from: "Press enter")
    #expect(r.text.isEmpty)
    #expect(r.pressEnter)
}

@Test func pressEnterSoleContentWithPunctuation() {
    let r = TranscriptProcessor.extractPressEnter(from: "Press enter.")
    #expect(r.text.isEmpty)
    #expect(r.pressEnter)
}

@Test func plainTextUnchanged() {
    let r = TranscriptProcessor.extractPressEnter(from: "just a normal sentence")
    #expect(r.text == "just a normal sentence")
    #expect(!r.pressEnter)
}

@Test func snippetExactMatchExpands() {
    let snips = [Snippet(triggerPhrase: "my email address", body: "ralvahi@proton.me")!]
    let out = TranscriptProcessor.expandSnippets(in: "My email address", snippets: snips)
    #expect(out == "ralvahi@proton.me")
}

@Test func snippetEmbeddedPhraseExpands() {
    let snips = [Snippet(triggerPhrase: "my calendar link", body: "https://cal.example/raul")!]
    let out = TranscriptProcessor.expandSnippets(in: "sure, my calendar link works", snippets: snips)
    #expect(out == "sure, https://cal.example/raul works")
}

@Test func longestTriggerWinsAndNoPartialWordMatch() {
    let snips = [
        Snippet(triggerPhrase: "my email", body: "SHORT")!,
        Snippet(triggerPhrase: "my email address", body: "LONG")!,
    ]
    #expect(TranscriptProcessor.expandSnippets(in: "use my email address here", snippets: snips)
        == "use LONG here")
    // "myemailaddress" has no word boundary — must not expand
    #expect(TranscriptProcessor.expandSnippets(in: "usemy email addressx", snippets: snips)
        == "usemy email addressx")
}

@Test func noSnippetNoChange() {
    let out = TranscriptProcessor.expandSnippets(in: "nothing here", snippets: [])
    #expect(out == "nothing here")
}
