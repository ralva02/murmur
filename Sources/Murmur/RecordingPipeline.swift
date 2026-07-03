import Foundation
import MurmurCore

/// Serial orchestrator: ready → transcribing → transcribed → summarizing →
/// done, with per-stage failure capture. Audio is never deleted by the
/// pipeline; a quit mid-stage is reset (not auto-restarted) on next launch.
@MainActor
final class RecordingPipeline {

    private let store: AppStore
    private let recordings: RecordingsStore
    private let transcriber = FileTranscriber()
    private var active = Set<UUID>()

    /// UI refresh hook + live progress (0…1) per recording while transcribing.
    var onChange: (() -> Void)?
    private(set) var progress: [UUID: Double] = [:]

    init(store: AppStore, recordings: RecordingsStore) {
        self.store = store
        self.recordings = recordings
        resetStuckStatuses()
    }

    /// Recordings stuck mid-stage from a previous run drop back to the last
    /// completed stage — visible with a Retry button, never auto-restarted.
    private func resetStuckStatuses() {
        for var rec in recordings.recordings {
            switch rec.status {
            case .transcribing:
                rec.status = .ready
                recordings.update(rec)
            case .summarizing:
                rec.status = .transcribed
                recordings.update(rec)
            default:
                break
            }
        }
    }

    func process(_ id: UUID) {
        guard !active.contains(id) else { return }
        active.insert(id)
        Task {
            await run(id)
            active.remove(id)
            progress[id] = nil
            onChange?()
        }
    }

    func resummarize(_ id: UUID, template: SummaryTemplate) {
        guard var rec = recordings.recordings.first(where: { $0.id == id }),
              recordings.transcript(for: id) != nil else { return }
        rec.template = template
        rec.status = .transcribed
        recordings.update(rec)
        process(id)
    }

    private func run(_ id: UUID) async {
        guard var rec = recordings.recordings.first(where: { $0.id == id }) else { return }

        // Stage 1: transcription (skipped when a transcript already exists).
        if recordings.transcript(for: id) == nil {
            rec.status = .transcribing
            recordings.update(rec); onChange?()
            do {
                let text = try await transcriber.transcribe(
                    fileURL: recordings.audioURL(for: rec),
                    locale: Locale(identifier: rec.language),
                    contextualStrings: store.dictionary.map(\.term),
                    onProgress: { [weak self] fraction in
                        self?.progress[id] = fraction
                        self?.onChange?()
                    })
                guard !text.isEmpty else {
                    throw FileTranscriber.FileTranscriberError.emptyTranscript
                }
                recordings.saveTranscript(text, for: id)
                rec.status = .transcribed
                recordings.update(rec); onChange?()
            } catch {
                rec.status = .failed(stage: .transcription, message: error.localizedDescription)
                recordings.update(rec); onChange?()
                return
            }
        }

        // Stage 2: summarization.
        rec.status = .summarizing
        recordings.update(rec); onChange?()
        do {
            let (provider, tag) = try makeProvider()
            let transcript = recordings.transcript(for: id) ?? ""
            let summary = try await provider.summarize(transcript: transcript, template: rec.template)
            recordings.saveSummary(summary, for: id)
            rec.summaryEngine = tag
            rec.status = .done
        } catch let error as AnthropicError {
            rec.status = .failed(stage: .summarization, message: error.message)
        } catch {
            rec.status = .failed(stage: .summarization, message: error.localizedDescription)
        }
        recordings.update(rec); onChange?()
    }

    private func makeProvider() throws -> (SummaryProvider, String) {
        let settings = store.settings
        switch settings.summaryEngine {
        case .ollama:
            guard let url = URL(string: settings.ollamaURL) else {
                throw AnthropicError(kind: .http(0), message: "Invalid Ollama URL in Settings.")
            }
            return (OllamaSummaryProvider(client: OllamaClient(baseURL: url), model: settings.cleanupModel),
                    "ollama:\(settings.cleanupModel)")
        case .claude:
            guard let key = KeychainStore.readClaudeKey(), !key.isEmpty else {
                throw AnthropicError(kind: .invalidKey, message: "No Claude API key — add one in Settings → Summaries.")
            }
            return (ClaudeSummaryProvider(client: AnthropicClient(apiKey: key, model: settings.claudeModel)),
                    "claude:\(settings.claudeModel)")
        }
    }
}
