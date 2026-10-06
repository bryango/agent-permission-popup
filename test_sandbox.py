"""Headless contract tests for ``permission-popup``.

These tests only cover input rejection and request paths that must return no
decision.  They never send a payload eligible to open the native AppKit popup:
Codex auto-review and Claude auto-mode for a supported tool require a live GUI
session and are covered by the binary's Swift self-test instead.

Pass a compiled binary as the sole positional argument, or build it at
``build/permission-popup`` before running this module directly.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DEFAULT_BINARY = Path(__file__).with_name("build") / "permission-popup"
BINARY = Path(sys.argv[1]) if len(sys.argv) == 2 else DEFAULT_BINARY
if len(sys.argv) == 2:
    del sys.argv[1]


def clean_environment():
    """Prevent local popup configuration from changing a headless test."""
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("PERMISSION_POPUP", "CODEX_PERMISSION"))
    }


class PermissionPopupSandboxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError(f"compiled binary not found: {BINARY}")

    def run_popup(self, payload=b"", *arguments):
        return subprocess.run(
            [str(BINARY), *arguments],
            input=payload,
            capture_output=True,
            env=clean_environment(),
            timeout=5,
        )

    def assert_skipped(self, payload, *arguments):
        result = self.run_popup(json.dumps(payload).encode(), *arguments)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"")

    @staticmethod
    def claude_payload(**overrides):
        payload = {
            "hook_event_name": "PreToolUse",
            "cwd": "/tmp/sandbox-test",
            "tool_name": "Bash",
            "tool_input": {"command": "true"},
        }
        payload.update(overrides)
        return payload

    @staticmethod
    def codex_payload(transcript_path, **overrides):
        payload = {
            "hook_event_name": "PermissionRequest",
            "session_id": "sandbox-session",
            "turn_id": "sandbox-turn",
            "transcript_path": str(transcript_path),
            "cwd": "/tmp/sandbox-test",
            "tool_name": "Bash",
            "tool_input": {"command": "true"},
        }
        payload.update(overrides)
        return payload

    def test_self_test_succeeds(self):
        result = self.run_popup(b"", "--self-test")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_invalid_options_reject_without_stdout(self):
        for arguments in (
            ("--host", "invalid"),
            ("--host", "codex", "--host", "claude"),
            ("--unknown",),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_popup(b"", *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_malformed_json_skips(self):
        result = self.run_popup(b"not json")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b"")

    def test_claude_non_auto_modes_skip_repeatedly(self):
        modes = ("default", "plan", "acceptEdits", "bypassPermissions", "dontAsk", "unknown")
        for mode in modes:
            for _ in range(2 if mode in {"default", "plan"} else 1):
                with self.subTest(mode=mode):
                    self.assert_skipped(self.claude_payload(permission_mode=mode), "--host", "claude")

    def test_claude_missing_and_null_permission_modes_skip(self):
        missing = self.claude_payload()
        self.assert_skipped(missing, "--host", "claude")
        self.assert_skipped(self.claude_payload(permission_mode=None), "--host", "claude")

    def test_claude_wrong_event_skips_even_in_auto_mode(self):
        self.assert_skipped(
            self.claude_payload(hook_event_name="PermissionRequest", permission_mode="auto"),
            "--host",
            "claude",
        )

    def test_claude_auto_unsupported_tools_skip(self):
        for tool_name in ("Read", "MCP"):
            with self.subTest(tool_name=tool_name):
                self.assert_skipped(
                    self.claude_payload(tool_name=tool_name, permission_mode="auto"),
                    "--host",
                    "claude",
                )

    def test_codex_wrong_event_skips(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "rollout.jsonl"
            transcript.write_text("")
            self.assert_skipped(
                self.codex_payload(transcript, hook_event_name="PreToolUse"))

    def test_codex_user_and_missing_turns_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            transcript = Path(directory) / "rollout.jsonl"
            transcript.write_text(
                json.dumps({
                    "type": "turn_context",
                    "payload": {
                        "turn_id": "sandbox-turn",
                        "approvals_reviewer": "user",
                    },
                }) + "\n"
            )
            self.assert_skipped(self.codex_payload(transcript))
            self.assert_skipped(self.codex_payload(transcript, turn_id="missing-turn"))


if __name__ == "__main__":
    unittest.main()
