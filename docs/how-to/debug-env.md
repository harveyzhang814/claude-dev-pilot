# How to use the debug logging environment

## What this covers

AgentPilot is a macOS app with an embedded HTTP server (Hummingbird) and SQLite database (GRDB). Since the database and server are in-process, there is no separate db or server process to tail. All log output from the running app flows through macOS unified logging (the same system Console.app reads).

Three log sources are captured:

| Source | When it produces output |
|---|---|
| `app.log` | Continuously while the app is running |
| `http.log` | When verify-logs.sh sends test curl requests |
| `test.log` | When you run `swift test` |

## Quick start

```bash
# 1. Start the app (must be running as a proper .app bundle)
make run

# 2. Start log capture in a separate terminal
bash harness/debug/start-log-capture.sh

# 3. Verify everything is wired up
bash harness/debug/verify-logs.sh
# → All OK? You're ready to debug.

# 4. Watch the app log
tail -f tmp/logs/app.log
```

## Why `log stream` (not tail on a file)

When the app is launched via `make run` (which calls `open AgentPilot.app`), macOS routes the process's stdout and swift-log output into the **unified logging system** — not to a terminal. You cannot `tail` a plain file because there isn't one. `log stream` is the standard macOS mechanism for tapping this output.

This means:
- Log capture **must** run in a background process (`log stream ... >> app.log &`)
- If you kill the `log stream` process, capture stops — the app keeps running
- Restart capture any time with `start-log-capture.sh`

## Stopping and restarting capture

```bash
# Stop
bash harness/debug/stop-log-capture.sh

# Restart (e.g., after app relaunch)
bash harness/debug/start-log-capture.sh
```

After `make run` relaunches the app, restart capture because the old `log stream` process may have drifted.

## Debugging workflow

**Problem in a specific layer?**

1. Check `app.log` for the app/server layer: `grep -i error tmp/logs/app.log`
2. Check `http.log` for HTTP-level failures: `cat tmp/logs/http.log`
3. Run tests to isolate logic bugs: `bash harness/debug/run-tests.sh`

**Need a cross-layer timeline?**

Both `app.log` and `http.log` carry timestamps. You can sort them together:

```bash
sort -m \
  <(grep -v "^Filtering\|^Timestamp" tmp/logs/app.log) \
  tmp/logs/http.log
```

## Cleaning up logs

```bash
rm -f tmp/logs/*.log
```

Logs are gitignored (`tmp/`) so they will never be committed.

## Adding a new log source

1. Decide whether the source is **常驻** (always running) or **任务驱动型** (only produces output during a task).
2. Add capture to `start-log-capture.sh` (or a new helper script).
3. Add a corresponding check block to `verify-logs.sh`.
4. Re-run `verify-logs.sh` to confirm it works.

## Verify script frequency

Run `verify-logs.sh`:
- At the start of any debug session
- After restarting the app
- After any structural change to log capture setup

It exits non-zero if any 常驻 source is missing or stale, so it's safe to use as a gate in scripts.
