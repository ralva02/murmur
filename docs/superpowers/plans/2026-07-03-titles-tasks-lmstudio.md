# Titles, Task Extraction & LM Studio Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recording summaries also name the recording and extract reviewable to-dos into a new Tasks section; add LM Studio (OpenAI-compatible) as a local summary engine.

**Architecture:** MurmurCore gains the pure tested layer — `SummaryOutput` (parse title + strip task block), `TaskExtractor`, `TasksStore` + `Task`, `OpenAICompatibleClient` + `LMStudioSummaryProvider`, new Settings/Recording fields. The summary prompt emits a `TITLE:` line and a `<!--TASKS-->` block. The app target gains a Tasks section, a draft-then-confirm review sheet, and LM Studio settings fields. Spec: `docs/superpowers/specs/2026-07-03-titles-tasks-lmstudio-design.md`.

**Tech Stack:** Swift 6 / SPM, swift-testing, SwiftUI, OpenAI-compatible chat-completions HTTP (LM Studio `localhost:1234/v1`).

**Conventions:** `swift test` after every core task; commit per task. Stores use temp roots in tests + production-path trap. UI follows `Theme`.

---

### Task 1: `SummaryOutput` — parse title + strip task block; update prompt

**Files:**
- Modify: `Sources/MurmurCore/SummaryPrompt.swift`
- Create: `Sources/MurmurCore/SummaryOutput.swift`
- Test: `Tests/MurmurCoreTests/SummaryOutputTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
@testable import MurmurCore

@Test func parseSplitsTitleAndStripsTaskBlock() {
    let raw = """
    TITLE: Q3 Launch Sync
    ## Overview
    We shipped it.
    <!--TASKS
    - Prepare the deck | Priya
    - Send the contract | Unassigned
    -->
    """
    let out = SummaryOutput.parse(raw)
    #expect(out.title == "Q3 Launch Sync")
    #expect(out.body.contains("## Overview"))
    #expect(!out.body.contains("TITLE:"))
    #expect(!out.body.contains("TASKS"))
    #expect(!out.body.contains("Prepare the deck"))
}

@Test func parseToleratesMissingTitleAndTasks() {
    let out = SummaryOutput.parse("## Overview\nJust a summary.")
    #expect(out.title == nil)
    #expect(out.body == "## Overview\nJust a summary.")
}

@Test func promptRequestsTitleAndTasks() {
    let system = SummaryPrompt.build(template: .auto, transcript: "t").system
    #expect(system.contains("TITLE:"))
    #expect(system.contains("<!--TASKS"))
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter SummaryOutput` → compile error (`SummaryOutput` undefined).

- [ ] **Step 3: Create `Sources/MurmurCore/SummaryOutput.swift`:**

```swift
import Foundation

/// Splits a raw summary completion into its parts: the leading `TITLE:` line,
/// the visible markdown body, and (stripped out of the body) the machine
/// `<!--TASKS ... -->` block that TaskExtractor reads.
public enum SummaryOutput {

    public static func parse(_ raw: String) -> (title: String?, body: String) {
        var title: String?
        var lines = raw.components(separatedBy: "\n")

        // Title: the first non-empty line if it starts with TITLE:
        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let range = lines[firstIndex].range(of: "TITLE:", options: [.anchored, .caseInsensitive]) {
            title = String(lines[firstIndex][range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            lines.removeSubrange(...firstIndex)
        }

        var body = lines.joined(separator: "\n")
        // Strip the TASKS comment block (non-greedy, across newlines).
        if let start = body.range(of: "<!--TASKS"),
           let end = body.range(of: "-->", range: start.upperBound..<body.endIndex) {
            body.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return (title?.isEmpty == true ? nil : title,
                body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

- [ ] **Step 4: Update the prompt** — in `SummaryPrompt.swift`, change the `base` string's closing rules to require the title and task block. Replace the final rule line:

```swift
        - Do not include preamble or commentary — output only the summary document.

        Begin your output with a title line: `TITLE: ` followed by a concise
        name for this recording (6 words or fewer). Then the summary sections.
        After the summary, if there are any action items, append a machine block
        listing them, one per line as `- <task> | <assignee>` (use `Unassigned`
        when no owner is named):

        <!--TASKS
        - <task> | <assignee>
        -->

        Include the TASKS block only if there are action items; never invent tasks.
