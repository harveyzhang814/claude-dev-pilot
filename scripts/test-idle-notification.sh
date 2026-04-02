#!/usr/bin/env bash
# Test script for feat/idle-notification
# Usage: ./scripts/test-idle-notification.sh
#
# Scenarios covered:
#   1. Idle path  — Stop only → session goes idle → "Claude is ready" notification
#   2. Waiting path — Stop + permission_prompt within 2s → session stays waiting, NO idle notification
#   3. Notification first — permission_prompt then Stop → waiting (order-independent)
#   4. idle_prompt — treated like Stop, not Notification → resolves to idle
#   5. Rapid multiple idle sessions — verify each gets its own notification
#
# Prerequisites:
#   - App is running (make run)
#   - TOKEN env var set, or ~/.agent-dev-pilot/token readable

set -euo pipefail

TOKEN="${TOKEN:-$(cat ~/.agent-dev-pilot/token 2>/dev/null || echo '')}"
BASE="http://localhost:9876"
SID_PREFIX="test-idle-$(date +%s)"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: No token found. Run the app first (make run) or set TOKEN env var." >&2
  exit 1
fi

post() {
  local payload="$1"
  curl -s -X POST "$BASE/event" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

health() {
  curl -s "$BASE/health"
}

wait_window() {
  echo "  ... waiting 2.5s for stop window to expire ..."
  sleep 2.5
}

separator() {
  echo ""
  echo "────────────────────────────────────────"
  echo "$1"
  echo "────────────────────────────────────────"
}

# Verify app is up
separator "0. Health check"
HEALTH=$(health)
echo "  $HEALTH"
if ! echo "$HEALTH" | grep -q '"status":"running"'; then
  echo "ERROR: App is not running. Start it with: make run" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────
# SCENARIO 1: Idle path
# Expected: session transitions to idle, "Claude is ready" notification fires
# ─────────────────────────────────────────────────────────
separator "1. Idle path (Stop only → idle notification)"
SID="${SID_PREFIX}-s1"

echo "  → SessionStart"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/my-project",
  "hook_event_name": "SessionStart",
  "message": "",
  "source": "startup"
}'

echo ""
echo "  → PreToolUse (to put session in running state)"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/my-project",
  "hook_event_name": "PreToolUse",
  "message": "Running bash",
  "title": "bash"
}'

echo ""
echo "  → Stop (no Notification follows)"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/my-project",
  "hook_event_name": "Stop",
  "message": "Task completed"
}'

wait_window
echo "  EXPECT: notification titled 'my-project' with body 'Claude is ready'"

# ─────────────────────────────────────────────────────────
# SCENARIO 2: Permission prompt after Stop — should stay waiting, NO idle notification
# ─────────────────────────────────────────────────────────
separator "2. Waiting path (Stop then permission_prompt within 2s)"
SID="${SID_PREFIX}-s2"

echo "  → SessionStart"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/another-project",
  "hook_event_name": "SessionStart",
  "message": "",
  "source": "startup"
}'

echo ""
echo "  → PreToolUse"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/another-project",
  "hook_event_name": "PreToolUse",
  "message": "Running tool",
  "title": "bash"
}'

echo ""
echo "  → Stop"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/another-project",
  "hook_event_name": "Stop",
  "message": ""
}'

echo ""
sleep 0.5
echo "  → Notification (permission_prompt) — within 2s of Stop"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/another-project",
  "hook_event_name": "Notification",
  "message": "Allow tool: bash",
  "notification_type": "permission_prompt"
}'

wait_window
echo "  EXPECT: permission notification shown, NO 'Claude is ready' notification"

# ─────────────────────────────────────────────────────────
# SCENARIO 3: Notification before Stop (order independence)
# ─────────────────────────────────────────────────────────
separator "3. Order-independent waiting (Notification first, then Stop)"
SID="${SID_PREFIX}-s3"

echo "  → SessionStart"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj3",
  "hook_event_name": "SessionStart",
  "message": "",
  "source": "startup"
}'

echo ""
echo "  → Notification (permission_prompt) arrives FIRST"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj3",
  "hook_event_name": "Notification",
  "message": "Allow read file?",
  "notification_type": "permission_prompt"
}'

echo ""
sleep 0.3
echo "  → Stop arrives 0.3s later"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj3",
  "hook_event_name": "Stop",
  "message": ""
}'

wait_window
echo "  EXPECT: session is waiting, permission notification shown, NO idle notification"

# ─────────────────────────────────────────────────────────
# SCENARIO 4: idle_prompt treated as Stop-like → resolves to idle
# ─────────────────────────────────────────────────────────
separator "4. idle_prompt treated as Stop-like → idle notification"
SID="${SID_PREFIX}-s4"

echo "  → SessionStart"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj4",
  "hook_event_name": "SessionStart",
  "message": "",
  "source": "startup"
}'

echo ""
echo "  → Stop"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj4",
  "hook_event_name": "Stop",
  "message": ""
}'

echo ""
sleep 0.5
echo "  → Notification (idle_prompt) — also Stop-like"
post '{
  "session_id": "'"$SID"'",
  "cwd": "/Users/test/proj4",
  "hook_event_name": "Notification",
  "message": "Claude is idle",
  "notification_type": "idle_prompt"
}'

wait_window
echo "  EXPECT: 'Claude is ready' notification for proj4 (idle_prompt does NOT block idle resolution)"

# ─────────────────────────────────────────────────────────
# SCENARIO 5: Multiple concurrent sessions each get own idle notification
# ─────────────────────────────────────────────────────────
separator "5. Multiple concurrent idle sessions"

for i in 1 2 3; do
  SID="${SID_PREFIX}-multi-$i"
  PROJECT="project-$i"
  echo "  → Session $i: Start + PreToolUse + Stop"
  post '{
    "session_id": "'"$SID"'",
    "cwd": "/Users/test/'"$PROJECT"'",
    "hook_event_name": "SessionStart",
    "message": "",
    "source": "startup"
  }' > /dev/null
  post '{
    "session_id": "'"$SID"'",
    "cwd": "/Users/test/'"$PROJECT"'",
    "hook_event_name": "PreToolUse",
    "message": "tool",
    "title": "bash"
  }' > /dev/null
  post '{
    "session_id": "'"$SID"'",
    "cwd": "/Users/test/'"$PROJECT"'",
    "hook_event_name": "Stop",
    "message": ""
  }' > /dev/null
done

wait_window
echo "  EXPECT: 3 separate 'Claude is ready' notifications (one per project)"

echo ""
separator "All scenarios sent. Check the notification center."
echo "  Summary:"
echo "    ✓ Scenario 1: 'Claude is ready' for my-project"
echo "    ✓ Scenario 2: permission notification only (no idle notification)"
echo "    ✓ Scenario 3: permission notification only (order-independent)"
echo "    ✓ Scenario 4: 'Claude is ready' for proj4 (idle_prompt is Stop-like)"
echo "    ✓ Scenario 5: 3x 'Claude is ready' (multi-session)"
echo ""
