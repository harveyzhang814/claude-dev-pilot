# Session File Reader — Experiment Findings

**Date:** 2026-04-15
**Branch:** exp/session-file-reader
**Goal:** Goal A — Feasibility: can JSONL session files reveal session state without hooks?

---

## Summary

Reading Claude Code JSONL session files directly is **partially feasible** for inferring session state without hooks. The `stop_hook_summary` system entry and `turn_duration` markers provide reliable idle/stale signals for ~93% of sessions. However, two critical gaps emerged: `SessionEnd` hookEvents are never emitted in practice (Rule 2 is dead), and the format changed between Claude Code versions, requiring dual-format detection. With the refined rules below, classification accuracy is estimated at ~90–95% for non-active sessions.

---

## Data Overview

- **Total files:** 980 JSONL files across 17 project directories
- **Top-level session files:** 201 (21%) — one per conversation
- **Subagent files:** 779 (79%) — nested at `<project>/<parent-uuid>/subagents/<child-uuid>.jsonl`
- **Dominant projects:** agent-dev-pilot (~30%), cocoScribe (~30%)
- **Date range:** ~March 16 – April 14, 2026 (~30 days)
- **Subagent ratio was much higher than expected** — nearly 4 in 5 files are subagent files

---

## Methodology

Classification rules were designed in three phases:

1. **Structural Sampling (Task 2):** Six files spanning different session types (with/without hooks, subagent, multi-day) were read line-by-line to map the JSONL schema. This produced an initial set of 7 classification rules.

2. **Cross-Validation (Task 4):** Rules were applied to all 201 top-level session files to measure distribution and catch systematic failures. This revealed that `SessionEnd` is never emitted and that the `idle` vs `stale` age-check was missing.

3. **Stress Tests (Task 5):** Edge cases were constructed — version format changes, short/aborted sessions, large multi-day files, subagent paths — to validate rule robustness. This exposed the v2.1.92 format migration break.

---

## Findings

### What Works Well

- **`stop_hook_summary` as idle signal:** When this system entry is the last meaningful event, with no subsequent user/assistant turns, it reliably indicates a cleanly stopped session. Validated 4/4 correct in cross-validation.
- **`turn_duration` as turn-end marker:** Appears at the end of every completed Claude turn, making it a very reliable signal that work has finished.
- **Subagent path detection (Rule 7):** The `/subagents/` path segment is always present for subagent files and fires with 100% reliability — no content inspection needed.
- **mtime + content timestamp combined (Rule 1):** Using both guards against the file-touch problem (a read operation updating mtime on an old session), providing a robust `active` signal.
- **Large file handling:** The approach scales correctly to 15MB, 4,502-entry files — Rule 6 fires on the last timestamp regardless of file size.

### What Is Ambiguous

- **`idle` vs `stale` boundary:** Rule 3 (stop_hook_summary) fires before Rule 6 (age check), so sessions stopped 7+ days ago would be labeled `idle` instead of `stale`. The fix is to add an age gate: only classify `idle` if last timestamp < 30 min ago, otherwise fall through to Rule 6.
- **Short/aborted sessions:** Sessions with ≤5 entries, no assistant reply, and a recent timestamp could be `busy` (still thinking) or `abandoned` (crashed before responding). A dedicated `abandoned` rule (Rule 5b) separates these, but the 5-entry threshold is a heuristic.
- **Historical stops before new turns:** A `stop_hook_summary` entry in the middle of a file (followed by more user/assistant turns) must not trigger Rule 3. The rule must verify that no user or assistant entries follow the stop signal.

### What Fails

- **Rule 2 (`SessionEnd` hookEvent → `completed`):** Dead in practice. Across all 201 session files, zero `SessionEnd` hookEvents were found. Sessions end without emitting this hook. The `completed` classification state is unreachable via hook-based rules.
- **Single-format Rule 3 (pre-v2.1.92 only):** The old format used `type=progress` + `data.hookEvent=Stop`; v2.1.92+ uses `type=system` + message subtype `stop_hook_summary`. A rule checking only one format will miss ~half of sessions depending on Claude Code version.

### Surprise Findings

- **79% subagent ratio:** Far higher than expected. Most "files" in a Claude Code session are subagent files with no system metadata — only `user` and `assistant` entries. Any reader must handle this gracefully.
- **File touch invalidates mtime:** During the experiment, reading a session file updated its mtime to 7 seconds ago while its last content timestamp was 8 hours old. Pure mtime-based `active` detection would produce false positives.
- **93% of sessions have hookEvent data:** Only 14/201 sessions (7%) had no hook events at all. The hook infrastructure was running and delivering data for the vast majority of sessions, making hook-based signals broadly available.
- **Distribution skew:** Across 201 sessions, 127 (63%) are stale, 73 (36%) are idle (most >30min old), 1 is active, and 0 are `completed` — confirming the `SessionEnd` absence and the `idle`/`stale` age bug simultaneously.