```

(Replace the existing single "Do not include preamble…" line with the block above.)

- [ ] **Step 5: Run full suite** — `swift test` → pass.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat(core): parse LLM title + task block from summary output"`

---

### Task 2: `TaskExtractor`

**Files:**
- Create: `Sources/MurmurCore/TaskExtractor.swift`
- Test: `Tests/MurmurCoreTests/TaskExtractorTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Testing
@testable import MurmurCore

@Test func extractsTasksWithAndWithoutAssignee() {
    let raw = """
    TITLE: x
    ## Overview
    body
    <!--TASKS
    - Prepare the deck | Priya
    - Send the contract | Unassigned
    - Book the room
    -->
    """
    let tasks = TaskExtractor.parse(raw)
    #expect(tasks.count == 3)
    #expect(tasks[0] == ExtractedTask(title: "Prepare the deck", assignee: "Priya"))
    #expect(tasks[1].assignee == "Unassigned")
    #expect(tasks[2] == ExtractedTask(title: "Book the room", assignee: "Unassigned"))
}

@Test func extractsNothingWhenNoBlock() {
    #expect(TaskExtractor.parse("## Overview\nno tasks here").isEmpty)
}

@Test func skipsBlankAndMalformedLines() {
    let raw = "<!--TASKS\n- \n-  | Bob\nReal task | Sue\n-->"
    let tasks = TaskExtractor.parse(raw)
    #expect(tasks == [ExtractedTask(title: "Real task", assignee: "Sue")])
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter TaskExtractor` → compile error.

- [ ] **Step 3: Create `Sources/MurmurCore/TaskExtractor.swift`:**

```swift
import Foundation

public struct ExtractedTask: Sendable, Equatable, Codable {
    public var title: String
    public var assignee: String
    public init(title: String, assignee: String) {
        self.title = title
        self.assignee = assignee
    }
}

/// Reads action items from the `<!--TASKS ... -->` block in a raw summary.
public enum TaskExtractor {
    public static func parse(_ raw: String) -> [ExtractedTask] {
        guard let start = raw.range(of: "<!--TASKS"),
              let end = raw.range(of: "-->", range: start.upperBound..<raw.endIndex) else {
            return []
        }
        let block = raw[start.upperBound..<end.lowerBound]
        return block.components(separatedBy: "\n").compactMap { line in
            var item = line.trimmingCharacters(in: .whitespaces)
            guard item.hasPrefix("-") else { return nil }
            item = String(item.dropFirst()).trimmingCharacters(in: .whitespaces)
            let title: String
            let assignee: String
            if let pipe = item.range(of: "|", options: .backwards) {
                title = String(item[..<pipe.lowerBound]).trimmingCharacters(in: .whitespaces)
                let a = String(item[pipe.upperBound...]).trimmingCharacters(in: .whitespaces)
                assignee = a.isEmpty ? "Unassigned" : a
            } else {
                title = item
                assignee = "Unassigned"
            }
            guard !title.isEmpty else { return nil }
            return ExtractedTask(title: title, assignee: assignee)
        }
    }
}
```

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): TaskExtractor for action items"`

---

### Task 3: `Recording` gains `titleIsCustom` + `pendingTasks`

**Files:**
- Modify: `Sources/MurmurCore/Recordings.swift` (Recording struct)
- Test: `Tests/MurmurCoreTests/RecordingsStoreTests.swift` (append)

- [ ] **Step 1: Write the failing test** — append:

```swift
@Test func recordingNewFieldsDefaultAndPersist() throws {
    let root = tempRoot()
    let store = RecordingsStore(rootDirectory: root)
    var rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .auto)
    #expect(rec.titleIsCustom == false)
    #expect(rec.pendingTasks.isEmpty)

    rec.titleIsCustom = true
    rec.pendingTasks = [ExtractedTask(title: "t", assignee: "Sue")]
    store.update(rec)
    let reloaded = RecordingsStore(rootDirectory: root)
    #expect(reloaded.recordings[0].titleIsCustom == true)
    #expect(reloaded.recordings[0].pendingTasks == [ExtractedTask(title: "t", assignee: "Sue")])

    // Legacy meta.json without the fields decodes to defaults.
    let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as! [String: Any]
    var stripped = legacy
    stripped.removeValue(forKey: "titleIsCustom")
    stripped.removeValue(forKey: "pendingTasks")
    let decoded = try JSONDecoder().decode(
        Recording.self, from: JSONSerialization.data(withJSONObject: stripped))
    #expect(decoded.titleIsCustom == false)
    #expect(decoded.pendingTasks.isEmpty)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter recordingNewFields` → compile error.

- [ ] **Step 3: Implement** — in `Recording`, add stored properties after `tag`:

```swift
    /// True once the user renames the recording — stops summarize from
    /// overwriting the title with the LLM-generated one.
    public var titleIsCustom: Bool
    /// Extracted-but-unreviewed action items (draft-then-confirm).
    public var pendingTasks: [ExtractedTask]
```

Add init params (with defaults) and assignments:

```swift
        tag: String? = nil,
        titleIsCustom: Bool = false,
        pendingTasks: [ExtractedTask] = []
    ) {
        ...
        self.tag = tag
        self.titleIsCustom = titleIsCustom
        self.pendingTasks = pendingTasks
    }
```

`Recording` uses the compiler-synthesized `Codable`; optional/defaulted
fields need custom decoding to tolerate their absence. Add an explicit
`init(from:)` that decodes existing fields normally and the two new ones
with `decodeIfPresent … ?? default`. To keep it small, add:

```swift
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration, source, audioFilename, language
        case template, summaryEngine, status, micOnly, tag, titleIsCustom, pendingTasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        source = try c.decode(Source.self, forKey: .source)
        audioFilename = try c.decode(String.self, forKey: .audioFilename)
        language = try c.decode(String.self, forKey: .language)
        template = try c.decode(SummaryTemplate.self, forKey: .template)
        summaryEngine = try c.decodeIfPresent(String.self, forKey: .summaryEngine)
        status = try c.decode(Status.self, forKey: .status)
        micOnly = try c.decodeIfPresent(Bool.self, forKey: .micOnly) ?? false
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        pendingTasks = try c.decodeIfPresent([ExtractedTask].self, forKey: .pendingTasks) ?? []
    }
```

(The memberwise `init(...)` stays; the synthesized encoder is fine.)

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): Recording titleIsCustom + pendingTasks fields"`

---

### Task 4: `Task` model + `TasksStore`

**Files:**
- Create: `Sources/MurmurCore/Tasks.swift`
- Test: `Tests/MurmurCoreTests/TasksStoreTests.swift`

- [ ] **Step 1: Write the failing tests:**

