#!/bin/bash
# Agent Dev Pilot — Claude Code hook helper script
# Reads hook event JSON from stdin and forwards to the local HTTP server.
#
# SECURITY: Use --data-binary @- to pipe stdin directly to curl.
# Do NOT capture stdin into a variable (shell expansion risk).
# head -c 65536 enforces 64KB max payload at the source.
TOKEN=$(cat ~/.agent-dev-pilot/token 2>/dev/null)
cat | head -c 65536 | curl -s -X POST http://127.0.0.1:9876/event \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @- \
  --max-time 2 \
  >/dev/null 2>&1 &
# Fire-and-forget: if app is not running, event is silently lost.
# This is intentional — hooks must never block Claude Code's workflow.
