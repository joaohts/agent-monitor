#!/usr/bin/env python3
"""Verify that remote Codex titles bind only to their live owning terminal."""

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "codex_terminal", Path(__file__).resolve().parents[1] / "hooks/codex-terminal.py",
)
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)


class CodexTerminalTests(unittest.TestCase):
    def session(self, thread="wanted", pid=101, **overrides):
        return dict(harness="codex", harness_session_id=thread, process_id=pid,
                    process_started=f"start {pid}", **overrides)

    def process(self, pid, fields):
        return f"start {pid}" if fields == "lstart=,comm=" else f"ttys{pid}"

    def test_selects_exact_thread_even_when_sessions_share_a_directory(self):
        rows = [self.session("other", 202, cwd="/same"),
                self.session(cwd="/same")]
        self.assertEqual(terminal.resolve_terminal("wanted", rows, self.process), "ttys101")

    def test_accepts_multiple_aliases_for_the_same_owner(self):
        rows = [self.session(), self.session()]
        self.assertEqual(terminal.resolve_terminal("wanted", rows, self.process), "ttys101")

    def test_rejects_ambiguous_live_terminals(self):
        self.assertEqual(terminal.resolve_terminal("wanted", [self.session(), self.session(pid=202)], self.process), "")

    def test_rejects_closed_missing_and_reused_processes(self):
        for rows, reader in [
            ([self.session(ended_at=1)], self.process),
            ([self.session()], lambda pid, fields: ""),
            ([self.session()], lambda pid, fields: "different start"),
            ([self.session(pid=0)], self.process),
            ([self.session(pid="101")], self.process),
            ([self.session("another thread")], self.process),
        ]:
            with self.subTest(rows=rows):
                self.assertEqual(terminal.resolve_terminal("wanted", rows, reader), "")

    def test_rejects_a_background_process_without_a_terminal(self):
        def reader(pid, fields):
            return self.process(pid, fields) if fields == "lstart=,comm=" else "??"
        self.assertEqual(terminal.resolve_terminal("wanted", [self.session()], reader), "")

    def test_unavailable_or_invalid_node_does_not_break_hooks(self):
        outcomes = [FileNotFoundError(), subprocess.TimeoutExpired("comms", 1),
                    subprocess.CompletedProcess([], 1, "", "offline"),
                    subprocess.CompletedProcess([], 0, "invalid", ""),
                    subprocess.CompletedProcess([], 0, "{}", "")]
        for outcome in outcomes:
            with self.subTest(outcome=outcome), patch.object(terminal.subprocess, "run") as run, patch("builtins.print") as output:
                if isinstance(outcome, Exception):
                    run.side_effect = outcome
                else:
                    run.return_value = outcome
                terminal.main("wanted")
                output.assert_not_called()


if __name__ == "__main__":
    unittest.main()
