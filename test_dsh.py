"""Headless DSH contracts and byte-for-byte Codex/Claude regressions.

Build the real popup first, then run ``python3 test_dsh.py [binary]``.
Private Swift logic is exercised by appending a test entry point to temporary
copies of the source, with only the production @main annotation removed.
The comparison copy comes from the pinned pre-DSH Git revision (override with
``PERMISSION_POPUP_BASELINE_REV``). No production test bypass is needed,
and eligible requests are never passed to the real GUI entry point.
"""

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
BASELINE_REV = os.environ.get("PERMISSION_POPUP_BASELINE_REV",
                              "d8dd7bb7a2ac55202d508e0418fc66f9b26ecc2a")
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else ROOT / "build/permission-popup"
if len(sys.argv) == 2:
    del sys.argv[1]
SOURCES = ("PermissionRequestPopup.swift", "ClaudeThreadTitle.swift", "ClaudeHostApplication.swift")
ENV_KEYS = ("PERMISSION_POPUP_HOTKEY", "CODEX_PERMISSION_HOTKEY",
            "PERMISSION_POPUP_TIMEOUT", "CODEX_PERMISSION_POPUP_TIMEOUT")


DRIVER = r'''
extension PermissionPopupMain {
    static func regressionLifetime() -> TimeInterval { configuredLifetime() }
}

@main
private struct RegressionMain {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let command = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let host = PopupHost(rawValue: command["host"] as? String ?? "codex")!
        var result: [String: Any] = [:]
        switch command["op"] as? String {
        case "parse":
            let data = Data(base64Encoded: command["data"] as! String)!
            do {
                let request = command["defaultHost"] as? Bool == true
                    ? try HookRequest.parse(data) : try HookRequest.parse(data, host: host)
                result = [
                    "sessionID": request.sessionID, "turnID": request.turnID,
                    "transcriptPath": request.transcriptPath as Any? ?? NSNull(),
                    "cwd": request.cwd, "toolName": request.toolName,
                    "permissionMode": request.permissionMode as Any? ?? NSNull(),
                    "reason": request.reason as Any? ?? NSNull(),
                    "source": request.source, "language": request.language.rawValue,
                    "shouldShow": host.shouldShow(request),
                ]
            } catch { result = ["error": String(describing: error)] }
        case "decisions":
            for (name, decision) in [("allow", HookDecision.allow), ("deny", .deny),
                                      ("timeout", .timeout), ("defer", .deferToHost)] {
                result[name] = decision.responseData(for: host)
                    .map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull()
                result[name + "Raises"] = decision.raisesHostWindow
            }
            result["defaultAllow"] = HookDecision.allow.responseData
                .map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull()
        case "environment":
            let key = HotKeySpec.fromEnvironment()
            result = ["modifiers": key.modifiers, "keyCode": key.keyCode,
                      "displayName": key.displayName,
                      "lifetime": PermissionPopupMain.regressionLifetime()]
        case "options":
            if let options = PopupOptions.parse(command["arguments"] as! [String]) {
                result = ["host": options.host.rawValue, "selfTest": options.selfTest]
            } else { result = ["error": "invalidOptions"] }
        case "keys":
            let fixtures = command["fixtures"] as! [[String: Any]]
            result["fixtures"] = fixtures.map { fixture -> [String: Any] in
                let keyCode = UInt16(fixture["keyCode"] as! Int)
                let mask = fixture["mask"] as! Int
                var flags: NSEvent.ModifierFlags = []
                for (bit, flag) in [(1, NSEvent.ModifierFlags.command), (2, .control),
                                    (4, .option), (8, .shift)] {
                    if mask & bit != 0 { flags.insert(flag) }
                }
                if fixture["irrelevantFlags"] as? Bool == true {
                    flags.formUnion([.capsLock, .function, .numericPad])
                }
                return [
                    "dismiss": isCommandWDismissal(
                        charactersIgnoringModifiers: fixture["characters"] as? String,
                        modifierFlags: flags),
                    "authorize": isLocalAuthorizeKey(keyCode: keyCode, modifierFlags: flags),
                    "continue": isPlainContinueKey(keyCode: keyCode, modifierFlags: flags),
                ]
            }
            let continueDecision = __CONTINUE_DECISION__
            result["continueResponse"] = continueDecision.responseData(for: host)
                .map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull()
        __HOST_CONTROLS__
        default: fatalError("Unknown test operation")
        }
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
'''

