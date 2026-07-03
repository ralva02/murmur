import Foundation

public struct CleanupResult: Sendable, Equatable {
    public let text: String
    public let usedFallback: Bool

    public init(text: String, usedFallback: Bool) {
        self.text = text
        self.usedFallback = usedFallback
    }
}

/// Turns a raw transcript into polished text (spec §3.1 stage 4).
/// Implementations must never fail the dictation: on any error they return
/// the raw transcript (spec §15 — never silently drop dictation).
public protocol CleanupProvider: Sendable {
    func cleanup(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) async -> CleanupResult
}

/// No-LLM fallback: returns the transcript as-is.
public struct PassthroughCleanupProvider: CleanupProvider {
    public init() {}

    public func cleanup(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) async -> CleanupResult {
        CleanupResult(text: rawTranscript, usedFallback: true)
    }
}

public struct OllamaCleanupProvider: CleanupProvider {
    let client: OllamaClient
    let model: String
    /// When set, the cleanup pass also translates into this language (spec §10).
    let translateTo: String?

    public init(client: OllamaClient, model: String, translateTo: String? = nil) {
        self.client = client
        self.model = model
        self.translateTo = translateTo
    }

    public func cleanup(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) async -> CleanupResult {
        let prompt = PromptBuilder.cleanupPrompt(
            rawTranscript: rawTranscript, context: context,
            dictionary: dictionary, style: style, translateTo: translateTo)
        do {
            let output = try await client.chat(model: model, system: prompt.system, user: prompt.user)
            guard Self.isSane(output: output, input: rawTranscript) else {
                return CleanupResult(text: rawTranscript, usedFallback: true)
            }
            return CleanupResult(text: output, usedFallback: false)
        } catch {
            return CleanupResult(text: rawTranscript, usedFallback: true)
        }
    }

    /// The cleanup contract is minimal-edit smoothing (spec §3.2). Empty output
    /// or output far longer than the input means the model went off-script.
    static func isSane(output: String, input: String) -> Bool {
        guard !output.isEmpty else { return false }
        let inputWords = input.split(whereSeparator: \.isWhitespace).count
        let outputWords = output.split(whereSeparator: \.isWhitespace).count
        return outputWords <= max(inputWords * 3, inputWords + 20)
    }
}