```swift
import Foundation
import Testing
@testable import MurmurCore

private func tempTasksRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("murmur-tasks-tests-\(UUID().uuidString)")
}

@Test func tasksAddPartitionToggleDelete() throws {
    let root = tempTasksRoot()
    let store = TasksStore(rootDirectory: root)
    let rid = UUID()
    store.add([
        MurmurTask(title: "A", assignee: "Sue", recordingID: rid, recordingTitle: "Rec"),
        MurmurTask(title: "B", assignee: "Bob", recordingID: rid, recordingTitle: "Rec"),
    ])
    #expect(store.open.count == 2)
    #expect(store.done.isEmpty)

    let a = store.tasks.first { $0.title == "A" }!
    store.toggleDone(id: a.id)
    #expect(store.open.count == 1)
    #expect(store.done.count == 1)

    // Persists.
    let reloaded = TasksStore(rootDirectory: root)
    #expect(reloaded.tasks.count == 2)
    #expect(reloaded.done.count == 1)

    store.delete(id: a.id)
    #expect(store.tasks.count == 1)
}

@Test func deleteTasksForRecording() throws {
    let store = TasksStore(rootDirectory: tempTasksRoot())
    let keep = UUID(); let drop = UUID()
    store.add([
        MurmurTask(title: "keep", assignee: "x", recordingID: keep, recordingTitle: "K"),
        MurmurTask(title: "drop", assignee: "x", recordingID: drop, recordingTitle: "D"),
    ])
    store.deleteTasks(forRecording: drop)
    #expect(store.tasks.map(\.title) == ["keep"])
}

@Test func productionPathTasksStoreTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        _ = TasksStore()
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter TasksStore` → compile error.

- [ ] **Step 3: Create `Sources/MurmurCore/Tasks.swift`:**

```swift
import Foundation

public struct MurmurTask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var assignee: String
    public var done: Bool
    public var recordingID: UUID
    public var recordingTitle: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), title: String, assignee: String, done: Bool = false,
        recordingID: UUID, recordingTitle: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.done = done
        self.recordingID = recordingID
        self.recordingTitle = recordingTitle
        self.createdAt = createdAt
    }
}

/// Flat global to-do list extracted from recordings. Single tasks.json under
/// Application Support/Murmur; same test-guard as the other stores.
public final class TasksStore: @unchecked Sendable {

    public static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/tasks.json")

    private let fileURL: URL
    public private(set) var tasks: [MurmurTask] = []

    public init(rootDirectory: URL? = nil) {
        let root = rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur")
        let isDefault = rootDirectory == nil
        precondition(
            !(AppStore.isRunningUnderTestHarness && isDefault),
            "TasksStore: refusing to touch the real tasks file from a test run — pass an explicit temp path")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("tasks.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([MurmurTask].self, from: data) {
            tasks = loaded
        }
    }

    public var open: [MurmurTask] { tasks.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt } }
    public var done: [MurmurTask] { tasks.filter { $0.done }.sorted { $0.createdAt > $1.createdAt } }

    public func add(_ newTasks: [MurmurTask]) {
        tasks.append(contentsOf: newTasks)
        save()
    }

    public func toggleDone(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        save()
    }

    public func delete(id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    public func deleteTasks(forRecording recordingID: UUID) {
        tasks.removeAll { $0.recordingID == recordingID }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

(Named `MurmurTask`, not `Task`, to avoid colliding with Swift concurrency's `Task`.)

- [ ] **Step 4: Run full suite** — `swift test` → pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): MurmurTask model + TasksStore"`

---

### Task 5: `OpenAICompatibleClient` + `LMStudioSummaryProvider` + settings + engine

**Files:**
- Create: `Sources/MurmurCore/OpenAICompatibleClient.swift`
- Modify: `Sources/MurmurCore/SummaryProvider.swift`
- Modify: `Sources/MurmurCore/Models.swift` (SummaryEngine + Settings)
- Test: `Tests/MurmurCoreTests/OpenAICompatibleClientTests.swift`
- Test: `Tests/MurmurCoreTests/ModelsTests.swift` (append)

- [ ] **Step 1: Write the failing tests** — new file:

