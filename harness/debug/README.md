# Debug Environment — Reference

## Log directory

```
/Users/harveyzhang96/Projects/agent-dev-pilot/tmp/logs/
```

(gitignored; persists across sessions until manually cleaned)

## Sources

| File | Source | Type | Capture mechanism |
|---|---|---|---|
| `app.log` | macOS unified log for AgentPilot process | 常驻 (needs app running) | `log stream --predicate 'process == "AgentPilot"'` |
| `http.log` | curl requests to localhost:9876 | 任务驱动型 | written by verify-logs.sh |
| `test.log` | `swift test` output | 任务驱动型 | written by run-tests.sh |

## Start / stop capture

```bash
# Start (Mode A — independent from app launch)
bash harness/debug/start-log-capture.sh

# Stop
bash harness/debug/stop-log-capture.sh
```

**Prerequisite:** start the app first with `make run`. Then start log capture.

## Verify

```bash
bash harness/debug/verify-logs.sh
```

Expected output when healthy:
```
[OK]   app.log — 有新内容，时间戳格式正确
[OK]   http.log — 有内容，时间戳格式正确
[SKIP] test.log — (任务驱动型)
```

## Run tests

```bash
# All tests
bash harness/debug/run-tests.sh

# Single target
bash harness/debug/run-tests.sh --filter SessionStateReducerTests
```

Output goes to `tmp/logs/test.log` and terminal.

## Query patterns

```bash
# Tail app log (live)
tail -f tmp/logs/app.log

# Filter for specific keyword
grep -i "error\|fail" tmp/logs/app.log

# HTTP request history
cat tmp/logs/http.log

# Test failures only
grep -E "FAIL|error" tmp/logs/test.log

# Cross-layer timeline (by timestamp)
sort -m \
  <(grep -v "^Filtering\|^Timestamp" tmp/logs/app.log) \
  tmp/logs/http.log \
  | head -50
```

## Timestamp format

- `app.log`: `YYYY-MM-DD HH:MM:SS.ffffff  AgentPilot[PID:TID] ...` (macOS log stream compact style)
- `http.log`: ISO 8601 strict: `YYYY-MM-DDTHH:MM:SS.000Z`
- `test.log`: plain `swift test` output with embedded timestamps in results

## Token location

```
~/.agentpilot/token
```

Used by verify-logs.sh for auth-gated endpoint tests.

## Port

Default: `9876`. Override with `AGENTPILOT_PORT` env var.
