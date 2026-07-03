import AppKit
import Foundation
import WisprrrCore

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

    private let store: AppStore
    private let transcriber = AudioTranscriber()
    private var sessionContext: ContextPayload = .empty
    private var sessionStartedAt: TimeInterval = 0
    private var lastTriggerAt: TimeInterval = 0
    private var commandModeArmed = false

    /// Recordings shorter than this are accidental taps and are discarded.
    private let minSessionDuration: TimeInterval = 0.30
    /// Debounce window against rapid start/stop toggling (spec §17).
    private let debounceInterval: TimeInterval = 0.20

    init(store: AppStore) {
        self.store = store
    }

    private func makePipeline() async -> DictationPipeline {
        let settings = store.settings
        var cleanup: CleanupProvider = PassthroughCleanupProvider()
        if settings.cleanupEnabled, let url = URL(string: settings.ollamaURL) {
            let client = OllamaClient(baseURL: url)
            if await client.isAlive() {
                cleanup = OllamaCleanupProvider(client: client, model: settings.cleanupModel)
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
        guard let selection = ContextReader.selectedText(), !selection.isEmpty else {
            TextInjector.notify(title: "Wisprrr",
                body: "Command Mode: select some text first, then speak an instruction.")
            return
        }
        commandSelection = selection
        commandModeArmed = true
        startRecording(handsFree: true)
    }

    func pasteLastTranscript() {
        guard let last = store.history.last else { return }
        Task { await TextInjector.insert(last.finalText) }
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
        guard state == .idle else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerAt >= debounceInterval else { return }
        lastTriggerAt = now

        guard Permissions.microphoneGranted else {
            TextInjector.notify(title: "Wisprrr",
                body: "Microphone access is required. Grant it in System Settings.")
            Permissions.openMicrophoneSettings()
            return
        }

        // Context is read once, at session start, and never from password fields (§6).
        sessionContext = ContextReader.read(contextAwareness: store.settings.contextAwareness)
        if sessionContext.isSecureField {
            TextInjector.notify(title: "Wisprrr", body: "Dictation is disabled in password fields.")
            commandModeArmed = false
            return
        }

        sessionStartedAt = now
        state = .recording(handsFree: handsFree)

        // Bias ASR with dictionary terms and on-screen names (spec §3.1 stage 3).
        let bias = store.dictionary.map(\.term) + sessionContext.properNouns
        let locale = Locale(identifier: store.settings.defaultLanguage)
        Task {
            do {
                try await transcriber.start(locale: locale, contextualStrings: bias)
            } catch {
                state = .idle
                commandModeArmed = false
                TextInjector.notify(title: "Wisprrr",
                    body: "Could not start dictation: \(error.localizedDescription)")
            }
        }
    }

    private func finishRecording() async {
        guard case .recording = state else { return }
        let wasCommandMode = commandModeArmed
        commandModeArmed = false

        let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartedAt
        if elapsed < minSessionDuration {
            await transcriber.cancel()
            state = .idle
            return
        }

        state = .processing
        let raw = await transcriber.stop()
        guard !raw.isEmpty else {
            state = .idle
            return
        }

        if wasCommandMode, let selection = commandSelection {
            commandSelection = nil
            await runCommandMode(instruction: raw, selection: selection)
            return
        }

        let pipeline = await makePipeline()
        let output = await pipeline.process(rawTranscript: raw, context: sessionContext)

        state = .injecting
        let result = await TextInjector.insert(output.textToInsert)
        if output.pressEnter && result.inserted && !result.fellBackToClipboard {
            TextInjector.pressEnter()
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
            TextInjector.notify(title: "Wisprrr",
                body: "Command Mode failed: \(error.localizedDescription)")
        }
        state = .idle
    }
}