```swift
import Foundation
import Testing
@testable import MurmurCore

private final class CapTransport: HTTPTransport, @unchecked Sendable {
    let response: (Data, Int)
    private let lock = NSLock()
    private var _reqs: [URLRequest] = []
    init(response: (Data, Int)) { self.response = response }
    var requests: [URLRequest] { lock.withLock { _reqs } }
    func send(_ r: URLRequest) async throws -> (Data, Int) { lock.withLock { _reqs.append(r) }; return response }
}

private func chatBody(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
}

@Test func openAIRequestShapeAndBearer() async throws {
    let t = CapTransport(response: (chatBody("hi"), 200))
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:1234/v1")!,
                                        model: "mlx-model", apiKey: "sk-x", transport: t)
    let out = try await client.chat(system: "s", user: "u")
    #expect(out == "hi")
    let req = t.requests[0]
    #expect(req.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
    let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "mlx-model")
    let msgs = body["messages"] as! [[String: String]]
    #expect(msgs[0]["role"] == "system")
}

@Test func openAINoBearerWhenNoKey() async throws {
    let t = CapTransport(response: (chatBody("hi"), 200))
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m", transport: t)
    _ = try await client.chat(system: "s", user: "u")
    #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func openAIThrowsOnNon200() async {
    let client = OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m",
                                        transport: CapTransport(response: (Data("{}".utf8), 500)))
    await #expect(throws: OllamaError.self) { _ = try await client.chat(system: "s", user: "u") }
}

@Test func lmStudioProviderRoutes() async throws {
    let provider = LMStudioSummaryProvider(
        client: OpenAICompatibleClient(baseURL: URL(string: "http://x/v1")!, model: "m",
                                       transport: CapTransport(response: (chatBody("## Overview\nx"), 200))))
    let out = try await provider.summarize(transcript: "t", template: .auto)
    #expect(out == "## Overview\nx")
}
```

Append to `ModelsTests.swift`:

```swift
@Test func lmStudioSettingsDefaultsAndRoundTrip() throws {
    let fresh = Settings()
    #expect(fresh.lmStudioURL == "http://localhost:1234/v1")
    #expect(fresh.lmStudioModel == "")
    var s = Settings()
    s.summaryEngine = .lmStudio
    s.lmStudioModel = "qwen-mlx"
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
    #expect(back.summaryEngine == .lmStudio)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter openAIRequestShape` → compile error.

- [ ] **Step 3: Create `Sources/MurmurCore/OpenAICompatibleClient.swift`:**

```swift
import Foundation

/// Chat-completions client for any OpenAI-compatible local server
/// (LM Studio, llama.cpp, vLLM, LiteLLM). Reuses OllamaError for parity.
public struct OpenAICompatibleClient: Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    let transport: HTTPTransport

    public init(
        baseURL: URL, model: String, apiKey: String? = nil,
        transport: HTTPTransport = URLSessionTransport(timeout: 300)
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        let choices: [Choice]
    }

    public func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "stream": false,
            "temperature": 0,
        ] as [String: Any])

        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw OllamaError(message: "LM Studio returned HTTP \(status)") }
        let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content ?? ""
        return OllamaClient.stripFences(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Add provider** — in `SummaryProvider.swift`, append:

```swift
public struct LMStudioSummaryProvider: SummaryProvider {
    let client: OpenAICompatibleClient
    public init(client: OpenAICompatibleClient) { self.client = client }
    public func summarize(transcript: String, template: SummaryTemplate) async throws -> String {
        let prompt = SummaryPrompt.build(template: template, transcript: transcript)
        return try await client.chat(system: prompt.system, user: prompt.user)
    }
}
```

- [ ] **Step 5: Settings** — in `Models.swift`, extend `SummaryEngine`:

```swift
public enum SummaryEngine: String, Codable, Sendable, Equatable {
    case ollama, lmStudio, claude
}
```

Add `Settings` fields `lmStudioURL`, `lmStudioModel` (properties + init params `lmStudioURL: String = "http://localhost:1234/v1"`, `lmStudioModel: String = ""` + assignments), add both to `CodingKeys`, and in `init(from:)`:

```swift
lmStudioURL = try c.decodeIfPresent(String.self, forKey: .lmStudioURL) ?? "http://localhost:1234/v1"
lmStudioModel = try c.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? ""
```

- [ ] **Step 6: Run full suite** — `swift test` → pass.
- [ ] **Step 7: Commit** — `git commit -am "feat(core): OpenAI-compatible client + LM Studio summary engine + settings"`

---

### Task 6: Pipeline applies title, populates pendingTasks, uses LM Studio; delete cleans tasks

**Files:**
- Modify: `Sources/Murmur/RecordingPipeline.swift`
- Modify: `Sources/Murmur/RecordingsPage.swift` (delete → task cleanup)
- Modify: `Sources/Murmur/AppMain.swift` (construct TasksStore, pass to model)

- [ ] **Step 1: Pipeline** — `RecordingPipeline` gains a `tasksStore` (unused directly here but the model needs it; keep pipeline focused). In `run(_:)` stage 2, change the summarize success path from saving the raw provider output to parsing it:

```swift
            let raw = try await provider.summarize(transcript: transcript, template: rec.template)
            let parsed = SummaryOutput.parse(raw)
            recordings.saveSummary(parsed.body, for: id)
            if let title = parsed.title, !rec.titleIsCustom {
                rec.title = title
            }
            rec.pendingTasks = TaskExtractor.parse(raw)
            rec.summaryEngine = tag
            rec.status = .done
