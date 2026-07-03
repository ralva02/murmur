# Onboarding, installer, and Apple Intelligence cleanup — design

**Date:** 2026-07-03
**Status:** approved

## Goal

Someone downloads Murmur from a GitHub release onto a Mac with no Ollama and
gets a working, polished dictation app: guided permission grants, transcript
cleanup that works out of the box via Apple's on-device model, and a clear
upgrade path to Ollama. Alongside this, the recording pill gets the Wispr
Flow interaction model (collapsed idle sliver, hover quick-actions, animated
recording state).

**Audience:** friends downloading a zip from GitHub Releases. No Apple
Developer Program membership — the app is signed with the free-tier "Apple
Development" identity, so Gatekeeper requires a one-time right-click-Open.
That dance is documented, not fought.

## Non-goals

- Notarization, DMG, auto-updates (Sparkle). Revisit if distribution widens.
- Replacing Ollama: it remains the highest-quality engine and the
  maintainer's daily driver.
- Any change to the deterministic command layer (`TranscriptProcessor`),
  the minimal-edit prompt contract, or the `com.raul.wisprrr` bundle id.

## 1. Cleanup engine: Apple Intelligence by default

### Setting and migration

`Settings` (MurmurCore, `Stores.swift`) gains:

```swift
enum CleanupEngine: String, Codable { case appleIntelligence, ollama }
var cleanupEngine: CleanupEngine
```

- Fresh install (no settings file): `appleIntelligence`.
- Existing settings file without the key (pre-this-version): decodes to
  `ollama`, preserving current behavior for existing installs.
- Pure decode logic — no side effects, no migration functions in
  initializers (per the 2026-07-03 postmortem invariant), unit-tested.

### AppleIntelligenceCleanupProvider

Lives in `Sources/Murmur` (app target), NOT MurmurCore: the Foundation
Models framework offers no injectable transport seam, so it cannot be
meaningfully unit-tested; MurmurCore stays pure and fully tested.

- Conforms to `CleanupProvider`.
- Prompt comes from `PromptBuilder` (MurmurCore — shared with Ollama, so the
  minimal-edit contract and style/dictionary/context injection stay
  identical and tested).
- Output passes the same sanity guard used by `OllamaCleanupProvider.isSane`
  (guard extracted to a shared, testable function in MurmurCore); failure
  falls back to the raw transcript.
- Uses `LanguageModelSession` with instructions built once per pipeline;
  session is created during recording start (the existing `pendingPipeline`
  prewarm path) so model load overlaps speech.
- Availability via `SystemLanguageModel.default.availability`:
  - `.available` → use it.
  - `.unavailable(.appleIntelligenceNotEnabled)` → passthrough; Settings and
    onboarding show "Enable Apple Intelligence in System Settings" with a
    deep link.
  - `.unavailable(.modelNotReady)` (still downloading) → passthrough; status
    shows "Apple's model is downloading — cleanup will start working
    automatically."
  - `.unavailable(.deviceNotEligible)` → passthrough; status recommends the
    Ollama path.

### Selection

`DictationController` builds the provider from `settings.cleanupEngine`:

- `appleIntelligence` → `AppleIntelligenceCleanupProvider` if available,
  else `PassthroughCleanupProvider`.
- `ollama` → existing behavior (`OllamaClient.isAlive()` probe →
  `OllamaCleanupProvider` or passthrough).

No silent cascading between engines: the engine is whatever the setting
says, and its live status (working / why not) is shown in Settings. The
`--process-text` debug entry honors the setting the same way.

## 2. Onboarding wizard

### Placement and lifecycle

- New `onboardingCompleted: Bool` in `Settings` (default false; existing
  settings files decode it as **true** — current users never see the wizard
  unless they ask).
- While false, `showMain()` presents `OnboardingView` as the MainWindow's
  content — no sidebar. On completion the window swaps to the normal
  `MainView`.
- On first launch the window opens automatically (replacing today's
  notch-fallback `showSettings()` call, which remains for onboarded users).
- Re-runnable from Settings ("Run setup again").
- Every page has a Skip; closing the window never blocks dictation.

### Pages

1. **Welcome** — what Murmur is; "hold Fn and talk."
   If the bundle path contains `/AppTranslocation/` (Gatekeeper ran a
   quarantined copy from a randomized location, which breaks stable TCC
   grants), the primary button becomes **Move to Applications**: copies the
   bundle to `/Applications`, relaunches from there.
2. **Microphone** — why (recording while the hotkey is held), live
   granted/denied indicator (1 s poll), button fires
   `Permissions.requestMicrophone()`; if previously denied, button deep
   links to System Settings instead.
3. **Accessibility** — same layout, `requestAccessibility()`.
4. **Input Monitoring** — same layout, `requestInputMonitoring()`.
   As grants land, the `HotkeyListener` re-arms (today it only arms at
   launch). The three system prompts move out of
   `applicationDidFinishLaunching` — the wizard owns first-run prompting;
   for onboarded users the launch path keeps its current checks-and-notify
   behavior but stops firing all three prompts at once.
