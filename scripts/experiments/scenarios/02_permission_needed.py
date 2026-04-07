#!/usr/bin/env python3
"""
Scenario 02: Permission needed (Bash blocked in acceptEdits mode) + user approves.
Key question: full hook sequence for permission approval flow.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from pty_session import PTYSession

def run(log_file: str):
    session = PTYSession("02_permission_needed", log_file)
    session.start(args=["claude", "--permission-mode", "acceptEdits"])
    session.mark("SCENARIO_START")

    session.read_until(">", timeout=15)
    session.mark("TUI_READY")

    session.send(b"Run the bash command: echo HOOK_PERM_TEST_02\r")
    session.mark("PROMPT_SENT")

    # Wait for permission dialog (Claude will say "Allow" or show a dialog)
    output = session.read_until("Allow", timeout=30)
    session.mark("PERMISSION_DIALOG_APPEARED" if b"Allow" in output else "PERMISSION_TIMEOUT")
    session.drain(seconds=2)

    # Approve
    session.send(b"y\r")
    session.mark("PERMISSION_APPROVED")

    # Wait for command output
    session.read_until("HOOK_PERM_TEST_02", timeout=20)
    session.mark("BASH_OUTPUT_RECEIVED")
    session.drain(seconds=5)
    session.mark("SCENARIO_COMPLETE")

    session.stop(flush_wait=6)

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_02.jsonl"
    run(log_file)
