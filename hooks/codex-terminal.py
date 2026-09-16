#!/usr/bin/env python3
"""Resolve an attached Codex session's terminal through the local comms node."""

import json
import re
import subprocess
import sys


def read_process(pid, fields):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", fields],
        capture_output=True, text=True, timeout=0.5,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def resolve_terminal(session_id, sessions, process_info=read_process):
    owners = set()
    for session in sessions:
        if not isinstance(session, dict):
            continue
        if (session.get("harness") != "codex"
                or session.get("harness_session_id") != session_id
                or session.get("ended_at") is not None):
            continue
        pid = session.get("process_id")
        started = session.get("process_started")
        if type(pid) is not int or pid <= 1 or not isinstance(started, str) or not started:
            continue
        if process_info(pid, "lstart=,comm=") != started:
            continue
        tty = process_info(pid, "tty=")
        if re.fullmatch(r"ttys[0-9]+", tty):
            owners.add((pid, started, tty))
    # A thread attached to several terminals has no unique tab to rename.
    return next(iter(owners))[2] if len(owners) == 1 else ""


def main(session_id):
    try:
        result = subprocess.run(
            ["comms", "sessions", "--json"],
            capture_output=True, text=True, timeout=1,
        )
        if result.returncode:
            return
        sessions = json.loads(result.stdout)
        if not isinstance(sessions, list):
            return
        tty = resolve_terminal(session_id, sessions)
        if tty:
            print(tty)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        # Monitoring is optional; an unavailable node must not block a hook.
        return


if __name__ == "__main__" and len(sys.argv) == 2:
    main(sys.argv[1])
