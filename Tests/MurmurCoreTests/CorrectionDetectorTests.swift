import Testing
@testable import MurmurCore

@Test func detectsSpellingCorrection() {
    let out = CorrectionDetector.corrections(
        inserted: "meet with Anais tomorrow at noon",
        current: "meet with Anaïs tomorrow at noon",
        knownTerms: [])
    #expect(out == ["Anaïs"])
}

@Test func detectsJargonRespelling() {
    let out = CorrectionDetector.corrections(
        inserted: "deploy it with cubectl today",
        current: "deploy it with kubectl today",
        knownTerms: [])
    #expect(out == ["kubectl"])
}

@Test func ignoresAppendedText() {
    let out = CorrectionDetector.corrections(
        inserted: "first sentence here",
        current: "first sentence here and then I kept typing more words",
        knownTerms: [])
    #expect(out.isEmpty)
}

@Test func ignoresCompleteRewrite() {
    let out = CorrectionDetector.corrections(
        inserted: "let's grab lunch on Friday",
        current: "the meeting is cancelled entirely",
        knownTerms: [])
    #expect(out.isEmpty)
}

@Test func ignoresCaseOnlyChanges() {
    // Sentence-casing tweaks are punctuation noise, not vocabulary.
    let out = CorrectionDetector.corrections(
        inserted: "okay see you then",
        current: "Okay see you then",
        knownTerms: [])
    #expect(out.isEmpty)
}

@Test func ignoresKnownTerms() {
    let out = CorrectionDetector.corrections(
        inserted: "ship it to wisper today",
        current: "ship it to Murmur today",
        knownTerms: ["Murmur"])
    #expect(out.isEmpty)
}

@Test func ignoresDifferentWordChoice() {
    // "tomorrow" → "Thursday" is an edit, not a spelling fix.
    let out = CorrectionDetector.corrections(
        inserted: "see you tomorrow then",
        current: "see you Thursday then",
        knownTerms: [])
    #expect(out.isEmpty)
}

@Test func stripsPunctuationFromCandidates() {
    let out = CorrectionDetector.corrections(
        inserted: "ask Jon, he knows",
        current: "ask John, he knows",
        knownTerms: [])
    #expect(out == ["John"])
}

@Test func editDistanceBasics() {
    #expect(CorrectionDetector.editDistance("kitten", "sitting") == 3)
    #expect(CorrectionDetector.editDistance("same", "same") == 0)
    #expect(CorrectionDetector.editDistance("", "abc") == 3)
}
