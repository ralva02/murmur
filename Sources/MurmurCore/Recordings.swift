import Foundation

// MARK: - Model

public enum SummaryTemplate: String, Codable, Sendable, CaseIterable, Equatable {
    case auto, meeting, lecture, memo, interview
}

public struct Recording: Codable, Sendable, Equatable, Identifiable {
    public enum Source: Codable, Sendable, Equatable {
        case inApp
        case imported(originalFilename: String)
    }

    public enum Stage: String, Codable, Sendable, Equatable {
        case transcription, summarization
    }

    public enum Status: Codable, Sendable, Equatable {
        case ready          // audio present, pipeline not started (both sources)
        case transcribing
        case transcribed
        case summarizing
        case done
        case failed(stage: Stage, message: String)
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var source: Source
    public var audioFilename: String
    public var language: String
    public var template: SummaryTemplate
    /// Engine tag of the last summary, e.g. "ollama:gemma4:e4b" / "claude:claude-opus-4-8".
    public var summaryEngine: String?
    public var status: Status
    /// True when in-app capture ran without the system-audio tap.
    public var micOnly: Bool
    /// Triage tag. nil = Inbox (new, not yet actioned); tagging moves the
    /// recording into that tag's section.
    public var tag: String?

    public init(
        id: UUID = UUID(), title: String, createdAt: Date = Date(),
        duration: TimeInterval, source: Source, audioFilename: String,
        language: String, template: SummaryTemplate,
        summaryEngine: String? = nil, status: Status = .ready, micOnly: Bool = false,
        tag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.audioFilename = audioFilename
        self.language = language
        self.template = template
        self.summaryEngine = summaryEngine
        self.status = status
        self.micOnly = micOnly
        self.tag = tag
    }
}

// MARK: - Store

/// One folder per recording under Application Support/Murmur/Recordings:
/// audio.<ext>, transcript.txt, summary.md, meta.json. Same conventions as
/// AppStore: atomic writes, main-actor access, temp roots in tests — this
/// store holds hours of irreplaceable audio, so the production-path trap
/// from the 2026-07-03 postmortem applies with force.
public final class RecordingsStore: @unchecked Sendable {

    public static let defaultRootDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/Recordings")

    public let rootDirectory: URL
    public private(set) var recordings: [Recording] = []   // newest first

    public init(rootDirectory: URL = RecordingsStore.defaultRootDirectory) {
        precondition(
            !(AppStore.isRunningUnderTestHarness && rootDirectory == Self.defaultRootDirectory),
            "RecordingsStore: refusing to touch the real recordings directory from a test run — pass an explicit temp path")
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)) ?? []
        recordings = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(Recording.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString)
    }

    public func audioURL(for recording: Recording) -> URL {
        directory(for: recording.id).appendingPathComponent(recording.audioFilename)
    }

    /// Copies the audio in — never moves the user's file.
    @discardableResult
    public func create(
        importingAudioFrom sourceURL: URL,
        source: Recording.Source,
        title: String,
        duration: TimeInterval,
        language: String,
        template: SummaryTemplate
    ) throws -> Recording {
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let recording = Recording(
            title: title, duration: duration, source: source,
            audioFilename: "audio.\(ext)", language: language, template: template)
        let dir = directory(for: recording.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: dir.appendingPathComponent(recording.audioFilename))
        recordings.insert(recording, at: 0)
        save(recording)
        return recording
    }

    public func update(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        }
        save(recording)
    }

    public func saveTranscript(_ text: String, for id: UUID) {
        try? Data(text.utf8).write(
            to: directory(for: id).appendingPathComponent("transcript.txt"), options: .atomic)
    }

    public func transcript(for id: UUID) -> String? {
        (try? Data(contentsOf: directory(for: id).appendingPathComponent("transcript.txt")))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public func saveSummary(_ markdown: String, for id: UUID) {
        try? Data(markdown.utf8).write(
            to: directory(for: id).appendingPathComponent("summary.md"), options: .atomic)
    }

    public func summary(for id: UUID) -> String? {
        (try? Data(contentsOf: directory(for: id).appendingPathComponent("summary.md")))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public func delete(id: UUID) {
        recordings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// All tags in use, sorted, for the tag-picker menu.
    public var allTags: [String] {
        Set(recordings.compactMap(\.tag)).sorted()
    }

    private func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recording) else { return }
        try? data.write(to: directory(for: recording.id).appendingPathComponent("meta.json"), options: .atomic)
    }
}
