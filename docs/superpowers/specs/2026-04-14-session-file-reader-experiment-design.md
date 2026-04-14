# Session File Reader — Experiment Design

**Date:** 2026-04-14  
**Type:** Experimental (isolated worktree branch: `exp/session-file-reader`)  
**Status:** Design approved, pending plan

---

## What This Is

An experiment conducted **by Claude**, using its native tools (Bash, Read, Grep) to directly read and analyze Claude Code's local session files. Claude is the researcher, not a script runner.

The output is a **written findings report** (`docs/superpowers/experiments/session-file-reader-findings.md`) that Claude produces after completing the investigation.

---

## Context

Agent Pilot currently relies entirely on Claude Code hooks (`notify.sh`) to receive session events. Hooks must be explicitly installed by the user.

This experiment explores an alternative: Claude Code writes a structured JSONL log for every session at `~/.claude/projects/<project-path>/<uuid>.jsonl`, regardless of hook configuration. Can this file be used to determine session state without hooks?

---

## Experiment Goal A: Feasibility

**Question:** Without any hooks installed, can session files alone tell us whether a Claude Code session is active?

**Success criteria:**
1. Can we enumerate all sessions across all projects?
2. Can we classify each session's state (active / idle / completed)?
3. Does that classification agree with the evidence inside the files (hookEvent entries, message timestamps)?

**Out of scope:**
- Accuracy parity with the full hook pipeline (Goal B — future)
- LLM conversation summarization (Goal C — future TODO)
- Latency / polling comparison (Goal D — future)

---

## Session File Structure (already confirmed)

Location: `~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl`

Each line is a JSON object:

```json
{
  "type": "user|assistant|progress|file-history-snapshot|system",
  "timestamp": "2026-04-13T03:09:01.445Z",
  "sessionId": "06333507-...",
  "cwd": "/Users/.../project",
  ...
}
```

Key entry types:

| type | Content |
|------|---------|
| `progress` | Hook event: `data.hookEvent` = SessionStart / Stop / PostToolUse / etc. |
| `user` | User message (string) or tool results |
| `assistant` | Model response + tool calls |

---

## Experiment Protocol

Claude executes these steps using Bash, Glob, and Read tools. No Python script required — all analysis is done in-context.

### Step 1 — Enumerate sessions

```bash
find ~/.claude/projects/ -name "*.jsonl" | sort
```

Record: total count, project distribution, date range of files.

### Step 2 — Sample and characterize

Pick a representative sample (≥5 sessions across different projects and ages). For each:
- File mtime (filesystem)
- First and last `timestamp` in file
- Entry type distribution (`type` field counts)
- Which `hookEvent` values appear in `progress` entries

### Step 3 — Classify each sampled session

Apply this logic and record the result:

| Signal | Classification |
|--------|---------------|
| File mtime < 2 min ago | `active` (fast path) |
| Last `hookEvent` = `SessionEnd` | `completed` |
| Last `hookEvent` = `Stop` and no subsequent `user` message | `idle` |
| Last `type=user` was a plain string and timestamp < 30 min ago | `busy` |
| Last timestamp > 30 min ago | `stale` |

### Step 4 — Cross-validate

For sessions that have both hook signals AND timestamp signals, check whether they agree. Note any contradictions.

### Step 5 — Stress test edge cases

Deliberately look for sessions that might be ambiguous or hard to classify:
- Sessions with no `progress` entries (hooks not installed)
- Very short sessions (1–2 messages)
- Sessions that were interrupted mid-task

### Step 6 — Write findings report

Produce `docs/superpowers/experiments/session-file-reader-findings.md` with:
- What worked well
- What was ambiguous or unreliable
- Confidence level: is Goal A feasible? (yes / partial / no)
- Specific gaps that Goal B would need to fill
- Recommended next step

---

## What Claude Should NOT Do

- Do not write a Python script and run it — analyze directly
- Do not read every single `.jsonl` file — sample intelligently
- Do not try to simulate real-time watching — this is a static snapshot experiment
- Do not modify any session files

---

## Deliverable

A single findings report committed to the `exp/session-file-reader` branch:

```
docs/superpowers/experiments/session-file-reader-findings.md
```

Format: markdown. Sections: Summary, Methodology, Findings, Confidence Assessment, Next Steps.

---

## Future Work (not part of this experiment)

- **Goal B:** Extract structured events (permission requests, AskUserQuestion) from message content
- **Goal D:** Real-time watching — poll vs FSEvents latency comparison  
- **Goal C (TODO):** LLM summarization of conversation content
- **Integration:** If A proves feasible, design a `SessionFileWatcher` Swift service to complement or replace hooks
