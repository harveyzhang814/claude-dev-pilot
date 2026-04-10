#!/usr/bin/env python3
"""
verify_e2e.py — Real-time HookStreamDetector e2e verifier.

Polls hook_logs + sessions DB every 0.5s, runs the Python reducer
in parallel, and compares predicted state vs actual session status.

Usage:
    python3 scripts/verify_e2e.py [--watch] [--session SESSION_ID]

Options:
    --watch     Keep running and stream new events as they arrive
    --session   Filter to a specific session_id prefix
    --reset     Clear seen events and start fresh (don't re-process old rows)
"""
import argparse
import json
import sqlite3
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

DB_PATH = Path.home() / "Library/Application Support/AgentDevPilot/db.sqlite"

# ── Python replica of SessionStateReducer ────────────────────────────────────

PERMISSION_NOTIFICATION_TYPES = {"permission_prompt", "elicitation_dialog"}


@dataclass
class MachineState:
    status: str = "idle"        # idle | busy | waiting | completed | stale
    stop_window_active: bool = False
    db_session_exists: bool = False


@dataclass
class ReducerResult:
    state: MachineState
    actions: list[str]


def classify(row: dict) -> Optional[dict]:
    """Turn a hook_logs row into a typed event dict."""
    name = row.get("hook_event_name", "")
    sid = row.get("session_id", "")
    raw = json.loads(row.get("raw_payload", "{}"))

    if name == "SessionStart":
        return {"type": "sessionStart", "sessionId": sid}
    elif name == "SessionEnd":
        return {"type": "sessionEnd", "sessionId": sid}
    elif name == "UserPromptSubmit":
        return {"type": "userPromptSubmit", "sessionId": sid}
    elif name == "PreToolUse":
        tool = raw.get("tool_name", "")
        if not tool:
            return None
        return {"type": "preToolUse", "sessionId": sid, "toolName": tool}
    elif name == "PostToolUse":
        tool = raw.get("tool_name", "")
        if not tool:
            return None
        return {"type": "postToolUse", "sessionId": sid, "toolName": tool}
    elif name == "Notification":
        nt = raw.get("notification_type", "")
        if nt in PERMISSION_NOTIFICATION_TYPES:
            kind = "permissionPrompt"
        elif nt == "idle_prompt":
            kind = "idlePrompt"
        else:
            kind = "other"
        return {"type": "notification", "sessionId": sid, "kind": kind}
    elif name == "Stop":
        return {"type": "stop", "sessionId": sid}
    return None


def reduce(state: MachineState, event: dict) -> ReducerResult:
    """Python replica of SessionStateReducer.reduce() — all 13 rules."""
    t = event["type"]
    actions = []

    # Rule 1: sessionStart → idle
    if t == "sessionStart":
        new_state = MachineState(status="idle", stop_window_active=False,
                                 db_session_exists=True)
        actions.append("upsertSession(idle)")
        if state.stop_window_active:
            actions.append("cancelStopWindow")
        return ReducerResult(new_state, actions)

    # Rule 2: sessionEnd → completed
    if t == "sessionEnd":
        new_state = MachineState(status="completed",
                                 stop_window_active=False,
                                 db_session_exists=state.db_session_exists)
        if state.stop_window_active:
            actions.append("cancelStopWindow")
        actions.append("updateStatus(completed)")
        return ReducerResult(new_state, actions)

    # Rule 3: userPromptSubmit → busy
    if t == "userPromptSubmit":
        new_state = MachineState(status="busy",
                                 stop_window_active=state.stop_window_active,
                                 db_session_exists=state.db_session_exists)
        actions += ["updateStatus(busy)", "dismissPriorEvents",
                    "insertEvent(promptSubmitted/background)"]
        return ReducerResult(new_state, actions)

    # Rule 4: preToolUse(AskUserQuestion) → waiting
    if t == "preToolUse" and event.get("toolName") == "AskUserQuestion":
        new_state = MachineState(status="waiting",
                                 stop_window_active=state.stop_window_active,
                                 db_session_exists=state.db_session_exists)
        actions += ["updateStatus(waiting)", "insertEvent(permissionNeeded/action)"]
        return ReducerResult(new_state, actions)

    # Rules 5-7: notification(permissionPrompt)
    if t == "notification" and event.get("kind") == "permissionPrompt":
        if state.stop_window_active:
            # Rule 5
            new_state = MachineState(status="waiting",
                                     stop_window_active=False,
                                     db_session_exists=state.db_session_exists)
            actions += ["cancelStopWindow", "updateStatus(waiting)",
                        "insertEvent(permissionNeeded/action)"]
            return ReducerResult(new_state, actions)
        elif state.status != "waiting":
            # Rule 6
            new_state = MachineState(status="waiting",
                                     stop_window_active=False,
                                     db_session_exists=state.db_session_exists)
            actions += ["updateStatus(waiting)", "insertEvent(permissionNeeded/action)"]
            return ReducerResult(new_state, actions)
        else:
            # Rule 7: no-op (idempotent)
            return ReducerResult(state, [])

    # Rule 8: postToolUse where waiting → busy
    if t == "postToolUse" and state.status == "waiting":
        new_state = MachineState(status="busy",
                                 stop_window_active=state.stop_window_active,
                                 db_session_exists=state.db_session_exists)
        actions.append("updateStatus(busy)")
        return ReducerResult(new_state, actions)

    # Rule 9: stop → stopWindowActive=true
    if t == "stop":
        new_state = MachineState(status=state.status,
                                 stop_window_active=True,
                                 db_session_exists=state.db_session_exists)
        actions.append("startStopWindow")
        return ReducerResult(new_state, actions)

    # Rule 10: stopWindowExpired → idle
    if t == "stopWindowExpired":
        new_state = MachineState(status="idle",
                                 stop_window_active=False,
                                 db_session_exists=state.db_session_exists)
        actions += ["updateStatus(idle)", "insertEvent(agentStopped/review)"]
        return ReducerResult(new_state, actions)

    # Rule 11: preToolUse (non-AQU) where idle|waiting → busy
    if t == "preToolUse" and state.status in ("idle", "waiting"):
        new_state = MachineState(status="busy",
                                 stop_window_active=state.stop_window_active,
                                 db_session_exists=state.db_session_exists)
        actions.append("updateStatus(busy)")
        return ReducerResult(new_state, actions)

    # Rules 12-13: no-op
    return ReducerResult(state, [])


