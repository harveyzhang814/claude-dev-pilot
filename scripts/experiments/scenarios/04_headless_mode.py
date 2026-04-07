#!/usr/bin/env python3
"""
Scenario 04: claude -p (headless/print) mode — baseline comparison.
Key question: which hooks fire in -p mode? Confirms PostToolUse/AskUserQuestion
does NOT fire (known prior result — this is baseline documentation).
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

def run(log_file: str):
    env = {**os.environ, "AGENT_DEV_PILOT_EXP_LOG": log_file}

    def mark(label):
        entry = json.dumps({"_marker": label, "_ts": time.time(), "_scenario": "04_headless_mode"})
        with open(log_file, "a") as f:
            f.write(entry + "\n")

    mark("SCENARIO_START")

    result = subprocess.run(
        ["claude", "-p", "What is 2 + 2? Reply in exactly one word."],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )

    mark("PROCESS_COMPLETE")
    time.sleep(6)  # Flush async hook writes
    mark("SCENARIO_COMPLETE")

if __name__ == "__main__":
    log_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hook_exp_04.jsonl"
    run(log_file)
