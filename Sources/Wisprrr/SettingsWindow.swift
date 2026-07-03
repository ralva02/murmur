import SwiftUI
import WisprrrCore

/// Settings UI (spec §12): General, Personalization, Data & Privacy, Audio.
struct SettingsView: View {
    @State private var model: SettingsModel
    let onBindingsChanged: () -> Void

    init(store: AppStore, onBindingsChanged: @escaping () -> Void) {
        _model = State(initialValue: SettingsModel(store: store))
        self.onBindingsChanged = onBindingsChanged
    }

    var body: some View {
        TabView {
            GeneralTab(model: model, onBindingsChanged: onBindingsChanged)
                .tabItem { Label("General", systemImage: "gearshape") }
            PersonalizationTab(model: model)
                .tabItem { Label("Personalization", systemImage: "person.text.rectangle") }
            PrivacyTab(model: model)
                .tabItem { Label("Data & Privacy", systemImage: "lock") }
            AudioTab()
                .tabItem { Label("Audio", systemImage: "waveform") }
        }
        .frame(width: 620, height: 460)
        .padding()
    }
}

/// Observable wrapper bridging AppStore to SwiftUI.
@MainActor @Observable
final class SettingsModel {
    let store: AppStore

    var settings: WisprrrCore.Settings {
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

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: SettingsModel
    let onBindingsChanged: () -> Void

    var body: some View {
        Form {
            Section("Dictation") {
                TextField("Language (BCP-47)", text: $model.settings.defaultLanguage)
                Toggle("Clean up transcripts with LLM", isOn: $model.settings.cleanupEnabled)
                TextField("Ollama model", text: $model.settings.cleanupModel)
                TextField("Ollama URL", text: $model.settings.ollamaURL)
                Toggle("Enable “press enter” command", isOn: $model.settings.pressEnterEnabled)
            }
            Section("Shortcuts") {
                Text("Hold **Fn** to dictate · double-tap **Fn** for hands-free · **Esc** cancels while recording")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(rebindableActions, id: \.self) { action in
                    ShortcutRow(action: action, model: model, onBindingsChanged: onBindingsChanged)
                }
                Button("Reset Shortcuts to Defaults") {
                    model.settings.bindings = HotkeyBinding.defaults
                    onBindingsChanged()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rebindableActions: [BindableAction] {
        [.commandMode, .pasteLastTranscript, .viewDiff]
    }
}

private struct ShortcutRow: View {
    let action: BindableAction
    @Bindable var model: SettingsModel
    let onBindingsChanged: () -> Void
    @State private var capturing = false

    var body: some View {
        HStack {
            Text(label(for: action))
            Spacer()
            Button(capturing ? "Press a key combo…" : currentBindingDescription) {
                startCapture()
            }
            .buttonStyle(.bordered)
        }
    }

    private func label(for action: BindableAction) -> String {
        switch action {
        case .commandMode: "Command Mode"
        case .pasteLastTranscript: "Paste Last Transcript"
        case .viewDiff: "View Diff / Activity"
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

// MARK: - Personalization

private struct PersonalizationTab: View {
    @Bindable var model: SettingsModel
    @State private var newTerm = ""
    @State private var newTrigger = ""
    @State private var newBody = ""

    var body: some View {
        Form {
            Section {
                Toggle("Auto-add to dictionary", isOn: $model.settings.autoAddDictionary)
                Text("When you correct a word Wisprrr inserted, the corrected spelling is learned automatically. Only the field Wisprrr pasted into is checked.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Dictionary — names, jargon, terms spelled exactly") {
                ForEach(model.dictionary.indices, id: \.self) { i in
                    HStack {
                        Text(model.dictionary[i].term)
                        Spacer()
                        Button(role: .destructive) {
                            model.dictionary.remove(at: i)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add term", text: $newTerm)
                    Button("Add") {
                        let t = newTerm.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        model.dictionary.append(DictionaryEntry(term: t))
                        newTerm = ""
                    }
                }
            }
            Section("Snippets — say the trigger phrase, insert the block") {
                ForEach(model.snippets.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text("“\(model.snippets[i].triggerPhrase)”").bold()
                            Text(model.snippets[i].body).font(.callout)
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.snippets.remove(at: i)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                TextField("Trigger phrase (max 60 characters)", text: $newTrigger)
                TextField("Text to insert", text: $newBody, axis: .vertical).lineLimit(2...4)
                Button("Add Snippet") {
                    guard let snippet = Snippet(triggerPhrase: newTrigger, body: newBody),
                          !newBody.isEmpty else { NSSound.beep(); return }
                    model.snippets.append(snippet)
                    newTrigger = ""; newBody = ""
                }
            }
            Section("Styles — tone per app category (English, desktop)") {
                ForEach(model.styles.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.styles[i].appCategory.rawValue.capitalized)
                                .frame(width: 90, alignment: .leading)
                            TextField("Tone", text: $model.styles[i].tone)
                        }
                        TextField("Example of how you write here (optional — strongest tone signal)",
                                  text: $model.styles[i].sample, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Context Awareness") {
                Toggle("Read active app & nearby text to improve accuracy", isOn: $model.settings.contextAwareness)
                Text("Context is read locally, only during an active dictation, and never from password fields. With a local Ollama model, nothing leaves this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Keep local transcript history", isOn: $model.settings.historyEnabled)
                Button("Clear History", role: .destructive) {
                    model.store.clearHistory()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @State private var level: Float = 0
    @State private var meter: AudioLevelMeter?

    var body: some View {
        Form {
            Section("Microphone Test") {
                ProgressView(value: min(max(Double(level), 0), 1))
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
            }
        }
        .formStyle(.grouped)
        .onDisappear { meter?.stop(); meter = nil }
    }
}

/// Tiny RMS meter for the Audio settings tab.
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

import AVFAudio