# ── DB helpers ────────────────────────────────────────────────────────────────

def get_conn():
    return sqlite3.connect(str(DB_PATH), check_same_thread=False)


def fetch_hook_logs_since(conn, since_id: Optional[str], session_filter: Optional[str]) -> list[dict]:
    """Fetch hook_logs rows ordered by received_at, after since_id."""
    cur = conn.cursor()
    base = """
        SELECT id, received_at, hook_event_name, session_id,
               notification_type, raw_payload
        FROM hook_logs
    """
    conditions = []
    params = []
    if since_id:
        conditions.append("received_at > (SELECT received_at FROM hook_logs WHERE id = ?)")
        params.append(since_id)
    if session_filter:
        conditions.append("session_id LIKE ?")
        params.append(session_filter + "%")
    if conditions:
        base += " WHERE " + " AND ".join(conditions)
    base += " ORDER BY received_at ASC"
    cur.execute(base, params)
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def fetch_session_status(conn, session_id: str) -> Optional[str]:
    cur = conn.cursor()
    cur.execute("SELECT status FROM sessions WHERE id = ?", (session_id,))
    row = cur.fetchone()
    return row[0] if row else None


def fetch_recent_events(conn, session_id: str, limit: int = 3) -> list[dict]:
    cur = conn.cursor()
    cur.execute("""
        SELECT type, title, attention_tier, timestamp
        FROM events WHERE session_id = ?
        ORDER BY timestamp DESC LIMIT ?
    """, (session_id, limit))
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


# ── Display ───────────────────────────────────────────────────────────────────

COLORS = {
    "green": "\033[92m", "red": "\033[91m", "yellow": "\033[93m",
    "cyan": "\033[96m", "gray": "\033[90m", "bold": "\033[1m",
    "reset": "\033[0m",
}


def c(color, text):
    return f"{COLORS[color]}{text}{COLORS['reset']}"


STATUS_COLOR = {
    "idle": "green", "busy": "yellow", "waiting": "red",
    "completed": "gray", "stale": "gray",
}


def status_colored(s):
    return c(STATUS_COLOR.get(s, "reset"), s)


def print_event_row(event: dict, predicted_state: MachineState, actions: list[str],
                    actual_status: Optional[str], is_stop_virtual: bool = False):
    t = event["type"]
    tool = event.get("toolName", "")
    kind = event.get("kind", "")
    sid_short = event["sessionId"][-8:]

    # Event label
    if tool:
        label = f"{t}({tool})"
    elif kind and kind != "other":
        label = f"{t}({kind})"
    else:
        label = t

    if is_stop_virtual:
        label = c("gray", f"[2s] {label}")

    predicted = predicted_state.status
    match = actual_status == predicted if actual_status else None

    status_str = status_colored(predicted)
    if actual_status:
        if match:
            actual_str = c("green", f"✓ {actual_status}")
        else:
            actual_str = c("red", f"✗ actual={actual_status}")
    else:
        actual_str = c("gray", "no session")

    action_str = c("gray", ", ".join(actions)) if actions else ""

    print(f"  [{c('cyan', sid_short)}] {label:<42} → {status_str:<20} {actual_str}")
    if action_str:
        print(f"              {action_str}")


