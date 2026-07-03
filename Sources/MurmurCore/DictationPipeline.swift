import Foundation

/// The post-ASR half of the dictation pipeline (spec §3.1 stages 3–4):
/// deterministic transforms first, then LLM cleanup.
public struct DictationPipeline: Sendable {

    public struct Output: Sendable, Equatable {
        public let textToInsert: String
        public let pressEnter: Bool
        public let rawText: String
        public let usedFallback: Bool
    }

    let cleanup: CleanupProvider
    let snippets: [Snippet]
    let dictionary: [DictionaryEntry]
    let styles: [Style]
    let cleanupEnabled: Bool
    let pressEnterEnabled: Bool

    public init(
        cleanup: CleanupProvider,
        snippets: [Snippet],
        dictionary: [DictionaryEntry],
        styles: [Style],
        cleanupEnabled: Bool,
        pressEnterEnabled: Bool
    ) {
        self.cleanup = cleanup
        self.snippets = snippets
        self.dictionary = dictionary
        self.styles = styles
        self.cleanupEnabled = cleanupEnabled
        self.pressEnterEnabled = pressEnterEnabled
    }

    public func process(rawTranscript: String, context: ContextPayload) async -> Output {
        let raw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        var pressEnter = false
        var text = raw
        if pressEnterEnabled {
            let extracted = TranscriptProcessor.extractPressEnter(from: raw)
            text = extracted.text
            pressEnter = extracted.pressEnter
        }

        text = TranscriptProcessor.expandSnippets(in: text, snippets: snippets)

        guard cleanupEnabled, !text.isEmpty else {
            return Output(textToInsert: text, pressEnter: pressEnter, rawText: raw, usedFallback: false)
        }

        let style = styles.first { $0.appCategory == context.appCategory }
        let result = await cleanup.cleanup(
            rawTranscript: text, context: context, dictionary: dictionary, style: style)
        return Output(
            textToInsert: result.text, pressEnter: pressEnter,
            rawText: raw, usedFallback: result.usedFallback)
    }
}
