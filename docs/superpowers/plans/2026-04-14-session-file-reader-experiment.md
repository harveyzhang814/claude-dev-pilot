# Session File Reader Experiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Determine whether Claude Code session JSONL files can reliably reveal session activity state without requiring any hooks to be installed.

**Architecture:** Claude directly reads `~/.claude/projects/**/*.jsonl` using Bash and Read tools, analyzes the data as a researcher, and writes a structured findings report. No programs are written — Claude is the analysis engine.

**Tech Stack:** Bash (data extraction), Python one-liners (JSONL parsing), Claude reasoning (classification and conclusions)

---

## Known Context (gathered during brainstorming)

- **978 JSONL files** across **17 project directories** under `~/.claude/projects/`
- Most recent sessions: `cocoScribe` and `agent-dev-pilot` (today, Apr 14 2026)
- File sizes range from ~28KB to ~8.9MB
- Subagent files exist in nested subdirectories: `<session-uuid>/subagents/*.jsonl`
- Entry types confirmed: `progress` (hook events), `user`, `assistant`, `file-history-snapshot`, `system`
- `progress` entries contain `data.hookEvent` when hooks are configured (SessionStart, Stop, PostToolUse, etc.)

---

## Task 1: Full Enumeration

**Goal:** Get a complete picture of what's available before sampling.

**Files:** No files created. Findings noted in-context.

- [ ] **Step 1: Count files by project**

Run:
```bash
find ~/.claude/projects/ -name "*.jsonl" | sed 's|/[^/]*\.jsonl$||' | sed 's|.*/projects/||' | sort | uniq -c | sort -rn
```
Record: project name, file count, relative proportion.

- [ ] **Step 2: Find subagent files**

Run:
```bash
find ~/.claude/projects/ -path "*/subagents/*.jsonl" | wc -l
find ~/.claude/projects/ -name "*.jsonl" ! -path "*/subagents/*" | wc -l
```
Record: how many are top-level sessions vs subagent sessions. Note whether subagent files need different treatment.

- [ ] **Step 3: Assess age distribution**

Run:
```bash
find ~/.claude/projects/ -name "*.jsonl" ! -path "*/subagents/*" -newer ~/.claude/projects/-Users-harveyzhang96-Projects-agent-dev-pilot/06333507-269d-4ebc-a5c0-a4f0b84ffd5e.jsonl | wc -l
```
Then check oldest file:
```bash
find ~/.claude/projects/ -name "*.jsonl" ! -path "*/subagents/*" | xargs ls -lt | tail -3
```
Record: approximate date range of all sessions.

- [ ] **Step 4: Note enumeration findings in-context**

Answer these questions before moving on:
- Are subagent files structurally different from top-level session files?
- Is the project distribution uneven enough to affect sampling strategy?
- What is the date range of available data?

---

## Task 2: Structural Sampling

**Goal:** Understand the internal structure of different session types before attempting classification.

**Sample selection:** Pick 6 sessions with diversity across: project, recency, file size. At minimum include:
- 1 very recent (< 2h old) — likely active/idle
- 1 from today but older (2–8h) — likely idle
- 1 from yesterday
- 1 from > 3 days ago — likely completed/stale
- 1 with no hooks (no `progress` entries — to stress-test the no-hooks scenario)
- 1 subagent file

- [ ] **Step 1: Identify the 6 target files**

Run to find a recent file with no hooks:
```bash
for f in $(find ~/.claude/projects/ -name "*.jsonl" ! -path "*/subagents/*" | xargs ls -lt | awk '{print $NF}' | head -30); do
  count=$(python3 -c "import json,sys; lines=[l for l in open('$f') if json.loads(l).get('type')=='progress']; print(len(lines))" 2>/dev/null)
  echo "$count $f"
done | sort -n | head -5
```
Record the 6 chosen file paths explicitly.

- [ ] **Step 2: For each file, extract the entry type distribution**

For each chosen file path, run:
```bash
python3 -c "
import json, sys
from collections import Counter
counts = Counter()
for line in open('FILEPATH'):
    try: counts[json.loads(line).get('type','?')] += 1
    except: counts['PARSE_ERROR'] += 1
for k,v in counts.most_common(): print(f'{v:5d}  {k}')
"
```
Record the type breakdown for each file.

- [ ] **Step 3: Extract hook events from each file**

For each file, run:
```bash
python3 -c "
import json
events = []
for line in open('FILEPATH'):
    try:
        obj = json.loads(line)
        if obj.get('type') == 'progress' and obj.get('data', {}).get('hookEvent'):
            events.append({'hookEvent': obj['data']['hookEvent'], 'ts': obj.get('timestamp')})
    except: pass
for e in events: print(e)
print(f'Total hookEvents: {len(events)}')
"
```
Record: which hookEvents appear, in what order, what the last one is.

