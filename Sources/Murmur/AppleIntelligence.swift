import Foundation
import FoundationModels
import MurmurCore

/// Live availability of Apple's on-device model, mapped for UI copy.
enum AppleIntelligenceStatus: Equatable {
    case ready, notEnabled, modelDownloading, unsupported

    static func current() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .modelDownloading
        case .unavailable(.deviceNotEligible): .unsupported
        case .unavailable: .unsupported
        }
    }

    var explanation: String {
        switch self {
        case .ready: "Apple Intelligence is ready — cleanup works out of the box."
        case .notEnabled: "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri."
        case .modelDownloading: "Apple's model is still downloading. Cleanup starts working automatically when it finishes."
        case .unsupported: "This Mac can't run Apple Intelligence. Use Ollama below for polished transcripts."
        }
    }
}

/// Cleanup via the on-device Foundation Models framework. Same contract as
/// the Ollama provider: minimal-edit prompt from PromptBuilder, CleanupSanity
/// guard, raw-transcript fallback on any error (spec §15).
struct AppleIntelligenceCleanupProvider: CleanupProvider {
    let translateTo: String?

    func cleanup(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) async -> CleanupResult {
        let prompt = PromptBuilder.cleanupPrompt(
            rawTranscript: rawTranscript, context: context,
            dictionary: dictionary, style: style, translateTo: translateTo)
        do {
            let session = LanguageModelSession(instructions: prompt.system)
            let response = try await session.respond(
                to: prompt.user,
                options: GenerationOptions(sampling: .greedy))
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CleanupSanity.isSane(output: output, input: rawTranscript) else {
                return CleanupResult(text: rawTranscript, usedFallback: true)
            }
            return CleanupResult(text: output, usedFallback: false)
        } catch {
            Diag.dictation.error("Apple Intelligence cleanup failed: \(error.localizedDescription, privacy: .public)")
            return CleanupResult(text: rawTranscript, usedFallback: true)
        }
    }

    /// Loads model resources while the user is still speaking (mirrors the
    /// Ollama prewarm path).
    static func prewarm(
        context: ContextPayload, dictionary: [DictionaryEntry],
        style: Style?, translateTo: String?
    ) {
        let prompt = PromptBuilder.cleanupPrompt(
            rawTranscript: "", context: context,
            dictionary: dictionary, style: style, translateTo: translateTo)
        let session = LanguageModelSession(instructions: prompt.system)
        session.prewarm()
    }
}
