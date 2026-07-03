import Speech
import SwiftUI
import MurmurCore
@preconcurrency import AVFAudio

/// Observable wrapper bridging AppStore to SwiftUI.
@MainActor @Observable
final class SettingsModel {
    let store: AppStore

    var settings: MurmurCore.Settings {
        didSet { store.settings = settings }
    }
    var dictionary: [DictionaryEntry] {
        didSet { store.dictionary = dictionary; store.saveDictionary() }
    }
    var snippets: [Snippet] {
        didSet { store.snippets = snippets; store.saveSnippets() }
    }
    var styles: [Style] {
        didSet { store.styles = styles; store.saveStyles() }
    }

    init(store: AppStore) {
        self.store = store
        self.settings = store.settings
        self.dictionary = store.dictionary
        self.snippets = store.snippets
        self.styles = store.styles
    }
}

// MARK: - Settings page (Flow-styled)

struct SettingsPage: View {
    @Bindable var model: SettingsModel
    let onBindingsChanged: () -> Void
    let onRunSetup: () -> Void
    @State private var supportedLocales: [Locale] = []
    @State private var claudeKey = KeychainStore.readClaudeKey() ?? ""

    var body: some View {
        Page(title: "Settings") {
            EmptyView()
        } content: {
            section("Dictation") {
                labeledRow("Language") {
                    if supportedLocales.isEmpty {
                        TextField("BCP-47", text: $model.settings.defaultLanguage)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                    } else {
                        Picker("", selection: $model.settings.defaultLanguage) {
                            ForEach(supportedLocales, id: \.identifier) { locale in
                                Text(displayName(for: locale)).tag(locale.identifier(.bcp47))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: model.settings.defaultLanguage) {
                            let locale = Locale(identifier: model.settings.defaultLanguage)
                            Task { try? await AudioTranscriber.ensureAssets(locale: locale) }
                        }
                    }
                }
                labeledRow("Translate output to") {
                    TextField("Off — e.g. “Spanish”", text: Binding(
                        get: { model.settings.outputLanguage ?? "" },
                        set: { model.settings.outputLanguage = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 220)
                }
                toggleRow("“Press enter” command", isOn: $model.settings.pressEnterEnabled)
            }

            section("Cleanup") {
                toggleRow("Polish transcripts with the local LLM", isOn: $model.settings.cleanupEnabled)
                labeledRow("Engine") {
                    Picker("", selection: $model.settings.cleanupEngine) {
                        Text("Apple Intelligence").tag(CleanupEngine.appleIntelligence)
                        Text("Ollama").tag(CleanupEngine.ollama)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if model.settings.cleanupEngine == .appleIntelligence {
                    HStack {
                        Text(AppleIntelligenceStatus.current().explanation)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else {
                    labeledRow("Ollama model") {
                        TextField("model", text: $model.settings.cleanupModel)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                    }
                    labeledRow("Ollama URL") {
                        TextField("url", text: $model.settings.ollamaURL)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                    }
                }
            }

            section("Summaries") {
                labeledRow("Engine") {
                    Picker("", selection: $model.settings.summaryEngine) {
                        Text("Ollama (local)").tag(SummaryEngine.ollama)
                        Text("Claude API").tag(SummaryEngine.claude)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if model.settings.summaryEngine == .claude {
                    labeledRow("Claude model") {
                        TextField("model", text: $model.settings.claudeModel)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                    }
                    labeledRow("API key") {
                        SecureField("sk-ant-…", text: $claudeKey)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                            .onSubmit { KeychainStore.saveClaudeKey(claudeKey) }
                    }
                    HStack {
                        Text("Stored in the macOS Keychain. Transcripts (not audio) are sent to Anthropic when summarizing — roughly $0.10–0.15 per hour-long recording at Opus pricing.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                toggleRow("Watch Downloads for Plaud exports", isOn: $model.settings.downloadsWatcherEnabled)
                HStack {
                    Text("Applies at next launch.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            section("Shortcuts") {
                Text("Hold **Fn** to dictate · double-tap **Fn** for hands-free · **Esc** cancels")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                ForEach(rebindableActions, id: \.self) { action in
                    ShortcutRow(action: action, model: model, onBindingsChanged: onBindingsChanged)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                }
                HStack {
                    Button("Reset to defaults") {
                        model.settings.bindings = HotkeyBinding.defaults
                        onBindingsChanged()
                    }
                    .buttonStyle(GhostButtonStyle())
                    Spacer()
                }
                .padding(12)
            }

            section("Data & Privacy") {
                toggleRow("Context awareness — read the active app & nearby text", isOn: $model.settings.contextAwareness)
                toggleRow("Keep local transcript history", isOn: $model.settings.historyEnabled)
                HStack {
                    Text("Everything runs on this Mac. Nothing leaves it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Button("Clear history") { model.store.clearHistory() }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                HStack {
                    Text("Walk through permissions and cleanup setup again.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                    Spacer()
                    Button("Run setup again") { onRunSetup() }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            section("Audio") {
                MicTestRow()
            }
        }
        .task {
            var locales = await SpeechTranscriber.supportedLocales
            locales.sort { displayName(for: $0) < displayName(for: $1) }
            supportedLocales = locales
        }
    }

    private var rebindableActions: [BindableAction] {
        [.commandMode, .pasteLastTranscript, .copyLastTranscript, .viewDiff, .openScratchpad]
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: layout helpers

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .kerning(0.8)
            VStack(spacing: 0) { rows() }
                .card()
        }
    }

    private func labeledRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                Spacer()
                control()
                    .font(.system(size: 13.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Toggle(label, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
    }
}

// MARK: - Shortcut capture row

struct ShortcutRow: View {
    let action: BindableAction
    @Bindable var model: SettingsModel
    let onBindingsChanged: () -> Void
    @State private var capturing = false

    var body: some View {
        HStack {
            Text(label(for: action))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
            Spacer()
            Button(capturing ? "Press a key combo…" : currentBindingDescription) {
                startCapture()
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    private func label(for action: BindableAction) -> String {
        switch action {
        case .commandMode: "Command Mode"
        case .pasteLastTranscript: "Paste Last Transcript"
        case .copyLastTranscript: "Copy Last Transcript"
        case .viewDiff: "View Diff / Activity"
        case .openScratchpad: "Open Scratchpad"
        default: action.rawValue
        }
    }

    private var currentBindingDescription: String {
        guard let binding = model.settings.bindings.first(where: { $0.action == action }),
              let keyCode = binding.keyCode else { return "Not set" }
        return HotkeyFormatter.describe(keyCode: keyCode, modifiers: binding.modifiers)
    }

    private func startCapture() {
        capturing = true
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer {
                if let monitor { NSEvent.removeMonitor(monitor) }
                capturing = false
            }
            let relevantMask: UInt64 = (CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskShift.rawValue)
            let mods = UInt64(event.modifierFlags.rawValue) & relevantMask
            let keyCode = Int64(event.keyCode)

            // Validate: reject collisions with existing bindings (spec §4.2).
            let collides = model.settings.bindings.contains {
                $0.action != action && $0.keyCode == keyCode && $0.modifiers == mods
            }
            guard !collides else {
                NSSound.beep()
                return nil
            }
            if let index = model.settings.bindings.firstIndex(where: { $0.action == action }) {
                model.settings.bindings[index] = HotkeyBinding(action: action, keyCode: keyCode, modifiers: mods)
            } else {
                model.settings.bindings.append(HotkeyBinding(action: action, keyCode: keyCode, modifiers: mods))
            }
            onBindingsChanged()
            return nil
        }
    }
}

enum HotkeyFormatter {
    static func describe(keyCode: Int64, modifiers: UInt64) -> String {
        var parts: [String] = []
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { parts.append("⌃") }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { parts.append("⇧") }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        ]
        return names[keyCode] ?? "key\(keyCode)"
    }
}

// MARK: - Mic test

private struct MicTestRow: View {
    @State private var level: Float = 0
    @State private var meter: AudioLevelMeter?

    var body: some View {
        HStack(spacing: 14) {
            Button(meter == nil ? "Start Mic Test" : "Stop Mic Test") {
                if let running = meter {
                    running.stop()
                    meter = nil
                    level = 0
                } else {
                    let m = AudioLevelMeter { level = $0 }
                    do {
                        try m.start()
                        meter = m
                    } catch {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }
            .buttonStyle(GhostButtonStyle())
            ProgressView(value: min(max(Double(level), 0), 1))
                .tint(Theme.violet)
        }
        .padding(16)
        .onDisappear {
            meter?.stop()
            meter = nil
        }
    }
}

/// Tiny RMS meter for the Audio section.
@MainActor
final class AudioLevelMeter {
    struct MeterError: Error {}

    private let engine = AVAudioEngine()
    private let onLevel: @MainActor (Float) -> Void

    init(onLevel: @escaping @MainActor (Float) -> Void) {
        self.onLevel = onLevel
    }

    func start() throws {
        // Without microphone permission the input node reports a 0 Hz format,
        // and installTap raises an unrecoverable ObjC exception on it.
        guard engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            throw MeterError()
        }
        let handler = onLevel
        Self.installTap(on: engine) { rms in
            Task { @MainActor in handler(min(rms * 8, 1)) }
        }
        engine.prepare()
        try engine.start()
    }

    /// The tap closure runs on the audio thread. It must be formed in a
    /// nonisolated context — created inside a @MainActor method it would
    /// inherit main-actor isolation and trap the isolation assertion when
    /// the audio thread invokes it.
    private nonisolated static func installTap(
        on engine: AVAudioEngine,
        sink: @escaping @Sendable (Float) -> Void
    ) {
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += data[i] * data[i] }
            sink(frames > 0 ? sqrtf(sum / Float(frames)) : 0)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
