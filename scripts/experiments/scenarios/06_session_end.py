#!/usr/bin/env python3
"""
Scenario 06: Explicit /exit → SessionEnd.
Key question: does SessionEnd always fire on /exit? What's the exact sequence?
Is it: Stop → SessionEnd, or SessionEnd → Stop, or only one fires?
"""
import sys
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from pty_session import PTYSession

def run(log_file: str):
    session = PTYSession("06_session_end", log_file)
    session.start()
    session.mark("SCENARIO_START")

    session.read_until(">", timeout=15)
    session.mark("TUI_READY")

    # Do a minimal exchange to get a real session history
    session.send(b"Say the single word: hello\r")
    session.mark("PROMPT_SENT")
    session.read_until("hello", timeout=20)
    session.mark("RESPONSE_RECEIVED")
    session.drain(seconds=3)

    # Explicit exit — do NOT use session.stop() here
    # We want to observe what fires naturally
    session.send(b"/exit\r")
    session.mark("EXIT_SENT")

    # Wait for SessionEnd hook + 6s flush (no stop() call — process exits naturally)
    time.sleep(8)
    session.mark("SCENARIO_COMPLETE")

    session._cleanup()

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_06.jsonl"
    run(log_file)
