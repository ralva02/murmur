# Recordings (Plaud-style long-form capture, transcription & summaries) — design

**Date:** 2026-07-03
**Status:** approved

## Goal

Murmur gains a Recordings pillar: capture long-form audio in-app (mic **and**
system audio, so both sides of an on-Mac call are heard) or import recordings
exported from Plaud hardware, transcribe them on-device, and produce
structured summaries — locally by default, with an opt-in Claude API path for
higher quality.

**Hardware context:** the user's device is a Plaud Note Pro, which has **no
USB file access** — recordings leave it only through the Plaud app
(Bluetooth/Wi-Fi), which exports MP3/WAV. Murmur therefore ingests exported
audio files; it does not talk to the device.

## Non-goals

- Speaker diarization (SpeechTranscriber doesn't provide it; summaries work
  from an unlabeled transcript). Revisit when the OS API offers it.
- Ogg/Opus decoding (Plaud app exports MP3/WAV; AVAudioFile can't read
  Ogg-Opus natively). Revisit if raw device files ever become accessible.
- Apple Intelligence as a summarization engine — its ~4k-token context can't
  hold a long transcript. A chunked map-reduce path is future work.
- Phone-call capture (that's Plaud hardware's job).
- Streaming/live transcription of long recordings (transcribe on stop).

## 1. Data model & storage (MurmurCore, unit-tested)

### Recording

```swift
public struct Recording: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String                 // default: filename or "Recording <date>"
    public var createdAt: Date
    public var duration: TimeInterval
    public var source: Source                // .inApp | .imported(originalFilename: String)
    public var audioFilename: String         // relative to the recording's folder
    public var language: String              // BCP-47, defaults to settings.defaultLanguage
    public var template: SummaryTemplate     // last-used template
    public var summaryEngine: String?        // "ollama:<model>" | "claude:<model>"
    public var status: Status
}

public enum Status: Codable, Sendable, Equatable {
    case ready          // audio present, pipeline not started (both sources)
    case transcribing
    case transcribed
    case summarizing
    case done
    case failed(stage: Stage, message: String)   // Stage: transcription | summarization
}
```

### RecordingsStore

- Root: `Application Support/Murmur/Recordings/`; one folder per recording
  (`<uuid>/`) containing `audio.<ext>`, `transcript.txt`, `summary.md`, and
  `meta.json` (the `Recording` struct).
- Same persistence conventions as `AppStore`: atomic writes, pretty JSON,
  **and the production-path test guard** — tests must never touch the real
  directory (this store holds hours of irreplaceable audio; the 2026-07-03
  postmortem invariant applies with force).
- API: `list()`, `create(from:)` (copies the audio in — never moves the
  user's file), `updateStatus`, `saveTranscript`, `saveSummary`,
  `delete(id:)` (removes the folder), `transcript(for:)`, `summary(for:)`.
- Transcript/summary live as files (not embedded in meta.json) so they're
  user-greppable and the metadata stays small.

## 2. Intake

### In-app long-form recording (`LongFormRecorder`, app target)

- **Mic**: AVAudioEngine input node (the existing audio stack's rules apply:
  tap closures formed in `nonisolated` context; guard 0 Hz format).
- **System audio**: CoreAudio process tap (`AudioHardwareCreateProcessTap` +
  aggregate device) capturing global system output — the audio-only capture
  API whose TCC prompt is "System Audio Recording", not Screen Recording.
  `NSAudioCaptureUsageDescription` added to Info.plist.
- Both streams feed a mixer graph writing one AAC `.m4a` (48 kHz mono,
  ~24 kbps — an hour ≈ 11 MB).
- If the system-audio permission is denied/unavailable → record mic-only and
  set a visible "mic only" note on the recording. Recording never fails
  outright because one source is missing.
- Controls: Record/Stop on the Recordings page and in the menu-bar menu;
  while recording, the menu-bar icon shows a red badge and the Recordings
  page shows an elapsed timer. Dictation (Fn) remains fully functional while
  a long recording runs — separate engines.
- Stop finalizes the file, creates the `Recording`, and enters the pipeline.

### Import

- **Watched folder**: `~/Downloads`, watched with DispatchSource/FSEvents for
  new `wav/mp3/m4a` files (AirDrop from the Plaud app lands there). On a new
  file, Murmur posts a notification — "Import 'meeting.mp3' into Murmur?" —
  and imports only when clicked. Never silent ingestion; toggleable in
  Settings (default on after the user visits the Recordings page once).
- **Drag & drop** onto the Recordings page and an Import button (NSOpenPanel,
  multi-select).
- Import copies the file into the store; duration read via AVAudioFile.

## 3. Transcription (`FileTranscriber`, app target)

- Reads the audio file with AVAudioFile, converts to the analyzer format, and
  feeds `SpeechAnalyzer`/`SpeechTranscriber` in file mode with **full
  finalization** (no 700 ms cap here — accuracy over latency; measured
  ballpark: ~45 s per 30 min of audio, on-device).
- Locale from the recording's `language` (settable per-recording in the
  detail view before retry).
