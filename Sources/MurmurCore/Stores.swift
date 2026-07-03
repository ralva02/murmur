import Foundation

/// JSON-file-backed application state (spec §16): settings, personalization,
/// and local history under one root directory. Single-user, local-only (§14).
///
/// Not thread-safe by design — all app access happens on the main actor; tests
/// use isolated instances. Saves are atomic writes.
public final class AppStore: @unchecked Sendable {

    public static let defaultRootDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur")

    /// Pre-rename data location (the app used to be called Wisprrr).
    public static let legacyDefaultRootDirectory = FileManager.default
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
    public private(set) var notes: [Note]

    /// One-time migration from the pre-rename directory. Deliberately NOT part
    /// of init: implicit migration in a constructor once let unit tests using
    /// temp roots "migrate" (move!) the real user data into their sandboxes.
    /// The app calls this exactly once at launch, before building its store.
    public static func migrateLegacyDataIfNeeded(
        from legacy: URL = AppStore.legacyDefaultRootDirectory,
        to root: URL = AppStore.defaultRootDirectory
    ) {
        guard !FileManager.default.fileExists(atPath: root.path),
              FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.moveItem(at: legacy, to: root)
    }

    public init(rootDirectory: URL = AppStore.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        self.settings = Self.load("settings.json", from: rootDirectory) ?? Settings()
        self.dictionary = Self.load("dictionary.json", from: rootDirectory) ?? []
        self.snippets = Self.load("snippets.json", from: rootDirectory) ?? []
        self.styles = Self.load("styles.json", from: rootDirectory) ?? Style.defaults
        self.history = Self.load("history.json", from: rootDirectory) ?? []
        self.notes = Self.load("notes.json", from: rootDirectory) ?? []

        // Bindings added in newer versions must appear in settings saved by
        // older versions, or their actions are unreachable.
        let present = Set(settings.bindings.map(\.action))
        let missing = HotkeyBinding.defaults.filter { !present.contains($0.action) }
        if !missing.isEmpty {
            settings.bindings.append(contentsOf: missing)
        }
    }

    // MARK: - Notes (scratchpad)

    @discardableResult
    public func addNote(text: String) -> Note {
        let note = Note(text: text)
        notes.append(note)
        saveNotes()
        return note
    }

    public func updateNote(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        saveNotes()
    }

    public func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        saveNotes()
    }

    private func saveNotes() { save(notes, to: "notes.json") }

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