```

(Replace the existing three lines that saved `summary` and set `summaryEngine`/`status`.)

- [ ] **Step 2: LM Studio case** — in `makeProvider()`, add before the `.claude` case:

```swift
        case .lmStudio:
            guard let url = URL(string: settings.lmStudioURL) else {
                throw AnthropicError(kind: .http(0), message: "Invalid LM Studio URL in Settings.")
            }
            let model = settings.lmStudioModel.isEmpty ? "local-model" : settings.lmStudioModel
            return (LMStudioSummaryProvider(client: OpenAICompatibleClient(
                        baseURL: url, model: model)),
                    "lmstudio:\(settings.lmStudioModel.isEmpty ? "loaded" : settings.lmStudioModel)")
```

- [ ] **Step 3: Delete cleanup** — in `RecordingsModel.delete(_:)` (RecordingsPage.swift), after `recordingsStore.delete(id: id)` add `tasksModel.tasksStore.deleteTasks(forRecording: id)` — but to avoid a cross-model reference, give `RecordingsModel` a `let tasksStore: TasksStore` init param and call `tasksStore.deleteTasks(forRecording: id)` directly. Update `RecordingsModel.init` signature and the AppMain construction accordingly.

- [ ] **Step 4: AppMain** — add `private var tasksStore: TasksStore!`, construct `tasksStore = TasksStore()` next to `recordingsStore`, pass `tasksStore: tasksStore` into `RecordingsModel(...)`.

- [ ] **Step 5: Build** — `swift build` → compiles. `swift test` → pass.
- [ ] **Step 6: Commit** — `git commit -am "feat: pipeline applies LLM title, extracts pending tasks, supports LM Studio"`

---

### Task 7: Review sheet + Tasks section + LM Studio settings UI

**Files:**
- Create: `Sources/Murmur/TasksPage.swift`
- Modify: `Sources/Murmur/RecordingsPage.swift` (review affordance + sheet)
- Modify: `Sources/Murmur/MainWindow.swift` (MainSection.tasks + TasksModel on MainModel)
- Modify: `Sources/Murmur/AppMain.swift` (TasksModel), `Sources/Murmur/main.swift` (snapshot)
- Modify: `Sources/Murmur/SettingsPage.swift` (LM Studio fields)

- [ ] **Step 1: TasksModel + page** — create `Sources/Murmur/TasksPage.swift`:

```swift
import SwiftUI
import MurmurCore