# ── Main loop ─────────────────────────────────────────────────────────────────

def run(watch: bool, session_filter: Optional[str], reset: bool):
    if not DB_PATH.exists():
        print(c("red", f"DB not found: {DB_PATH}"))
        print("Start the app first with: make run")
        sys.exit(1)

    conn = get_conn()
    states: dict[str, MachineState] = {}
    seen_ids: set[str] = set()
    last_id: Optional[str] = None
    stop_window_sessions: set[str] = set()  # sessions awaiting stopWindowExpired

    # If reset, start from the latest row
    if reset:
        cur = conn.cursor()
        cur.execute("SELECT id FROM hook_logs ORDER BY received_at DESC LIMIT 1")
        row = cur.fetchone()
        if row:
            last_id = row[0]
            print(c("gray", f"Skipping existing events, watching from now..."))

    print(c("bold", "\n═══ HookStreamDetector E2E Verifier ═══"))
    print(c("gray", f"DB: {DB_PATH}"))
    print(c("gray", f"Session filter: {session_filter or 'all'}"))
    print(c("gray", "─" * 70))

    mismatches = 0
    total_events = 0

    try:
        while True:
            rows = fetch_hook_logs_since(conn, last_id, session_filter)

            if rows:
                for row in rows:
                    row_id = row["id"]
                    if row_id in seen_ids:
                        continue
                    seen_ids.add(row_id)
                    last_id = row_id

                    event = classify(row)
                    if not event:
                        continue

                    sid = event["sessionId"]
                    state = states.get(sid, MachineState())
                    result = reduce(state, event)
                    states[sid] = result.state
                    total_events += 1

                    # Check if stop window just started
                    if "startStopWindow" in result.actions:
                        stop_window_sessions.add(sid)

                    # Check actual DB state (slight delay to allow writes)
                    time.sleep(0.1)
                    actual = fetch_session_status(conn, sid)

                    print_event_row(event, result.state, result.actions, actual)

                    if actual and actual != result.state.status:
                        mismatches += 1

            # Check stop window expiry for pending sessions
            expired = set()
            for sid in stop_window_sessions:
                actual = fetch_session_status(conn, sid)
                if actual == "idle":
                    # stopWindowExpired fired
                    virtual = {"type": "stopWindowExpired", "sessionId": sid}
                    result = reduce(states.get(sid, MachineState()), virtual)
                    states[sid] = result.state
                    expired.add(sid)
                    recent_events = fetch_recent_events(conn, sid, 1)
                    has_ready = any(e["type"] == "agentStopped" for e in recent_events)
                    ready_str = c("green", "✓ agentStopped event found") if has_ready else c("red", "✗ no agentStopped event")
                    print_event_row(virtual, result.state, result.actions, actual, is_stop_virtual=True)
                    print(f"              {ready_str}")
            stop_window_sessions -= expired

            if not watch:
                break

            time.sleep(0.5)

    except KeyboardInterrupt:
        pass

    print(c("gray", "\n─" * 70))
    print(c("bold", "Summary"))
    print(f"  Total events processed: {total_events}")
    if mismatches == 0:
        print(c("green", f"  State mismatches: 0 ✓"))
    else:
        print(c("red", f"  State mismatches: {mismatches} ✗"))

    # Show final session states
    print(c("bold", "\nFinal predicted states:"))
    for sid, st in sorted(states.items()):
        actual = fetch_session_status(conn, sid)
        match_sym = c("green", "✓") if actual == st.status else c("red", "✗")
        print(f"  {sid[-12:]}  predicted={status_colored(st.status):20}  actual={status_colored(actual or 'unknown')}  {match_sym}")


def main():
    parser = argparse.ArgumentParser(description="HookStreamDetector e2e verifier")
    parser.add_argument("--watch", action="store_true",
                        help="Keep running and stream new events")
    parser.add_argument("--session", metavar="SID",
                        help="Filter to session ID prefix")
    parser.add_argument("--reset", action="store_true",
                        help="Skip existing events, only watch new ones")
    args = parser.parse_args()
    run(watch=args.watch, session_filter=args.session, reset=args.reset)


if __name__ == "__main__":
    main()
