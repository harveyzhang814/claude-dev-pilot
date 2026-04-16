# Hybrid Event Source — Design Spec

**Date:** 2026-04-16
**Branch:** exp/session-file-reader
**Status:** Design approved, pending implementation plan

---

## Context

Agent Pilot currently detects Claude Code session state exclusively via HTTP hooks (`notify.sh`). This requires users to manually install hooks and the app to be running when events fire — events fired while the app is offline are silently dropped.

The session file reader experiment (Goal A + B) confirmed that Claude Code's local JSONL session files at `~/.claude/projects/` contain enough signal to detect session state with ~90–95% accuracy, with no user configuration required.

This spec designs a **hybrid event source** that combines both channels into a single pipeline.

---

## Goals

1. **Zero-config baseline** — users without hooks installed still get session state detection
2. **Reliability improvement** — file monitoring catches events missed when the app was offline
3. **Accuracy measurement** — experiment quantifies whether hybrid improves over hooks-only
4. **Debugging visibility** — data source is visible in Settings for diagnostic purposes

---

## Architecture

Both event sources produce `HookPayload` and feed into the same `HookStreamCoordinator`. The Reducer is the sole arbiter of state — it has no knowledge of event origin.

```
notify.sh → POST /event → EventHandler
                               ↓ HookPayload (source: .hook)
                    ┌─────────────────────────┐
                    │   HookStreamCoordinator  │
                    │   SessionStateReducer    │
                    │   [Action] execution     │
                    └─────────────────────────┘
                               ↑ HookPayload (source: .fileWatcher)
              SessionFileWatcher (polls ~/.claude/projects/)
              JournalEventNormalizer (JSONL entry → HookPayload)
```

No deduplication layer. All events from both sources enter the Coordinator without pre-filtering. The Reducer's 13 rules handle duplicate state transitions naturally (idempotent). The experiment observes whether side-effectful transitions (e.g. `UserPromptSubmit` → dismiss prior events) cause problems when fired twice in quick succession.

---

## Components

### SessionFileWatcher

**File:** `Sources/Core/Services/SessionFileWatcher.swift`

**Responsibility:** Poll `~/.claude/projects/` every 2–3 seconds, find recently active JSONL files, read new lines incrementally, pass each new entry to `JournalEventNormalizer`.

**Polling scope:** Only files with `mtime` within the last 30 minutes. At any given time this is typically 1–5 files, keeping CPU overhead negligible.

**Incremental reads:** Maintains a `[String: Int]` dictionary of `filePath → lastByteOffset`. On each poll, seeks to the stored offset, reads to EOF, parses new JSONL lines, updates the offset. Files not seen before start at offset 0.

**New file detection:** On each poll pass, checks for JSONL files with `mtime` newer than last scan. Adds them to the tracking dictionary automatically — this handles new sessions starting mid-run.

**Subagent files:** Files at `<project>/<parent-uuid>/subagents/<child-uuid>.jsonl` are included in polling scope. Events produced from them carry the subagent's `sessionId`. Coordinator processes them the same as top-level sessions.

**Lifecycle:** Started in `AppState.start()` when `fileWatcherEnabled == true`. Stopped on `AppState` teardown. Runs on a background `DispatchQueue`.

**UserDefaults key:** `fileWatcherEnabled` (default `false` — opt-in during experiment, will become `true` by default post-experiment if results are positive).

### JournalEventNormalizer

**File:** `Sources/Core/Services/JournalEventNormalizer.swift`

**Responsibility:** Pure function. Maps a single JSONL entry (already parsed as `[String: Any]`) to `HookPayload?`. Returns `nil` for entries that don't map to any meaningful event.

**Mapping rules:**

