"""Check the popup toggle without opening a window or changing user settings."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else (
    Path(__file__).resolve().parent / "build/permission-popup")


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / "config.json"
        self.env = dict(os.environ, PERMISSION_POPUP_CONFIG=str(self.config))

    def run_popup(self, host, payload=b"not json"):
        result = subprocess.run([str(BINARY), "--host", host], input=payload,
                                capture_output=True, env=self.env, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_disabled_returns_no_decision_for_every_host(self):
        self.config.write_text('{"enabled":false}')
        payload = json.dumps({"hook_event_name": "PermissionRequest",
                              "cwd": "/tmp", "tool_name": "Bash",
                              "tool_input": {"command": "echo preview"}}).encode()
        for host in ("codex", "claude", "dsh"):
            self.assertEqual(self.run_popup(host), b"")
            self.assertEqual(self.run_popup(host, payload), b"")

    def test_missing_or_invalid_settings_keep_existing_behavior(self):
        for contents in (None, "bad json", "{}", '{"enabled":0}',
                         '{"enabled":"false"}', '{"enabled":null}',
                         '{"enabled":true}'):
            with self.subTest(contents=contents):
                if contents is not None:
                    self.config.write_text(contents)
                response = json.loads(self.run_popup("dsh"))
                self.assertEqual(response["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_changes_take_effect_on_next_invocation(self):
        for enabled in (False, True, False):
            self.config.write_text(json.dumps({"enabled": enabled, "other": "preserved"}))
            output = self.run_popup("dsh")
            self.assertEqual(bool(output), enabled)


if __name__ == "__main__":
    unittest.main()
