#!/usr/bin/env bash
# start-log-capture.sh — Start background log capture for AgentPilot
# Usage: bash harness/debug/start-log-capture.sh
# Run from project root.
#
# Mode A (独立启动): 与应用进程分离，可独立开关。
# 调用前请先用 make run 启动 app。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/tmp/logs"
PID_FILE="$PROJECT_ROOT/tmp/log-capture.pid"

mkdir -p "$LOG_DIR"

# ── Stop any existing capture first ──────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing log capture (PID $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$PID_FILE"
fi

# Kill any stale log stream process for AgentPilot
pkill -f "log stream.*AgentPilot" 2>/dev/null || true
sleep 0.3

# ── Start app.log capture via macOS unified logging ───────────────────────────
# macOS app launched with 'open' routes stdout → unified log (oslog).
# 'log stream' taps the system log and filters to AgentPilot process.
# Lines already carry timestamps in format: YYYY-MM-DD HH:MM:SS.ffffff+ZZZZ
# which satisfies ISO 8601 (space separator variant, per RFC 3339).
echo "Starting log stream for AgentPilot process → $LOG_DIR/app.log"
log stream \
    --predicate 'process == "AgentPilot"' \
    --style compact \
    >> "$LOG_DIR/app.log" 2>&1 &

LOG_PID=$!
echo $LOG_PID > "$PID_FILE"

sleep 0.5

if kill -0 "$LOG_PID" 2>/dev/null; then
    echo "  log stream started (PID $LOG_PID)"
else
    echo "  ERROR: log stream failed to start"
    rm -f "$PID_FILE"
    exit 1
fi

# ── Instructions ──────────────────────────────────────────────────────────────
echo ""
echo "Log capture running."
echo "  app.log  → $LOG_DIR/app.log"
echo "  http.log → written by verify-logs.sh (curl requests)"
echo "  test.log → written by run-tests.sh (swift test output)"
echo ""
echo "Stop with: bash harness/debug/stop-log-capture.sh"
echo "Verify with: bash harness/debug/verify-logs.sh"
