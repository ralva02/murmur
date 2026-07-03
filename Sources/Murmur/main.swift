import AppKit
import Foundation
import SwiftUI
import MurmurCore

// Debug entry: run a transcript through the summary engine + title/task
// extraction, no mic/AX. Verifies the Recordings core against a live model.
//   swift run Murmur --summarize "Priya will prep the deck. Book the room."
if let flagIndex = CommandLine.arguments.firstIndex(of: "--summarize"),
   CommandLine.arguments.count > flagIndex + 1 {
    let transcript = CommandLine.arguments[flagIndex + 1]
    let store = AppStore()
    let s = store.settings
    let provider: SummaryProvider = OllamaSummaryProvider(
        client: OllamaClient(baseURL: URL(string: s.ollamaURL)!), model: s.cleanupModel)
    let exit: Int32 = await {
        do {
            let raw = try await provider.summarize(transcript: transcript, template: .auto)
            let parsed = SummaryOutput.parse(raw)
            print("TITLE: \(parsed.title ?? "<none>")")
            print("--- body ---\n\(parsed.body)")
            print("--- tasks ---")
            for t in TaskExtractor.parse(parsed.body) { print("  • \(t.title)  →  \(t.assignee)") }
            return 0
        } catch {
            print("summarize failed: \(error)")
            return 1
        }
    }()
    Foundation.exit(exit)
}

// Debug entry: exercises the processing pipeline (snippets, press-enter,
// cleanup LLM) from the command line without mic/AX involvement.
//   wisprrr --process-text "um so lets meet tuesday wait no friday"
if let flagIndex = CommandLine.arguments.firstIndex(of: "--process-text"),
   CommandLine.arguments.count > flagIndex + 1 {
    let raw = CommandLine.arguments[flagIndex + 1]
    let store = AppStore()

    let exitCode: Int32 = await {
        let settings = store.settings
        let cleanup: CleanupProvider
        switch settings.cleanupEngine {
        case .appleIntelligence where AppleIntelligenceStatus.current() == .ready:
            cleanup = AppleIntelligenceCleanupProvider(translateTo: settings.outputLanguage)
            print("engine:     appleIntelligence")
        case .ollama:
            let client = OllamaClient(baseURL: URL(string: settings.ollamaURL)!)
            if await client.isAlive() {
                cleanup = OllamaCleanupProvider(client: client, model: settings.cleanupModel,
                                                translateTo: settings.outputLanguage)
                print("engine:     ollama (\(settings.cleanupModel))")
            } else {
                cleanup = PassthroughCleanupProvider()
                print("engine:     passthrough (Ollama unreachable)")
            }
        default:
            cleanup = PassthroughCleanupProvider()
            print("engine:     passthrough (Apple Intelligence unavailable: \(AppleIntelligenceStatus.current()))")
        }

        let pipeline = DictationPipeline(
            cleanup: cleanup,
            snippets: store.snippets,
            dictionary: store.dictionary,
            styles: store.styles,
            cleanupEnabled: store.settings.cleanupEnabled,
            pressEnterEnabled: store.settings.pressEnterEnabled)
        let out = await pipeline.process(rawTranscript: raw, context: .empty)
        print("raw:        \(out.rawText)")
        print("final:      \(out.textToInsert)")
        print("pressEnter: \(out.pressEnter)  fallback: \(out.usedFallback)")
        return 0
    }()
    exit(exitCode)
}

// Debug entry: waits 3 s (focus a text field somewhere), then runs the real
// injection path. Launch as the bundle so TCC attributes it to the app:
//   open build/Murmur.app --args --inject-text "hello from wisprrr"
if let flagIndex = CommandLine.arguments.firstIndex(of: "--inject-text"),
   CommandLine.arguments.count > flagIndex + 1 {
    let text = CommandLine.arguments[flagIndex + 1]
    let ok: Bool = await {
        print("accessibility trusted: \(Permissions.accessibilityTrusted)")
        try? await Task.sleep(for: .seconds(3))
        let result = await TextInjector.insert(text)
        print("inserted: \(result.inserted)  clipboardFallback: \(result.fellBackToClipboard)")
        return result.inserted
    }()
    exit(ok ? 0 : 1)
}

// Debug entry: renders every dashboard page to PNGs for design review —
// no window and no screen-recording permission needed.
//   swift run Murmur --snapshot /tmp/shots
if let flagIndex = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.count > flagIndex + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    await MainActor.run {
        let store = AppStore()
        let snapshotRecordings = RecordingsStore(rootDirectory:
            FileManager.default.temporaryDirectory.appendingPathComponent("murmur-snapshot-recordings"))
        let snapshotTasks = TasksStore(rootDirectory:
            FileManager.default.temporaryDirectory.appendingPathComponent("murmur-snapshot-tasks"))
        let model = MainModel(
            store: store,
            recordingsModel: RecordingsModel(
                recordingsStore: snapshotRecordings,
                pipeline: RecordingPipeline(store: store, recordings: snapshotRecordings),
                appStore: store, tasksStore: snapshotTasks),
            tasksModel: TasksModel(store: snapshotTasks),
            dictation: nil) {}
        for section in MainSection.allCases {
            model.section = section
            let renderer = ImageRenderer(content: MainView(model: model)
                .frame(width: 1060, height: 680))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let file = dir.appendingPathComponent("\(section.rawValue.lowercased()).png")
            try? png.write(to: file)
            print("wrote \(file.path)")
        }
    }
    exit(0)
}

// App mode (menu bar shell) is wired up in AppMain.
AppMain.run()
