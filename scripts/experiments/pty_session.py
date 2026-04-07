#!/usr/bin/env python3
"""
PTYSession: base class for Claude Code PTY experiments.

Handles:
- PTY fork and process lifecycle
- Per-scenario log isolation via AGENT_DEV_PILOT_EXP_LOG env var
- TUI output reading with timeout (pattern-based, not sleep-based)
- Clean shutdown with 6s flush wait for async hook writes
- atexit cleanup to avoid zombie processes

Usage:
    session = PTYSession("my_scenario", "/tmp/hook_exp_01.jsonl")
    session.start()
    session.mark("STEP_1")
    session.read_until(">", timeout=10)     # wait for TUI prompt
    session.send(b"hello\r")
    session.read_until("response", timeout=20)
    session.stop()
"""

import atexit
import json
import os
import pty
import select
import signal
import sys
import time
from typing import Optional


class PTYSession:
    FLUSH_WAIT_SECONDS = 6.0  # Wait for async hook writes after claude exits

    def __init__(self, scenario_name: str, log_file: str):
        self.scenario_name = scenario_name
        self.log_file = log_file
        self.pid: Optional[int] = None
        self.master_fd: Optional[int] = None
        self._stopped = False

    def mark(self, label: str):
        """Write a marker event to the log file for later analysis."""
        entry = json.dumps({
            "_marker": label,
            "_ts": time.time(),
            "_scenario": self.scenario_name,
        })
        with open(self.log_file, "a") as f:
            f.write(entry + "\n")

    def start(self, args: Optional[list] = None):
        """
        Fork a PTY and exec claude with the experiment log file set.
        Registers cleanup via atexit so SIGTERM is sent even on crash.
        """
        args = args or ["claude"]
        env = {**os.environ, "AGENT_DEV_PILOT_EXP_LOG": self.log_file}

        self.pid, self.master_fd = pty.fork()

        if self.pid == 0:
            # Child: replace process with claude
            os.execvpe("claude", args, env)
            sys.exit(1)

        atexit.register(self._cleanup)

    def send(self, data: bytes):
        """Write bytes to the PTY (simulates keyboard input)."""
        if self.master_fd is None:
            raise RuntimeError("Session not started")
        os.write(self.master_fd, data)

    def read_until(self, pattern: str, timeout: float = 30.0) -> bytes:
        """
        Read PTY output until `pattern` appears or timeout is reached.
        Returns all accumulated bytes regardless of whether pattern was found.
        This is the correct approach vs. sleep-based timing.
        """
        buf = b""
        deadline = time.time() + timeout
        pattern_bytes = pattern.encode()

        while time.time() < deadline:
            try:
                r, _, _ = select.select([self.master_fd], [], [], 0.2)
            except (ValueError, OSError):
                break
            if r:
                try:
                    chunk = os.read(self.master_fd, 4096)
                    buf += chunk
                    if pattern_bytes in buf:
                        return buf
                except OSError:
                    break

        return buf

    def drain(self, seconds: float = 2.0) -> bytes:
        """Read all PTY output for a fixed duration. Useful after sending input."""
        buf = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                r, _, _ = select.select([self.master_fd], [], [], 0.1)
            except (ValueError, OSError):
                break
            if r:
                try:
                    buf += os.read(self.master_fd, 4096)
                except OSError:
                    break
        return buf

    def stop(self, flush_wait: float = FLUSH_WAIT_SECONDS):
        """
        Send /exit and wait for async hook writes to complete.
        Claude hooks are fire-and-forget shell scripts; they need ~6s to finish.
        """
        if self._stopped:
            return
        try:
            os.write(self.master_fd, b"/exit\r")
        except OSError:
            pass
        time.sleep(flush_wait)
        self._cleanup()

    def _cleanup(self):
        """Send SIGTERM to child process. Safe to call multiple times."""
        if self._stopped:
            return
        self._stopped = True
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
            except (OSError, ChildProcessError):
                pass
            self.pid = None
        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = None