- [ ] **Step 4: Extract first and last timestamps + last user message**

For each file, run:
```bash
python3 -c "
import json
entries = []
for line in open('FILEPATH'):
    try: entries.append(json.loads(line))
    except: pass
if entries:
    print('first ts:', entries[0].get('timestamp'))
    print('last ts:', entries[-1].get('timestamp'))
    last_user = next((e for e in reversed(entries) if e.get('type')=='user'), None)
    if last_user:
        content = last_user.get('message',{}).get('content','')
        if isinstance(content, str):
            print('last user msg:', repr(content[:100]))
        else:
            print('last user content type:', type(content).__name__, 'len:', len(content) if hasattr(content,'__len__') else '?')
"
```
Record: timestamps and last user message nature.

- [ ] **Step 5: Record structural observations in-context**

Answer before moving to Task 3:
- Do files with hooks look structurally different from those without?
- Is the last entry always the most recent activity signal?
- Are subagent files a different schema or the same?

---

## Task 3: Classify Each Sampled Session

**Goal:** Apply the classification logic from the spec to each sampled session and record the result.

Classification rules (apply in priority order):

| Priority | Signal | Result |
|----------|--------|--------|
| 1 | File mtime < 2 min ago | `active` |
| 2 | Last `hookEvent` = `SessionEnd` anywhere in file | `completed` |
| 3 | Last `hookEvent` = `Stop`, no subsequent `user` string message | `idle` |
| 4 | Last `type=user` is a plain string AND last timestamp < 30 min ago | `busy` |
| 5 | Last timestamp > 30 min ago | `stale` |
| 6 | No hookEvents, last timestamp < 30 min ago | `active-no-hooks` (needs further analysis) |

- [ ] **Step 1: Check file mtime for each file**

Run for each file path:
```bash
stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" FILEPATH
```
Record: mtime. Note which files are < 2 min old at time of running.

- [ ] **Step 2: Apply classification logic to each file**

For each of the 6 files, work through the priority list using data already collected in Task 2. Write out:
- Which rule matched (priority 1–6)
- Final classification
- Confidence level (high / medium / low) and why

Format the results as a table in-context:

```
FILE          PROJECT         LAST_TS              MTIME              LAST_HOOK    CLASSIFICATION   CONFIDENCE
<uuid>...     agent-dev...    2026-04-14 23:39     2026-04-14 23:39   Stop         idle             high
...
```

- [ ] **Step 3: Identify ambiguous cases**

Flag any session where:
- Two rules give conflicting signals
- The last hookEvent doesn't match what the timestamps suggest
- The file has no hookEvents at all

For each ambiguous case, note what additional information would resolve it.

---

## Task 4: Cross-Validate

**Goal:** For sessions that have both hook signals and timestamp signals, check whether they agree.

- [ ] **Step 1: Find sessions with rich hook data**

Among the 978 files, find 3 files that have SessionEnd in them (confirmed completed):
```bash
python3 -c "
import json, os, glob
files = glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True)
for f in files:
    try:
        content = open(f).read()
        if 'SessionEnd' in content:
            last_ts = None
            for line in content.strip().split('\n'):
                try:
                    obj = json.loads(line)
                    if obj.get('timestamp'): last_ts = obj['timestamp']
                except: pass
            print(last_ts, f)
    except: pass
" | sort | tail -5
```

- [ ] **Step 2: For each confirmed-completed session, verify classification**

Run the classification logic on these files. Expected result: priority 2 fires (last hookEvent = SessionEnd → `completed`). If it doesn't, record why.

- [ ] **Step 3: Find sessions with Stop as last hookEvent**

```bash
python3 -c "
import json, os, glob
files = glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True)
results = []
for f in files:
    try:
        hooks = []
        for line in open(f):
            try:
                obj = json.loads(line)
                if obj.get('type') == 'progress' and obj.get('data',{}).get('hookEvent'):
                    hooks.append(obj['data']['hookEvent'])
            except: pass
        if hooks and hooks[-1] == 'Stop':
            results.append(f)
    except: pass
print('\n'.join(results[:5]))
print(f'Total: {len(results)}')
"
```
Pick 2 of these. Classify them and verify confidence.

- [ ] **Step 4: Record cross-validation results**

For each validated session, note:
- Expected classification (from hook evidence)
- Achieved classification (from running rules)
- Agreement: yes / no / partial

---

## Task 5: Stress Test Edge Cases

