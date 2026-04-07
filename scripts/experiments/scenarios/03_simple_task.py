#!/usr/bin/env python3
"""
Scenario 03: Simple task with no tools → completion.
Key question: do Stop and Notification(idle_prompt) always co-occur? Which is first?
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from pty_session import PTYSession

def run(log_file: str):
    session = PTYSession("03_simple_task", log_file)
    session.start()
    session.mark("SCENARIO_START")

    session.read_until(">", timeout=15)
    session.mark("TUI_READY")

    session.send(b"What is 2 + 2? Reply in exactly one word.\r")
    session.mark("PROMPT_SENT")

    # Wait for Claude to finish (response will contain "four" or "4")
    session.read_until("our", timeout=25)  # matches "four" or "Four"
    session.mark("RESPONSE_RECEIVED")

    # Drain to capture Stop + Notification hooks
    session.drain(seconds=5)
    session.mark("SCENARIO_COMPLETE")

    session.stop(flush_wait=6)

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_03.jsonl"
    run(log_file)
