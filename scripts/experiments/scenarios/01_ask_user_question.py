#!/usr/bin/env python3
"""
Scenario 01: AskUserQuestion — what fires after user answers?

Key question: after PreToolUse/AskUserQuestion + Notification(permission_prompt),
when the user answers, does:
  A) PostToolUse/AskUserQuestion fire?
  B) UserPromptSubmit fire with the answer text?
  C) Something else entirely?

Run: python3 scenarios/01_ask_user_question.py /tmp/hook_exp_01.jsonl
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from pty_session import PTYSession


def run(log_file: str):
    session = PTYSession("01_ask_user_question", log_file)
    session.start()
    session.mark("SCENARIO_START")

    # Wait for TUI ready (the ">" prompt indicator or welcome text)
    output = session.read_until(">", timeout=15)
    if b">" not in output:
        session.mark("TUI_TIMEOUT")
        session.stop()
        return
    session.mark("TUI_READY")

    # Ask Claude to invoke AskUserQuestion
    prompt = (
        b"Use the ask_user_question tool to ask me: what is your favorite color? "
        b"Provide options: Blue, Red, Green, Purple. "
        b"After I answer, tell me which color I chose.\r"
    )
    session.send(prompt)
    session.mark("PROMPT_SENT")

    # Wait for the AskUserQuestion dialog to appear.
    # The TUI renders the question text + options in a box.
    # "favorite color" should appear in the dialog.
    output = session.read_until("favorite color", timeout=40)
    if b"favorite color" not in output:
        session.mark("DIALOG_NOT_APPEARED")
        session.stop()
        return
    session.mark("DIALOG_APPEARED")

    # Give hooks time to fire: PreToolUse/AskUserQuestion + Notification(permission_prompt)
    session.drain(seconds=3)
    session.mark("PRE_ANSWER_HOOKS_CAPTURED")

    # Send the answer "Blue"
    session.send(b"Blue\r")
    session.mark("ANSWER_SENT")

    # Wait for Claude to confirm it received the answer
    output = session.read_until("Blue", timeout=25)
    session.mark("RESPONSE_RECEIVED" if b"Blue" in output else "RESPONSE_TIMEOUT")

    # Drain to capture PostToolUse/AskUserQuestion (if it fires) or UserPromptSubmit
    session.drain(seconds=5)
    session.mark("POST_ANSWER_HOOKS_CAPTURED")

    session.stop(flush_wait=6)


if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_01.jsonl"
    run(log_file)
