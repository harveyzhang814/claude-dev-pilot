#!/usr/bin/env python3
"""
Unified experiment runner.

Runs all scenario scripts sequentially. Manages ~/.claude/settings.json:
- Backs up before adding capture hooks
- Restores via atexit, even if runner crashes

Usage:
    cd scripts/experiments
    python3 runner.py                        # run all scenarios
    python3 runner.py scenarios/01_*.py      # run specific scenarios
"""
import atexit
import importlib.util
import json
import multiprocessing
import os
import shutil
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).parent
CAPTURE_SH = str(SCRIPTS_DIR / "capture.sh")
SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
SETTINGS_BACKUP = Path.home() / ".claude" / "settings.json.bak_experiment_runner"
RAW_DATA_DIR = SCRIPTS_DIR / "data" / "raw"

SCENARIO_TIMEOUT = 300  # 5 minutes max per scenario


# ── Settings management ───────────────────────────────────────────────────────

def backup_and_patch_settings():
    """
    Backup settings.json, then add PreToolUse/PostToolUse capture hooks.
    Registers restore via atexit so it runs even on crash.
    """
    if SETTINGS_PATH.exists():
        shutil.copy2(SETTINGS_PATH, SETTINGS_BACKUP)
        print(f"[runner] Settings backed up → {SETTINGS_BACKUP}")
    else:
        print("[runner] WARNING: ~/.claude/settings.json not found")
        return

    settings = json.loads(SETTINGS_PATH.read_text())
    hooks = settings.setdefault("hooks", {})

    for hook_name in ("PreToolUse", "PostToolUse"):
        entries = hooks.setdefault(hook_name, [])
        already = any(
            CAPTURE_SH in str(h.get("hooks", [{}])[0].get("command", ""))
            for h in entries
        )
        if not already:
            entries.append({
                "matcher": "",
                "hooks": [{"type": "command", "command": CAPTURE_SH}],
            })

    SETTINGS_PATH.write_text(json.dumps(settings, indent=2))
    print("[runner] Capture hooks added to settings.json")

    # Register restore — called on normal exit AND on crash/exception
    atexit.register(_restore_settings)


def _restore_settings():
    if SETTINGS_BACKUP.exists():
        shutil.copy2(SETTINGS_BACKUP, SETTINGS_PATH)
        SETTINGS_BACKUP.unlink()
        print(f"\n[runner] Settings restored from backup ✓")


# ── Scenario execution ────────────────────────────────────────────────────────

def _run_in_subprocess(scenario_path: str, log_file: str):
    """Target function for multiprocessing — runs in a child process."""
    spec = importlib.util.spec_from_file_location("scenario", scenario_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.run(log_file)


def run_scenario(scenario_path: str, log_file: str) -> str:
    """
    Run a scenario in a child process with a hard timeout.
    Returns "ok", "timeout", or "error:<msg>".
    The child process is SIGKILL'd if it exceeds SCENARIO_TIMEOUT.
    """
    p = multiprocessing.Process(target=_run_in_subprocess, args=(scenario_path, log_file))
    p.start()
    p.join(timeout=SCENARIO_TIMEOUT)
    if p.is_alive():
        p.kill()
        p.join(timeout=5)
        return f"timeout:{SCENARIO_TIMEOUT}s"
    if p.exitcode != 0:
        return f"error:exit_code={p.exitcode}"
    return "ok"


def analyze_results(log_files: list[str]):
    """Run analyze.py on all collected log files."""
    output = str(SCRIPTS_DIR / "data" / "feature_table.md")
    print(f"\n[runner] Running analyze.py on {len(log_files)} log files...")

    sys.path.insert(0, str(SCRIPTS_DIR))
    from analyze import main as analyze_main
    analyze_main(log_files, output)
    print(f"[runner] Feature table written to {output}")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    RAW_DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Determine which scenarios to run
    if len(sys.argv) > 1:
        scenario_paths = [Path(p) for p in sys.argv[1:]]
    else:
        scenario_paths = sorted(
            (SCRIPTS_DIR / "scenarios").glob("[0-9][0-9]_*.py")
        )

    print(f"[runner] Running {len(scenario_paths)} scenarios\n")

    # Setup: backup settings and add capture hooks
    backup_and_patch_settings()

    results = {}
    log_files = []

    for scenario_path in scenario_paths:
        name = scenario_path.stem
        timestamp = int(time.time())
        log_file = str(RAW_DATA_DIR / f"{name}_{timestamp}.jsonl")

        print(f"[{name}] Starting...")
        start = time.time()

        try:
            status = run_scenario(str(scenario_path), log_file)
            elapsed = time.time() - start
            ok = status == "ok"
            results[name] = {"status": status, "log": log_file, "elapsed_s": round(elapsed, 1)}
            if ok:
                log_files.append(log_file)
            icon = "✓" if ok else "⚠"
            print(f"[{name}] {icon} {status} ({elapsed:.1f}s) → {log_file}\n")
        except Exception as e:
            elapsed = time.time() - start
            results[name] = {"status": f"error:{e}", "elapsed_s": round(elapsed, 1)}
            print(f"[{name}] ✗ ERROR: {e} ({elapsed:.1f}s)\n")

    # Summary
    print("\n=== RUNNER SUMMARY ===")
    ok_count = sum(1 for r in results.values() if r["status"] == "ok")
    for name, result in results.items():
        icon = "✓" if result["status"] == "ok" else "✗"
        print(f"  {icon} {name}: {result['status']} ({result['elapsed_s']}s)")
    print(f"\n{ok_count}/{len(results)} scenarios succeeded")

    # Analyze results
    if log_files:
        analyze_results(log_files)
    else:
        print("\n[runner] No successful scenarios — skipping analysis")


if __name__ == "__main__":
    main()
