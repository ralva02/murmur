# Recordings (Long-Form Capture, Transcription & Summaries) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Recordings pillar in Murmur — record in-app (mic + system audio) or import Plaud-app exports, transcribe on-device, summarize locally via Ollama or opt-in via Claude.

**Architecture:** MurmurCore gains the pure, tested layer (Recording model + RecordingsStore, SummaryPrompt templates, AnthropicClient with injectable transport, SummaryProviders, new Settings fields). The app target gains capture (`LongFormRecorder` + `SystemAudioTap`), `FileTranscriber` (SpeechAnalyzer file mode), a serial `RecordingPipeline`, Keychain storage for the Claude key, a Recordings UI section, and a Downloads watcher with confirm-to-import notifications. Spec: `docs/superpowers/specs/2026-07-03-recordings-design.md`.

**Tech Stack:** Swift 6 / SPM, swift-testing, AVFoundation (AVAudioEngine/AVAudioFile/AVMutableComposition), CoreAudio process taps (`AudioHardwareCreateProcessTap`), SpeechAnalyzer (macOS 26), Anthropic Messages API (raw HTTP; model `claude-opus-4-8`, adaptive thinking, **no sampling params**), Security.framework (Keychain), UserNotifications.

**Conventions:** `swift test` after every core task; commit per task. Tests use temp roots only — RecordingsStore must carry the same production-path trap as AppStore. UI follows `Theme`.

---

### Task 1: `Recording` model + `RecordingsStore`

**Files:**
- Create: `Sources/MurmurCore/Recordings.swift`
- Test: `Tests/MurmurCoreTests/RecordingsStoreTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import MurmurCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("murmur-rec-tests-\(UUID().uuidString)")
}

private func makeAudioFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-\(UUID().uuidString).wav")
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)   // content irrelevant to the store
    return url
}

@Test func createCopiesAudioAndPersists() throws {
    let root = tempRoot()
    let store = RecordingsStore(rootDirectory: root)
    let audio = try makeAudioFixture()

    let rec = try store.create(
        importingAudioFrom: audio,
        source: .imported(originalFilename: "meeting.wav"),
        title: "Team sync", duration: 61.5,
        language: "en-US", template: .auto)

    #expect(rec.status == .ready)
    #expect(FileManager.default.fileExists(atPath: audio.path))          // copied, not moved
    #expect(FileManager.default.fileExists(atPath: store.audioURL(for: rec).path))

    let reloaded = RecordingsStore(rootDirectory: root)
    #expect(reloaded.recordings.count == 1)
    #expect(reloaded.recordings[0].title == "Team sync")
}

@Test func transcriptAndSummaryRoundTrip() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    let rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .meeting)

    store.saveTranscript("hello world", for: rec.id)
    store.saveSummary("## Summary\n- hi", for: rec.id)
    #expect(store.transcript(for: rec.id) == "hello world")
    #expect(store.summary(for: rec.id) == "## Summary\n- hi")
}

@Test func statusUpdatesPersist() throws {
    let root = tempRoot()
    let store = RecordingsStore(rootDirectory: root)
    var rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .auto)

    rec.status = .failed(stage: .transcription, message: "boom")
    store.update(rec)
    let reloaded = RecordingsStore(rootDirectory: root)
    #expect(reloaded.recordings[0].status == .failed(stage: .transcription, message: "boom"))
}

@Test func deleteRemovesFolder() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    let rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .auto)
    let dir = store.directory(for: rec.id)
    store.delete(id: rec.id)
    #expect(store.recordings.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func newestFirstOrdering() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    _ = try store.create(importingAudioFrom: makeAudioFixture(), source: .inApp,
                         title: "old", duration: 1, language: "en-US", template: .auto)
    _ = try store.create(importingAudioFrom: makeAudioFixture(), source: .inApp,
                         title: "new", duration: 1, language: "en-US", template: .auto)
    #expect(store.recordings.first?.title == "new")
}

// Same regression guard as AppStore (2026-07-03 data-loss postmortem):
// production-path construction from a test process must trap.
@Test func productionPathRecordingsStoreTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        _ = RecordingsStore()
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter RecordingsStore` → compile error (`RecordingsStore` undefined).

- [ ] **Step 3: Implement `Sources/MurmurCore/Recordings.swift`:**

```swift
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

    public init(
        id: UUID = UUID(), title: String, createdAt: Date = Date(),
        duration: TimeInterval, source: Source, audioFilename: String,
        language: String, template: SummaryTemplate,
        summaryEngine: String? = nil, status: Status = .ready, micOnly: Bool = false
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

    private func save(_ recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recording) else { return }
        try? data.write(to: directory(for: recording.id).appendingPathComponent("meta.json"), options: .atomic)
    }
}
```

- [ ] **Step 4: Run full suite** — `swift test` → all pass.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(core): Recording model + RecordingsStore with production-path guard"`

---

### Task 2: `SummaryPrompt` templates

**Files:**
- Create: `Sources/MurmurCore/SummaryPrompt.swift`
- Test: `Tests/MurmurCoreTests/SummaryPromptTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
@testable import MurmurCore

@Test func autoTemplateHasCoreSections() {
    let p = SummaryPrompt.build(template: .auto, transcript: "we decided to ship friday")
    #expect(p.system.contains("Overview"))
    #expect(p.system.contains("Action items"))
    #expect(p.system.contains("only what was said") || p.system.contains("Never invent"))
    #expect(p.user.contains("we decided to ship friday"))
}

@Test func templatesSpecialize() {
    #expect(SummaryPrompt.build(template: .meeting, transcript: "t").system.contains("Decisions"))
    #expect(SummaryPrompt.build(template: .lecture, transcript: "t").system.contains("takeaway"))
    #expect(SummaryPrompt.build(template: .memo, transcript: "t").system.contains("to-do"))
    #expect(SummaryPrompt.build(template: .interview, transcript: "t").system.contains("question"))
}

@Test func allTemplatesDemandMarkdownAndFidelity() {
    for template in SummaryTemplate.allCases {
        let system = SummaryPrompt.build(template: template, transcript: "t").system
        #expect(system.contains("Markdown") || system.contains("markdown"))
        #expect(system.contains("Never invent"))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SummaryPrompt` → compile error.

