import Foundation
import WisprrrCore

// Debug entry: exercises the processing pipeline (snippets, press-enter,
// cleanup LLM) from the command line without mic/AX involvement.
//   wisprrr --process-text "um so lets meet tuesday wait no friday"
if let flagIndex = CommandLine.arguments.firstIndex(of: "--process-text"),
   CommandLine.arguments.count > flagIndex + 1 {
    let raw = CommandLine.arguments[flagIndex + 1]
    let store = AppStore()
    let client = OllamaClient(baseURL: URL(string: store.settings.ollamaURL)!)

    let exitCode: Int32 = await {
        let alive = await client.isAlive()
        let cleanup: CleanupProvider = alive
            ? OllamaCleanupProvider(client: client, model: store.settings.cleanupModel)
            : PassthroughCleanupProvider()
        if !alive { FileHandle.standardError.write(Data("warning: Ollama unreachable, passthrough mode\n".utf8)) }

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

// App mode (menu bar shell) is wired up in AppMain.
AppMain.run()
