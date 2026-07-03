import AppKit
import Foundation
import MurmurCore

/// Orchestrates a dictation session (spec §3.1): trigger → capture/ASR →
/// pipeline → injection → history. The only stateful coordinator in the app.
@MainActor
final class DictationController {

    enum State: Equatable {
        case idle
        case recording(handsFree: Bool)
        case processing
        case injecting
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    var onTranscriptRecorded: ((TranscriptRecord) -> Void)?
    /// Live transcript (finalized + volatile) while recording.
    var onPartialTranscript: ((String) -> Void)?
    /// Mic level (0…1) while recording, for the pill waveform.
    var onAudioLevel: ((Float) -> Void)?

    private let store: AppStore
    private let transcriber = AudioTranscriber()
    /// In-flight ASR engine startup; stop/cancel must await it or they race
    /// past an engine that comes up moments later and runs orphaned.
    private var startTask: Task<Void, any Error>?
    private var sessionContext: ContextPayload = .empty
    private var sessionStartedAt: TimeInterval = 0
    private var lastTriggerAt: TimeInterval = 0
    private var commandModeArmed = false

    /// Recordings shorter than this are accidental taps and are discarded.
    private let minSessionDuration: TimeInterval = 0.30
    /// Debounce window against rapid start/stop toggling (spec §17).
    private let debounceInterval: TimeInterval = 0.20

    private lazy var autoDictionary = AutoDictionaryMonitor(store: store)

    init(store: AppStore) {
        self.store = store
        transcriber.onPartial = { [weak self] text in
            self?.onPartialTranscript?(text)
        }
        transcriber.onLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
    }

    /// Built while the user is still speaking so the Ollama health check and
    /// model load/prefill overlap with the recording instead of adding to the
    /// release-to-text pause.
    private var pendingPipeline: Task<DictationPipeline, Never>?

    private func makePipeline(prewarmFor context: ContextPayload?) async -> DictationPipeline {
        let settings = store.settings
        var cleanup: CleanupProvider = PassthroughCleanupProvider()
        if settings.cleanupEnabled {
            switch settings.cleanupEngine {
            case .appleIntelligence:
                if AppleIntelligenceStatus.current() == .ready {
                    cleanup = AppleIntelligenceCleanupProvider(translateTo: settings.outputLanguage)
                    if let context {
                        AppleIntelligenceCleanupProvider.prewarm(
                            context: context, dictionary: store.dictionary,
                            style: store.style(for: context.appCategory),
                            translateTo: settings.outputLanguage)
                    }
                }
            case .ollama:
                if let url = URL(string: settings.ollamaURL) {
                    let client = OllamaClient(baseURL: url)
                    if await client.isAlive() {
                        cleanup = OllamaCleanupProvider(
                            client: client, model: settings.cleanupModel,
                            translateTo: settings.outputLanguage)
                        if let context {
                            let prompt = PromptBuilder.cleanupPrompt(
                                rawTranscript: "", context: context,
                                dictionary: store.dictionary,
                                style: store.style(for: context.appCategory),
                                translateTo: settings.outputLanguage)
                            let model = settings.cleanupModel
                            Task.detached { await client.prewarm(model: model, system: prompt.system) }
                        }
                    }
                }
            }
        }
        return DictationPipeline(
            cleanup: cleanup,
            snippets: store.snippets,
            dictionary: store.dictionary,
            styles: store.styles,
            cleanupEnabled: settings.cleanupEnabled,
            pressEnterEnabled: settings.pressEnterEnabled)
    }

    // MARK: - Triggers

    func pttStart() {
        startRecording(handsFree: false)
    }

    func pttEnd() {
        guard case .recording(handsFree: false) = state else { return }
        Task { await finishRecording() }
    }

    func handsFreeToggle() {
        switch state {
        case .recording:
            Task { await finishRecording() }
        case .idle:
            startRecording(handsFree: true)
        default:
            break
        }
    }

    func cancel() {
        guard case .recording = state else { return }
        Task {
            try? await startTask?.value
            await transcriber.cancel()
            commandModeArmed = false
            state = .idle
        }
    }

    /// Command Mode (§8.1): capture the current selection, then record the
    /// spoken instruction hands-free; on stop, rewrite and replace.
    private var commandSelection: String?

    func commandModeToggle() {
        if case .recording = state {
            Task { await finishRecording() }
            return
        }
        guard state == .idle else { return }
        // With a selection: spoken instruction rewrites it (§8.1).
        // Without: spoken question routes to a web search (§8.2).
        commandSelection = ContextReader.selectedText().flatMap { $0.isEmpty ? nil : $0 }
        commandModeArmed = true
        startRecording(handsFree: true)
    }

    func pasteLastTranscript() {
        guard let last = store.history.last else { return }
        Task { await TextInjector.insert(last.finalText) }
    }

    func copyLastTranscript() {
        guard let last = store.history.last else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.finalText, forType: .string)
    }