5. **Cleanup engine** — explains polishing. Apple Intelligence preselected
   with its live availability state (per §1). An expandable "Use Ollama
   instead (best quality)" section:
   - Ollama not installed → link to ollama.com/download, live "waiting for
     Ollama…" probe.
   - Installed and running → **Download model** runs `/api/pull` for
     `settings.cleanupModel` (default `gemma4:e4b`), streaming progress (Ollama's pull API reports
     completed/total bytes per layer) with cancel + retry. Pull-progress
     parsing lives in MurmurCore behind `HTTPTransport` (unit-tested).
   - Selecting either engine writes `cleanupEngine`.
6. **Try it** — a text field inside the wizard; user holds Fn and dictates
   into it; the polished insert is the payoff moment. "Finish" sets
   `onboardingCompleted`.

### Page anatomy

One reusable `OnboardingPage` scaffold (Theme-styled: cream canvas, serif
headline, hero-violet accents) with status row, primary action, Skip, and
Back/Continue. Continue enables when the page's grant/choice is satisfied,
but Skip always works.

## 3. Recording pill (Wispr Flow interaction model)

Existing `RecordingPillController` NSPanel stays non-activating (focus must
never leave the target app) and keeps its `nonisolated` audio-tap
invariants. New state machine:

- **Collapsed** (idle): small dark lozenge (~56×10 pt) bottom-center,
  always on screen. Replaces today's hidden-when-idle behavior.
- **Hover**: expands upward to a "Dictate **fn**" label pill plus a
  quick-action row: globe (language menu), mic (hands-free toggle), note
  (scratchpad), gear (settings). Hover tracked with `NSTrackingArea`;
  collapses on exit.
- **Recording**: spring animation into the wide pill — ⨯ button (cancel) ·
  mic-level dot waveform (driven by the existing audio level callback) · ✓
  button (stop and insert). No live transcript (deliberate simplification
  of the current pill; the polish step is trusted).
- **Processing**: brief shimmer on the dots, then insert → collapse.

Animation via SwiftUI springs inside the panel; the panel frame is sized to
the maximum state and content is laid out within it, so no NSWindow frame
animation is needed. Esc continues to cancel through `HotkeyListener`.
Clicks on the panel must not activate Murmur (`.nonactivatingPanel`
preserved).

## 4. Release script and install story

`Scripts/make_release.sh`:

1. Runs `make_app.sh` (release build, real-identity signing — unchanged).
2. `ditto -c -k --keepParent build/Murmur.app build/Murmur-<version>.zip`
   (ditto preserves the signature).
3. Prints the `gh release create v<version> build/Murmur-<version>.zip`
   command with a changelog stub. Version read from one `VERSION=` variable
   at the top, also injected into Info.plist by `make_app.sh` (single
   source of truth).

README gains an **Install** section: download zip → unzip → drag to
Applications → right-click → Open (once) → follow the in-app setup. States
plainly that the app isn't notarized and what that means.

## 5. Error handling

Every failure leaves a working dictation app:

| Failure | Behavior |
| --- | --- |
| Apple Intelligence unavailable (any reason) | Passthrough cleanup; reason + fix shown in Settings and onboarding page 5 |
| Apple model returns garbage | `isSane` guard → raw transcript (same as Ollama today) |
| Ollama pull fails (network/disk) | Progress UI shows error + Retry; engine stays on previous value |
| Permission denied / revoked later | Existing re-grant flow; wizard pages deep-link to System Settings |
| Move to Applications fails (e.g. no write access) | Alert with manual instruction; app keeps running translocated |
| Wizard skipped entirely | App behaves exactly like today's first run |

## 6. Testing

- **MurmurCore (unit, TDD):** `cleanupEngine` + `onboardingCompleted`
  decode/migration matrix; shared output-sanity guard; Ollama pull-progress
  stream parsing via injected `HTTPTransport`.
- **App target (live verification):** build + wizard walkthrough with the
  screencapture workflow (Zed has Screen Recording; window-ID captures per
  page); pill state screenshots (collapsed/hover/recording); self-dictation
  E2E for the "Try it" page and for each engine (`--process-text` for the
  pipeline, spoken E2E for the full path).
- **Release:** run `make_release.sh`, unzip the artifact elsewhere, launch,
  verify signature survives (`codesign -v`) and the translocation prompt
  appears when quarantined.

## Build order (implementation plan will detail)

1. Settings fields + migrations + shared sanity guard (MurmurCore, TDD).
2. `AppleIntelligenceCleanupProvider` + engine selection + Settings status.
3. Ollama pull support (MurmurCore client + progress parsing).
4. Onboarding wizard pages + launch-path changes.
5. Pill state machine + animations.
6. `make_release.sh` + README install section.
