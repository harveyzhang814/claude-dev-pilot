#!/bin/bash
# Hook capture script — logs all incoming Claude Code hook payloads to JSONL
# Set AGENT_DEV_PILOT_EXP_LOG env var to write to a scenario-specific file.
# Defaults to /tmp/hook_capture.jsonl for regular (non-experiment) use.

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
LOG_FILE="${AGENT_DEV_PILOT_EXP_LOG:-/tmp/hook_capture.jsonl}"

if command -v jq &>/dev/null; then
    jq -c --arg ts "$TIMESTAMP" '. + {_captured_at: $ts}' >> "$LOG_FILE" 2>/dev/null
else
    # Fallback: raw append with timestamp prefix
    echo -n "{\"_captured_at\":\"$TIMESTAMP\",\"_raw\":" >> "$LOG_FILE"
    cat >> "$LOG_FILE"
    echo "}" >> "$LOG_FILE"
fi

exit 0
