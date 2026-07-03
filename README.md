# Murmur

A free, fully local, single-user voice-to-text layer for macOS — a personal
[Wispr Flow](docs/wispr-flow-spec.md) clone. Hold a hotkey, speak naturally, and
cleaned, punctuated, context-appropriate text is inserted at the cursor in
whatever app is focused. Nothing leaves your Mac.

- **ASR:** Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+),
  biased with your dictionary and on-screen proper nouns.
- **Cleanup:** a local LLM applies the minimal-edit cleanup contract — fillers
  removed, punctuation inferred, self-corrections resolved ("let's meet
  Tuesday, wait no, Friday" → "Let's meet Friday"), tone matched to the app
  category. Apple Intelligence out of the box; a local Ollama model (default
  `gemma4:e4b`) as the higher-quality upgrade.
- **Insertion:** Accessibility API with retry, synthetic-paste fallback, and
  clipboard + notification as the last resort — dictation is never lost.

## Install

1. Download `Murmur-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag `Murmur.app` into **Applications**.
3. **Right-click → Open** the first time (Murmur isn't notarized; macOS blocks
   double-click opens of unidentified apps — right-click bypasses this once,
   permanently).
4. Follow the in-app setup: it walks you through the three permissions and
   picks a cleanup engine. With Apple Intelligence available, dictation is
   polished out of the box; installing [Ollama](https://ollama.com) later
   upgrades quality (Settings → Cleanup).

## Requirements

- macOS 26+ on Apple Silicon
- For cleanup, one of:
  - **Apple Intelligence** enabled (zero setup — the default for new installs)
  - **[Ollama](https://ollama.com)** with the cleanup model:
    `ollama pull gemma4:e4b` (best quality; the in-app setup can download the
    model for you)

  Without either, Murmur still works — it inserts the raw on-device transcript.

## Build & run

```bash
bash Scripts/make_app.sh     # builds build/Murmur.app
open build/Murmur.app
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
| Command Mode (ask the web) | **⌃⌥C** with nothing selected, speak a question → opens a Perplexity search |
| Paste / copy last transcript | **⌃⌥V** / **⌃⌥X** |
| Scratchpad (brain-dump notes) | **⌃⌥N** or menu bar |
| Recent activity / View Diff | **⌃⌥D** or menu bar |
| "press enter" | say it at the very end of a dictation to submit (Slack, chat, etc.) |

Settings (menu bar → Settings…): language (picker of all on-device speech
locales), optional translation of output into another language, Ollama
model/URL, shortcuts, dictionary, snippets ("my email address" → your@email),
per-app-category tone + writing samples, context awareness, history.

## Development

```bash
swift test                                        # unit tests (MurmurCore)
swift run Murmur --process-text "some raw text"  # pipeline smoke test, no mic/AX
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
  Murmur inserted and the corrected spelling is learned automatically — it
  then biases both recognition and the cleanup pass.
- **Style samples**: paste an example of how you actually write per app
  category; it's injected into the cleanup prompt as a few-shot exemplar
  (a much stronger tone signal than the tone adjective).

## Known limitations (v1)

- Undo forwards ⌘Z to the target app (relies on its undo stack).
- One language per session (pick it in Settings); no mid-sentence language
  switching or auto-detect — Apple's on-device transcriber is single-locale.
- Custom (non-standard) password fields may not be detected as secure — same
  documented limitation as the original.