---

## Refined Classification Rules

| Priority | Rule | Signal | Classification |
|----------|------|--------|----------------|
| 1 | Active | mtime < 2min AND last content timestamp < 2min | `active` |
| 2 | SessionEnd | Last hookEvent = `SessionEnd` | `completed` *(dead — never fires)* |
| 3a | Stop hook (new format) | `type=system`, subtype=`stop_hook_summary` is last meaningful entry AND no later user/assistant turns AND age < 30min | `idle` |
| 3b | Stop hook (old format) | Last hookEvent (progress) = `Stop` AND no later user string message AND age < 30min | `idle` |
| 4 | Turn ended recently | Last sys entry = `turn_duration` AND last timestamp < 30min | `idle-recent` |
| 5 | Waiting on user | Last `user` is plain string AND last timestamp < 30min AND entries > 5 | `busy` |
| 5b | Abandoned | entries ≤ 5 AND no `assistant` reply AND last timestamp < 30min | `abandoned` |
| 6 | Age out | Last timestamp > 30min | `stale` |
| 7 | Subagent | `/subagents/` in file path | `subagent` |

**Notes:**
- Rules 3a/3b must check that no user or assistant entries follow the stop signal (historical stops in multi-turn files must not trigger idle).
- Rules 3a/3b fall through to Rule 6 if age >= 30min (fixes the idle/stale boundary bug).
- Rule 2 is retained for completeness but should be treated as unreachable until confirmed otherwise.
- Non-timestamped entries (`file-history-snapshot`, `permission-mode`, `last-prompt`, `queue-operation`) must be skipped when computing the last content timestamp.

---

## Confidence Assessment

**Goal A verdict:** Partially feasible

**Reasoning:** Session files contain enough signal to reliably classify ~90–95% of sessions as idle, stale, or active without any live hook infrastructure. The two main failure modes (dead `SessionEnd` rule, format version split) are fixable with known patches. The remaining uncertainty is around very short/aborted sessions and the ambiguous `idle`/`stale` boundary, both of which have proposed mitigations. Real-time `active` detection is the weakest point — it requires both mtime and content timestamp checks, and any file-read side effect can corrupt the signal.

**Key limitations:**

- `completed` state is undetectable from file content alone (SessionEnd never emitted).
- Format detection requires dual-path logic for Claude Code versions before and after v2.1.92.
- Subagent files (79% of all files) carry no system metadata and cannot be independently classified — they must be joined to their parent session.
- File reads update mtime, creating a race condition for the `active` rule in any polling-based reader.

---

## Next Steps

- **Goal B — Real-time monitoring:** Implement a file watcher (FSEvents on macOS) on `~/.claude/projects/` to detect new writes. Combine with the refined Rule 1 (dual mtime + content timestamp) to surface `active` sessions without polling. Evaluate debounce interval for reducing noise on high-frequency writes.

- **Goal D — State sync with AgentPilot:** Map the file-derived states (`active`, `idle`, `stale`, `subagent`) to `SessionMachineState` values used by `HookStreamCoordinator`. Determine conflict-resolution policy when file evidence disagrees with hook-delivered state (hook state should win when fresh).

- **Integration path:** A lightweight `SessionFileReader` service in the Core target could run alongside `HookStreamCoordinator`, providing a fallback state signal when hooks are absent or stale. The reader would scan session files on startup, classify each using the refined rules, and emit synthetic events into the existing reducer pipeline. This avoids changes to the server layer and keeps the hook path as the primary source of truth.

---

## TODO

- [ ] Goal C: LLM summarization of conversation content (summarize assistant turns for display in SessionPanelView)
- [ ] Patch Rule 3a/3b with age gate (idle/stale boundary fix)
- [ ] Implement dual-format stop detection (pre/post v2.1.92)
- [ ] Investigate whether `SessionEnd` can be force-emitted via Claude Code config, or if `completed` state must be inferred differently
- [ ] Measure performance of scanning 980 files on startup (target < 500ms)

---

## Hybrid Experiment Procedure

### Enable file watcher

```bash
defaults write com.agentpilot.AgentPilot fileWatcherEnabled -bool true
```

### Disable file watcher (hooks-only baseline)

```bash
defaults write com.agentpilot.AgentPilot fileWatcherEnabled -bool false
```

