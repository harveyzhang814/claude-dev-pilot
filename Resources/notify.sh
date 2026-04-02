#!/bin/bash
# Agent Dev Pilot — Claude Code hook helper script
# Reads hook event JSON from stdin and forwards to the local HTTP server.
# Injects tty and terminal_app fields for terminal window focus feature.
#
# SECURITY: Use --data-binary @- to pipe stdin directly to curl.
# Do NOT capture stdin into a variable (shell expansion risk).
# head -c 65536 enforces 64KB max payload at the source.
TOKEN=$(cat ~/.agent-dev-pilot/token 2>/dev/null)
TTY_PATH=$(tty 2>/dev/null || echo "")
TERM_PROG="${TERM_PROGRAM:-}"

if command -v jq &>/dev/null; then
    # Inject tty and terminal_app into the JSON payload
    cat | head -c 65536 \
      | jq --arg tty "$TTY_PATH" --arg terminal_app "$TERM_PROG" \
           '. + {tty: $tty, terminal_app: $terminal_app}' \
      | curl -s -X POST http://127.0.0.1:9876/event \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          --data-binary @- \
          --max-time 2 \
          >/dev/null 2>&1 &
else
    # jq not available — forward as-is; terminal focus won't work but events still flow
    cat | head -c 65536 | curl -s -X POST http://127.0.0.1:9876/event \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      --data-binary @- \
      --max-time 2 \
      >/dev/null 2>&1 &
fi
# Fire-and-forget: if app is not running, event is silently lost.
# This is intentional — hooks must never block Claude Code's workflow.
