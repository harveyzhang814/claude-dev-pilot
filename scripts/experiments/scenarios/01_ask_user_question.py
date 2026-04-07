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

    # Wait for TUI ready — drain until output settles (15s max)
    session.drain(seconds=15)
    session.mark("TUI_READY")

    # Ask Claude to invoke AskUserQuestion (no options — free-text reply is simpler to detect)
    prompt = (
        b"Use the ask_user_question tool to ask me exactly this question: "
        b"'What is your favorite color?' "
        b"After I answer, tell me which color I chose.\r"
    )
    session.send(prompt)
    session.mark("PROMPT_SENT")

    # Wait 50s for Claude to call AskUserQuestion and show the dialog.
    # TUI output contains ANSI codes — avoid pattern matching, use time-based wait.
    session.drain(seconds=50)
    session.mark("PRE_ANSWER_HOOKS_CAPTURED")

    # Send the answer
    session.send(b"Blue\r")
    session.mark("ANSWER_SENT")

    # Wait for Claude to process the answer and respond (30s)
    session.drain(seconds=30)
    session.mark("POST_ANSWER_HOOKS_CAPTURED")

    session.stop(flush_wait=6)


if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_01.jsonl"
    run(log_file)