**Goal:** Deliberately find sessions that challenge the classification logic.

- [ ] **Step 1: Find sessions with zero hookEvents (no hooks installed)**

```bash
python3 -c "
import json, os, glob
files = glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True)
no_hooks = []
for f in files[:200]:  # sample first 200 to avoid timeout
    try:
        has_hook = any(
            json.loads(l).get('type') == 'progress' and json.loads(l).get('data',{}).get('hookEvent')
            for l in open(f) if l.strip()
        )
        if not has_hook:
            no_hooks.append(f)
    except: pass
print(f'Files with no hookEvents: {len(no_hooks)} / 200 sampled')
print('\n'.join(no_hooks[:3]))
"
```
For each no-hook file found: what signals are available? Can we still classify? What's missing?

- [ ] **Step 2: Find very short sessions (≤ 3 entries)**

```bash
python3 -c "
import json, glob, os
files = glob.glob(os.path.expanduser('~/.claude/projects/**/*.jsonl'), recursive=True)
short = [(len(open(f).readlines()), f) for f in files if os.path.getsize(f) < 5000]
for n, f in sorted(short)[:5]: print(n, f)
"
```
Classify 2 of these. Note: do they have enough signal?

- [ ] **Step 3: Find largest files (potential long-running sessions)**

```bash
find ~/.claude/projects/ -name "*.jsonl" ! -path "*/subagents/*" | xargs ls -lS | head -5
```
For the largest file: read the last 20 lines. What is its classification? Does file size correlate with session length?

- [ ] **Step 4: Subagent file classification**

Pick the subagent file identified in Task 1. Run the same classification logic on it. Note: does it have `SessionStart`/`SessionEnd`? Is it fundamentally different or the same schema?

- [ ] **Step 5: Record stress test findings in-context**

For each edge case, note:
- What broke or surprised you
- Whether the classification logic handles it or needs a new rule
- Confidence: would this be a reliable signal in production?

---

## Task 6: Write Findings Report

**Goal:** Produce the experiment's deliverable — a structured findings report committed to the branch.

- [ ] **Step 1: Create the experiments directory**

```bash
mkdir -p /Users/harveyzhang96/Projects/agent-dev-pilot/.worktrees/exp-session-file-reader/docs/superpowers/experiments/
```

- [ ] **Step 2: Write the report**

Save to:
```
docs/superpowers/experiments/session-file-reader-findings.md
```

Use this structure:

```markdown
# Session File Reader — Experiment Findings

**Date:** 2026-04-14
**Branch:** exp/session-file-reader
**Experiment Goal:** Goal A — Feasibility

## Summary

[2-3 sentence verdict: is reading session files a viable way to detect session state without hooks?]

## Data Overview

[Total files, projects, date range, subagent files — from Task 1]

## Methodology

[Brief description of the classification logic used and the 6-session sample]

## Findings

### What Works Well
[Signals that reliably indicate session state]

### What Is Ambiguous
[Cases where the logic was uncertain or conflicting]

### What Fails
[Cases where classification logic gave wrong or insufficient signal]

### Surprise Findings
[Anything discovered that wasn't anticipated — e.g., subagent structure, no-hooks prevalence]

## Classification Logic Assessment

[Table: each rule from the spec, how often it fired, confidence level]

| Rule | Fired in N/6 samples | Confidence | Notes |
|------|----------------------|------------|-------|
| mtime < 2min → active | ... | ... | ... |
| ...

## Confidence Assessment

**Goal A verdict:** [Feasible / Partially feasible / Not feasible]

**Reasoning:** [2-4 sentences]

**Key limitation:** [The single biggest blocker to relying on files alone]

## Next Steps

- **Goal B (recommended if A is feasible):** [What to extract next — permission requests, AskUserQuestion]
- **Goal D:** [Latency comparison approach]
- **Integration path:** [What a Swift SessionFileWatcher would need to implement]

## TODO

- [ ] Goal C: LLM summarization of conversation content
```

- [ ] **Step 3: Commit the findings**

```bash
cd /Users/harveyzhang96/Projects/agent-dev-pilot/.worktrees/exp-session-file-reader
git add docs/superpowers/experiments/session-file-reader-findings.md
git commit -m "experiment: session file reader — Goal A findings"
```

---

## Execution Notes

- Tasks 1–5 are pure research: read files, record observations, draw conclusions. No code is written.
- If any bash command times out (large file set), reduce scope with `| head -N` or restrict to one project.
- The findings report in Task 6 is the only artifact. Everything else is in-context reasoning.
- When in doubt between two classifications, record both and note the ambiguity — that's a finding.
