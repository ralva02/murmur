import Foundation
import Testing
@testable import WisprrrCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test func settingsPersistAndReload() throws {
    let root = tempRoot()
    let store = AppStore(rootDirectory: root)
    var s = store.settings
    s.cleanupEnabled = false
    store.settings = s
    let store2 = AppStore(rootDirectory: root)
    #expect(store2.settings.cleanupEnabled == false)
}

@Test func personalizationDefaultsAndCRUD() throws {
    let root = tempRoot()
    let store = AppStore(rootDirectory: root)
    #expect(store.styles.count == AppCategory.allCases.count)
    store.dictionary.append(DictionaryEntry(term: "Wisprrr"))
    store.saveDictionary()
    store.snippets.append(Snippet(triggerPhrase: "my email address", body: "x@y.z")!)
    store.saveSnippets()
    let store2 = AppStore(rootDirectory: root)
    #expect(store2.dictionary.map(\.term) == ["Wisprrr"])
    #expect(store2.snippets.count == 1)
}

@Test func stylesPersistEdits() throws {
    let root = tempRoot()
    let store = AppStore(rootDirectory: root)
    store.styles[0].tone = "extremely formal"
    store.saveStyles()
    let store2 = AppStore(rootDirectory: root)
    #expect(store2.styles[0].tone == "extremely formal")
}

@Test func historyAppendsAndPrunes() throws {
    let root = tempRoot()
    let store = AppStore(rootDirectory: root)
    for i in 0..<520 {
        store.appendHistory(TranscriptRecord(
            appBundleId: nil, appCategory: .other,
            rawText: "r\(i)", finalText: "f\(i)", language: "en-US", mode: "dictate"))
    }
    #expect(store.history.count == 500)
    #expect(store.history.last?.rawText == "r519")
    let store2 = AppStore(rootDirectory: root)
    #expect(store2.history.count == 500)
    store.clearHistory()
    #expect(store.history.isEmpty)
    #expect(AppStore(rootDirectory: root).history.isEmpty)
}

@Test func snippetTriggerLengthValidated() {
    #expect(Snippet(triggerPhrase: String(repeating: "a", count: 61), body: "b") == nil)
    #expect(Snippet(triggerPhrase: String(repeating: "a", count: 60), body: "b") != nil)
    #expect(Snippet(triggerPhrase: "   ", body: "b") == nil)
}

@Test func corruptFileFallsBackToDefaults() throws {
    let root = tempRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: root.appendingPathComponent("settings.json"))
    let store = AppStore(rootDirectory: root)
    #expect(store.settings == Settings())
}
