import Foundation

/// Turns a transcript into a markdown summary. Unlike CleanupProvider,
/// failures are thrown — the pipeline surfaces them per-stage with retry.
public protocol SummaryProvider: Sendable {
    func summarize(transcript: String, template: SummaryTemplate) async throws -> String
}

public struct OllamaSummaryProvider: SummaryProvider {
    let client: OllamaClient
    let model: String

    public init(client: OllamaClient, model: String) {
        self.client = client
        self.model = model
    }

    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.chat(model: model, system: prompt.system, user: prompt.user)
    }
}

public struct LMStudioSummaryProvider: SummaryProvider {
    let client: OpenAICompatibleClient
    public init(client: OpenAICompatibleClient) { self.client = client }
    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.chat(system: prompt.system, user: prompt.user)
    }
}

public struct ClaudeSummaryProvider: SummaryProvider {
    let client: AnthropicClient

    public init(client: AnthropicClient) {
        self.client = client
    }

    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.complete(system: prompt.system, user: prompt.user)
    }
}
