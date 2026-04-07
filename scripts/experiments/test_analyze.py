#!/usr/bin/env python3
"""
Unit tests for analyze.py.
Run: cd scripts/experiments && python3 -m pytest test_analyze.py -v
"""
import json
import os
import tempfile
from pathlib import Path

import pytest

import sys
sys.path.insert(0, str(Path(__file__).parent))


# ── Fixture data ──────────────────────────────────────────────────────────────

SIMPLE_TASK_EVENTS = [
    {"hook_event_name": "SessionStart",      "session_id": "aaa", "_captured_at": "2026-04-07T00:00:01Z"},
    {"hook_event_name": "UserPromptSubmit",  "session_id": "aaa", "_captured_at": "2026-04-07T00:00:02Z", "permission_mode": "default"},
    {"hook_event_name": "PreToolUse",        "session_id": "aaa", "_captured_at": "2026-04-07T00:00:03Z", "tool_name": "Bash"},
    {"hook_event_name": "PostToolUse",       "session_id": "aaa", "_captured_at": "2026-04-07T00:00:04Z", "tool_name": "Bash"},
    {"hook_event_name": "Stop",              "session_id": "aaa", "_captured_at": "2026-04-07T00:00:05Z"},
    {"hook_event_name": "Notification",      "session_id": "aaa", "_captured_at": "2026-04-07T00:00:06Z", "notification_type": "idle_prompt"},
]

AQU_EVENTS = [
    {"hook_event_name": "SessionStart",      "session_id": "bbb", "_captured_at": "2026-04-07T00:01:00Z"},
    {"hook_event_name": "UserPromptSubmit",  "session_id": "bbb", "_captured_at": "2026-04-07T00:01:01Z"},
    {"hook_event_name": "PreToolUse",        "session_id": "bbb", "_captured_at": "2026-04-07T00:01:02Z", "tool_name": "AskUserQuestion"},
    {"hook_event_name": "Notification",      "session_id": "bbb", "_captured_at": "2026-04-07T00:01:03Z", "notification_type": "permission_prompt"},
]

MIXED_EVENTS = SIMPLE_TASK_EVENTS + AQU_EVENTS


@pytest.fixture
def simple_task_jsonl(tmp_path):
    path = tmp_path / "simple.jsonl"
    path.write_text("\n".join(json.dumps(e) for e in SIMPLE_TASK_EVENTS) + "\n")
    return str(path)


@pytest.fixture
def mixed_jsonl(tmp_path):
    path = tmp_path / "mixed.jsonl"
    path.write_text("\n".join(json.dumps(e) for e in MIXED_EVENTS) + "\n")
    return str(path)


# ── Tests: parse_jsonl ────────────────────────────────────────────────────────

def test_parse_jsonl_returns_all_events(simple_task_jsonl):
    from analyze import parse_jsonl
    events = parse_jsonl(simple_task_jsonl)
    assert len(events) == 6


def test_parse_jsonl_skips_invalid_json(tmp_path):
    from analyze import parse_jsonl
    path = tmp_path / "bad.jsonl"
    path.write_text('{"valid": true}\nNOT JSON\n{"also": "valid"}\n')
    events = parse_jsonl(str(path))
    assert len(events) == 2


def test_parse_jsonl_handles_empty_file(tmp_path):
    from analyze import parse_jsonl
    path = tmp_path / "empty.jsonl"
    path.write_text("")
    events = parse_jsonl(str(path))
    assert events == []


def test_parse_jsonl_handles_blank_lines(tmp_path):
    from analyze import parse_jsonl
    path = tmp_path / "blank.jsonl"
    path.write_text('{"a": 1}\n\n{"b": 2}\n\n')
    events = parse_jsonl(str(path))
    assert len(events) == 2


# ── Tests: extract_sequences ──────────────────────────────────────────────────

def test_extract_sequences_groups_by_session_id():
    from analyze import extract_sequences
    sessions = extract_sequences(MIXED_EVENTS)
    assert "aaa" in sessions
    assert "bbb" in sessions
    assert len(sessions["aaa"]) == 6
    assert len(sessions["bbb"]) == 4


def test_extract_sequences_skips_marker_events():
    from analyze import extract_sequences
    events_with_markers = [
        {"_marker": "EXP_START", "_ts": 1.0},
        {"hook_event_name": "SessionStart", "session_id": "ccc", "_captured_at": "2026-04-07T00:00:00Z"},
    ]
    sessions = extract_sequences(events_with_markers)
    assert "ccc" in sessions
    assert len(sessions["ccc"]) == 1
    assert sessions["ccc"][0].hook_event_name == "SessionStart"