@MainActor @Observable
final class TasksModel {
    let store: TasksStore
    var tasks: [MurmurTask] = []
    /// Set by RecordingsModel to jump to a recording when a task is tapped.
    var onOpenRecording: (UUID) -> Void = { _ in }

    init(store: TasksStore) {
        self.store = store
        tasks = store.tasks
    }

    func refresh() { tasks = store.tasks }
    func toggle(_ id: UUID) { store.toggleDone(id: id); refresh() }
    func delete(_ id: UUID) { store.delete(id: id); refresh() }
    var open: [MurmurTask] { store.open }
    var done: [MurmurTask] { store.done }
}

struct TasksPage: View {
    @Bindable var model: TasksModel

    var body: some View {
        Page(title: "Tasks") {
            EmptyView()
        } content: {
            if model.tasks.isEmpty {
                Text("Action items from your recordings show up here after you review them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(24)
            } else {
                if !model.open.isEmpty {
                    sectionLabel("Open", model.open.count)
                    ForEach(model.open) { row($0) }
                }
                if !model.done.isEmpty {
                    sectionLabel("Done", model.done.count)
                    ForEach(model.done) { row($0) }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private func sectionLabel(_ title: String, _ count: Int) -> some View {
        Text("\(title.uppercased())  \(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
            .kerning(0.8)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ task: MurmurTask) -> some View {
        HStack(spacing: 10) {
            Button { model.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? .green : Theme.inkTertiary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(task.done ? Theme.inkTertiary : Theme.ink)
                    .strikethrough(task.done)
                Button {
                    model.onOpenRecording(task.recordingID)
                } label: {
                    Text(task.recordingTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if task.assignee != "Unassigned" {
                Text(task.assignee)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.sidebarSelection, in: Capsule())
            }
            Button { model.delete(task.id) } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .card()
        .padding(.bottom, 6)
    }
}

/// Draft-then-confirm sheet: edit title/assignee, keep/drop, then commit.
struct TaskReviewSheet: View {
    let recording: Recording
    let tasksStore: TasksStore
    let recordingsStore: RecordingsStore
    let onClose: () -> Void

    @State private var drafts: [Draft]

    struct Draft: Identifiable {
        let id = UUID()
        var title: String
        var assignee: String
        var keep: Bool
    }

    init(recording: Recording, tasksStore: TasksStore, recordingsStore: RecordingsStore, onClose: @escaping () -> Void) {
        self.recording = recording
        self.tasksStore = tasksStore
        self.recordingsStore = recordingsStore
        self.onClose = onClose
        _drafts = State(initialValue: recording.pendingTasks.map {
            Draft(title: $0.title, assignee: $0.assignee, keep: true)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review tasks")
                .font(Theme.serif(20))
                .foregroundStyle(Theme.ink)
            Text("The LLM guessed the owners — fix any that are wrong before adding.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($drafts) { $draft in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $draft.keep).labelsHidden().controlSize(.small)
                            TextField("Task", text: $draft.title)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("Assignee", text: $draft.assignee)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .frame(width: 120)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.canvas, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                        }
                        .opacity(draft.keep ? 1 : 0.45)
                        .padding(10)
                        .card()
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Button("Dismiss") { clearPending(); onClose() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Add to Tasks") { commit(); onClose() }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.card)
    }

    private func commit() {
        let kept = drafts.filter { $0.keep && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let tasks = kept.map {
            MurmurTask(title: $0.title, assignee: $0.assignee.isEmpty ? "Unassigned" : $0.assignee,
                       recordingID: recording.id, recordingTitle: recording.title)
        }
        tasksStore.add(tasks)
        clearPending()
    }

    private func clearPending() {
        var rec = recording
        rec.pendingTasks = []
        recordingsStore.update(rec)
    }
}
```

- [ ] **Step 2: Review affordance** — in `RecordingsPage.swift` `RecordingDetail`, add a `@State private var reviewing = false` and, when `recording.pendingTasks` is non-empty, a button above the summary:

```swift
            if !recording.pendingTasks.isEmpty {
                Button {
                    reviewing = true
                } label: {
                    Label("\(recording.pendingTasks.count) tasks to review", systemImage: "checklist")
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
```

and a sheet on the detail `VStack`:

```swift
        .sheet(isPresented: $reviewing) {
            TaskReviewSheet(recording: recording, tasksStore: model.tasksStore,
                            recordingsStore: model.recordingsStore) {
                reviewing = false
                model.recordings = model.recordingsStore.recordings
                model.tasksModel?.refresh()
            }
        }
```

`RecordingsModel` gains `let tasksStore: TasksStore` (from Task 6) and `weak var tasksModel: TasksModel?` (set by AppMain so the review sheet can refresh the Tasks list).

- [ ] **Step 3: Section wiring** — `MainWindow.swift`: add `case tasks = "Tasks"` after `.recordings`, icon `"checklist"`, into the sidebar `ForEach` array after `.recordings`, `case .tasks: TasksPage(model: model.tasksModel)` in `contentPane`, and `let tasksModel: TasksModel` on `MainModel` + init param. In AppMain construct `tasksModel = TasksModel(store: tasksStore)`, wire `recordingsModel.tasksModel = tasksModel` and `tasksModel.onOpenRecording = { [weak self] id in self?.recordingsModel.selectedID = id; self?.showMain(.recordings) }`, and pass `tasksModel:` into `MainModel(...)`. In `main.swift` snapshot, construct a temp-root `TasksStore` + `TasksModel` and pass it.

- [ ] **Step 4: LM Studio settings** — in `SettingsPage.swift` `section("Summaries")`, add `Text("LM Studio").tag(SummaryEngine.lmStudio)` to the engine picker, and after the Claude branch add:

```swift
            if model.settings.summaryEngine == .lmStudio {
                labeledRow("Base URL") {
                    TextField("http://localhost:1234/v1", text: $model.settings.lmStudioURL)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 220)
                }
                labeledRow("Model (optional)") {
                    TextField("loaded model", text: $model.settings.lmStudioModel)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 220)
                }
            }
```

- [ ] **Step 5: Build + verify** — `swift build && swift test`; `bash Scripts/make_app.sh && open build/Murmur.app`. Import the Task-8 fixture (or reuse an existing recording), confirm a generated title replaces the default, click "N tasks to review", edit an assignee, Add to Tasks → open the Tasks section → the tasks appear under Open; check one → moves to Done; click a task's recording link → jumps to Recordings. Screenshot the review sheet and Tasks section.
- [ ] **Step 6: Commit** — `git commit -am "feat: Tasks section, draft-then-confirm review sheet, LM Studio settings"`

---

### Task 8: E2E + docs

**Files:** `README.md`, `CLAUDE.md`; verification.

- [ ] **Step 1:** `swift test` all green; `swift build` clean.
- [ ] **Step 2:** Fixture recording E2E: `say -o /tmp/f.aiff "Let's ship Friday. Priya will prepare the deck and someone needs to book the room." && afconvert -f WAVE -d LEI16 /tmp/f.aiff /tmp/f.wav`; import, confirm generated title + review sheet lists "Prepare the deck | Priya" and "Book the room | Unassigned".
- [ ] **Step 3:** LM Studio path (if a server is running): Settings → engine LM Studio → re-summarize → summary appears; if not running, row shows the connection error + Retry.
- [ ] **Step 4:** README bullet: `- ✅ **Tasks** — action items are extracted from recordings, you confirm the owners, and they land in a built-in to-do list`; note LM Studio as a summary-engine option. CLAUDE.md: one line on the title/task extraction + LM Studio engine.
- [ ] **Step 5:** Commit + push — `git commit -am "docs: titles, tasks, LM Studio" && git push origin main`.