HOST_CONTROLS = r'''
        case "failure":
            result = ["response": String(decoding: DSHFailure.responseData(command["reason"] as! String),
                                         as: UTF8.self)]
        case "controls":
            result = ["allowTitle": host.allowButtonTitle,
                      "hasContinue": host.hasContinueButton,
                      "authorizeResponse": host.authorizeDecision.responseData(for: host)
                        .map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull(),
                      "continueResponse": host.continueDecision.responseData(for: host)
                        .map { String(decoding: $0, as: UTF8.self) } as Any? ?? NSNull()]
'''


def environment(overrides=None):
    clean = {key: value for key, value in os.environ.items()
             if not key.startswith(("PERMISSION_POPUP", "CODEX_PERMISSION"))}
    clean.update(overrides or {})
    return clean


class DSHContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError(f"compiled popup not found: {BINARY}")
        cls.temporary = tempfile.TemporaryDirectory(prefix="permission-popup-regression-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.drivers = {}
        for label in ("baseline", "candidate"):
            directory = cls.directory / label
            directory.mkdir()
            for name in SOURCES:
                source = (subprocess.check_output(["git", "show", f"{BASELINE_REV}:{name}"], cwd=ROOT).decode()
                          if label == "baseline" else (ROOT / name).read_text())
                if name == SOURCES[0]:
                    source, count = re.subn(r"@main\s+(?=private struct PermissionPopupMain\b)",
                                            "", source)
                    if count != 1:
                        raise RuntimeError("expected exactly one production entry point")
                    source += DRIVER.replace("__HOST_CONTROLS__",
                                             HOST_CONTROLS if label == "candidate" else "").replace(
                                                 "__CONTINUE_DECISION__", "host.continueDecision"
                                                 if label == "candidate" else "HookDecision.deferToHost")
                (directory / name).write_text(source)
            binary = directory / "driver"
            compilation = subprocess.run(["/usr/bin/swiftc", "-parse-as-library", "-framework", "AppKit",
                            "-framework", "Carbon", "-lsqlite3", "-module-cache-path",
                            str(cls.directory / "module-cache"),
                            *(str(directory / name) for name in SOURCES), "-o", str(binary)],
                           capture_output=True, timeout=120)
            if compilation.returncode:
                raise RuntimeError(f"{label} driver compilation failed:\n{compilation.stderr.decode()}")
            cls.drivers[label] = binary

    def snapshot(self, label="candidate", overrides=None, **command):
        result = subprocess.run([str(self.drivers[label])], input=json.dumps(command).encode(),
                                capture_output=True, env=environment(overrides), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)

    def parse(self, payload, host="dsh", label="candidate", default=False):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        return self.snapshot(label, op="parse", host=host, defaultHost=default,
                             data=base64.b64encode(data).decode())

    def assert_unchanged(self, **command):
        self.assertEqual(self.snapshot("baseline", **command), self.snapshot(**command))

    @staticmethod
    def payload(**overrides):
        payload = {"hook_event_name": "PermissionRequest", "cwd": "/tmp/dsh-test",
                   "tool_name": "Bash", "tool_input": {"command": "echo hello"}}
        payload.update(overrides)
        return payload

    def test_codex_and_claude_parse_and_eligibility_unchanged(self):
        transcript = self.directory / "rollout.jsonl"
        for reviewer in ("auto_review", "user", "unknown"):
            transcript.write_text(json.dumps({"type": "turn_context", "payload": {
                "turn_id": "turn", "approvals_reviewer": reviewer}}) + "\n")
            for turn in ("turn", "missing", ""):
                for tool, input_value in (("Bash", {"command": "pwd", "description": "why"}),
                                          ("apply_patch", {"command": "patch"}),
                                          ("unknown", [1, "x"]), ("Bash", None)):
                    payload = self.payload(session_id="session", turn_id=turn,
                                           transcript_path=str(transcript), tool_name=tool,
                                           tool_input=input_value)
                    baseline = self.parse(payload, "codex", "baseline")
                    self.assertEqual(baseline, self.parse(payload, "codex"))
                    self.assertEqual(baseline, self.parse(payload, "codex", default=True))
                    self.assertEqual(baseline.get("shouldShow"),
                                     reviewer == "auto_review" and turn == "turn")
        inputs = {"Bash": {"command": "pwd", "justification": "why"},
                  "Edit": {"file_path": "a", "old_string": "old", "new_string": "new"},
                  "Write": {"file_path": "a", "content": "content"},
                  "Read": {"file_path": "a"}, "MCP": {"arbitrary": [1, True]}}
        for mode in ("auto", "default", "plan", "acceptEdits", "bypassPermissions",
                     "dontAsk", "unknown", None):
            for tool, input_value in inputs.items():
                payload = self.payload(hook_event_name="PreToolUse", permission_mode=mode,
                                       tool_name=tool, tool_input=input_value)
                baseline = self.parse(payload, "claude", "baseline")
                self.assertEqual(baseline, self.parse(payload, "claude"))
                self.assertEqual(baseline["shouldShow"], mode == "auto" and tool in {"Bash", "Edit", "Write"})
        for payload in (b"not json", b"[]", self.payload(hook_event_name="wrong"),
                        self.payload(tool_input="text"), self.payload(cwd=None)):
            for host in ("codex", "claude"):
                self.assertEqual(self.parse(payload, host, "baseline"), self.parse(payload, host))
        missing_mode = self.payload(hook_event_name="PreToolUse")
        self.assertEqual(self.parse(missing_mode, "claude", "baseline"),
                         self.parse(missing_mode, "claude"))
        self.assertFalse(self.parse(missing_mode, "claude")["shouldShow"])

    def test_decision_bytes_and_options_unchanged(self):
        for host in ("codex", "claude"):
            self.assert_unchanged(op="decisions", host=host)
        for arguments in ([], ["--host", "codex"], ["--host", "claude"], ["--self-test"],
                          ["--host", "invalid"], ["--host"], ["--unknown"],
                          ["--host", "codex", "--host", "claude"]):
            self.assert_unchanged(op="options", arguments=arguments)
        self.assertEqual(self.snapshot(op="options", arguments=["--host", "dsh"]),
                         {"host": "dsh", "selfTest": False})

    def test_environment_precedence_and_fallbacks_unchanged(self):
        cases = ({}, {ENV_KEYS[1]: "command+a", ENV_KEYS[3]: "30"},
                 {ENV_KEYS[0]: "option+b", ENV_KEYS[1]: "command+a",
                  ENV_KEYS[2]: "75", ENV_KEYS[3]: "30"},
                 {ENV_KEYS[0]: "", ENV_KEYS[1]: "command+a", ENV_KEYS[2]: "", ENV_KEYS[3]: "30"},
                 {ENV_KEYS[0]: "not-a-key", ENV_KEYS[2]: "NaN"},
                 {ENV_KEYS[2]: "1"}, {ENV_KEYS[2]: "900"})
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.assert_unchanged(op="environment", overrides=overrides)
        self.assertEqual(self.snapshot(op="environment")["lifetime"], 540)
        self.assertEqual(self.snapshot(op="environment", overrides={ENV_KEYS[2]: "1"})["lifetime"], 10)
        self.assertEqual(self.snapshot(op="environment", overrides={ENV_KEYS[2]: "900"})["lifetime"], 590)

    def test_dsh_permission_modes_are_not_an_eligibility_gate(self):
        for mode in ("auto", "semi-auto", None, "unknown"):
            for tool in ("Bash", "Edit", "Write", "Read", "arbitrary_tool"):
                payload = self.payload(tool_name=tool, tool_input={"arbitrary": {"nested": [1, True]}})
                if mode is not None:
                    payload["permission_mode"] = mode
                with self.subTest(mode=mode, tool=tool):
                    result = self.parse(payload)
                    self.assertNotIn("error", result)
                    self.assertTrue(result["shouldShow"])
                    self.assertEqual(result["permissionMode"], mode)

    def test_synthetic_key_predicates_and_continue_routing(self):
        fixtures = [{"keyCode": key, "characters": characters, "mask": mask,
                     "irrelevantFlags": irrelevant}
                    for key, characters in ((36, "\r"), (76, "\r"), (13, "w"),
                                            (13, "W"), (53, "\x1b"))
                    for mask in range(16) for irrelevant in (False, True)]
        for host in ("codex", "claude"):
            self.assert_unchanged(op="keys", host=host, fixtures=fixtures)
        result = self.snapshot(op="keys", host="dsh", fixtures=fixtures)
        for fixture, interpretation in zip(fixtures, result["fixtures"]):
            with self.subTest(fixture=fixture):
                self.assertEqual(interpretation["continue"],
                                 fixture["keyCode"] in (36, 76) and fixture["mask"] == 0)
                self.assertEqual(interpretation["authorize"],
                                 fixture["keyCode"] in (36, 76) and fixture["mask"] == 2)
                self.assertEqual(interpretation["dismiss"],
                                 fixture["characters"].lower() == "w" and fixture["mask"] == 1)
        self.assertEqual(result["continueResponse"],
                         self.snapshot(op="decisions", host="dsh")["allow"])

    def test_dsh_rendering_and_input_limit(self):
        self.assertEqual(self.parse(self.payload())["language"], "shell")
        self.assertEqual(self.parse(self.payload())["source"], "echo hello")
        extra_input = {"command": "echo hello", "extra": {"must_not_disappear": True}}
        rendered = self.parse(self.payload(tool_input=extra_input))
        self.assertEqual(rendered["language"], "json")
        self.assertEqual(json.loads(rendered["source"]), extra_input)
        for tool in ("Edit", "Write", "apply_patch", "unknown"):
            result = self.parse(self.payload(tool_name=tool, tool_input={"content": "hello"}))
            self.assertEqual(result["language"], "json")
            self.assertEqual(json.loads(result["source"]), {"content": "hello"})
        canonical = {
            "Edit": ({"file_path": "a", "old_string": "old\nsnippet", "new_string": "new\nsnippet",
                      "replace_all": True},
                     "File: a\nReplace all: true\nBefore snippet:\nold\nsnippet\nAfter snippet:\nnew\nsnippet"),
            "Write": ({"file_path": "a", "content": "full\ncontent"},
                      "File: a\nContent:\nfull\ncontent"),
        }
        for tool, (input_value, source) in canonical.items():
            result = self.parse(self.payload(tool_name=tool, tool_input=input_value))
            self.assertEqual(result["language"], "text")
            self.assertEqual(result["source"], source)
            with_extra = dict(input_value, unknown="preserve me")
            result = self.parse(self.payload(tool_name=tool, tool_input=with_extra))
            self.assertEqual(result["language"], "json")
            self.assertEqual(json.loads(result["source"]), with_extra)
        oversized = b" " * (8 * 1024 * 1024 + 1)
        for host in ("codex", "claude", "dsh"):
            self.assertEqual(self.parse(oversized, host)["error"], "inputTooLarge")
        valid = json.dumps(self.payload()).encode()
        self.assertTrue(self.parse(valid.ljust(8 * 1024 * 1024, b" "))["shouldShow"])

    def test_dsh_decisions_and_continue_controls(self):
        decisions = self.snapshot(op="decisions", host="dsh")
        codex = self.snapshot(op="decisions", host="codex")
        for name in ("allow", "deny", "timeout"):
            self.assertEqual(decisions[name], codex[name])
        self.assertEqual(decisions["defer"], decisions["deny"])
        controls = self.snapshot(op="controls", host="dsh")
        self.assertEqual(controls["allowTitle"], "Directly Approve  ⌃↩")
        self.assertEqual(controls["continueResponse"], decisions["allow"])
        self.assertEqual(json.loads(controls["authorizeResponse"]), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "allow_direct"}}})
        self.assertTrue(controls["hasContinue"])
        for host in ("codex", "claude"):
            controls = self.snapshot(op="controls", host=host)
            self.assertIsNone(controls["continueResponse"])
            self.assertEqual(controls["authorizeResponse"],
                             self.snapshot(op="decisions", host=host)["allow"])
            self.assertTrue(controls["hasContinue"])

    def test_dsh_malformed_requests_fail_closed_without_gui(self):
        invalid = [b"", b"not json", b"[]", self.payload(hook_event_name="PreToolUse")]
        for key in ("cwd", "tool_name", "tool_input"):
            missing = self.payload()
            del missing[key]
            invalid.append(missing)
            for value in (None, "", 1, [], "   "):
                invalid.append(self.payload(**{key: value}))
        invalid.append(b" " * (8 * 1024 * 1024 + 1))
        for payload in invalid:
            with self.subTest(payload=repr(payload)[:160]):
                self.assertIn("error", self.parse(payload))
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                result = subprocess.run([str(BINARY), "--host", "dsh"], input=data,
                                        capture_output=True, env=environment(), timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                response = json.loads(result.stdout)
                output = response["hookSpecificOutput"]
                self.assertEqual(output["hookEventName"], "PermissionRequest")
                self.assertEqual(output["decision"]["behavior"], "deny")
                self.assertTrue(output["decision"]["message"])
                self.assertEqual(set(response), {"hookSpecificOutput"})
                self.assertEqual(set(output), {"hookEventName", "decision"})

    def test_dsh_infrastructure_failure_serialization(self):
        reason = 'Queue unavailable: "quoted"\nsecond line ☃'
        response = self.snapshot(op="failure", reason=reason)["response"]
        self.assertEqual(json.loads(response), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": reason}}})


if __name__ == "__main__":
    unittest.main()