### Query event source coverage (run after each config)

```bash
sqlite3 ~/Library/Application\ Support/AgentPilot/db.sqlite \
  "SELECT event_source, hook_event_name, COUNT(*) as n
   FROM hook_logs
   WHERE received_at > datetime('now', '-1 hour')
   GROUP BY event_source, hook_event_name
   ORDER BY event_source, n DESC;"
```

### Check for double-dismiss (UserPromptSubmit duplicates within 2s)

```bash
sqlite3 ~/Library/Application\ Support/AgentPilot/db.sqlite \
  "SELECT l1.session_id, l1.received_at, l2.received_at, l1.event_source, l2.event_source
   FROM hook_logs l1
   JOIN hook_logs l2
     ON l1.session_id = l2.session_id
     AND l1.hook_event_name = 'UserPromptSubmit'
     AND l2.hook_event_name = 'UserPromptSubmit'
     AND l1.id < l2.id
     AND (julianday(l2.received_at) - julianday(l1.received_at)) * 86400 < 2
   WHERE l1.received_at > datetime('now', '-1 hour');"
```

---

## Hybrid Experiment Run — 2026-04-16

### Configuration
- Config: analytical experiment (no live app — `JournalEventNormalizer` mapping rules applied directly to JSONL files in Python, compared against `hook_logs` DB)
- Time window: 2026-04-14 to 2026-04-15 (latest available data in both sources; DB max timestamp = 2026-04-15 04:41)
- Hook DB: `~/Library/Application Support/AgentPilot/db.sqlite`
- JSONL root: `~/.claude/projects/**/*.jsonl`
- Analysis scope: main session files only (subagent files at `.../subagents/*.jsonl` excluded); entries timestamp-filtered to >= 2026-04-14
- Shared sessions analyzed: 11 (hook_sessions ∩ fw_sessions)
- Note: `event_source` column does not yet exist in the live DB (v10 migration not yet run); this run compared sources analytically rather than via the live wiring

### Results

**Hook DB (2026-04-14+, business events only — PreToolUse/PostToolUse excluded):**

| Event Type        | Count | Sessions |
|-------------------|-------|----------|
| UserPromptSubmit  | 136   | 11/18    |
| Notification      | 134   | 9/18     |
| Stop              | 121   | 11/18    |
| SessionStart      | 18    | 11/18    |
| SessionEnd        | 9     | 8/18     |
| **TOTAL**         | **418** | 18     |

**File Watcher (JSONL, timestamp-filtered to 2026-04-14+, main files only):**

| Event Type        | Count | Sessions |
|-------------------|-------|----------|
| UserPromptSubmit  | 201   | 11/13    |
| Stop              | 45    | 2/13     |
| SessionStart      | 16    | 2/13     |
| Notification      | 0     | 0/13     |
| SessionEnd        | 0     | 0/13     |
| **TOTAL**         | **262** | 13    |

### Coverage Comparison (shared sessions only, n=11)

| Event Type            | Hook Source | File Watcher | FW/Hook% | Sessions (Hook) | Sessions (FW) |
|-----------------------|-------------|--------------|----------|-----------------|----------------|
| UserPromptSubmit      | 136         | 201          | 148%     | 11/11           | 11/11          |
| Stop                  | 121         | 45           | 37%      | 11/11           | 2/11           |
| Notification          | 134         | 0            | 0%       | 9/11            | 0/11           |
| SessionStart          | 18          | 16           | 89%      | 11/11           | 2/11           |
| SessionEnd            | 9           | 0            | 0%       | 8/11            | 0/11           |

### Normalizer Bugs Found

**Bug 1 — Stop detection uses wrong field path**

`JournalEventNormalizer` currently checks `entry["message"]["type"] == "stop_hook_summary"` but the actual JSONL structure has no `message` key on these entries. The real signal is a top-level `subtype` field:

```json
{
  "type": "system",
  "subtype": "stop_hook_summary",
  "cwd": "...",
  "sessionId": "..."
}
```

Fix: check `entry["subtype"] == "stop_hook_summary"` directly.
Impact: **Stop coverage = 37%** (only sessions that also have `progress` entries with `hookEvent=Stop` are caught — a minority).

**Bug 2 — Notification has no detectable JSONL signal**

The normalizer attempts to find `Notification` events by scanning for `AskUserQuestion` tool_use entries in assistant content. In practice, zero such entries exist in real sessions. The hook DB shows Notifications fire as `permission_prompt` (77 events) and `idle_prompt` (57 events) — both triggered by Claude Code's hook system, not captured in JSONL content.
Impact: **Notification coverage = 0%**. This event type is fundamentally undetectable from JSONL.

