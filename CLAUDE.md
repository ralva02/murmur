# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Murmur (formerly Wisprrr) — a fully local macOS menu-bar voice-to-text app: hold Fn, speak, and LLM-polished text is inserted at the cursor of whatever app is focused. It is a personal clone of Wispr Flow built from the reverse-engineered spec in `docs/wispr-flow-spec.md`; design decisions are in `docs/superpowers/specs/2026-07-03-wisprrr-design.md`. Requires macOS 26+ (SpeechAnalyzer API) and a local Ollama for cleanup (default model `gemma4:e4b`; app degrades to raw-transcript passthrough without it).

## Commands

```bash
swift build                                   # debug build
swift test                                    # all unit tests (MurmurCore only)
swift test --filter <testName>                # single test
bash Scripts/make_app.sh                      # release build + signed build/Murmur.app
open build/Murmur.app                         # launch (menu-bar only, no Dock icon)
swift run Murmur --process-text "raw words"   # pipeline smoke test without mic/AX
swift Scripts/make_icon.swift                 # regenerate Resources/icon_1024.png (then iconutil for .icns)
```

Debug the running app via unified logging:

```bash
log stream --predicate 'subsystem == "com.raul.wisprrr"' --style compact
```

(`log show` on this machine often returns nothing for this subsystem; `log stream` works.)

## Critical invariants — do not "fix" these

- **`CFBundleIdentifier` must stay `com.raul.wisprrr`** even though the app is named Murmur. macOS TCC permission grants (Accessibility, Input Monitoring, Microphone) are keyed to it; changing it forces the user to re-grant everything. Same for the `Diag` log subsystem string.
- **`make_app.sh` must sign with the real "Apple Development" identity**, never ad-hoc. Ad-hoc signatures change per build, which resets TCC grants on every rebuild.
- **AVAudioEngine tap closures must be formed in `nonisolated` context** (see `installStreamTap` / `installTap` static helpers). A closure created inside a `@MainActor` method inherits main-actor isolation and the Swift runtime traps (SIGTRAP) when the realtime audio thread invokes it. Also guard `inputNode` format `sampleRate > 0` before `installTap` — a 0 Hz format (mic permission missing) raises an uncatchable ObjC exception.
- **Tests must never touch `~/Library/Application Support/Murmur`.** `AppStore` preconditions against production paths under a test harness (see `docs/postmortems/2026-07-03-tests-swallowed-user-data.md` — a constructor-default migration once let tests move and destroy real user data). Destructive one-time operations (migrations) live in explicit static functions called only from `applicationDidFinishLaunching`, never in initializers.
- **"press enter" and snippet expansion are deterministic code** (`TranscriptProcessor`), intentionally not delegated to the LLM. The LLM cleanup obeys a minimal-edit contract (`PromptBuilder`) with an output sanity guard that falls back to the raw transcript (`OllamaCleanupProvider.isSane`).

## Architecture

Two SPM targets, strict boundary:

- **`Sources/MurmurCore`** — pure logic, no AppKit, fully unit-tested (TDD is the norm here): models + JSON stores (`Stores.swift`, files under Application Support), transcript post-processing, prompt building, Ollama client (injectable `HTTPTransport` for tests), word diff, correction detection.
- **`Sources/Murmur`** — the app shell and OS adapters; verified by build + live end-to-end runs, not unit tests.

Dictation flow (one stateful orchestrator, `DictationController`: idle → recording → processing → injecting):

1. `HotkeyListener` (listen-only CGEventTap): Fn held ≥250 ms → push-to-talk; double-tap → hands-free; single tap stops hands-free. PTT deliberately does NOT start on key-down (would make double-tap unreachable).
2. On start: `ContextReader` (AX) captures app/category/nearby text/proper nouns once — never from password fields; `AudioTranscriber` streams mic → `SpeechTranscriber` with dictionary+proper-nouns as `AnalysisContext.contextualStrings`; meanwhile the Ollama pipeline is **pre-built and pre-warmed in parallel** (`pendingPipeline`) so model load overlaps speech.
3. On stop: waits for the in-flight ASR start task (`startTask` — stopping without awaiting it orphans the engine and yields empty transcripts), caps finalization wait at 700 ms (volatile transcript + LLM re-punctuation make full finalization unnecessary), then `DictationPipeline.process` → `TextInjector` (AX insert ×5 retries → synthetic ⌘V with pasteboard restore → clipboard + notification).
4. UI surfaces: `RecordingPill` (non-activating bottom-center NSPanel with live transcript), menu-bar `StatusItemController` (has notch-hidden detection — this user's menu bar is crowded and new status items land behind the notch invisible; the app opens Settings as fallback), Settings/Activity/Scratchpad windows (SwiftUI in NSWindows).

Latency budget (measured): ~0.4 s release-to-text warm. The enemies are cold Ollama loads (mitigated by prewarm + `keep_alive: 30m`) and ASR finalization (capped) — not inference.

## Verifying changes end-to-end without a human

The app can dictate to itself: synthesize Fn via CGEvent (`flagsChanged` + `maskSecondaryFn`, keycode 63), speak through the speakers with `say`, target TextEdit, and read the result back with AppleScript. Helpers from past sessions live in the session scratchpad (`fnhold.swift`, `keypress.swift`) — pattern: hold Fn in background, `say "..."`, wait, then `osascript -e 'tell application "TextEdit" to get text of document 1'`. Check the `Diag` log stream for the per-stage trace (recording started / ASR engine running / transcript N chars / pipeline → inserted).
