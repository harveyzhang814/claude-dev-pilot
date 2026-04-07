#!/usr/bin/env python3
"""
Scenario 07: AskUserQuestion — free-text answer to confirm PostToolUse fires.

Previous run (scenario 01) sent "Blue\r" but Claude created a dialog with
selectable OPTIONS (arrow-key navigation), so the text input was ignored and
the tool hung. This scenario explicitly instructs Claude to ask WITHOUT options
so the TUI renders a plain text input box — typing works directly.

Key question: after user submits free-text answer, does PostToolUse/AskUserQuestion fire?

Expected hook sequence:
  SessionStart
  UserPromptSubmit
  PreToolUse/AskUserQuestion     ← waiting
  Notification(permission_prompt)
  [user types answer]
  PostToolUse/AskUserQuestion    ← busy  (THIS is what we want to confirm)
  Stop
  SessionEnd  (after /exit)
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from pty_session import PTYSession


def run(log_file: str):
    session = PTYSession("07_ask_user_question_freetext", log_file)
    session.start()
    session.mark("SCENARIO_START")

    session.drain(seconds=15)
    session.mark("TUI_READY")

    # Explicitly request NO options — forces free-text TUI input box
    prompt = (
        b"Use the ask_user_question tool to ask me this question: "
        b"'What is your favorite color?' "
        b"IMPORTANT: do NOT include any options list — leave the options array empty "
        b"so I can type a free-text answer. "
        b"After I answer, tell me what color I chose.\r"
    )
    session.send(prompt)
    session.mark("PROMPT_SENT")

    # Wait for Claude to call the tool and TUI to show the text input box (~30s)
    session.drain(seconds=35)
    session.mark("DIALOG_APPEARED")

    # Submit free-text answer — works when TUI shows a text input (not option list)
    session.send(b"Blue\r")
    session.mark("ANSWER_SENT")

    # Wait for PostToolUse/AskUserQuestion + Claude's follow-up response (30s)
    session.drain(seconds=30)
    session.mark("POST_ANSWER_HOOKS_CAPTURED")

    session.stop(flush_wait=8)


if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_07.jsonl"
    run(log_file)
