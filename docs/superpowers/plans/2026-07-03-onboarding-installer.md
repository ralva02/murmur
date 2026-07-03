# Onboarding, Installer & Apple Intelligence Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fresh download of Murmur works out of the box: guided onboarding for permissions, Apple Intelligence as the zero-setup cleanup engine (Ollama as opt-in upgrade with in-app model pull), a Wispr-style always-visible pill, and a release zip script.

**Architecture:** MurmurCore gains pure, tested logic (settings migration, shared sanity guard, pull-progress streaming). The app target gains a Foundation Models cleanup provider, an onboarding wizard hosted by MainWindow, and a rebuilt pill state machine. Spec: `docs/superpowers/specs/2026-07-03-onboarding-installer-design.md`.

**Tech Stack:** Swift 6 / SPM, swift-testing (`@Test`/`#expect`), SwiftUI + AppKit (NSPanel), FoundationModels (macOS 26), Ollama HTTP API.

**Conventions:** Run tests with `swift test`. Commit after every green task. All UI follows `Theme` (light-only; window pinned to aqua). Never touch `~/Library/Application Support/Murmur` from tests — temp roots only.

---

### Task 1: Settings fields `cleanupEngine` + `onboardingCompleted` with migration

Old settings files (key absent) must decode to `.ollama` / `true`; fresh installs default to `.appleIntelligence` / `false`.

**Files:**
- Modify: `Sources/MurmurCore/Models.swift` (Settings, ~line 64)
- Test: `Tests/MurmurCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing tests** — append to `Tests/MurmurCoreTests/ModelsTests.swift`:

```swift
@Test func freshSettingsDefaultToAppleIntelligenceAndOnboardingPending() {
    let s = Settings()
    #expect(s.cleanupEngine == .appleIntelligence)
    #expect(s.onboardingCompleted == false)
}

