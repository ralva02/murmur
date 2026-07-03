# Postmortem: unit tests moved and destroyed the real user data directory

**Date:** 2026-07-03 · **Severity:** critical class, trivial actual impact · **Status:** fixed + guarded

## What happened

During the Wisprrr→Murmur rename, a one-time data migration was added to
`AppStore.init`, with the legacy directory as a **defaulted parameter**
pointing at the real `~/Library/Application Support/Wisprrr`:

```swift
init(rootDirectory: URL = .default, legacyRootDirectory: URL = .legacyDefault) {
    if !exists(rootDirectory), exists(legacyRootDirectory) {
        moveItem(legacyRootDirectory, to: rootDirectory)   // ← the bug
    }
    ...
}
```

Unit tests construct `AppStore(rootDirectory: <fresh temp dir>)`. A fresh temp
root never exists, and the defaulted legacy path pointed at real data — so the
**first test to run migrated (moved!) the production directory into its
sandbox**. That instance belonged to `historyAppendsAndPrunes`, whose
assertions include `clearHistory()`, which destroyed the real history file.
At next app launch the production directory was gone, so an empty one was
created: from the user's perspective, all app data silently vanished.

## Timeline (evidence in session logs)

1. ~11:52 — migration added to `AppStore.init` with defaulted legacy path.
2. ~11:55 — `swift test` (parallel runners). First default-legacy `AppStore`
   construction moves `…/Wisprrr` → `/var/folders/…/T/8BA76490-…/`.
   `clearHistory()` in that test erases the history file.
3. 12:00 — first Murmur launch finds no legacy dir; creates empty data dir.
4. 12:0x — discovered when Copy-Last-Transcript produced an empty pasteboard;
   `history.json`/`settings.json` missing from production dir.
5. Recovery — sandbox located by fingerprint (`autoAddDictionary: true` in its
   settings.json); `settings.json` restored intact. Dictionary was empty
   before the incident; snippets/styles/notes had never been written. Lost
   forever: ~10 synthetic dictation-history records from testing. No real
   user content existed yet — luck, not design.

## Root cause chain

1. **Destructive filesystem operation in a constructor** — runs implicitly,
   in whatever process constructs the type, including parallel test runners.
2. **Production path as a parameter default** — every caller that didn't
   explicitly opt out became a production-data mutator.
3. **No isolation boundary** — nothing distinguished "test process" from
   "app process" at the storage layer, so tests could reach real data at all.

## Remediations

- **R1 (trigger):** migration moved to `AppStore.migrateLegacyDataIfNeeded()`,
  an explicit static called only from `applicationDidFinishLaunching`.
- **R2 (class):** `AppStore.init` and the migration now `precondition` that a
  test-harness process (detected via `swiftpm-testing-helper`/xctest markers)
  never operates on the real data directories. Two exit tests
  (`ProductionPathGuardTests`) prove the trap fires and act as regression
  guards.
- **R3 (culture):** lesson recorded in the assistant memory: destructive
  one-time operations never in initializers, and never with production paths
  as parameter defaults.

## What would have made this worse

Real usage history, a curated dictionary, snippets, and notes — i.e. this
same bug three months from now. The guard (R2) is what prevents the
recurrence, not the point-fix (R1).