def test_extract_sequences_sorts_by_captured_at():
    from analyze import extract_sequences
    out_of_order = [
        {"hook_event_name": "Stop",          "session_id": "ddd", "_captured_at": "2026-04-07T00:00:05Z"},
        {"hook_event_name": "SessionStart",  "session_id": "ddd", "_captured_at": "2026-04-07T00:00:01Z"},
        {"hook_event_name": "PreToolUse",    "session_id": "ddd", "_captured_at": "2026-04-07T00:00:03Z", "tool_name": "Bash"},
    ]
    sessions = extract_sequences(out_of_order)
    seq = sessions["ddd"]
    assert seq[0].hook_event_name == "SessionStart"
    assert seq[1].hook_event_name == "PreToolUse"
    assert seq[2].hook_event_name == "Stop"


def test_extract_sequences_skips_events_without_session_id():
    from analyze import extract_sequences
    events = [
        {"hook_event_name": "SessionStart"},  # no session_id
        {"hook_event_name": "SessionStart", "session_id": "eee", "_captured_at": "2026-04-07T00:00:01Z"},
    ]
    sessions = extract_sequences(events)
    assert list(sessions.keys()) == ["eee"]


# ── Tests: infer_state ────────────────────────────────────────────────────────

def test_infer_state_user_prompt_submit_is_busy():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="UserPromptSubmit")
    assert infer_state(evt, []) == "busy"


def test_infer_state_pre_tool_use_is_busy():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="PreToolUse", tool_name="Bash")
    assert infer_state(evt, []) == "busy"


def test_infer_state_notification_idle_prompt_is_idle():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="Notification", notification_type="idle_prompt")
    assert infer_state(evt, []) == "idle"


def test_infer_state_notification_permission_prompt_is_waiting():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="Notification", notification_type="permission_prompt")
    assert infer_state(evt, []) == "waiting"


def test_infer_state_stop_alone_is_idle():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="Stop")
    assert infer_state(evt, []) == "idle"


def test_infer_state_stop_after_permission_prompt_is_waiting():
    from analyze import HookEvent, infer_state
    prior = [HookEvent(hook_event_name="Notification", notification_type="permission_prompt")]
    evt = HookEvent(hook_event_name="Stop")
    assert infer_state(evt, prior) == "waiting"


def test_infer_state_session_start_is_idle():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="SessionStart")
    assert infer_state(evt, []) == "idle"


def test_infer_state_session_end_is_completed():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="SessionEnd")
    assert infer_state(evt, []) == "completed"


def test_infer_state_post_tool_use_bash_returns_none():
    from analyze import HookEvent, infer_state
    evt = HookEvent(hook_event_name="PostToolUse", tool_name="Bash")
    assert infer_state(evt, []) is None


# ── Tests: generate_feature_table ────────────────────────────────────────────

def test_generate_feature_table_contains_required_sections():
    from analyze import generate_feature_table
    records = [
        {"hook_event_name": "UserPromptSubmit", "tool_name": "", "notification_type": "", "inferred_state": "busy", "session_id": "aaa", "captured_at": ""},
        {"hook_event_name": "Notification",     "tool_name": "", "notification_type": "idle_prompt", "inferred_state": "idle", "session_id": "aaa", "captured_at": ""},
        {"hook_event_name": "Notification",     "tool_name": "", "notification_type": "permission_prompt", "inferred_state": "waiting", "session_id": "bbb", "captured_at": ""},
    ]
    table = generate_feature_table(records)
    assert "| Hook |" in table
    assert "UserPromptSubmit" in table
    assert "idle_prompt" in table
    assert "permission_prompt" in table
    assert "busy" in table
    assert "idle" in table
    assert "waiting" in table


def test_generate_feature_table_counts_occurrences():
    from analyze import generate_feature_table
    records = [
        {"hook_event_name": "UserPromptSubmit", "tool_name": "", "notification_type": "", "inferred_state": "busy", "session_id": "x", "captured_at": ""}
        for _ in range(3)
    ]
    table = generate_feature_table(records)
    assert "3" in table


# ── Tests: full pipeline ──────────────────────────────────────────────────────

def test_full_pipeline_simple_task(simple_task_jsonl):
    from analyze import parse_jsonl, extract_sequences, analyze_state_transitions
    events = parse_jsonl(simple_task_jsonl)
    sessions = extract_sequences(events)
    records = analyze_state_transitions(sessions)

    states = {r["inferred_state"] for r in records}
    assert "busy" in states
    assert "idle" in states


def test_full_pipeline_aqu_sequence_produces_waiting():
    from analyze import extract_sequences, analyze_state_transitions
    sessions = extract_sequences(AQU_EVENTS)
    records = analyze_state_transitions(sessions)
    states = {r["inferred_state"] for r in records}
    assert "waiting" in states


def test_full_pipeline_with_real_fixture():
    from analyze import parse_jsonl, extract_sequences, analyze_state_transitions, generate_feature_table
    fixture = str(Path(__file__).parent / "data" / "fixtures" / "real_178_events.jsonl")
    if not Path(fixture).exists():
        pytest.skip("Fixture file not present — run Task 1 first")

    events = parse_jsonl(fixture)
    sessions = extract_sequences(events)
    records = analyze_state_transitions(sessions)
    table = generate_feature_table(records)

    assert len(sessions) >= 2
    assert len(records) >= 10
    assert "| Hook |" in table