- [ ] **Step 3: Implement `Sources/MurmurCore/SummaryPrompt.swift`:**

```swift
import Foundation

/// Prompts for long-form transcript summarization. Same ethos as the
/// dictation cleanup contract: faithful to what was said, never generative.
public enum SummaryPrompt {

    public static func build(template: SummaryTemplate, transcript: String) -> PromptBuilder.Prompt {
        let base = """
        You summarize transcripts of recorded audio. The transcript below has \
        no speaker labels and imperfect punctuation — that is expected.

        Rules:
        - Report only what was said. Never invent facts, names, numbers, or commitments.
        - Omit any section that would be empty rather than padding it.
        - Write in clear, complete sentences. Output Markdown with `##` section headings.
        - Do not include preamble or commentary — output only the summary document.
        """

        let shape: String = switch template {
        case .auto: """
            Sections:
            ## Overview — 2–3 sentences on what this recording is about.
            ## Key points — the substantive points, as bullets.
            ## Decisions — decisions that were made, if any.
            ## Action items — tasks someone committed to, with the owner when stated.
            """
        case .meeting: """
            Sections:
            ## Overview — what meeting this was and what it covered, 2–3 sentences.
            ## Attendees — names mentioned as present, if identifiable.
            ## Discussion — the main threads, as bullets.
            ## Decisions — decisions that were made.
            ## Action items — tasks with owners and deadlines when stated.
            ## Next steps — agreed follow-ups or the next meeting, if mentioned.
            """
        case .lecture: """
            Sections:
            ## Topic — what this talk or lecture is about, 1–2 sentences.
            ## Main points — the argument or material, as structured bullets.
            ## Key takeaways — the 3–5 things worth remembering (takeaway per bullet).
            """
        case .memo: """
            This is a personal voice memo. Produce:
            ## Note — the memo's content as a cleaned-up narrative, keeping the speaker's intent and voice.
            ## To-dos — anything phrased as a task or reminder, as a to-do checklist.
            """
        case .interview: """
            Sections:
            ## Context — who appears to be talking and about what, 1–2 sentences.
            ## Questions & answers — each substantive question with a distilled answer.
            ## Highlights — the most notable statements or admissions.
            """
        }

        return PromptBuilder.Prompt(
            system: base + "\n\n" + shape,
            user: "Transcript:\n\n" + transcript)
    }
}
```

Note: `PromptBuilder.Prompt`'s memberwise init is internal — check `Sources/MurmurCore/PromptBuilder.swift`; if `Prompt(system:user:)` isn't accessible, add a `public init(system: String, user: String)` to it (it currently has only `public let` fields).

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): summary prompt templates"`

---

### Task 3: Settings fields (`summaryEngine`, `claudeModel`, `downloadsWatcherEnabled`)

**Files:**
- Modify: `Sources/MurmurCore/Models.swift` (Settings)
- Test: `Tests/MurmurCoreTests/ModelsTests.swift` (append)

- [ ] **Step 1: Write the failing tests** — append:

```swift
@Test func summarySettingsDefaultsAndMigration() throws {
    let fresh = Settings()
    #expect(fresh.summaryEngine == .ollama)
    #expect(fresh.claudeModel == "claude-opus-4-8")
    #expect(fresh.downloadsWatcherEnabled == false)

    // Settings written before these fields existed decode to the same defaults.
    let old = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(fresh))
    #expect(old.summaryEngine == .ollama)

    var s = Settings()
    s.summaryEngine = .claude
    s.claudeModel = "claude-sonnet-5"
    s.downloadsWatcherEnabled = true
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter summarySettings` → compile error.

- [ ] **Step 3: Implement** — in `Models.swift`, add above `Settings`:

```swift
public enum SummaryEngine: String, Codable, Sendable, Equatable {
    case ollama, claude
}
```

Add to `Settings`: properties `public var summaryEngine: SummaryEngine`, `public var claudeModel: String`, `public var downloadsWatcherEnabled: Bool`; memberwise-init params `summaryEngine: SummaryEngine = .ollama`, `claudeModel: String = "claude-opus-4-8"`, `downloadsWatcherEnabled: Bool = false` (assign all three); add `summaryEngine, claudeModel, downloadsWatcherEnabled` to `CodingKeys`; and in `init(from:)`:

```swift
summaryEngine = try c.decodeIfPresent(SummaryEngine.self, forKey: .summaryEngine) ?? .ollama
claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "claude-opus-4-8"
downloadsWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .downloadsWatcherEnabled) ?? false
```

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): summary engine settings"`

---

### Task 4: `AnthropicClient`

**Files:**
- Create: `Sources/MurmurCore/AnthropicClient.swift`
- Test: `Tests/MurmurCoreTests/AnthropicClientTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import MurmurCore

private final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let response: (Data, Int)
    init(response: (Data, Int)) { self.response = response }
    var requests: [URLRequest] { lock.withLock { _requests } }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { _requests.append(request) }
        return response
    }
}

private func okBody(text: String, stopReason: String = "end_turn") -> Data {
    let json: [String: Any] = [
        "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
        "stop_reason": stopReason,
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

@Test func requestShapeIsCorrect() async throws {
    let transport = CapturingTransport(response: (okBody(text: "Hi."), 200))
    let client = AnthropicClient(apiKey: "sk-test", model: "claude-opus-4-8", transport: transport)
    _ = try await client.complete(system: "sys", user: "usr")

    let request = transport.requests[0]
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "claude-opus-4-8")
    #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect(body["temperature"] == nil)   // sampling params 400 on Opus 4.8
    #expect(body["top_p"] == nil)
    #expect(body["system"] as? String == "sys")
}

@Test func extractsTextSkippingThinkingBlocks() async throws {
    let client = AnthropicClient(apiKey: "k", transport: CapturingTransport(response: (okBody(text: "Summary."), 200)))
    let out = try await client.complete(system: "s", user: "u")
    #expect(out == "Summary.")
}

@Test func mapsErrorStatuses() async {
    for (status, kind) in [(401, AnthropicError.Kind.invalidKey), (429, .rateLimited), (500, .http(500))] {
        let client = AnthropicClient(apiKey: "k", transport: CapturingTransport(response: (Data("{}".utf8), status)))
        await #expect(throws: AnthropicError.self) {
            _ = try await client.complete(system: "s", user: "u")
        }
        do { _ = try await client.complete(system: "s", user: "u") }
        catch let error as AnthropicError { #expect(error.kind == kind) }
        catch { Issue.record("wrong error type") }
    }
}

@Test func surfacesRefusalAndTruncation() async {
    let refused = AnthropicClient(apiKey: "k",
        transport: CapturingTransport(response: (okBody(text: "", stopReason: "refusal"), 200)))
    do { _ = try await refused.complete(system: "s", user: "u") }
    catch let error as AnthropicError { #expect(error.kind == .refused) }
    catch { Issue.record("wrong error type") }

    let truncated = AnthropicClient(apiKey: "k",
        transport: CapturingTransport(response: (okBody(text: "partial", stopReason: "max_tokens"), 200)))
    do { _ = try await truncated.complete(system: "s", user: "u") }
    catch let error as AnthropicError { #expect(error.kind == .truncated) }
    catch { Issue.record("wrong error type") }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter AnthropicClient` → compile error.

- [ ] **Step 3: Implement `Sources/MurmurCore/AnthropicClient.swift`:**

```swift
import Foundation

public struct AnthropicError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case invalidKey
        case rateLimited
        case refused
        case truncated
        case http(Int)
    }
    public let kind: Kind
    public let message: String
}

/// Minimal Messages API client for summarization (no Swift SDK exists).
/// Mirrors OllamaClient's injectable-transport shape. The caller supplies the
/// API key (the app reads it from the Keychain — MurmurCore never does).
public struct AnthropicClient: Sendable {
    public let apiKey: String
    public let model: String
    let transport: HTTPTransport

    public init(
        apiKey: String,
        model: String = "claude-opus-4-8",
        transport: HTTPTransport = URLSessionTransport(timeout: 300)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    /// Single-turn completion. Adaptive thinking; NO sampling parameters —
    /// temperature/top_p/top_k return 400 on Opus 4.8-class models.
    public func complete(system: String, user: String, maxTokens: Int = 8192) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "thinking": ["type": "adaptive"],
        ] as [String: Any])

        let (data, status) = try await transport.send(request)
        switch status {
        case 200:
            break
        case 401:
            throw AnthropicError(kind: .invalidKey, message: "Invalid Claude API key — check Settings.")
        case 429:
            throw AnthropicError(kind: .rateLimited, message: "Claude is rate-limiting requests — try again shortly.")
        default:
            throw AnthropicError(kind: .http(status), message: "Claude returned HTTP \(status).")
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" {
            throw AnthropicError(kind: .refused, message: "Claude declined to process this recording.")
        }
        let text = response.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if response.stop_reason == "max_tokens" {
            throw AnthropicError(kind: .truncated, message: "Summary was truncated — try a more focused template.")
        }
        guard !text.isEmpty else {
            throw AnthropicError(kind: .http(200), message: "Claude returned an empty response.")
        }
        return text
    }
}
```

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): AnthropicClient (raw Messages API, injectable transport)"`

---

### Task 5: `SummaryProvider` + Ollama/Claude implementations

**Files:**
- Create: `Sources/MurmurCore/SummaryProvider.swift`
- Test: `Tests/MurmurCoreTests/SummaryProviderTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import MurmurCore

private struct StubTransport: HTTPTransport {
    let body: Data
    func send(_ request: URLRequest) async throws -> (Data, Int) { (body, 200) }
}

@Test func ollamaProviderRoutesThroughChat() async throws {
    let chatBody = try JSONSerialization.data(withJSONObject: ["message": ["content": "## Overview\nhi"]])
    let provider = OllamaSummaryProvider(
        client: OllamaClient(baseURL: URL(string: "http://x")!, transport: StubTransport(body: chatBody)),
        model: "gemma4:e4b")
    let out = try await provider.summarize(transcript: "hello", template: .auto)
    #expect(out == "## Overview\nhi")
}

@Test func claudeProviderRoutesThroughComplete() async throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "content": [["type": "text", "text": "## Overview\nhi"]],
        "stop_reason": "end_turn",
    ])
    let provider = ClaudeSummaryProvider(
        client: AnthropicClient(apiKey: "k", transport: StubTransport(body: body)))
    let out = try await provider.summarize(transcript: "hello", template: .meeting)
    #expect(out == "## Overview\nhi")
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SummaryProvider` → compile error.

- [ ] **Step 3: Implement `Sources/MurmurCore/SummaryProvider.swift`:**

```swift
import Foundation

/// Turns a transcript into a markdown summary. Unlike CleanupProvider,
/// failures are thrown — the pipeline surfaces them per-stage with retry.
public protocol SummaryProvider: Sendable {
    func summarize(transcript: String, template: SummaryTemplate) async throws -> String
}

public struct OllamaSummaryProvider: SummaryProvider {
    let client: OllamaClient
    let model: String

    public init(client: OllamaClient, model: String) {
        self.client = client
        self.model = model
    }

    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.chat(model: model, system: prompt.system, user: prompt.user)
    }
}

public struct ClaudeSummaryProvider: SummaryProvider {
    let client: AnthropicClient

    public init(client: AnthropicClient) {
        self.client = client
    }

    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.complete(system: prompt.system, user: prompt.user)
    }
}
```

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): SummaryProvider protocol + Ollama/Claude engines"`

---

### Task 6: `KeychainStore` (app target)

**Files:**
- Create: `Sources/Murmur/KeychainStore.swift`

- [ ] **Step 1: Create the file** (no unit tests — Security.framework, verified live in Task 11):

```swift
import Foundation
import Security

/// Generic-password storage for the Claude API key. The key never touches
/// settings.json; MurmurCore receives it as a plain init parameter.
enum KeychainStore {
    private static let service = "com.raul.wisprrr.claude"
    private static let account = "api-key"

    static func readClaudeKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveClaudeKey(_ key: String) {
        deleteClaudeKey()
        guard !key.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func deleteClaudeKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Build** — `swift build` → compiles.
- [ ] **Step 3: Commit** — `git commit -am "feat: keychain storage for Claude API key"`

---

### Task 7: `FileTranscriber` + `RecordingPipeline`

**Files:**
- Create: `Sources/Murmur/FileTranscriber.swift`
- Create: `Sources/Murmur/RecordingPipeline.swift`

- [ ] **Step 1: Create `Sources/Murmur/FileTranscriber.swift`** (patterns mirror `AudioTranscriber` — asset checks, conversion, finalization; full finalization here, no 700 ms cap):

```swift
@preconcurrency import AVFAudio
import Foundation
import Speech

/// On-device transcription of an audio file via SpeechAnalyzer.
/// Accuracy over latency: full finalization, no cap.
@MainActor
final class FileTranscriber {

    enum FileTranscriberError: LocalizedError {
        case unreadable, localeUnsupported(String), noAudioFormat
        var errorDescription: String? {
            switch self {
            case .unreadable: "The audio file could not be read"
            case .localeUnsupported(let l): "Speech recognition does not support \(l)"
            case .noAudioFormat: "No compatible audio format for transcription"
            }
        }
    }

    func transcribe(
        fileURL: URL,
        locale: Locale,
        contextualStrings: [String],
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        guard let file = try? AVAudioFile(forReading: fileURL) else {
            throw FileTranscriberError.unreadable
        }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw FileTranscriberError.localeUnsupported(locale.identifier)
        }
        try await AudioTranscriber.ensureAssets(locale: supported)

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence, modules: [transcriber], analysisContext: context)

        // Collect finalized segments only — volatile results are superseded.
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: file.processingFormat),
              let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
            throw FileTranscriberError.noAudioFormat
        }

        let chunkFrames: AVAudioFrameCount = 8192
        let totalFrames = file.length
        var framesRead: Int64 = 0
        while file.framePosition < totalFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            framesRead += Int64(buffer.frameLength)
            if let converted = Self.convert(buffer: buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            onProgress(Double(framesRead) / Double(max(totalFrames, 1)))
        }
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same conversion shape as AudioTranscriber.convert (nonisolated, local captures only).
    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? out : nil
    }
}
```

- [ ] **Step 2: Create `Sources/Murmur/RecordingPipeline.swift`:**

```swift
import Foundation
import MurmurCore

/// Serial orchestrator: ready → transcribing → transcribed → summarizing →
/// done, with per-stage failure capture. Audio is never deleted by the
/// pipeline; a quit mid-stage is reset (not auto-restarted) on next launch.
@MainActor
final class RecordingPipeline {

    private let store: AppStore
    private let recordings: RecordingsStore
    private let transcriber = FileTranscriber()
    private var active = Set<UUID>()

    /// UI refresh hook + live progress (0…1) per recording while transcribing.
    var onChange: (() -> Void)?
    private(set) var progress: [UUID: Double] = [:]

    init(store: AppStore, recordings: RecordingsStore) {
        self.store = store
        self.recordings = recordings
        resetStuckStatuses()
    }

    /// Recordings stuck mid-stage from a previous run drop back to the last
    /// completed stage — visible with a Retry button, never auto-restarted.
    private func resetStuckStatuses() {
        for var rec in recordings.recordings {
            switch rec.status {
            case .transcribing:
                rec.status = .ready
                recordings.update(rec)
            case .summarizing:
                rec.status = .transcribed
                recordings.update(rec)
            default:
                break
            }
        }
    }

    func process(_ id: UUID) {
        guard !active.contains(id) else { return }
        active.insert(id)
        Task {
            await run(id)
            active.remove(id)
            progress[id] = nil
            onChange?()
        }
    }

    func resummarize(_ id: UUID, template: SummaryTemplate) {
        guard var rec = recordings.recordings.first(where: { $0.id == id }),
              recordings.transcript(for: id) != nil else { return }
        rec.template = template
        rec.status = .transcribed
        recordings.update(rec)
        process(id)
    }

    private func run(_ id: UUID) async {
        guard var rec = recordings.recordings.first(where: { $0.id == id }) else { return }

        // Stage 1: transcription (skipped when a transcript already exists).
        if recordings.transcript(for: id) == nil {
            rec.status = .transcribing
            recordings.update(rec); onChange?()
            do {
                let text = try await transcriber.transcribe(
                    fileURL: recordings.audioURL(for: rec),
                    locale: Locale(identifier: rec.language),
                    contextualStrings: store.dictionary.map(\.term),
                    onProgress: { [weak self] fraction in
                        self?.progress[id] = fraction
                        self?.onChange?()
                    })
                guard !text.isEmpty else {
                    throw FileTranscriber.FileTranscriberError.unreadable
                }
                recordings.saveTranscript(text, for: id)
                rec.status = .transcribed
                recordings.update(rec); onChange?()
            } catch {
                rec.status = .failed(stage: .transcription, message: error.localizedDescription)
                recordings.update(rec); onChange?()
                return
            }
        }

        // Stage 2: summarization.
        rec.status = .summarizing
        recordings.update(rec); onChange?()
        do {
            let (provider, tag) = try makeProvider()
            let transcript = recordings.transcript(for: id) ?? ""
            let summary = try await provider.summarize(transcript: transcript, template: rec.template)
            recordings.saveSummary(summary, for: id)
            rec.summaryEngine = tag
            rec.status = .done
        } catch let error as AnthropicError {
            rec.status = .failed(stage: .summarization, message: error.message)
        } catch {
            rec.status = .failed(stage: .summarization, message: error.localizedDescription)
        }
        recordings.update(rec); onChange?()
    }

    private func makeProvider() throws -> (SummaryProvider, String) {
        let settings = store.settings
        switch settings.summaryEngine {
        case .ollama:
            guard let url = URL(string: settings.ollamaURL) else {
                throw AnthropicError(kind: .http(0), message: "Invalid Ollama URL in Settings.")
            }
            return (OllamaSummaryProvider(client: OllamaClient(baseURL: url), model: settings.cleanupModel),
                    "ollama:\(settings.cleanupModel)")
        case .claude:
            guard let key = KeychainStore.readClaudeKey(), !key.isEmpty else {
                throw AnthropicError(kind: .invalidKey, message: "No Claude API key — add one in Settings → Summaries.")
            }
            return (ClaudeSummaryProvider(client: AnthropicClient(apiKey: key, model: settings.claudeModel)),
                    "claude:\(settings.claudeModel)")
        }
    }
}
```

- [ ] **Step 3: Build** — `swift build` → compiles. If SpeechAnalyzer API names differ (e.g. `finalizeAndFinishThroughEndOfInput`), match `AudioTranscriber.swift`'s working usage.
- [ ] **Step 4: Commit** — `git commit -am "feat: file transcriber (SpeechAnalyzer file mode) + recording pipeline"`

---

### Task 8: Recordings UI + section + Settings

**Files:**
- Create: `Sources/Murmur/RecordingsPage.swift`
- Modify: `Sources/Murmur/MainWindow.swift` (MainSection + sidebar + contentPane + MainModel)
- Modify: `Sources/Murmur/AppMain.swift` (construct store/pipeline/model)
- Modify: `Sources/Murmur/main.swift` (snapshot MainModel call site)
- Modify: `Sources/Murmur/SettingsPage.swift` (Summaries section)

- [ ] **Step 1: `RecordingsModel` + page — create `Sources/Murmur/RecordingsPage.swift`:**

```swift
import AppKit
@preconcurrency import AVFAudio
import SwiftUI
import UniformTypeIdentifiers
import MurmurCore

@MainActor @Observable
final class RecordingsModel {
    let recordingsStore: RecordingsStore
    let pipeline: RecordingPipeline
    let appStore: AppStore
    var recordings: [Recording] = []
    var selectedID: UUID?
    var progress: [UUID: Double] = [:]

    init(recordingsStore: RecordingsStore, pipeline: RecordingPipeline, appStore: AppStore) {
        self.recordingsStore = recordingsStore
        self.pipeline = pipeline
        self.appStore = appStore
        self.recordings = recordingsStore.recordings
        pipeline.onChange = { [weak self] in
            guard let self else { return }
            self.recordings = self.recordingsStore.recordings
            self.progress = self.pipeline.progress
        }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls where ["wav", "mp3", "m4a"].contains(url.pathExtension.lowercased()) {
            let duration = (try? AVAudioFile(forReading: url)).map {
                Double($0.length) / $0.processingFormat.sampleRate
            } ?? 0
            if let rec = try? recordingsStore.create(
                importingAudioFrom: url,
                source: .imported(originalFilename: url.lastPathComponent),
                title: url.deletingPathExtension().lastPathComponent,
                duration: duration,
                language: appStore.settings.defaultLanguage,
                template: .auto) {
                recordings = recordingsStore.recordings
                pipeline.process(rec.id)
            }
        }
    }

    func addInAppRecording(url: URL, duration: TimeInterval, micOnly: Bool) {
        guard var rec = try? recordingsStore.create(
            importingAudioFrom: url, source: .inApp,
            title: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
            duration: duration,
            language: appStore.settings.defaultLanguage, template: .auto) else { return }
        rec.micOnly = micOnly
        recordingsStore.update(rec)
        recordings = recordingsStore.recordings
        pipeline.process(rec.id)
    }

    func retry(_ id: UUID) { pipeline.process(id) }

    func delete(_ id: UUID) {
        recordingsStore.delete(id: id)
        recordings = recordingsStore.recordings
        if selectedID == id { selectedID = nil }
    }

    func rename(_ id: UUID, to title: String) {
        guard var rec = recordings.first(where: { $0.id == id }) else { return }
        rec.title = title
        recordingsStore.update(rec)
        recordings = recordingsStore.recordings
    }
}

struct RecordingsPage: View {
    @Bindable var model: RecordingsModel

    var body: some View {
        Page(title: "Recordings") {
            Button("Import…") { openImportPanel() }
                .buttonStyle(GhostButtonStyle())
        } content: {
            if model.recordings.isEmpty {
                emptyState
            } else {
                ForEach(model.recordings) { recording in
                    RecordingRow(model: model, recording: recording,
                                 expanded: model.selectedID == recording.id)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFiles([url]) } }
                }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No recordings yet")
                .font(Theme.serif(22))
                .foregroundStyle(Theme.ink)
            Text("Record a meeting with the ● button, drag audio files here, or export from the Plaud app (MP3/WAV) and import. Transcription runs on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(24)
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.importFiles(panel.urls)
        }
    }
}

private struct RecordingRow: View {
    @Bindable var model: RecordingsModel
    let recording: Recording
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.selectedID = expanded ? nil : recording.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel)\(recording.micOnly ? " · mic only" : "")")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    statusBadge
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                RecordingDetail(model: model, recording: recording)
                    .padding([.horizontal, .bottom], 14)
            }
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
        .card()
        .padding(.bottom, 8)
    }

    private var durationLabel: String {
        let total = Int(recording.duration)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder private var statusBadge: some View {
        switch recording.status {
        case .ready:
            Text("Ready").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView(value: model.progress[recording.id] ?? 0)
                    .frame(width: 60)
                Text("Transcribing").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        case .transcribed:
            Text("Transcribed").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
        case .summarizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(_, let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1).frame(maxWidth: 220)
                Button("Retry") { model.retry(recording.id) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

private struct RecordingDetail: View {
    @Bindable var model: RecordingsModel
    let recording: Recording
    @State private var player = PlayerModel()
    @State private var template: SummaryTemplate = .auto
    @State private var transcriptShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Editable title (spec: inline-editable)
            TextField("Title", text: Binding(
                get: { recording.title },
                set: { model.rename(recording.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)

            // Player
            HStack(spacing: 10) {
                Button {
                    player.toggle(url: model.recordingsStore.audioURL(for: recording))
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
                Slider(value: $player.position, in: 0...max(recording.duration, 1)) { editing in
                    if !editing { player.seek(to: player.position) }
                }
                Text(player.timeLabel(total: recording.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }

            // Summarize controls
            HStack(spacing: 10) {
                Picker("", selection: $template) {
                    ForEach(SummaryTemplate.allCases, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button(model.recordingsStore.summary(for: recording.id) == nil ? "Summarize" : "Re-summarize") {
                    model.pipeline.resummarize(recording.id, template: template)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(model.recordingsStore.transcript(for: recording.id) == nil)
                Spacer()
                if let summary = model.recordingsStore.summary(for: recording.id) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Export…") { exportSummary(summary) }
                        .buttonStyle(GhostButtonStyle())
                }
                Button(role: .destructive) { confirmDelete() } label: { Text("Delete") }
                    .buttonStyle(GhostButtonStyle())
            }

            if let summary = model.recordingsStore.summary(for: recording.id) {
                summaryView(summary)
            }

            if let transcript = model.recordingsStore.transcript(for: recording.id) {
                DisclosureGroup("Transcript", isExpanded: $transcriptShown) {
                    Text(transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            }
        }
        .onAppear { template = recording.template }
        .onDisappear { player.stop() }
    }

    private func summaryView(_ markdown: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        return Text(attributed)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func exportSummary(_ summary: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.title + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            let doc = "# \(recording.title)\n\n_\(recording.createdAt.formatted())_\n\n" + summary
            try? Data(doc.utf8).write(to: url)
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(recording.title)”?"
        alert.informativeText = "The audio, transcript, and summary will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.delete(recording.id)
        }
    }
}

/// Small AVAudioPlayer wrapper with scrubbing.
@MainActor @Observable
final class PlayerModel {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var position: TimeInterval = 0

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
        }
        player?.currentTime = position
        player?.play()
        isPlaying = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        position = time
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }

    func timeLabel(total: TimeInterval) -> String {
        func fmt(_ t: TimeInterval) -> String {
            String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
        }
        return "\(fmt(position)) / \(fmt(total))"
    }
}
```

- [ ] **Step 2: Section + wiring** — in `MainWindow.swift`: add `case recordings = "Recordings"` to `MainSection` (after `home`), icon `"waveform"`, add `.recordings` to the sidebar `ForEach` array after `.home`, and `case .recordings: RecordingsPage(model: model.recordingsModel)` in `contentPane`. `MainModel` gains `let recordingsModel: RecordingsModel` + init param (before `onBindingsChanged`). In `AppMain.applicationDidFinishLaunching`, construct after `store`:

```swift
recordingsStore = RecordingsStore()
recordingPipeline = RecordingPipeline(store: store, recordings: recordingsStore)
recordingsModel = RecordingsModel(recordingsStore: recordingsStore, pipeline: recordingPipeline, appStore: store)
```

(as `private var` properties on AppDelegate), pass `recordingsModel: recordingsModel` at the `MainModel(...)` call in `showMain`. In `main.swift` `--snapshot`, construct a temp-root store so snapshots don't touch real data:

```swift
let snapshotRecordings = RecordingsStore(rootDirectory:
    FileManager.default.temporaryDirectory.appendingPathComponent("murmur-snapshot-recordings"))
let model = MainModel(
    store: store,
    recordingsModel: RecordingsModel(
        recordingsStore: snapshotRecordings,
        pipeline: RecordingPipeline(store: store, recordings: snapshotRecordings),
        appStore: store),
    dictation: nil) {}
```

(adjust to the actual parameter order used in `MainModel.init`).

- [ ] **Step 3: Settings section** — in `SettingsPage.swift`, after the `section("Cleanup")` block add:

```swift
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
}
```

with `@State private var claudeKey = KeychainStore.readClaudeKey() ?? ""` on `SettingsPage`.

- [ ] **Step 4: Verify** — `swift build && swift test`; `bash Scripts/make_app.sh && open build/Murmur.app`; open Recordings (sidebar), import a small wav (make one: `say -o /tmp/fixture.aiff "hello from the fixture" && afconvert -f WAVE -d LEI16 /tmp/fixture.aiff /tmp/fixture.wav`), watch it transcribe + summarize via Ollama; screenshot list + detail.
- [ ] **Step 5: Commit** — `git commit -am "feat: Recordings section — import, pipeline UI, player, summaries settings"`

---

### Task 9: `SystemAudioTap` + `LongFormRecorder` + record controls

**Files:**
- Create: `Sources/Murmur/SystemAudioTap.swift`
- Create: `Sources/Murmur/LongFormRecorder.swift`
- Modify: `Sources/Murmur/RecordingsPage.swift` (record button + timer)
- Modify: `Sources/Murmur/StatusItemController.swift` (menu item)
- Modify: `Sources/Murmur/AppMain.swift` (wiring)
- Modify: `Scripts/make_app.sh` (NSAudioCaptureUsageDescription)

- [ ] **Step 1: Create `Sources/Murmur/SystemAudioTap.swift`:**

```swift
@preconcurrency import AVFAudio
import AudioToolbox
import Foundation

/// Captures system audio output via a CoreAudio process tap (macOS 14.2+).
/// First use prompts for the "System Audio Recording" permission
/// (NSAudioCaptureUsageDescription) — audio-only, not Screen Recording.
final class SystemAudioTap {

    enum TapError: Error { case create(OSStatus), format, aggregate(OSStatus), ioProc(OSStatus) }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func start(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.create(status) }   // permission denial lands here
        tapID = tap

        // Tap stream format
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw TapError.format
        }

        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur System Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError.aggregate(status) }

        // IOProc runs on the audio thread — only locals captured, writes only.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            try? file.write(from: buffer)
        }
        guard status == noErr, let procID = ioProcID else { stop(); throw TapError.ioProc(status) }
        AudioDeviceStart(aggregateID, procID)
    }

    func stop() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
```

- [ ] **Step 2: Create `Sources/Murmur/LongFormRecorder.swift`:**

```swift
@preconcurrency import AVFAudio
import AVFoundation
import Foundation
import MurmurCore

/// Long-form capture: mic via AVAudioEngine and system audio via
/// SystemAudioTap, written to two temp files and merged into one m4a on
/// stop. Degrades to mic-only when the tap is unavailable. Independent of
/// the dictation engines — Fn dictation works while this records.
@MainActor
final class LongFormRecorder {

    enum RecorderError: LocalizedError {
        case micUnavailable
        var errorDescription: String? { "Microphone is unavailable — check permissions." }
    }

    private let micEngine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private var micURL: URL?
    private var systemURL: URL?
    private(set) var startedAt: Date?
    private(set) var systemAudioActive = false
    var isRecording: Bool { startedAt != nil }
    var onStateChange: (() -> Void)?

    func start() throws {
        guard !isRecording else { return }
        let micFormat = micEngine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { throw RecorderError.micUnavailable }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-longform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.m4a")
        let sys = dir.appendingPathComponent("system.m4a")

        let micFile = try AVAudioFile(forWriting: mic, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: micFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        Self.installWriterTap(on: micEngine, file: micFile)
        micEngine.prepare()
        try micEngine.start()
        micURL = mic

        do {
            try tap.start(writingTo: sys)
            systemAudioActive = true
            systemURL = sys
        } catch {
            Diag.app.notice("system audio tap unavailable: \(String(describing: error), privacy: .public)")
            systemAudioActive = false
            systemURL = nil
        }

        startedAt = Date()
        onStateChange?()
    }

    /// The tap closure runs on the audio thread — formed nonisolated,
    /// captures only locals (same invariant as AudioTranscriber).
    private nonisolated static func installWriterTap(on engine: AVAudioEngine, file: AVAudioFile) {
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
    }

    /// Stops capture and returns the final audio (merged when both sources ran).
    func stop() async throws -> (url: URL, duration: TimeInterval, micOnly: Bool) {
        guard let started = startedAt, let mic = micURL else { throw RecorderError.micUnavailable }
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        tap.stop()
        let duration = Date().timeIntervalSince(started)
        startedAt = nil
        micURL = nil
        defer { onStateChange?() }

        if systemAudioActive, let sys = systemURL {
            let merged = mic.deletingLastPathComponent().appendingPathComponent("mixed.m4a")
            try await Self.merge(tracks: [mic, sys], to: merged)
            return (merged, duration, false)
        }
        return (mic, duration, true)
    }

    /// Multiple audio tracks in one composition mix down on M4A export.
    private static func merge(tracks: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for url in tracks {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let range = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
            try compositionTrack?.insertTimeRange(range, of: assetTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SystemAudioTap.TapError.format
        }
        try await export.export(to: output, as: .m4a)
    }
}
```

- [ ] **Step 3: Record controls** — in `RecordingsPage.swift`: `RecordingsModel` gains `let recorder = LongFormRecorder()` and:

```swift
var isRecording: Bool { recorder.isRecording }

func toggleRecording() {
    if recorder.isRecording {
        Task {
            if let result = try? await recorder.stop() {
                addInAppRecording(url: result.url, duration: result.duration, micOnly: result.micOnly)
            }
        }
    } else {
        try? recorder.start()
    }
}
```

(set `recorder.onStateChange = { [weak self] in self?.recordings = self?.recordingsStore.recordings ?? [] }` in init to poke observation). In `RecordingsPage`'s `trailing` toolbar, before Import:

```swift
Button {
    model.toggleRecording()
} label: {
    if model.isRecording {
        Label("Stop \(elapsed)", systemImage: "stop.circle.fill")
    } else {
        Label("Record", systemImage: "record.circle")
    }
}
.buttonStyle(PrimaryPillButtonStyle())
```

with an `elapsed` string computed from `model.recorder.startedAt` via `TimelineView(.periodic(from: .now, by: 1))` wrapping the toolbar button (or a 1 s `Timer.publish` + `@State`).

- [ ] **Step 4: Menu bar** — `StatusItemController` gains two stored closures (init params, wired from AppMain): `toggleLongRecording: () -> Void`, `longRecordingElapsed: () -> String?`. In `menuNeedsUpdate`, first items:

```swift
if let elapsed = longRecordingElapsed() {
    menu.addItem(withTitle: "Stop Recording (\(elapsed))",
                 action: #selector(toggleLongRec), keyEquivalent: "").target = self
} else {
    menu.addItem(withTitle: "Start Recording",
                 action: #selector(toggleLongRec), keyEquivalent: "").target = self
}
menu.addItem(.separator())
```

with `@objc private func toggleLongRec() { toggleLongRecording() }`. AppMain wires:

```swift
toggleLongRecording: { [weak self] in self?.recordingsModel.toggleRecording() },
longRecordingElapsed: { [weak self] in
    guard let started = self?.recordingsModel.recorder.startedAt else { return nil }
    let s = Int(Date().timeIntervalSince(started))
    return String(format: "%d:%02d", s / 60, s % 60)
}
```

- [ ] **Step 5: Info.plist** — in `Scripts/make_app.sh`, next to `NSMicrophoneUsageDescription` add:

```xml
    <key>NSAudioCaptureUsageDescription</key>
    <string>Murmur records system audio during long-form recordings so both sides of a call are captured.</string>
```

- [ ] **Step 6: Verify live** — `bash Scripts/make_app.sh && open build/Murmur.app` → Recordings → Record; play a `say "system audio test"` while recording; Stop → recording appears, transcribes, and the transcript contains "system audio test" (proves the tap; grant the System Audio Recording permission when prompted). Also verify mic-only degradation by denying the permission once.
- [ ] **Step 7: Commit** — `git commit -am "feat: long-form recorder — mic + system audio tap, merge, record controls"`

---

### Task 10: Downloads watcher + confirm-to-import notifications

**Files:**
- Create: `Sources/Murmur/DownloadsWatcher.swift`
- Modify: `Sources/Murmur/AppMain.swift` (delegate + wiring)

- [ ] **Step 1: Create `Sources/Murmur/DownloadsWatcher.swift`:**

```swift
import Foundation
import UserNotifications

/// Watches ~/Downloads for new audio files (AirDropped Plaud exports) and
/// offers a confirm-to-import notification. Never imports silently.
@MainActor
final class DownloadsWatcher {

    static let categoryID = "MURMUR_IMPORT"
    static let importAction = "MURMUR_IMPORT_ACTION"

    private let directory = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var known: Set<String> = []
    private let extensions: Set<String> = ["wav", "mp3", "m4a"]

    func start() {
        guard source == nil else { return }
        registerCategory()
        known = Set(currentAudioFiles())
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [descriptor = self.descriptor] in close(descriptor) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func currentAudioFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private func scan() {
        let files = currentAudioFiles()
        for name in files where !known.contains(name) {
            known.insert(name)
            let url = directory.appendingPathComponent(name)
            // Give AirDrop a moment to finish writing before offering.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.offerImport(url)
            }
        }
    }

    private func offerImport(_ url: URL) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Import into Murmur?"
            content.body = url.lastPathComponent
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(
                identifier: "import-\(url.lastPathComponent)", content: content, trigger: nil))
        }
    }

    private func registerCategory() {
        let action = UNNotificationAction(
            identifier: Self.importAction, title: "Import", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [action], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
```

- [ ] **Step 2: Wire in `AppMain.swift`** — `AppDelegate` conforms to `UNUserNotificationCenterDelegate`; in `applicationDidFinishLaunching` add:

```swift
UNUserNotificationCenter.current().delegate = self
downloadsWatcher = DownloadsWatcher()
if store.settings.downloadsWatcherEnabled { downloadsWatcher.start() }
```

(property `private var downloadsWatcher: DownloadsWatcher!`; `import UserNotifications` at top). Add the delegate method:

```swift
nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    let userInfo = response.notification.request.content.userInfo
    let action = response.actionIdentifier
    Task { @MainActor in
        if let path = userInfo["path"] as? String,
           action == DownloadsWatcher.importAction || action == UNNotificationDefaultActionIdentifier {
            self.recordingsModel.importFiles([URL(fileURLWithPath: path)])
            self.showMain(.recordings)
        }
        completionHandler()
    }
}
```

Toggling `downloadsWatcherEnabled` in Settings takes effect at next launch (documented in the toggle's row — add a footnote Text under it: "Applies at next launch."). `showMain(.recordings)` requires `MainSection.recordings` (Task 8).

- [ ] **Step 3: Verify** — enable the toggle, relaunch, copy an mp3 into ~/Downloads, notification appears, click Import → lands in Recordings and pipelines.
- [ ] **Step 4: Commit** — `git commit -am "feat: downloads watcher with confirm-to-import notifications"`

---

### Task 11: README/privacy copy + E2E sweep

**Files:**
- Modify: `README.md`, `CLAUDE.md`
- Verification (fix regressions found)

- [ ] **Step 1: README** — feature bullet under Why Murmur: `- 🎙️ **Recordings** — capture meetings (mic + system audio) or import Plaud exports; on-device transcription and local AI summaries (optional Claude API for higher quality)`. Amend the privacy line: "Everything runs on this Mac. Nothing leaves it — unless you enable Claude summaries, in which case transcripts (not audio) are sent to Anthropic." CLAUDE.md architecture section gains one line describing the Recordings pipeline + the new stores.
- [ ] **Step 2:** `swift test` all green; `swift build` clean.
- [ ] **Step 3:** Import fixture E2E (Task 8 fixture) → done state, summary sections present; screenshot list/detail/empty.
- [ ] **Step 4:** In-app recording E2E with `say` (Task 9 verification) if not already done.
- [ ] **Step 5:** Claude path: with a real key in Settings and engine=Claude, re-summarize the fixture → summary appears; with a bogus key → row shows "Invalid Claude API key" + Retry.
- [ ] **Step 6:** Quit mid-pipeline test: import a longer file, quit during transcription, relaunch → status back to Ready with Retry (no auto-start).
- [ ] **Step 7:** Commit + push — `git commit -am "docs: recordings feature + privacy carve-out" && git push origin main`.
