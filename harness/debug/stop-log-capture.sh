#!/usr/bin/env bash
# stop-log-capture.sh — Stop background log capture for AgentPilot
# Usage: bash harness/debug/stop-log-capture.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PID_FILE="$PROJECT_ROOT/tmp/log-capture.pid"

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "Stopped log capture (PID $PID)"
    else
        echo "PID $PID is not running"
    fi
    rm -f "$PID_FILE"
else
    echo "No PID file found; killing any stale log stream processes..."
    pkill -f "log stream.*AgentPilot" 2>/dev/null && echo "Killed stale log stream" || echo "No stale processes found"
fi
