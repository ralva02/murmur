# Recording titles, task extraction & LM Studio engine — design

**Date:** 2026-07-03
**Status:** approved

Three related additions to the Recordings pipeline:

1. **LLM-generated titles** — summarization also names the recording.
2. **Task extraction** — action items become reviewable to-dos in a new Tasks
   section (draft-then-confirm, because assignees are often ambiguous).
3. **LM Studio engine** — a local OpenAI-compatible summary engine, since the
   user's MLX models summarize better than the default Ollama model.

## 1. LLM-generated titles

The summary prompt gains a required first line the model must emit before the
markdown body:

```
TITLE: <≤ 6 words naming the recording>
```

`SummaryPrompt` (MurmurCore) adds this instruction; a new pure parser
`SummaryOutput.parse(_:) -> (title: String?, body: String)` splits the
`TITLE:` line off the top and returns the remaining markdown as the summary.
The pipeline saves `body` as `summary.md` (unchanged storage) and applies
`title` to the recording.

**Don't clobber a manual rename.** `Recording` gains `titleIsCustom: Bool`
(default false; decodes to false for existing records). Editing the title
inline sets it true. On summarize, the generated title applies **only when
`titleIsCustom == false`**. Imported files keep starting with the filename
and in-app recordings with "Recording <date>"; both are replaced by the
generated title on first summarize unless the user renamed first.

Testable in MurmurCore: prompt contains the TITLE instruction;
`SummaryOutput.parse` handles present/absent/multiline title lines.

## 2. Task extraction (draft-then-confirm)

### Extraction (MurmurCore, unit-tested)

The summary prompt gains a machine-readable task block after the body,
fenced so the parser can find it and it stays out of the rendered summary:

```
<!--TASKS
- Prepare the Q3 deck | Priya
- Send the vendor contract | Unassigned
-->
```

`TaskExtractor.parse(_ summaryOutput: String) -> [ExtractedTask]` reads the
`<!--TASKS ... -->` block, splitting each line on the last `|` into
`title` and `assignee` (assignee defaults to "Unassigned" when the segment
is missing or literally "Unassigned"). The block is stripped from the
rendered body by `SummaryOutput.parse` so users never see the raw comment.

`ExtractedTask`: `title: String`, `assignee: String` (Sendable, Equatable).

### Review gate

Extracted tasks are held on the recording as `pendingTasks: [ExtractedTask]`
(persisted in meta.json) until reviewed — nothing reaches the Tasks list
automatically, because assignee guesses are unreliable. When
`pendingTasks` is non-empty, the recording's detail view shows a
**"N tasks to review"** button opening a review sheet:

- One row per task: editable **title** field, editable **assignee** field
  pre-filled with the LLM's guess, and a keep/drop toggle (default keep).