    func undoLastInsertion() {
        TextInjector.undoLastInsertion()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Session lifecycle

    private func startRecording(handsFree: Bool) {
        guard state == .idle else {
            Diag.dictation.notice("startRecording skipped: not idle")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerAt >= debounceInterval else {
            Diag.dictation.notice("startRecording skipped: debounced")
            return
        }
        lastTriggerAt = now

        guard Permissions.microphoneGranted else {
            TextInjector.notify(title: "Murmur",
                body: "Microphone access is required. Grant it in System Settings.")
            Permissions.openMicrophoneSettings()
            return
        }

        // Context is read once, at session start, and never from password fields (§6).
        sessionContext = ContextReader.read(contextAwareness: store.settings.contextAwareness)
        if sessionContext.isSecureField {
            TextInjector.notify(title: "Murmur", body: "Dictation is disabled in password fields.")
            commandModeArmed = false
            return
        }

        sessionStartedAt = now
        state = .recording(handsFree: handsFree)

        // Bias ASR with dictionary terms and on-screen names (spec §3.1 stage 3).
        let bias = store.dictionary.map(\.term) + sessionContext.properNouns
        let locale = Locale(identifier: store.settings.defaultLanguage)
        Diag.dictation.notice("recording started (handsFree=\(handsFree), app=\(self.sessionContext.appBundleId ?? "?", privacy: .public))")
        let context = sessionContext
        pendingPipeline = Task { await makePipeline(prewarmFor: context) }
        startTask = Task {
            do {
                try await transcriber.start(locale: locale, contextualStrings: bias)
                Diag.dictation.notice("ASR engine running")
            } catch {
                Diag.dictation.error("ASR start FAILED: \(error.localizedDescription, privacy: .public)")
                state = .idle
                commandModeArmed = false
                TextInjector.notify(title: "Murmur",
                    body: "Could not start dictation: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func finishRecording() async {
        guard case .recording = state else { return }
        let wasCommandMode = commandModeArmed
        commandModeArmed = false

        let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartedAt
        if elapsed < minSessionDuration {
            Diag.dictation.notice("session discarded: too short (\(elapsed, format: .fixed(precision: 2))s)")
            await transcriber.cancel()
            state = .idle
            return
        }

        state = .processing
        do {
            try await startTask?.value
        } catch {
            state = .idle
            return   // engine never started; the start path already notified
        }
        let raw = await transcriber.stop()
        Diag.dictation.notice("transcript: \(raw.count) chars, app=\(self.sessionContext.appBundleId ?? "?", privacy: .public)")
        guard !raw.isEmpty else {
            state = .idle
            return
        }

        if wasCommandMode {
            let selection = commandSelection
            commandSelection = nil
            if let selection {
                await runCommandMode(instruction: raw, selection: selection)
            } else {
                routeQueryToSearch(raw)
            }
            return
        }

        let pipeline: DictationPipeline
        if let pending = pendingPipeline {
            pipeline = await pending.value
        } else {
            pipeline = await makePipeline(prewarmFor: nil)
        }
        pendingPipeline = nil
        let output = await pipeline.process(rawTranscript: raw, context: sessionContext)

        state = .injecting
        let result = await TextInjector.insert(output.textToInsert)
        Diag.dictation.notice("pipeline: \(output.textToInsert.count) chars (fallback=\(output.usedFallback)) → inserted=\(result.inserted) clipboard=\(result.fellBackToClipboard)")
        if output.pressEnter && result.inserted && !result.fellBackToClipboard {
            TextInjector.pressEnter()
        }
        if result.inserted && !result.fellBackToClipboard && !output.textToInsert.isEmpty {
            autoDictionary.watch(insertedText: output.textToInsert)
        }

        if store.settings.historyEnabled {
            let record = TranscriptRecord(
                appBundleId: sessionContext.appBundleId,
                appCategory: sessionContext.appCategory,
                rawText: output.rawText,
                finalText: output.textToInsert,
                language: store.settings.defaultLanguage,
                mode: "dictate")
            store.appendHistory(record)
            onTranscriptRecorded?(record)
        }
        state = .idle
    }

    /// Command Mode with no selection (§8.2): the spoken words become a web
    /// search in the default browser.
    private func routeQueryToSearch(_ query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.perplexity.ai/search?q=\(encoded)")
        else {
            state = .idle
            return
        }
        Diag.dictation.notice("command mode: routing query to search")
        NSWorkspace.shared.open(url)
        if store.settings.historyEnabled {
            let record = TranscriptRecord(
                appBundleId: sessionContext.appBundleId,
                appCategory: sessionContext.appCategory,
                rawText: query,
                finalText: url.absoluteString,
                language: store.settings.defaultLanguage,
                mode: "command")
            store.appendHistory(record)
            onTranscriptRecorded?(record)
        }
        state = .idle
    }

    private func runCommandMode(instruction: String, selection: String) async {
        let settings = store.settings
        guard let url = URL(string: settings.ollamaURL) else {
            state = .idle
            return
        }
        let client = OllamaClient(baseURL: url)
        let prompt = PromptBuilder.commandPrompt(instruction: instruction, selection: selection)

        do {
            let rewritten = try await client.chat(
                model: settings.cleanupModel, system: prompt.system, user: prompt.user)
            guard !rewritten.isEmpty else { throw OllamaError(message: "empty rewrite") }
            state = .injecting
            await TextInjector.insert(rewritten)
            if store.settings.historyEnabled {
                let record = TranscriptRecord(
                    appBundleId: sessionContext.appBundleId,
                    appCategory: sessionContext.appCategory,
                    rawText: instruction,
                    finalText: rewritten,
                    language: settings.defaultLanguage,
                    mode: "command")
                store.appendHistory(record)
                onTranscriptRecorded?(record)
            }
        } catch {
            TextInjector.notify(title: "Murmur",
                body: "Command Mode failed: \(error.localizedDescription)")
        }
        state = .idle
    }
}
