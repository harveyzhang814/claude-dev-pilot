#!/usr/bin/env python3
"""
Scenario 08: Task interrupt via ESC — verify stop_hook_active value.

Previous run (scenario 05) only waited 6s after ESC before stop(). The Stop
hook fires asynchronously and needs ~2-3s to write; cleanup was killing it too
quickly. This scenario waits 30s after ESC for natural Stop/SessionEnd.

Key question: when Claude is interrupted mid-task via ESC, what fires?
  A) Stop with stop_hook_active=True  (hook was active during stop)
  B) Stop with stop_hook_active=False (hook was not active)
  C) SessionEnd fires immediately after Stop
  D) SessionEnd never fires (session stays open after interrupt)

Strategy: use time-based waits only (no pattern matching — ANSI codes break it).
Give Claude a multi-file task to ensure tool calls are in flight when we interrupt.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from pty_session import PTYSession


def run(log_file: str):
    session = PTYSession("08_interrupt_esc", log_file)
    session.start()
    session.mark("SCENARIO_START")

    # Wait for TUI to be ready
    session.drain(seconds=15)
    session.mark("TUI_READY")

    # Give Claude a multi-step task that definitely uses tools (Read + Bash)
    # Long enough that it will be mid-execution when we interrupt
    session.send(
        b"Please count all the Swift source files in the Sources/ directory, "
        b"read CLAUDE.md, and tell me how many lines it has and "
        b"which SPM targets are defined. Take your time.\r"
    )
    session.mark("PROMPT_SENT")

    # Wait for Claude to start executing tools (PreToolUse should have fired)
    # 20s is enough for initial tool calls to begin
    session.drain(seconds=20)
    session.mark("TASK_IN_PROGRESS")

    # Send ESC to interrupt Claude mid-task
    session.send(b"\x1b")
    session.mark("INTERRUPT_SENT")

    # CRITICAL: wait long enough for Stop hook to fire and hook script to write.
    # Stop hook fires within ~2s of ESC; hook script (notify.sh) needs ~2s more.
    # SessionEnd may or may not follow. Wait 30s to capture everything.
    session.drain(seconds=30)
    session.mark("POST_INTERRUPT_HOOKS_CAPTURED")

    session.stop(flush_wait=8)


if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_08.jsonl"
    run(log_file)
