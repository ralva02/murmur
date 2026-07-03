# Wisprrr

A free, fully local, single-user voice-to-text layer for macOS — a personal
[Wispr Flow](docs/wispr-flow-spec.md) clone. Hold a hotkey, speak naturally, and
cleaned, punctuated, context-appropriate text is inserted at the cursor in
whatever app is focused. Nothing leaves your Mac.

- **ASR:** Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+),
  biased with your dictionary and on-screen proper nouns.
- **Cleanup:** a local Ollama model (default `gemma4:e4b`) applies the
  minimal-edit cleanup contract — fillers removed, punctuation inferred,
  self-corrections resolved ("let's meet Tuesday, wait no, Friday" → "Let's meet
  Friday"), tone matched to the app category.
- **Insertion:** Accessibility API with retry, synthetic-paste fallback, and
  clipboard + notification as the last resort — dictation is never lost.

## Requirements

- macOS 26+ on Apple Silicon
- [Ollama](https://ollama.com) running locally with the cleanup model:
  `ollama pull gemma4:e4b`
  (Without Ollama, Wisprrr still works — it inserts the raw on-device transcript.)

## Build & run

```bash
bash Scripts/make_app.sh     # builds build/Wisprrr.app
open build/Wisprrr.app
```

First run: grant the three permissions when prompted (all re-grantable later
from the menu-bar icon):

1. **Microphone** — to hear you.
2. **Accessibility** — to insert text at the cursor and read the focused field.
3. **Input Monitoring** — to see the Fn key globally.

The first dictation may download the on-device speech model (system-managed,
one-time).

## Usage

| Action | Trigger |
|---|---|
| Push-to-talk | **hold Fn**, speak, release |
| Hands-free toggle | **double-tap Fn** (stop with another double-tap or single press) |
| Cancel while recording | **Esc** |
| Command Mode (rewrite selection) | select text, **⌃⌥C**, speak an instruction ("make this more concise") |
| Paste last transcript | **⌃⌥V** |
| Recent activity / View Diff | **⌃⌥D** or menu bar |
| "press enter" | say it at the very end of a dictation to submit (Slack, chat, etc.) |

Settings (menu bar → Settings…): language, Ollama model/URL, shortcuts,
dictionary, snippets ("my email address" → your@email), per-app-category tone,
context awareness, history.

## Development

```bash
swift test                                        # unit tests (WisprrrCore)
swift run Wisprrr --process-text "some raw text"  # pipeline smoke test, no mic/AX
```

Design doc: `docs/superpowers/specs/2026-07-03-wisprrr-design.md` ·
Plan: `docs/superpowers/plans/2026-07-03-wisprrr.md` ·
Source spec: `docs/wispr-flow-spec.md`

## Manual acceptance checklist (spec §19)

- [ ] Rambling sentence with "um"/false starts in Mail → clean, punctuated paragraph at cursor.
- [ ] "let's meet Tuesday, wait no, Friday" → "Let's meet Friday." *(verified via `--process-text`)*
- [ ] Dictate into Slack ending with "press enter" → message sent, no stray text/punctuation.
- [ ] Name visible on screen → spelled correctly (contextual-strings biasing).
- [ ] Select paragraph, ⌃⌥C, "turn this into bullet points" → selection replaced.
- [ ] Variable name in VS Code → camelCase/snake_case preserved.
- [ ] Whispered sentence in a quiet room → still transcribes.
- [ ] Quit and relaunch → permissions persist, dictation works.
- [ ] Insertion into an unsupported field → clipboard + notification, nothing lost.
- [ ] Network disabled → dictation still works end-to-end (all local).

## Personalization that compounds

- **Auto-add to dictionary** (Settings → Personalization): correct a word
  Wisprrr inserted and the corrected spelling is learned automatically — it
  then biases both recognition and the cleanup pass.
- **Style samples**: paste an example of how you actually write per app
  category; it's injected into the cleanup prompt as a few-shot exemplar
  (a much stronger tone signal than the tone adjective).

## Known limitations (v1)

- Command Mode query routing (§8.2) is not implemented.
- Undo forwards ⌘Z to the target app (relies on its undo stack).
- One language per session (the `defaultLanguage` setting); no mid-sentence
  language switching.
- Custom (non-standard) password fields may not be detected as secure — same
  documented limitation as the original.