| JSONL Entry | Mapped HookPayload event |
|-------------|--------------------------|
| `type=user`, `message.content` is plain String | `UserPromptSubmit` |
| `type=assistant`, content contains `tool_use` with `name=AskUserQuestion` | `Notification(permissionNeeded)` (approximation for experiment) |
| `type=system`, subtype=`stop_hook_summary` | `Stop` |
| `type=progress`, `data.hookEvent=SessionStart` | `SessionStart` (legacy v≤2.1.81) |
| `type=progress`, `data.hookEvent=Stop` | `Stop` (legacy v≤2.1.81) |
| `type=progress`, `data.hookEvent=UserPromptSubmit` | `UserPromptSubmit` (legacy) |
| All other entries | `nil` (ignored) |

**Populated fields from JSONL envelope:**
- `sessionId` ← entry's `sessionId`
- `cwd` ← entry's `cwd`
- `tool` ← `"claude-code"` (fixed)
- `timestamp` ← entry's `timestamp`
- `source` ← `.fileWatcher` (new field)

**Note on AskUserQuestion:** Mapped to `permissionNeeded` as an experiment approximation. The Reducer will transition session to `.waiting`. Goal B production work will differentiate the two event types properly.

---

## HookPayload Changes

**File:** `Sources/Core/Models/HookPayload.swift`

Add:
```swift
enum EventSource: String, Codable {
    case hook
    case fileWatcher
}

// In HookPayload:
var source: EventSource = .hook
```

`source` defaults to `.hook`, so all existing HTTP-originated payloads require no changes. The field is not part of the JSON decoding path — set programmatically by `JournalEventNormalizer`.

---

## HookLog Changes

**File:** `Sources/Core/Models/HookLog.swift` and `Sources/Core/Store/HookLogStore.swift`

Add `source: String` column to `hook_logs` table (new migration `v9_hook_log_source`). Written as `"hook"` or `"file_watcher"` on every insert. Used for experiment analysis — query by source to compare event streams.

---

## AppState Changes

**File:** `Sources/App/AppState.swift`

1. Instantiate `SessionFileWatcher` (lazy, guarded by `fileWatcherEnabled`)
2. In `start()`: if `fileWatcherEnabled`, call `fileWatcher.start { [weak self] payload in self?.coordinator.process(payload) }`
3. Expose `@Published var activeEventSources: Set<EventSource>` for Settings UI

**Settings UI addition:** A read-only status row in Settings showing:
```
Event Sources   hooks ✓   file watcher ✓
```
Both indicators go green when that source has produced at least one event in the current session. For debugging only — no user action required.

---

## Experiment Design

### Three configurations

| Config | fileWatcherEnabled | Hooks installed | Purpose |
|--------|-------------------|-----------------|---------|
| A: Hooks-only | false | yes | Baseline accuracy |
| B: FileWatcher-only | true | no | Zero-config accuracy |
| C: Hybrid | true | yes | Combined accuracy |

### Metrics (queried from HookLog after each run)

| Metric | Query |
|--------|-------|
| Event coverage | Count of key events (UserPromptSubmit, Stop, AskUserQuestion) by source |
| State accuracy | Final session state vs ground truth (hook-logged events as ground truth for config C) |
| Side-effect duplicates | Count of `UserPromptSubmit` events within 2s windows per session (double-dismiss detection) |
| Source distribution | `SELECT source, COUNT(*) FROM hook_logs GROUP BY source` |

### Success criteria

- Config B achieves ≥85% event coverage vs Config A baseline
- Config C achieves ≥Config A accuracy (hybrid never worse than hooks-only)
- Side-effect duplicates in Config C are rare enough to not require deduplication

---

## What Is Not Changed

- `HookStreamCoordinator` — zero changes
- `SessionStateReducer` — zero changes
- `HookEventClassifier` — zero changes
- HTTP server, `EventHandler` — zero changes
- All existing tests — zero changes

---

## Future Work (post-experiment)

- If results positive: set `fileWatcherEnabled = true` by default, promote to production
- Differentiate `AskUserQuestion` from `permissionNeeded` in normalizer (Goal B proper)
- Switch from polling to `FSEventStream` for lower latency in production
- Handle `SessionEnd` gap: explore whether file close time + hook_logs correlation is practical