- **Add to Tasks** commits the kept rows into `TasksStore` and clears
  `pendingTasks`. **Dismiss** clears `pendingTasks` without adding (the
  recording's summary still stands; re-summarize regenerates them).

### Tasks store & section

New **Tasks** sidebar section (`MainSection.tasks`, `checklist` icon,
after Recordings). Backed by `TasksStore` (MurmurCore) — single
`tasks.json` under Application Support/Murmur, same atomic-write +
**production-path test guard** as the other stores.

`Task`: `id: UUID`, `title: String`, `assignee: String`, `done: Bool`,
`recordingID: UUID`, `recordingTitle: String` (denormalized so the Tasks
list links back without loading the recording), `createdAt: Date`.

The Tasks page is a **flat global list** across all recordings, **Open**
group above **Done**. Each row: checkbox (toggles done), title, assignee
chip, and the source recording name (tapping selects that recording in the
Recordings section). Delete via a row button. **No due dates in v1** — the
audio rarely states them cleanly; added later if wanted.

Store API: `add(_ tasks: [Task])`, `toggleDone(id:)`, `delete(id:)`,
`open`/`done` computed partitions, `deleteTasks(forRecording:)` (called when
a recording is deleted, so orphans don't linger).

## 3. LM Studio (OpenAI-compatible) summary engine

### Client (MurmurCore, unit-tested via injectable transport)

New `OpenAICompatibleClient` mirroring `OllamaClient`/`AnthropicClient`:

- `POST <baseURL>/chat/completions`, `Content-Type: application/json`,
  optional `Authorization: Bearer <key>` when a key is set (LM Studio needs
  none; llama.cpp/vLLM/LiteLLM may).
- Body: `{model, messages:[{role:system},{role:user}], stream:false,
  temperature:0}`.
- Response: `choices[0].message.content`. Errors map like OllamaClient
  (non-200 → thrown error with the status).
- `baseURL` defaults to `http://localhost:1234/v1` (LM Studio's default).

### Engine wiring

`SummaryEngine` gains `.lmStudio`:

```swift
public enum SummaryEngine: String, Codable, Sendable, Equatable {
    case ollama, lmStudio, claude
}
```

`Settings` gains `lmStudioURL: String` (default
`"http://localhost:1234/v1"`) and `lmStudioModel: String` (default `""` —
LM Studio serves whatever model is loaded; empty means "use the loaded
model", which LM Studio accepts). Both decode to defaults for existing
settings files.

A new `LMStudioSummaryProvider` (MurmurCore) wraps `OpenAICompatibleClient`
+ `SummaryPrompt`, same shape as the Ollama/Claude providers.
`RecordingPipeline.makeProvider()` adds the `.lmStudio` case, tagging
summaries `"lmstudio:<model or 'loaded'>"`.

Cleanup engine is untouched (summaries only, per scope). The client is
reusable, so adding LM Studio to cleanup later is a one-case change.

### Settings UI

The Summaries section's engine picker becomes **Ollama · LM Studio ·
Claude**. Selecting LM Studio reveals editable **Base URL** and **Model**
fields (model optional). Claude's key/model fields stay as they are.

## Error handling

| Failure | Behavior |
| --- | --- |
| Title line missing from summary output | Recording keeps its prior title; summary still saves |
| Task block missing / malformed lines | Those lines skipped; valid tasks still extracted; no crash |
| LM Studio not running / wrong URL | `failed(summarization)` with the connection error + Retry; transcript intact |
| Review dismissed | `pendingTasks` cleared; summary unaffected; re-summarize regenerates |
| Recording deleted with tasks in the list | `TasksStore.deleteTasks(forRecording:)` removes them |

## Testing

- **MurmurCore (TDD):** `SummaryOutput.parse` (title split + task-block
  strip); `TaskExtractor.parse` (assignee present/absent/"Unassigned",
  malformed lines, empty block); prompt-shape assertions (TITLE line +
  TASKS block instructions); `TasksStore` CRUD + partitions +
  production-path guard + `deleteTasks(forRecording:)`;
  `OpenAICompatibleClient` request shape (path, bearer-when-keyed, body) and
  response/error mapping via fake transport; `LMStudioSummaryProvider`
  routing; `Settings` migration for the four new fields
  (`titleIsCustom` on Recording; `lmStudioURL`/`lmStudioModel`/`.lmStudio`).
- **App target (live):** import a fixture recording, confirm a generated
  title appears and the review sheet lists tasks with assignee guesses;
  add tasks → they appear in the Tasks section, check one → moves to Done;
  point the engine at a running LM Studio and re-summarize; screenshots of
  the review sheet and Tasks section.

## Build order (plan will detail)

1. `SummaryOutput.parse` + title instruction + `titleIsCustom` (core, TDD;
   pipeline applies title).
2. `TaskExtractor` + task-block instruction + `pendingTasks` on Recording
   (core, TDD).
3. `TasksStore` + `Task` model (core, TDD).
4. `OpenAICompatibleClient` + `LMStudioSummaryProvider` + settings fields +
   engine wiring (core, TDD).
5. Tasks UI (section + list) and review sheet (app; pipeline populates
   `pendingTasks`, recording-delete cleans tasks).
6. Settings LM Studio fields; README note; screenshots.
