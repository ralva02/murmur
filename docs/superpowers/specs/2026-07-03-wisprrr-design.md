# Wisprrr — Design (macOS personal Wispr Flow clone)

**Date:** 2026-07-03
**Source spec:** `/Users/raul/Downloads/wispr-flow-spec_1.md` (copied to `docs/wispr-flow-spec.md`)
**Mode:** autonomous goal build; decisions recorded here in lieu of interactive brainstorming.

## 1. Scope

Implements the source spec's build order (§18) stages 1–5 for **macOS only**, in the
personal-use configuration of §14 (fully local, no accounts/billing/telemetry/sync):

- Push-to-talk (hold hotkey) and hands-free (double-tap toggle) dictation.
- Streaming capture → on-device ASR → LLM cleanup per the §3.2 contract → insertion
  at cursor in the focused app, with retry + clipboard fallback (§5.1).
- Context awareness (§6): active app id/category, nearby text, proper nouns; never
  password fields; local read, slice passed to the cleanup model.
- Personalization (§7): dictionary, snippets (trigger ≤60 chars), styles per app
  category. Auto-add-to-dictionary is **out of scope v1** (requires post-insertion
  field monitoring; noted as future work).
- Command Mode §8.1 only (selection → spoken instruction → LLM rewrite → replace).
  §8.2 routing: out of scope v1.
- "press enter" end-of-dictation command (§9), stripped from text, Enter synthesized,
  no stray punctuation when it is the sole content.
- UI (§12): menu-bar item with state, recent-activity window with raw-vs-final diff,
  undo last insertion, settings (general/shortcuts, personalization, privacy, audio).

**Out of scope:** iOS/Android, cross-device sync, multi-engine per-language ASR
(§3.1 stage 7), translation, whisper-mode tuning (on-device ASR handles quiet speech
as-is), teams/enterprise, telemetry.

## 2. Platform decisions (why)

| Concern | Choice | Rationale |
|---|---|---|
| Language/UI | Swift 6 + AppKit/SwiftUI, SPM executable + app-bundle script | Native AX/CGEvent/AVAudioEngine access; no Xcode project churn; machine has Xcode 26.6 |
| ASR | Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) | On-device (spec §14.1 "fully local"), streaming volatile results, zero model management; behind `TranscriberProtocol` so whisper.cpp can be swapped in |
| Cleanup LLM | Ollama HTTP API, default model `gemma4:e4b` | Already installed with models; §14.1 recommends small local instruct model; behind `CleanupProvider` protocol |
| Cleanup fallback | Passthrough (raw transcript, deterministic punctuation of nothing) | §15: never silently drop dictation; Ollama down ≠ dictation broken |
| Injection | AX `AXUIElement` insert at selection → CGEvent Cmd+V paste (pasteboard save/restore) → clipboard + user notification | §5 macOS + §5.1 retry ≤5 then clipboard+toast |
| Hotkeys | `CGEventTap` on `flagsChanged`/`keyDown`; default hold-Fn, fallback Ctrl+Opt if no Fn seen; double-tap = hands-free | §4.1 defaults; rebindable per §4.2 |
| Storage | JSON files in `~/Library/Application Support/Wisprrr/` | §16 data model, single-user, local |

## 3. Architecture

```
HotkeyListener ──trigger──► DictationController (state machine)
                                │ start
                                ▼
                     AudioCapture (AVAudioEngine)
                                │ buffers (streamed during hold)
                                ▼
                     Transcriber (SpeechTranscriber)   ◄── ContextReader (AX, read at start)
                                │ raw transcript              │ ContextPayload
                                ▼                             ▼
                     TranscriptProcessor (pure logic)
                       - snippet expansion, dictionary hints, "press enter" detection
                                │ CleanupRequest
                                ▼
                     CleanupProvider (Ollama | Passthrough)
                                │ final text
                                ▼
                     TextInjector (AX → paste → clipboard) ──► Enter synthesis if commanded
                                │
                     HistoryStore (raw, final, diff, app) ──► UI (menu bar, activity, settings)
```

`DictationController` is the only stateful orchestrator: `idle → recording →
processing → injecting → idle`, with debounce for rapid toggles (§17) and a
cancel path.

### Module boundaries

- **WisprrrCore** (library target, no AppKit imports where avoidable, fully unit-tested):
  models (§16), `TranscriptProcessor` (press-enter, snippets, dictionary), prompt
  builder implementing the §3.2 cleanup contract, `OllamaClient` (URLSession, injectable
  transport), stores (settings/dictionary/snippets/styles/history), word-level diff.
- **Wisprrr** (executable): AppKit/SwiftUI shell + OS adapters (hotkeys, audio, ASR,
  AX context/injection, notifications). Thin; logic lives in Core.

### Key behaviors

- **Cleanup contract prompt** (§3.2): minimal-edit smoothing; keep wording; never
  invent; resolve self-corrections; format lists; apply style for app category;
  spell dictionary terms exactly. Deterministic (temperature 0). Output guarded:
  if the model returns something wildly longer/shorter than input heuristics allow,
  fall back to raw transcript.
- **"press enter"**: detected deterministically in code at end of transcript
  (regex, tolerant of trailing punctuation), stripped *before* the LLM call, Enter
  sent after successful injection. Mid-sentence occurrences left literal. Sole-content
  case injects nothing and sends Enter only.
- **Snippets** expanded deterministically when the whole transcript (or a clause)
  matches a trigger phrase case-insensitively — not left to the LLM.
- **Context** (§6.2 exclusions): skip `AXSecureTextField` subroles and password-ish
  fields entirely; ignore placeholder text (`AXPlaceholderValue`); read only during
  an active session; context-awareness master toggle in settings.
- **Failure handling** (§17): injection retry ≤5 → clipboard + notification; ASR or
  cleanup failure → raw text still delivered (clipboard at worst); permission missing
  → menu-bar warning state with re-grant link, app keeps running.

## 4. Testing

- Unit tests (swift-testing) for all of WisprrrCore: press-enter cases (end, mid,
  sole, punctuation), snippet expansion, dictionary hint assembly, prompt builder,
  Ollama client against a stubbed transport, stores round-trip, diff.
- OS adapters verified by build + manual smoke (mic/AX cannot run headless in CI);
  a `wisprrr --process-text "raw transcript"` debug flag exercises the
  processor+cleanup pipeline end-to-end from the CLI for scripted verification.
- Acceptance scenarios from spec §19 tracked in README as a manual checklist.

## 5. Risks

- `SpeechAnalyzer` asset download needed on first run (system-managed; surfaced in UI).
- Fn-key event tap requires Accessibility + Input Monitoring permissions; first-run
  flow must explain both.
- gemma4:e4b latency ~1–2 s per dictation on this machine — within spec §15's
  accepted 1–4 s perceived window, not Wispr's 700 ms target (§14.1 accepts this).