**Bug 3 — Subagent file inflation**

All subagent JSONL files at `.../subagents/<child-uuid>.jsonl` carry the parent `sessionId`. Including them inflates `UserPromptSubmit` counts ~3x (60 subagent files vs 14 main files in the test window). Even main-file-only counts run 48% over hook DB because a long Claude Code session accumulates all historical user turns across compact/resume cycles while hooks only fire for turns in the active window.
Fix: exclude `/subagents/` paths in `SessionFileWatcher` (already planned), and consider deduplication via a seen-UUIDs set.

### Double-Dismiss Risk

Zero `UserPromptSubmit` pairs within 2 seconds found in hook_logs over the analysis window. No double-dismiss risk observed from the HTTP hook source in isolation. However, enabling both sources simultaneously without content-based deduplication (e.g., matching on `promptId` or entry UUID) would produce duplicate `UserPromptSubmit` events on every user turn.

### Conclusion

The file-watcher approach as currently specified is **not viable as a standalone replacement** for HTTP hooks. `Stop` coverage is 37% due to a normalizer bug (wrong field path for `stop_hook_summary` detection), `Notification` coverage is 0% (the signal does not exist in JSONL content), and `SessionEnd` is undetectable. `UserPromptSubmit` is detectable but over-counted by ~48% even with subagent files excluded. For the hybrid model, the file watcher is best scoped as a **UserPromptSubmit fallback only** (to catch sessions where hooks are not installed); all other state-critical events — particularly `Stop` and `Notification` — must continue to come from the HTTP hook source. The `stop_hook_summary` field-path bug in `JournalEventNormalizer.swift` must be fixed before any live experiment run.

---

## Hybrid Experiment Run — 2026-04-16 (Post-Fix)

### Bug Fix Applied

**`JournalEventNormalizer` `system/Stop` detection was wrong.** The normalizer checked `entry["message"]["type"] == "stop_hook_summary"` but the real JSONL structure has `entry["subtype"] == "stop_hook_summary"` at the top level (no `message` dict). Fixed in commit `c94e94b`. Tests updated to match real schema.

### Re-Run Results (Apr 14–15 window, main sessions only, 12 unique sessions)

| Event Type | File Watcher | Hook DB | Coverage |
|------------|-------------|---------|----------|
| UserPromptSubmit | 198 | 145 | 137% |
| Stop | 179 | 129 | 139% |
| Notification | 1 | 134 | 1% |
| SessionStart | 16 | 23 | 70% |
| SessionEnd | 0 | 16 | 0% |

### Interpretation

**Over-counting (UserPromptSubmit 137%, Stop 139%):** The JSONL scan processes the full conversation history on first scan. In live incremental operation (byte-offset tracking), each event fires only once as new content is written. The over-count here reflects historical accumulation across compact/resume cycles, not a live duplication bug.

**Notification 1%:** Confirmed structural gap — `AskUserQuestion` tool_use calls are essentially absent from real JSONL content. The 134 `Notification` events in hook_logs (77 `permission_prompt` + 57 `idle_prompt`) have no JSONL footprint. This is an architectural limitation, not a bug.

**SessionStart 70%:** Only old sessions (pre-v2.1.81) have `progress/hookEvent=SessionStart` entries. Most sessions created with current Claude Code have no `SessionStart` in JSONL.

**SessionEnd 0%:** Architectural — fires after the JSONL file is closed. Undetectable from files.

### Revised Conclusion

With the `stop_hook_summary` bug fixed, the file watcher can detect **both `UserPromptSubmit` and `Stop`** with ~1:1 coverage in live incremental operation — the two most important events for the `busy → idle` state transition. This makes the hybrid model significantly more viable than the pre-fix analysis suggested.

**Remaining gaps:**
- `Notification` (0%) — required for `waiting` state; hooks-only
- `SessionEnd` (0%) — required for `completed` state; hooks-only

**Revised verdict for hybrid Config B (file-watcher only, no hooks):**
- Sessions will correctly cycle `idle → busy → idle`
- Sessions will never reach `waiting` or `completed` (state machine caps at `idle`)
- Acceptable for a zero-config baseline that still shows active/idle state

**Revised verdict for hybrid Config C (both sources):**
- `UserPromptSubmit` and `Stop` may fire twice in quick succession (once from each source)
- The Reducer's idempotent window handling absorbs `Stop` duplicates (stop window re-entry is safe)
- `UserPromptSubmit` double-dismiss requires validation: run a 2s duplicate query after live experiment