- Progress: frames-processed fraction surfaced to the UI.
- Dictionary terms bias recognition via `contextualStrings`, same as
  dictation.
- Output: plain text transcript → `transcript.txt`, status → `transcribed`.

## 4. Summarization

### Prompts (MurmurCore, unit-tested)

`SummaryTemplate`: `auto` (default), `meeting`, `lecture`, `memo`,
`interview`. `SummaryPrompt.build(template:transcript:)` returns
system+user strings. The `auto` shape: 2–3 sentence overview, key points,
decisions, action items (with owners when stated) — sections omitted when
empty. Others specialize (meeting adds attendees/next steps; lecture: topics
+ takeaways; memo: cleaned narrative + todos; interview: Q&A distillation).
All prompts instruct markdown output and "only what was said — no
invention", mirroring the dictation minimal-edit ethos.

### Engines (`SummaryProvider` protocol)

```swift
public protocol SummaryProvider: Sendable {
    func summarize(transcript: String, template: SummaryTemplate) async throws -> String
}
```

- **`OllamaSummaryProvider`** (MurmurCore, default): reuses `OllamaClient`
  (`think: false`, existing retry semantics). gemma4:e4b's 131k context
  holds 8+ hours of transcript — single request, no chunking.
- **`ClaudeSummaryProvider`** (MurmurCore): uses the new `AnthropicClient`.

### AnthropicClient (MurmurCore, unit-tested via injectable transport)

Raw HTTP (no Swift SDK exists) mirroring `OllamaClient`'s shape:

