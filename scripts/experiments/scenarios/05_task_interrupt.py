#!/usr/bin/env python3
"""
Scenario 05: Task interrupt via ESC key mid-task.
Key question: what hooks fire when Claude is interrupted?
Does Stop fire with stop_hook_active=True? Does SessionEnd fire?
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from pty_session import PTYSession

def run(log_file: str):
    session = PTYSession("05_task_interrupt", log_file)
    session.start()
    session.mark("SCENARIO_START")

    session.read_until(">", timeout=15)
    session.mark("TUI_READY")

    # Start a task that will definitely invoke tools (giving us time to interrupt)
    session.send(b"Read the file CLAUDE.md and count how many lines it has.\r")
    session.mark("PROMPT_SENT")

    # Wait for Claude to start using tools (PreToolUse should fire)
    session.read_until("CLAUDE", timeout=25)
    session.drain(seconds=2)
    session.mark("TASK_IN_PROGRESS")

    # Send ESC to interrupt
    session.send(b"\x1b")  # ESC key
    session.mark("INTERRUPT_SENT")

    # Wait to observe what happens
    session.drain(seconds=6)
    session.mark("SCENARIO_COMPLETE")

    session.stop(flush_wait=6)

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_05.jsonl"
    run(log_file)