@Test func legacySettingsFileKeepsOllamaAndSkipsOnboarding() throws {
    // A settings.json written before these fields existed.
    let json = """
    {"contextAwareness":true,"autoAddDictionary":false,"defaultLanguage":"en-US",
     "cleanupEnabled":true,"cleanupModel":"gemma4:e4b","ollamaURL":"http://127.0.0.1:11434",
     "pressEnterEnabled":true,"historyEnabled":true,"bindings":[]}
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.cleanupEngine == .ollama)
    #expect(s.onboardingCompleted == true)
}

@Test func cleanupEngineAndOnboardingRoundTrip() throws {
    var s = Settings()
    s.cleanupEngine = .ollama
    s.onboardingCompleted = true
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter freshSettingsDefaultToAppleIntelligence`
Expected: compile error — `cleanupEngine` not a member of `Settings`.

- [ ] **Step 3: Implement** — in `Sources/MurmurCore/Models.swift`, add above `Settings`:

```swift
public enum CleanupEngine: String, Codable, Sendable, Equatable {
    case appleIntelligence, ollama
}
```

Add to `Settings` (properties + init params with defaults):

```swift
/// Which LLM polishes transcripts. Fresh installs use the zero-setup Apple
/// on-device model; files saved before this field existed decode to .ollama
/// so existing installs keep their behavior.
public var cleanupEngine: CleanupEngine
public var onboardingCompleted: Bool
```

In the memberwise `init`, add parameters `cleanupEngine: CleanupEngine = .appleIntelligence` and `onboardingCompleted: Bool = false` and assign them.

Add explicit `CodingKeys` and this decoder **inside the `Settings` struct** (all existing properties plus the two new) — the two new keys default differently from the memberwise init, which is the whole migration:

```swift
enum CodingKeys: String, CodingKey {
    case contextAwareness, autoAddDictionary, defaultLanguage, outputLanguage
    case cleanupEnabled, cleanupModel, ollamaURL, pressEnterEnabled
    case historyEnabled, bindings, cleanupEngine, onboardingCompleted
}

public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    contextAwareness = try c.decode(Bool.self, forKey: .contextAwareness)
    autoAddDictionary = try c.decode(Bool.self, forKey: .autoAddDictionary)
    defaultLanguage = try c.decode(String.self, forKey: .defaultLanguage)
    outputLanguage = try c.decodeIfPresent(String.self, forKey: .outputLanguage)
    cleanupEnabled = try c.decode(Bool.self, forKey: .cleanupEnabled)
    cleanupModel = try c.decode(String.self, forKey: .cleanupModel)
    ollamaURL = try c.decode(String.self, forKey: .ollamaURL)
    pressEnterEnabled = try c.decode(Bool.self, forKey: .pressEnterEnabled)
    historyEnabled = try c.decode(Bool.self, forKey: .historyEnabled)
    bindings = try c.decode([HotkeyBinding].self, forKey: .bindings)
    // Pre-existing installs (key absent) keep Ollama and never see the wizard.
    cleanupEngine = try c.decodeIfPresent(CleanupEngine.self, forKey: .cleanupEngine) ?? .ollama
    onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
}
```

- [ ] **Step 4: Run full suite** — `swift test` → all pass (existing `settingsPersistAndReload` keeps passing because encoding writes both keys).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(core): cleanupEngine + onboardingCompleted settings with legacy-file migration"`

---

### Task 2: Shared output-sanity guard `CleanupSanity`

**Files:**
- Modify: `Sources/MurmurCore/CleanupProvider.swift:71-78`
- Test: `Tests/MurmurCoreTests/DictationPipelineTests.swift` (append)

- [ ] **Step 1: Write the failing test** — append:

```swift
@Test func cleanupSanityRejectsEmptyAndRunawayOutput() {
    #expect(!CleanupSanity.isSane(output: "", input: "hello there"))
    #expect(CleanupSanity.isSane(output: "Hello there.", input: "hello there"))
    let runaway = Array(repeating: "word", count: 200).joined(separator: " ")
    #expect(!CleanupSanity.isSane(output: runaway, input: "short input"))
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter cleanupSanityRejects` → compile error, `CleanupSanity` undefined.

- [ ] **Step 3: Implement** — in `CleanupProvider.swift`, replace the `static func isSane` on `OllamaCleanupProvider` with a shared public enum (placed above `OllamaCleanupProvider`):

```swift
/// The cleanup contract is minimal-edit smoothing (spec §3.2). Empty output
/// or output far longer than the input means the model went off-script.
/// Shared by every LLM-backed provider.
public enum CleanupSanity {
    public static func isSane(output: String, input: String) -> Bool {
        guard !output.isEmpty else { return false }
        let inputWords = input.split(whereSeparator: \.isWhitespace).count
        let outputWords = output.split(whereSeparator: \.isWhitespace).count
        return outputWords <= max(inputWords * 3, inputWords + 20)
    }
}
```

In `OllamaCleanupProvider.cleanup`, change `Self.isSane(...)` → `CleanupSanity.isSane(...)` and delete the old static func. Run `grep -rn "isSane" Sources Tests` and update any other references the same way.

- [ ] **Step 4: Run full suite** — `swift test` → pass.

- [ ] **Step 5: Commit** — `git commit -am "refactor(core): extract shared CleanupSanity guard"`

---

### Task 3: Ollama model pull with streamed progress

**Files:**
- Modify: `Sources/MurmurCore/OllamaClient.swift`
- Test: `Tests/MurmurCoreTests/OllamaClientTests.swift` (append)

- [ ] **Step 1: Write the failing tests** — append:

```swift
private struct FakeLineTransport: LineStreamingTransport {
    let linesToSend: [String]
    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            for line in linesToSend { c.yield(line) }
            c.finish()
        }
    }
}

@Test func pullParsesProgressAndCompletes() async throws {
    let transport = FakeLineTransport(linesToSend: [
        #"{"status":"pulling manifest"}"#,
        #"{"status":"pulling abc123","digest":"abc123","total":100,"completed":25}"#,
        #"{"status":"pulling abc123","digest":"abc123","total":100,"completed":100}"#,
        #"{"status":"success"}"#,
    ])
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)
    let box = EventBox()
    try await client.pull(model: "gemma4:e4b", transport: transport) { event in
        box.append(event)   // synchronous — no race with the assertions below
    }
    let events = box.events
    #expect(events.first?.status == "pulling manifest")
    #expect(events.contains { $0.fraction == 0.25 })
    #expect(events.last?.isSuccess == true)
}

@Test func pullThrowsOnOllamaError() async {
    let transport = FakeLineTransport(linesToSend: [#"{"error":"no such model"}"#])
    let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)
    await #expect(throws: OllamaError.self) {
        try await client.pull(model: "nope", transport: transport) { _ in }
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PullEvent] = []
    var events: [PullEvent] { lock.withLock { storage } }
    func append(_ e: PullEvent) { lock.withLock { storage.append(e) } }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter pullParses` → compile error.

- [ ] **Step 3: Implement** — append to `OllamaClient.swift`:

```swift
// MARK: - Model pull (NDJSON progress stream)

public protocol LineStreamingTransport: Sendable {
    func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error>
}

public struct URLSessionLineTransport: LineStreamingTransport {
    public init() {}
    public func lines(_ request: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw OllamaError(message: "Ollama returned HTTP \(status)") }
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct PullEvent: Sendable, Equatable, Decodable {
    public let status: String?
    public let completed: Int64?
    public let total: Int64?
    public let error: String?

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
    public var isSuccess: Bool { status == "success" }
}

extension OllamaClient {
    static func parsePullLine(_ line: String) -> PullEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try? JSONDecoder().decode(PullEvent.self, from: Data(trimmed.utf8))
    }

    /// Downloads a model, reporting each progress event. Throws on transport
    /// failure or an Ollama-reported error. Cancellable via task cancellation.
    public func pull(
        model: String,
        transport: LineStreamingTransport = URLSessionLineTransport(),
        onEvent: @escaping @Sendable (PullEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        for try await line in transport.lines(request) {
            try Task.checkCancellation()
            guard let event = Self.parsePullLine(line) else { continue }
            if let message = event.error { throw OllamaError(message: message) }
            onEvent(event)
        }
    }
}
```

Note: `PullEvent.status` is optional because error lines have no status; `isSuccess` compares against the optional. The test's `events.first?.status == "pulling manifest"` compares `String?` — fine.

- [ ] **Step 4: Run full suite** — `swift test` → pass.

- [ ] **Step 5: Commit** — `git commit -am "feat(core): ollama model pull with streamed NDJSON progress"`

---

### Task 4: `AppleIntelligenceCleanupProvider` (app target)

No unit tests possible (Foundation Models has no seam) — verified by build + Task 13 E2E. Keep it thin: all prompt/sanity logic already tested in MurmurCore.

**Files:**
- Create: `Sources/Murmur/AppleIntelligence.swift`

- [ ] **Step 1: Create the file:**

```swift
import Foundation
import FoundationModels
import MurmurCore

/// Live availability of Apple's on-device model, mapped for UI copy.
enum AppleIntelligenceStatus: Equatable {
    case ready, notEnabled, modelDownloading, unsupported

    static func current() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .modelDownloading
        case .unavailable(.deviceNotEligible): .unsupported
        case .unavailable: .unsupported
        }
    }

    var explanation: String {
        switch self {
        case .ready: "Apple Intelligence is ready — cleanup works out of the box."
        case .notEnabled: "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri."
        case .modelDownloading: "Apple's model is still downloading. Cleanup starts working automatically when it finishes."
        case .unsupported: "This Mac can't run Apple Intelligence. Use Ollama below for polished transcripts."
        }
    }
}

/// Cleanup via the on-device Foundation Models framework. Same contract as
/// the Ollama provider: minimal-edit prompt from PromptBuilder, CleanupSanity
/// guard, raw-transcript fallback on any error (spec §15).
struct AppleIntelligenceCleanupProvider: CleanupProvider {
    let translateTo: String?

    func cleanup(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) async -> CleanupResult {
        let prompt = PromptBuilder.cleanupPrompt(
            rawTranscript: rawTranscript, context: context,
            dictionary: dictionary, style: style, translateTo: translateTo)
        do {
            let session = LanguageModelSession(instructions: prompt.system)
            let response = try await session.respond(
                to: prompt.user,
                options: GenerationOptions(sampling: .greedy))
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CleanupSanity.isSane(output: output, input: rawTranscript) else {
                return CleanupResult(text: rawTranscript, usedFallback: true)
            }
            return CleanupResult(text: output, usedFallback: false)
        } catch {
            Diag.pipeline.error("Apple Intelligence cleanup failed: \(error.localizedDescription, privacy: .public)")
            return CleanupResult(text: rawTranscript, usedFallback: true)
        }
    }

    /// Loads model resources while the user is still speaking (mirrors the
    /// Ollama prewarm path).
    static func prewarm(
        context: ContextPayload, dictionary: [DictionaryEntry],
        style: Style?, translateTo: String?
    ) {
        let prompt = PromptBuilder.cleanupPrompt(
            rawTranscript: "", context: context,
            dictionary: dictionary, style: style, translateTo: translateTo)
        let session = LanguageModelSession(instructions: prompt.system)
        session.prewarm()
    }
}
```

If `Diag.pipeline` doesn't exist (check `Sources/Murmur/Diagnostics.swift`), use the closest existing category (e.g. `Diag.dictation`) instead — do not invent a new one.

- [ ] **Step 2: Build** — `swift build` → compiles. If `GenerationOptions(sampling: .greedy)` doesn't exist in this SDK seed, use `GenerationOptions(temperature: 0)`; if `respond(to:options:)` mismatches, check with `swift build 2>&1 | head` and adapt to the SDK's actual signature — the shape (session → respond → `.content: String`) is the WWDC25 API.

- [ ] **Step 3: Commit** — `git commit -am "feat: Apple Intelligence cleanup provider"`

---

### Task 5: Engine selection in pipeline, CLI, and Settings UI

**Files:**
- Modify: `Sources/Murmur/DictationController.swift:54-81` (`makePipeline`)
- Modify: `Sources/Murmur/main.swift:9-37` (`--process-text`)
- Modify: `Sources/Murmur/SettingsPage.swift:76-90` (Cleanup section)

- [ ] **Step 1: `makePipeline`** — replace the body of the `if settings.cleanupEnabled` block:

```swift
if settings.cleanupEnabled {
    switch settings.cleanupEngine {
    case .appleIntelligence:
        if AppleIntelligenceStatus.current() == .ready {
            cleanup = AppleIntelligenceCleanupProvider(translateTo: settings.outputLanguage)
            if let context {
                AppleIntelligenceCleanupProvider.prewarm(
                    context: context, dictionary: store.dictionary,
                    style: store.style(for: context.appCategory),
                    translateTo: settings.outputLanguage)
            }
        }
    case .ollama:
        if let url = URL(string: settings.ollamaURL) {
            let client = OllamaClient(baseURL: url)
            if await client.isAlive() {
                cleanup = OllamaCleanupProvider(
                    client: client, model: settings.cleanupModel,
                    translateTo: settings.outputLanguage)
                if let context {
                    let prompt = PromptBuilder.cleanupPrompt(
                        rawTranscript: "", context: context,
                        dictionary: store.dictionary,
                        style: store.style(for: context.appCategory),
                        translateTo: settings.outputLanguage)
                    let model = settings.cleanupModel
                    Task.detached { await client.prewarm(model: model, system: prompt.system) }
                }
            }
        }
    }
}
```

- [ ] **Step 2: `--process-text`** — in `main.swift`, replace the provider construction (lines 12-21) with the same switch (no prewarm; print which engine ran):

```swift
let store = AppStore()
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
```

(Keep the surrounding `exitCode` closure structure; drop the old `alive` variable.)

- [ ] **Step 3: Settings UI** — in `SettingsPage.swift`, replace the `section("Cleanup")` block:

```swift
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
```

- [ ] **Step 4: Build + smoke test** — `swift build && swift run Murmur --process-text "um hello there"` → prints `engine:` line matching your settings (existing install → ollama). `swift test` still green.

- [ ] **Step 5: Commit** — `git commit -am "feat: cleanup engine selection (Apple Intelligence / Ollama) in pipeline, CLI, settings"`

---

### Task 6: Onboarding scaffold + routing + Welcome page (translocation)

**Files:**
- Create: `Sources/Murmur/OnboardingView.swift`
- Modify: `Sources/Murmur/MainWindow.swift:26-74` (MainModel + MainView routing)
- Modify: `Sources/Murmur/AppMain.swift` (launch behavior)

- [ ] **Step 1: MainModel routing** — in `MainWindow.swift`, add to `MainModel`:

```swift
var showOnboarding: Bool
/// Re-arms the hotkey listener after permission grants (set by AppDelegate).
var onPermissionsChanged: () -> Void = {}
```

and in `MainModel.init`, after `self.onBindingsChanged = onBindingsChanged`:

```swift
self.showOnboarding = !store.settings.onboardingCompleted
    || CommandLine.arguments.contains("--onboarding")
```

In `MainView.body`, wrap the existing `HStack` so onboarding replaces everything:

```swift
var body: some View {
    Group {
        if model.showOnboarding {
            OnboardingView(model: model)
        } else {
            mainChrome
        }
    }
    .background(Theme.canvas)
    .frame(minWidth: 940, minHeight: 620)
}

private var mainChrome: some View {
    HStack(spacing: 0) {
        Sidebar(model: model)
            .frame(width: 208)
        contentPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
            .padding(.vertical, 14)
            .padding(.trailing, 14)
    }
}
```

- [ ] **Step 2: Scaffold + Welcome page** — create `Sources/Murmur/OnboardingView.swift`:

```swift
import AppKit
import Combine   // Timer.publish for the 1 s permission polls
import SwiftUI
import MurmurCore

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, cleanup, tryIt
}

struct OnboardingView: View {
    @Bindable var model: MainModel
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(36)
        .background(Theme.canvas)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .microphone:
            PermissionStep(
                title: "Microphone",
                explanation: "Murmur records your voice only while you hold the dictation key. Audio never leaves this Mac.",
                isGranted: { Permissions.microphoneGranted },
                request: { Task { _ = await Permissions.requestMicrophone() } },
                openSettings: Permissions.openMicrophoneSettings)
        case .accessibility:
            PermissionStep(
                title: "Accessibility",
                explanation: "Lets Murmur type the polished text into whatever app you're using.",
                isGranted: { Permissions.accessibilityTrusted },
                request: Permissions.requestAccessibility,
                openSettings: Permissions.openAccessibilitySettings)
        case .inputMonitoring:
            PermissionStep(
                title: "Input Monitoring",
                explanation: "Lets Murmur notice when you hold Fn to dictate. It listens for that key only.",
                isGranted: { Permissions.inputMonitoringGranted },
                request: Permissions.requestInputMonitoring,
                openSettings: Permissions.openInputMonitoringSettings)
        case .cleanup: CleanupStep(model: model)
        case .tryIt: TryItStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }.buttonStyle(GhostButtonStyle())
            }
            Spacer()
            Text("\(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Button(step == .tryIt ? "Finish" : "Continue") {
                if step == .tryIt { finish() } else { move(1) }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
            model.onPermissionsChanged()   // re-arm hotkeys as grants land
        }
    }

    private func finish() {
        model.store.settings.onboardingCompleted = true
        model.settingsModel.settings.onboardingCompleted = true
        model.onPermissionsChanged()
        withAnimation(.easeInOut(duration: 0.25)) { model.showOnboarding = false }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    @State private var moveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(nsImage: MurmurIcon.idle)
            Text("Speak it. Murmur types it.")
                .font(Theme.serif(34))
                .foregroundStyle(Theme.ink)
            Text("Hold Fn and talk — polished text lands wherever your cursor is. Everything runs on this Mac; nothing leaves it. The next steps set up the three permissions dictation needs.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            if AppRelocator.isTranslocated {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Murmur is running from a temporary location, which makes macOS forget its permissions. Move it to Applications first.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                    Button("Move to Applications and Relaunch") {
                        if !AppRelocator.moveToApplicationsAndRelaunch() { moveFailed = true }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    if moveFailed {
                        Text("Couldn't move automatically — quit Murmur, drag it to Applications in Finder, and open it again.")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(Theme.violet.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gatekeeper app translocation runs quarantined apps from a randomized
/// read-only path; TCC grants don't stick there. Detect and fix.
@MainActor
enum AppRelocator {
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Copies the bundle to /Applications, strips quarantine (the user already
    /// approved the app by opening it), relaunches from there. Returns false
    /// if any step fails so the UI can show manual instructions.
    static func moveToApplicationsAndRelaunch() -> Bool {
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let dest = URL(fileURLWithPath: "/Applications/Murmur.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
        } catch { return false }

        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? strip.run()
        strip.waitUntilExit()

        NSWorkspace.shared.openApplication(
            at: dest, configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        return true
    }
}

// MARK: - Permission step (shared by mic / AX / input monitoring)

private struct PermissionStep: View {
    let title: String
    let explanation: String
    let isGranted: () -> Bool
    let request: () -> Void
    let openSettings: () -> Void

    @State private var granted = false
    @State private var requested = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HStack(spacing: 10) {
                Circle()
                    .fill(granted ? Color.green : Theme.inkTertiary)
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(Theme.serif(30))
                    .foregroundStyle(Theme.ink)
            }
            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    Button("Grant Access") {
                        requested = true
                        request()
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    if requested {
                        Button("Open System Settings") { openSettings() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                Text("You can skip this and grant it later — Murmur keeps working either way.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { granted = isGranted() }
        .onReceive(tick) { _ in granted = isGranted() }
    }
}
```

(`CleanupStep` and `TryItStep` are Task 7 — for this task, add placeholder views so it compiles:)

```swift
private struct CleanupStep: View {
    @Bindable var model: MainModel
    var body: some View { Text("cleanup step").foregroundStyle(Theme.ink) }
}

private struct TryItStep: View {
    var body: some View { Text("try it").foregroundStyle(Theme.ink) }
}
```

- [ ] **Step 3: Launch behavior** — in `AppMain.swift` `applicationDidFinishLaunching`:

Replace the three unconditional permission request lines (51-53) with:

```swift
// First-run prompting is owned by the onboarding wizard. Users who finished
// (or predate) onboarding keep the old prompt-on-launch behavior.
if store.settings.onboardingCompleted {
    if !Permissions.accessibilityTrusted { Permissions.requestAccessibility() }
    if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }
    Task { _ = await Permissions.requestMicrophone() }
}
```

After the `hotkeys.start()` block, add hotkey re-arm plumbing to the class:

```swift
private var hotkeysArmed = false
```

set `hotkeysArmed = hotkeys.start()` where `start()` is currently called (keep the failure notification only for onboarded users: wrap the `TextInjector.notify` in `if store.settings.onboardingCompleted`), and add:

```swift
func rearmHotkeysIfNeeded() {
    guard !hotkeysArmed else { return }
    hotkeysArmed = hotkeys.start()
}
```

In `showMain`, after `mainModel = model`, add:

```swift
model.onPermissionsChanged = { [weak self] in self?.rearmHotkeysIfNeeded() }
```

At the end of `applicationDidFinishLaunching`, open the window for first-run users:

```swift
if !store.settings.onboardingCompleted { showMain(.home) }
```

- [ ] **Step 4: Verify** — `swift build`, then `bash Scripts/make_app.sh && open build/Murmur.app --args --onboarding` → wizard shows Welcome; click through pages; permission pages show green dots (already granted on this Mac); Finish lands in the normal dashboard. Screenshot each page with the window-capture workflow (`winclick`/`screencapture -l`) and inspect.

- [ ] **Step 5: Commit** — `git commit -am "feat: onboarding wizard scaffold, permission pages, translocation relocator"`

---

### Task 7: Cleanup-engine page + Try-it page + "Run setup again"

**Files:**
- Modify: `Sources/Murmur/OnboardingView.swift` (replace the two placeholders)
- Modify: `Sources/Murmur/SettingsPage.swift` (add re-run row)
- Modify: `Sources/Murmur/MainWindow.swift:71` (pass re-run closure)

- [ ] **Step 1: CleanupStep** — replace placeholder:

```swift
private struct CleanupStep: View {
    @Bindable var model: MainModel
    @State private var aiStatus = AppleIntelligenceStatus.current()
    @State private var showOllama = false
    @State private var ollamaAlive = false
    @State private var pullProgress: Double?
    @State private var pullStatus: String?
    @State private var pullError: String?
    @State private var pullTask: Task<Void, Never>?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Polished, not just transcribed")
                .font(Theme.serif(30))
                .foregroundStyle(Theme.ink)
            Text("A local model removes filler words, fixes punctuation, and resolves \"wait, no…\" corrections. Nothing leaves this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 480, alignment: .leading)

            engineRow(
                selected: model.settingsModel.settings.cleanupEngine == .appleIntelligence,
                title: "Apple Intelligence",
                subtitle: aiStatus.explanation,
                enabled: aiStatus == .ready
            ) { model.settingsModel.settings.cleanupEngine = .appleIntelligence }

            engineRow(
                selected: model.settingsModel.settings.cleanupEngine == .ollama,
                title: "Ollama (best quality)",
                subtitle: ollamaAlive
                    ? "Ollama is running."
                    : "Runs larger models locally. Install it from ollama.com, then download a model here.",
                enabled: ollamaAlive
            ) { model.settingsModel.settings.cleanupEngine = .ollama }

            DisclosureGroup("Set up Ollama", isExpanded: $showOllama) {
                VStack(alignment: .leading, spacing: 10) {
                    if !ollamaAlive {
                        HStack(spacing: 10) {
                            Button("Get Ollama") {
                                NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                            }
                            .buttonStyle(GhostButtonStyle())
                            Text("Waiting for Ollama to start…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    } else if let progress = pullProgress {
                        HStack(spacing: 10) {
                            ProgressView(value: progress).tint(Theme.violet).frame(width: 220)
                            Text(pullStatus ?? "downloading…")
                                .font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                            Button("Cancel") { pullTask?.cancel() }.buttonStyle(GhostButtonStyle())
                        }
                    } else {
                        Button("Download \(model.settingsModel.settings.cleanupModel)") { startPull() }
                            .buttonStyle(PrimaryPillButtonStyle())
                    }
                    if let pullError {
                        HStack(spacing: 10) {
                            Text(pullError).font(.system(size: 12)).foregroundStyle(.red)
                            Button("Retry") { startPull() }.buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: 480, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { probe() }
        .onReceive(tick) { _ in probe() }
        .onDisappear { pullTask?.cancel() }
    }

    private func probe() {
        aiStatus = AppleIntelligenceStatus.current()
        guard let url = URL(string: model.settingsModel.settings.ollamaURL) else { return }
        Task {
            let alive = await OllamaClient(baseURL: url).isAlive()
            await MainActor.run { ollamaAlive = alive }
        }
    }

    private func startPull() {
        guard let url = URL(string: model.settingsModel.settings.ollamaURL) else { return }
        let modelName = model.settingsModel.settings.cleanupModel
        pullError = nil
        pullProgress = 0
        pullTask = Task {
            do {
                try await OllamaClient(baseURL: url).pull(model: modelName) { event in
                    Task { @MainActor in
                        if let f = event.fraction { pullProgress = f }
                        pullStatus = event.status
                        if event.isSuccess {
                            pullProgress = nil
                            model.settingsModel.settings.cleanupEngine = .ollama
                        }
                    }
                }
                await MainActor.run { pullProgress = nil }
            } catch is CancellationError {
                await MainActor.run { pullProgress = nil }
            } catch {
                await MainActor.run {
                    pullProgress = nil
                    pullError = error.localizedDescription
                }
            }
        }
    }

    private func engineRow(
        selected: Bool, title: String, subtitle: String,
        enabled: Bool, choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.violet : Theme.inkTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: 480, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.violet : Theme.cardBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !selected)
        .opacity(enabled || selected ? 1 : 0.55)
    }
}
```

- [ ] **Step 2: TryItStep** — replace placeholder:

```swift
private struct TryItStep: View {
    @State private var scratch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Try it")
                .font(Theme.serif(30))
                .foregroundStyle(Theme.ink)
            Text("Click into the field below, hold **Fn**, and say something like \"um so let's meet tuesday, wait no, friday\". Release Fn and watch the polished version land.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 480, alignment: .leading)
            TextEditor(text: $scratch)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxWidth: 480, minHeight: 120, maxHeight: 160)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

Note: dictating into the wizard requires the MainWindow to be key — it is (the user clicked into the field), and `TextInjector` targets the focused field, so the insert lands in this `TextEditor`.

- [ ] **Step 3: "Run setup again"** — in `SettingsPage`, add a parameter `let onRunSetup: () -> Void` (after `onBindingsChanged`), and at the end of the `section("Data & Privacy")` block add a row:

```swift
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
```

In `MainWindow.swift` `contentPane`, update the settings case:

```swift
case .settings: SettingsPage(
    model: model.settingsModel,
    onBindingsChanged: model.onBindingsChanged,
    onRunSetup: { model.showOnboarding = true })
```

- [ ] **Step 4: Verify** — `swift build && bash Scripts/make_app.sh && open build/Murmur.app --args --onboarding`. Walk the wizard: cleanup page shows AI status + your live Ollama (running) with radio selection; Try-it accepts a real dictation; Settings → "Run setup again" re-enters the wizard. Screenshot each state.

- [ ] **Step 5: Commit** — `git commit -am "feat: onboarding cleanup-engine and try-it pages; run-setup-again"`

---

### Task 8: Mic level callback for the pill waveform

**Files:**
- Modify: `Sources/Murmur/AudioTranscriber.swift:119-144` (tap)
- Modify: `Sources/Murmur/DictationController.swift:20-47` (relay)

- [ ] **Step 1: AudioTranscriber** — add next to `onPartial` (line 37):

```swift
/// Called on the main actor with the mic RMS level (0…1) while recording.
/// Declared @MainActor so it can be captured by the @Sendable audio-thread
/// sink — same proven pattern as AudioLevelMeter (SettingsPage.swift:332).
var onLevel: (@MainActor (Float) -> Void)?
```

In `start(...)`, change the tap installation call to pass a level sink (the closure is formed here but only captures the local `@MainActor` handler — the nonisolated rule applies to the tap closure itself, which stays in the static helper):

```swift
let levelHandler = onLevel
Self.installStreamTap(
    on: audioEngine, converter: tapConverter,
    format: analyzerFormat, continuation: continuation,
    levelSink: { rms in
        Task { @MainActor in levelHandler?(min(rms * 8, 1)) }
    })
```

Change `installStreamTap` to compute RMS on the raw buffer (same math as `AudioLevelMeter.installTap` in SettingsPage.swift:354-366):

```swift
private nonisolated static func installStreamTap(
    on engine: AVAudioEngine,
    converter: AVAudioConverter,
    format: AVAudioFormat,
    continuation: AsyncStream<AnalyzerInput>.Continuation,
    levelSink: @escaping @Sendable (Float) -> Void
) {
    let micFormat = engine.inputNode.outputFormat(forBus: 0)
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) {
        buffer, _ in
        if let data = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += data[i] * data[i] }
            levelSink(frames > 0 ? sqrtf(sum / Float(frames)) : 0)
        }
        guard let converted = convert(buffer: buffer, with: converter, to: format)
        else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }
}
```

- [ ] **Step 2: DictationController relay** — add near `onPartialTranscript` (line 23):

```swift
/// Mic level (0…1) while recording, for the pill waveform.
var onAudioLevel: ((Float) -> Void)?
```

and in `init` after the `onPartial` wiring:

```swift
transcriber.onLevel = { [weak self] level in
    self?.onAudioLevel?(level)
}
```

- [ ] **Step 3: Build** — `swift build` → compiles (nothing consumes it yet).

- [ ] **Step 4: Commit** — `git commit -am "feat: mic level callback from ASR tap for pill waveform"`

---

### Task 9: Pill state machine — collapsed / hover / recording / processing

**Files:**
- Rewrite: `Sources/Murmur/RecordingPill.swift`
- Modify: `Sources/Murmur/AppMain.swift:41-48` (wiring)

- [ ] **Step 1: Rewrite `RecordingPill.swift`:**

```swift
import AppKit
import SwiftUI
import MurmurCore

/// Actions the pill's hover quick-buttons trigger (wired by AppDelegate).
struct PillActions {
    var handsFreeToggle: () -> Void = {}
    var cancelDictation: () -> Void = {}
    var confirmDictation: () -> Void = {}
    var openScratchpad: () -> Void = {}
    var openSettings: () -> Void = {}
    var setLanguage: (String) -> Void = { _ in }
    var currentLanguage: () -> String = { "en-US" }
}

/// Wispr-style pill at the bottom-center of the screen: a collapsed sliver
/// when idle, quick actions on hover, cancel · waveform · confirm while
/// recording. A non-activating panel — it never steals focus from the app
/// being dictated into.
@MainActor
final class RecordingPillController {

    @Observable
    final class Model {
        enum Phase { case collapsed, hover, recording, processing }
        var phase: Phase = .collapsed
        var level: Float = 0
        var actions = PillActions()
    }

    private var panel: NSPanel?
    private let model = Model()

    init(actions: PillActions) {
        model.actions = actions
    }

    /// Called once at launch: the pill is always on screen from now on.
    func install() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
    }

    func transition(to state: DictationController.State) {
        switch state {
        case .recording:
            model.phase = .recording
        case .processing:
            model.phase = .processing
        case .injecting, .idle:
            model.phase = .collapsed
            model.level = 0
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // SwiftUI draws its own
        panel.level = .statusBar
        panel.ignoresMouseEvents = false // hover + buttons
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 8))
    }
}

// MARK: - SwiftUI content

private struct PillView: View {
    @Bindable var model: RecordingPillController.Model
    @State private var supportedLanguages: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch model.phase {
            case .collapsed:
                collapsedSliver
            case .hover:
                hoverStack
            case .recording:
                recordingPill
            case .processing:
                processingPill
            }
        }
        .frame(width: 460, height: 130, alignment: .bottom)
        .padding(.bottom, 6)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: phaseKey)
        .onHover { hovering in
            switch (hovering, model.phase) {
            case (true, .collapsed): model.phase = .hover
            case (false, .hover): model.phase = .collapsed
            default: break
            }
        }
        .task {
            // Long-term this could come from SpeechTranscriber.supportedLocales;
            // a short curated list keeps the hover menu instant.
            supportedLanguages = ["en-US", "es-ES", "fr-FR", "de-DE", "pt-BR", "it-IT", "ja-JP"]
        }
    }

    private var phaseKey: String {
        switch model.phase {
        case .collapsed: "collapsed"
        case .hover: "hover"
        case .recording: "recording"
        case .processing: "processing"
        }
    }

    private var collapsedSliver: some View {
        Capsule()
            .fill(.black.opacity(0.85))
            .frame(width: 64, height: 10)
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .contentShape(Capsule().scale(2.2))   // generous hover target
    }

    private var hoverStack: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Dictate")
                    .foregroundStyle(.white)
                Text("fn")
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 0.9, green: 0.7, blue: 1.0), Color(red: 0.7, green: 0.5, blue: 1.0)],
                        startPoint: .leading, endPoint: .trailing))
                    .fontWeight(.bold)
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.92), in: Capsule())

            HStack(spacing: 10) {
                Menu {
                    ForEach(supportedLanguages, id: \.self) { lang in
                        Button {
                            model.actions.setLanguage(lang)
                        } label: {
                            if lang == model.actions.currentLanguage() {
                                Label(displayName(lang), systemImage: "checkmark")
                            } else {
                                Text(displayName(lang))
                            }
                        }
                    }
                } label: {
                    quickIcon("globe")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)

                Button { model.actions.handsFreeToggle() } label: { quickIcon("mic.fill", prominent: true) }
                    .buttonStyle(.plain)
                Button { model.actions.openScratchpad() } label: { quickIcon("note.text") }
                    .buttonStyle(.plain)
                Button { model.actions.openSettings() } label: { quickIcon("gearshape.fill") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func quickIcon(_ symbol: String, prominent: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: prominent ? 16 : 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: prominent ? 52 : 40, height: 40)
            .background(.black.opacity(0.92), in: Capsule())
            .contentShape(Capsule())
    }

    private var recordingPill: some View {
        HStack(spacing: 14) {
            Button { model.actions.cancelDictation() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.25), in: Circle())
            }
            .buttonStyle(.plain)

            WaveDots(level: model.level)

            Button { model.actions.confirmDictation() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private var processingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Polishing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.92), in: Capsule())
    }
}

/// Mic-level-driven dotted waveform (the Wispr look).
private struct WaveDots: View {
    let level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 14)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(history.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: max(4, CGFloat(history[i]) * 22))
            }
        }
        .frame(height: 24)
        .onChange(of: level) {
            history.removeFirst()
            history.append(level)
        }
        .animation(.linear(duration: 0.08), value: history)
    }
}
```

- [ ] **Step 2: Wire in `AppMain.swift`** — replace `pill = RecordingPillController()` (line 41) with:

```swift
var pillActions = PillActions()
pillActions.handsFreeToggle = { [weak self] in self?.dictation.handsFreeToggle() }
pillActions.cancelDictation = { [weak self] in self?.dictation.cancel() }
pillActions.confirmDictation = { [weak self] in self?.dictation.handsFreeToggle() } // stops any recording
pillActions.openScratchpad = { [weak self] in self?.showScratchpad() }
pillActions.openSettings = { [weak self] in self?.showSettings() }
pillActions.setLanguage = { [weak self] lang in
    guard let self else { return }
    store.settings.defaultLanguage = lang
    Task { try? await AudioTranscriber.ensureAssets(locale: Locale(identifier: lang)) }
}
pillActions.currentLanguage = { [weak self] in self?.store.settings.defaultLanguage ?? "en-US" }
pill = RecordingPillController(actions: pillActions)
pill.install()
```

and after the existing `dictation.onPartialTranscript` wiring add:

```swift
dictation.onAudioLevel = { [weak self] level in
    self?.pill.updateLevel(level)
}
```

Delete the now-unused `dictation.onPartialTranscript = ...` block and the `updateTranscript` call chain (the new pill has no transcript). Remove `onPartialTranscript` consumers only — leave the `DictationController.onPartialTranscript` property in place (harmless, and `--process-text` paths don't use it).

`confirmDictation` reuses `handsFreeToggle()` because its `case .recording` branch finishes any in-flight recording, push-to-talk included (DictationController.swift:94-103).

- [ ] **Step 3: Verify live** — `bash Scripts/make_app.sh && open build/Murmur.app`. Check: sliver visible at bottom; hovering expands (screenshot); starting a dictation (Fn) morphs to the recording pill with moving dots (screenshot); ✓ inserts, ✗ cancels; pill collapses after. Confirm focus never leaves the target app (dictate into TextEdit while clicking pill buttons).

- [ ] **Step 4: Commit** — `git commit -am "feat: Wispr-style pill — collapsed/hover/recording/processing states"`

---

### Task 10: Release script + README install section

**Files:**
- Modify: `Scripts/make_app.sh` (version injection)
- Create: `Scripts/make_release.sh`
- Modify: `README.md`

- [ ] **Step 1: Version injection** — in `make_app.sh`, add near the top:

```bash
VERSION="${MURMUR_VERSION:-0.1.0}"
```

change the heredoc delimiter from `<<'PLIST'` to `<<PLIST` and the two version lines to:

```
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
```

(No other `$` appears in the plist, so unquoting the heredoc is safe.)

- [ ] **Step 2: Create `Scripts/make_release.sh`:**

```bash
#!/bin/bash
# Builds a distributable zip of Murmur for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make_release.sh <version>   e.g. make_release.sh 0.2.0}"

MURMUR_VERSION="$VERSION" bash Scripts/make_app.sh

ZIP="build/Murmur-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves the code signature; plain zip does not.
ditto -c -k --keepParent build/Murmur.app "$ZIP"

echo
codesign --verify --deep --strict build/Murmur.app && echo "signature: OK"
shasum -a 256 "$ZIP"
echo
echo "Publish with:"
echo "  gh release create v$VERSION $ZIP --title \"Murmur $VERSION\" --notes \"<what changed>\""
```

Then `chmod +x Scripts/make_release.sh`.

- [ ] **Step 3: README** — add an `## Install` section (after the intro, before any build docs):

```markdown
## Install

1. Download `Murmur-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag `Murmur.app` into **Applications**.
3. **Right-click → Open** the first time (Murmur isn't notarized; macOS
   blocks double-click opens of unidentified apps — right-click bypasses
   this once, permanently).
4. Follow the in-app setup: it walks you through the three permissions and
   picks a cleanup engine. With Apple Intelligence available, dictation is
   polished out of the box; installing [Ollama](https://ollama.com) later
   upgrades quality (Settings → Cleanup).

Requires macOS 26+.
```

- [ ] **Step 4: Verify** — `bash Scripts/make_release.sh 0.2.0` → zip created, `signature: OK`, sha printed. `ditto -x -k build/Murmur-0.2.0.zip /tmp/murmur-release-test && open /tmp/murmur-release-test/Murmur.app` launches.

- [ ] **Step 5: Commit** — `git commit -am "feat: release zip script, version injection, README install story"`

---

### Task 11: End-to-end verification sweep

**Files:** none (verification only; fix regressions found)

- [ ] **Step 1:** `swift test` → all green. `swift build` → clean.
- [ ] **Step 2:** `swift run Murmur --process-text "um so lets meet tuesday wait no friday"` → prints the engine line and a polished transcript (your install: ollama).
- [ ] **Step 3:** Wizard walkthrough — `bash Scripts/make_app.sh && open build/Murmur.app --args --onboarding`; window-capture every page (welcome, 3 permission pages, cleanup, try-it) and visually inspect against the Theme.
- [ ] **Step 4:** Try-it dictation E2E — with the wizard on the try-it page, use the self-dictation pattern (hold Fn via CGEvent keycode 63, `say "hello world"`, release) and confirm text lands in the wizard field. Check `log stream --predicate 'subsystem == "com.raul.wisprrr"'` for the pipeline trace.
- [ ] **Step 5:** Pill states — capture collapsed, hover, recording (during a `say`-driven dictation), processing; confirm animations and that clicking ✓/✗ works without stealing focus from TextEdit.
- [ ] **Step 6:** Engine matrix — temporarily set `"cleanupEngine": "appleIntelligence"` in `~/Library/Application Support/Murmur/settings.json` (with the app quit, back up the file first, restore after), run `--process-text`, confirm the Apple engine (or its documented passthrough reason) is reported. Restore settings.
- [ ] **Step 7:** Release artifact — `bash Scripts/make_release.sh 0.2.0-test`, unzip to /tmp, launch, `codesign --verify --deep --strict` passes.
- [ ] **Step 8:** Commit any fixes; final `git commit -am "chore: post-implementation verification fixes"` if needed.