- `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`,
  `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Body: `model` (default `claude-opus-4-8`, configurable in Settings),
  `max_tokens: 8192`, `system`, `messages: [user: transcript-bearing prompt]`,
  `thinking: {type: "adaptive"}`. **No `temperature`/`top_p`/`top_k`** —
  they return 400 on Opus 4.8.
- Response handling: guard `stop_reason == "refusal"` (surface "Claude
  declined to process this recording") and `max_tokens` (surface "summary
  truncated — retry with a shorter template"); map 401 → "invalid API key",
  429/5xx → retryable error.
- Non-streaming (8k output at Opus speed is well under timeout).
- Cost note for the UI/docs: an hour-long meeting is ~10–15k input tokens ≈
  **$0.10–0.15 per summary** at Opus 4.8 pricing ($5/$25 per MTok).

### Configuration

- `Settings.summaryEngine: .ollama | .claude` (default `.ollama`) and
  `Settings.claudeModel: String` (default `claude-opus-4-8`).
- The API key is stored in the **macOS Keychain**
  (service `com.raul.wisprrr.claude`), never in settings.json. A small
  `KeychainStore` helper in the app target; Settings UI has a secure field
  with save/clear. `AnthropicClient` takes the key as an init parameter —
  MurmurCore never touches the Keychain (keeps the core AppKit-free and the
  client trivially testable).
- README/Settings privacy copy gains the carve-out: "Everything runs on this
  Mac — unless you enable Claude summaries, in which case transcripts (not
  audio) are sent to Anthropic."

## 5. Pipeline orchestration

`RecordingPipeline` (app target, one per app, serial queue):

1. On intake: status `transcribing` → `FileTranscriber` → `transcribed`.
2. Then `summarizing` → selected `SummaryProvider` → `done`.
3. Any error → `failed(stage:message:)`; audio and any completed transcript
   are preserved.
4. Statuses persist through `RecordingsStore`, so a quit mid-pipeline is
   resumable: on launch, recordings stuck in `transcribing`/`summarizing`
   are reset to the last completed stage with a Retry affordance (no
   auto-restart — the user may have quit on purpose).
5. Re-summarize (template or engine change) re-runs stage 2 only.

## 6. UI (Recordings section)

- New `MainSection.recordings` ("Recordings", `waveform` icon) between Home
  and Dictionary.
- **List**: rows with title (inline-editable), date, duration, status badge
  (spinner + stage while working, red badge + message on failure). Toolbar:
  ● Record / ■ Stop, Import. Empty state explains the three intake doors and
  the Plaud app export flow.
- **Detail**: audio player (AVAudioPlayer: play/pause, scrubber, time);
  template picker + Summarize / Re-summarize button; rendered summary
  (markdown via AttributedString); collapsible transcript; Copy summary,
  Export (.md with title/date header), Delete (confirmed).
- Menu bar: "Start recording" / "Stop recording (mm:ss)" item.

## 7. Errors

| Failure | Behavior |
| --- | --- |
| System-audio tap unavailable/denied | Mic-only recording + note on the recording |
| Mic permission missing | Record button disabled with grant hint (existing Permissions flow) |
| Unreadable/corrupt import | `failed(transcription)` with message; file kept |
| Ollama down | `failed(summarization)`, Retry; transcript intact |
| Claude 401 | "Invalid API key" + link to Settings |
| Claude refusal / truncation | Explicit per-case message (see §4) |
| Quit mid-pipeline | Status persisted; Retry on relaunch, never auto-restart |
| Disk full during recording | Stop + finalize what was captured, surface error |

## 8. Testing

- **MurmurCore (TDD):** `RecordingsStore` CRUD/persistence/production-path
  guard (temp roots only); `SummaryPrompt` per-template shape assertions;
  `AnthropicClient` via fake transport — request shape (headers, model,
  no-sampling-params, adaptive thinking), refusal/max_tokens/401/429
  handling; `ClaudeSummaryProvider` + `OllamaSummaryProvider` error mapping;
  `Settings` migration for the new fields (absent keys decode to defaults).
- **App target (live verification):** import a small fixture WAV → full
  pipeline against live Ollama → summary appears; in-app recording E2E
  (record a `say` playback with the system tap — proves system audio);
  screenshots of list/detail/empty states via the established
  window-capture workflow; Claude path smoke-tested manually with a real
  key (transcript of the fixture).

## Build order (implementation plan will detail)

1. `Recording` model + `RecordingsStore` (MurmurCore, TDD).
2. `SummaryTemplate` + `SummaryPrompt` (MurmurCore, TDD).
3. `AnthropicClient` + both `SummaryProvider`s + Settings fields + Keychain
   (core TDD; keychain app-side).
4. `FileTranscriber` + `RecordingPipeline` + import (picker/drag-drop).
5. Recordings UI (list + detail) — pipeline usable end-to-end via import.
6. `LongFormRecorder` (mic, then system tap) + menu-bar controls.
7. Watched-folder import + notification flow.
8. README/privacy copy, screenshots, release.
