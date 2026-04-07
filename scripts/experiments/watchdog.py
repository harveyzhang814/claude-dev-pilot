#!/usr/bin/env python3
"""
Watchdog for experiment runner.

Monitors data/raw/ for progress. If no file grows for STALL_SECS, kills
the runner + all claude children, restores settings.json, and exits with
a non-zero code so the caller knows to restart.

Usage:
    python3 watchdog.py &          # start in background
    python3 watchdog.py --once     # check once and exit
"""
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent
RAW_DATA_DIR = SCRIPTS_DIR / "data" / "raw"
SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
SETTINGS_BACKUP = Path.home() / ".claude" / "settings.json.bak_experiment_runner"

STALL_SECS = 180       # declare stuck if no file grows for 3 minutes
CHECK_INTERVAL = 15    # check every 15 seconds


def get_runner_pid() -> int | None:
    try:
        result = subprocess.run(
            ["pgrep", "-f", "runner.py"],
            capture_output=True, text=True
        )
        pids = [int(p) for p in result.stdout.strip().split() if p]
        return pids[0] if pids else None
    except Exception:
        return None


def get_newest_file_size() -> tuple[str, int]:
    """Return (path, size) of most recently modified file in data/raw/."""
    files = [f for f in RAW_DATA_DIR.iterdir() if f.suffix == ".jsonl"]
    if not files:
        return ("", 0)
    newest = max(files, key=lambda f: f.stat().st_mtime)
    return (str(newest), newest.stat().st_size)


def restore_settings():
    if SETTINGS_BACKUP.exists():
        shutil.copy2(SETTINGS_BACKUP, SETTINGS_PATH)
        SETTINGS_BACKUP.unlink()
        print("[watchdog] settings.json restored ✓")


def kill_runner_and_claude():
    """Kill runner.py and all its claude child processes."""
    runner_pid = get_runner_pid()
    if not runner_pid:
        print("[watchdog] runner not found — already dead")
        return

    # Find all children of runner
    try:
        result = subprocess.run(
            ["pgrep", "-P", str(runner_pid)],
            capture_output=True, text=True
        )
        child_pids = [int(p) for p in result.stdout.strip().split() if p]
    except Exception:
        child_pids = []

    # Kill children first (close their PTYs)
    for pid in child_pids:
        try:
            os.kill(pid, signal.SIGKILL)
            print(f"[watchdog] killed child {pid}")
        except (OSError, ProcessLookupError):
            pass

    # Kill runner
    try:
        os.kill(runner_pid, signal.SIGKILL)
        print(f"[watchdog] killed runner {runner_pid}")
    except (OSError, ProcessLookupError):
        pass

    time.sleep(2)
    restore_settings()


def watch():
    print(f"[watchdog] monitoring {RAW_DATA_DIR} (stall timeout={STALL_SECS}s)")
    last_path, last_size = get_newest_file_size()
    last_change = time.time()

    while True:
        time.sleep(CHECK_INTERVAL)

        runner_pid = get_runner_pid()
        if not runner_pid:
            print("[watchdog] runner exited — done")
            return 0

        path, size = get_newest_file_size()
        if path != last_path or size != last_size:
            elapsed = time.time() - last_change
            print(f"[watchdog] progress: {Path(path).name} {last_size}→{size} bytes (+{elapsed:.0f}s)")
            last_path, last_size = path, size
            last_change = time.time()
        else:
            stalled = time.time() - last_change
            print(f"[watchdog] no progress for {stalled:.0f}s (stall limit {STALL_SECS}s)")
            if stalled > STALL_SECS:
                print(f"[watchdog] STALL DETECTED — killing runner")
                kill_runner_and_claude()
                return 1

    return 0


if __name__ == "__main__":
    sys.exit(watch())
