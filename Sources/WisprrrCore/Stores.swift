import Foundation

/// JSON-file-backed application state (spec §16): settings, personalization,
/// and local history under one root directory. Single-user, local-only (§14).
///
/// Not thread-safe by design — all app access happens on the main actor; tests
/// use isolated instances. Saves are atomic writes.
public final class AppStore: @unchecked Sendable {

    public static let defaultRootDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wisprrr")

    private static let historyCap = 500

    public let rootDirectory: URL

    public var settings: Settings {
        didSet { save(settings, to: "settings.json") }
    }
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var styles: [Style]
    public private(set) var history: [TranscriptRecord]

    public init(rootDirectory: URL = AppStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        self.settings = Self.load("settings.json", from: rootDirectory) ?? Settings()
        self.dictionary = Self.load("dictionary.json", from: rootDirectory) ?? []
        self.snippets = Self.load("snippets.json", from: rootDirectory) ?? []
        self.styles = Self.load("styles.json", from: rootDirectory) ?? Style.defaults
        self.history = Self.load("history.json", from: rootDirectory) ?? []
    }

    // MARK: - Personalization

    public func saveDictionary() { save(dictionary, to: "dictionary.json") }
    public func saveSnippets() { save(snippets, to: "snippets.json") }
    public func saveStyles() { save(styles, to: "styles.json") }

    public func style(for category: AppCategory) -> Style? {
        styles.first { $0.appCategory == category }
    }

    // MARK: - History

    public func appendHistory(_ record: TranscriptRecord) {
        history.append(record)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        save(history, to: "history.json")
    }

    public func clearHistory() {
        history = []
        save(history, to: "history.json")
    }

    // MARK: - Persistence plumbing

    private static func load<T: Decodable>(_ file: String, from root: URL) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to file: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: rootDirectory.appendingPathComponent(file), options: .atomic)
    }
}
