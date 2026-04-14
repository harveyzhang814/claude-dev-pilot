# Session File Reader — Experiment Design

**Date:** 2026-04-14  
**Type:** Experimental (isolated worktree branch)  
**Status:** Design approved, pending implementation

---

## Context

Agent Pilot currently relies entirely on Claude Code hooks (`notify.sh`) to receive session events. Hooks must be explicitly installed by the user and require the app to be running when events fire.

This experiment explores an alternative signal source: Claude Code's local session files at `~/.claude/projects/<project-path>/<uuid>.jsonl`. Every Claude Code session writes a structured JSONL log regardless of hook configuration.

---

## Experiment Goal A: Feasibility

**Question:** Without any hooks installed, can we accurately determine whether a Claude Code session is active — purely by reading session files?

**Success criteria:**
1. Enumerate all sessions across all projects under `~/.claude/projects/`
2. Classify each session as `active`, `idle`, or `completed`
3. Classification is consistent with what the JSONL content itself reveals (cross-validated against `hookEvent` entries already in the file)

**Out of scope for this experiment:**
- Accuracy parity with the full hook pipeline (Goal B — future)
- Extracting conversation summaries via LLM (Goal C — future TODO)
- Latency comparison between polling and FSEvents (Goal D — future)

---

## Session File Structure

Location: `~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl`

Each line is a JSON object with a common envelope:

```json
{
  "type": "user|assistant|progress|file-history-snapshot|system",
  "timestamp": "2026-04-13T03:09:01.445Z",
  "sessionId": "06333507-...",
  "cwd": "/Users/.../project",
  "uuid": "...",
  ...
}
```

Relevant entry types:

| type | Meaning |
|------|---------|
| `progress` | Hook event fired (has `data.hookEvent`: SessionStart, Stop, PostToolUse, etc.) |
| `user` | User message or tool result returned to model |
| `assistant` | Model response, may contain tool calls |

---

## Classification Logic

Session status derived from JSONL content:

| Signal | Inferred status |
|--------|----------------|
| Last entry `timestamp` < 30 min ago AND last `type=user` was a plain string prompt | `active/busy` |
| `progress` entry with `hookEvent=Stop` is the last meaningful event | `idle` |
| `progress` entry with `hookEvent=SessionEnd` present | `completed` |
| Last entry `timestamp` > 30 min ago | `idle` (stale) |
| File mtime < 30s ago | `active` (fast path, no JSONL parse needed) |

Status priority: `completed` > `active` (recent mtime) > content-derived.

---

## Script Design

Single file: `scripts/experiments/session_reader.py`

**Usage:**
```bash
python3 scripts/experiments/session_reader.py
```

No arguments. Runs the full experiment autonomously and exits. No human intervention required.

**Execution flow:**

```
1. discover_sessions()       — find all .jsonl files under ~/.claude/projects/
2. for each session:
     parse_session(path)     — read all lines, extract envelope fields
     compute_status(events)  — apply classification logic above
3. print_status_table()      — sorted by last_active desc
4. print_summary()           — total / active / idle / completed counts
5. print_validation_report() — cross-check: does computed status match hookEvent signals in file?
6. print_todo()              — next steps for Goal B and Goal D
```

**Output format** — stdout only, human-readable table + JSON summary at end:

```
SESSION ID     PROJECT              STATUS     LAST_ACTIVE           AGE
06333507...    agent-dev-pilot      completed  2026-04-13 11:16:25   1d ago
2bbce87c...    agent-dev-pilot      idle       2026-04-14 09:32:11   2h ago

SUMMARY
  Total sessions : 88
  Active         : 0
  Idle           : 71
  Completed      : 17

VALIDATION
  Sessions with hookEvent data     : 45
  Status matches hookEvent signal  : 43 / 45  (95.6%)
  Mismatches                       : 2 (see below)
  ...

TODO (future experiments)
  [ ] Goal B: extract permission requests and AskUserQuestion events
  [ ] Goal D: compare poll latency vs FSEvents latency
  [ ] Goal C: LLM summarization of conversation content
```

**Key functions:**

| Function | Signature | Notes |
|----------|-----------|-------|
| `discover_sessions` | `() -> list[SessionMeta]` | Walks `~/.claude/projects/`, skips dirs |
| `parse_session` | `(path: str) -> list[dict]` | Reads all JSONL lines, returns raw entries |
| `classify_entry` | `(entry: dict) -> str \| None` | Maps one JSONL entry to a signal label |
| `compute_status` | `(entries: list[dict]) -> SessionStatus` | Applies priority logic to signal list |
| `format_age` | `(ts: str) -> str` | ISO timestamp → "2h ago" / "3d ago" |
| `run_experiment` | `() -> None` | Top-level: discover → parse → classify → report |

---

## Implementation Notes

- Zero external dependencies (stdlib only: `json`, `os`, `pathlib`, `datetime`)
- Reads files at runtime only — no persistent state, no side effects
- If a `.jsonl` file is malformed or unreadable, skip and log to stderr
- Uses file `mtime` as fast-path check before parsing JSONL content
- Script is idempotent: safe to run multiple times

---

## What This Does NOT Do

- Does not write any files or modify any state
- Does not require Agent Pilot app to be running
- Does not poll or watch continuously (single-pass snapshot)
- Does not touch the existing hook pipeline or any Swift code

---

## Future Work

- **Goal B:** Extract structured events (permission requests, `AskUserQuestion`, tool call sequences) from JSONL content
- **Goal D:** Add `--mode poll` and `--mode watch` to compare latency of the two reading approaches
- **Goal C (TODO):** Feed conversation content to an LLM to generate natural language "what is this session doing" summaries
- **Integration decision:** If A+B prove accurate, evaluate replacing or supplementing `HookStreamCoordinator` with a `SessionFileWatcher` service in the Swift app
