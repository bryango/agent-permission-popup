# Native permission popup for Codex, Claude Code, and DSH

One macOS AppKit helper supports Codex `PermissionRequest` and Claude Code
`PreToolUse` through explicit host selection. With no arguments it keeps the
existing Codex behavior. `--host claude` selects the Claude adapter; payload
shape is never used to guess the host.

`--host dsh` adds the human gate for DSH Semi Auto. It uses an independent
`PermissionRequest` parser and explicit allow/deny responses; it does not change
the no-argument Codex contract.

Codex and Claude Code use one binary at `~/.agents/hooks/agent-permission-popup`.
Claude's TUI hook adds `--host claude`; Codex uses the default host. Updating this
shared binary updates both integrations; their event and decision contracts
remain separate.

In Codex mode, the helper reads one hook request from standard input and checks the matching
turn context in the session transcript. It opens an AppKit window only when the
active `approvals_reviewer` is `auto_review`. With the normal user reviewer
(“Ask for approval”), or when the reviewer cannot be determined, it returns no
decision without showing a popup so Codex continues to its built-in prompt.

When available, the popup reads the concise thread name from Codex's local
session index, falling back to a short, read-only SQLite query for older or
missing index entries. It uses the title as the popup's main heading and wraps
long values within the popup width. Missing files, busy reads, absent
rows, and internal schema changes simply omit the title without affecting the
permission request.

The popup plays the macOS Glass chime once when it appears, using explicit
audio playback and respecting output volume and mute. Requests skipped without
a popup remain silent. Set `CODEX_PERMISSION_POPUP_DEBUG=1` to log playback
start and completion results to standard error.

When shown, the popup returns a Codex permission decision on standard output:

- **Authorize** or window-local `⌃Return`/`⌃Enter` returns `behavior: allow`
  immediately.
- **Deny**, pressing `Esc` or `⌘W`, or closing the window returns
  `behavior: deny`, fully closes the popup, then sends a foreground reopen
  request to raise the main ChatGPT/Codex window.
- A **timeout**, including expiry while waiting behind another popup, returns
  `behavior: deny` with a timeout-specific message noting that the user may be
  away and asking Codex to pause after repeated timeouts, then raises the main
  ChatGPT/Codex window.
- **Auto review**, pressing plain `Return` or keypad `Enter`, the global
  shortcut, or an internal failure returns no decision, so Codex falls back to
  auto-review or its normal approval prompt.

The default global Codex-review shortcut is `⌃⌥⌘↩`. It is registered only
while a request is visible and does not require Accessibility permission.
The window-local `⌃Return` approval binding is not registered globally.
Concurrent requests share a per-user lock and are shown one at a time, so one
shortcut press cannot advance multiple requests.

## Claude Code adapter

Only `Bash` `PreToolUse` requests whose incoming `permission_mode` is exactly
`auto` can show a popup. They additionally require
`tool_input.dangerouslyDisableSandbox` to be the JSON Boolean `true`.
Missing, false, and non-Boolean values skip the popup. `Edit`, `Write`, and
all other tools skip the popup. Manual/default, plan,
acceptEdits, bypassPermissions, dontAsk, missing, and unknown modes return no
decision silently. Each invocation checks the payload anew, not session-start
settings. A mode change between invocations is therefore observed. The payload
is a snapshot: the helper cannot track a mode switch while its window is open.

`PreToolUse` creates a checkpoint for explicit Bash sandbox escapes in auto
mode. It does not detect all unsandboxed Bash execution: commands
excluded from sandboxing, or sessions with sandboxing disabled, can omit the
flag and therefore skip the popup. This is intentionally different from
`PermissionRequest`, which only covers calls reaching a permission prompt.
Do not register both events for this adapter.

- Continue/Return/global shortcut: exits successfully with no output. Claude
  continues its normal permission processing; a classifier check is not promised
  for calls its rules already resolve. This is not Claude's `defer` decision.
- Authorize/Control-Return: returns `hookSpecificOutput.permissionDecision: allow`.
  Claude's own rules and restrictions still apply; no persistent permissions or
  tool-input changes are returned.
- Deny/close/Esc/Command-W/timeout: returns `permissionDecision: deny` and
  `permissionDecisionReason`. Timeout uses the same agreed away/pause message
  as Codex. `hookEventName` is `PreToolUse`, never `PermissionRequest`.

The heading is the latest complete, nonempty `custom-title` metadata record
matching `session_id` in the supplied transcript. Lookup is read-only, bounded,
and optional; missing metadata or internal schema changes use the generic
heading. Transcript writes can lag, so the title may briefly be stale. No
conversation text is used as a title fallback.

On denial, Claude mode activates the running GUI app found in the process
ancestry captured before the popup opens. Set `PERMISSION_POPUP_HOST_BUNDLE_ID`
to an explicit running host app if ancestry is ambiguous (for example tmux).
It never guesses from the current foreground app and does not launch a new
Claude session if no owner can be found. This restores the application, not a
specific terminal tab; exact-tab behavior is not implemented or verified.

All hosts share the title **Agent Permission Request**, the **Auto review**,
**Authorize**, and **Deny** labels, and the same right-aligned footer. Typography,
shortcuts, and host-specific decision semantics are unchanged. Routine display
notes are hidden; hidden-character warnings remain visible. The Auto review label
does not guarantee a classifier check in Claude. Both hosts retain the same queue
lock and global shortcut. Generic `PERMISSION_POPUP_DEBUG`,
`PERMISSION_POPUP_HOTKEY`, and `PERMISSION_POPUP_TIMEOUT` override the legacy
`CODEX_PERMISSION_*` variables, which remain supported for compatibility.
The popup deadline defaults to 540 seconds, including queue time; finite
overrides are clamped to 10–590 seconds. Configure the outer hook for 600 seconds.

## DSH Semi Auto adapter

Launch the helper as `permission-popup --host dsh`. The trusted DSH caller must
select Semi Auto and decide which calls need human review. The popup accepts
every valid request in this explicit host mode, including MCP/unknown tools;
`permission_mode` is metadata, not a second mode selector or a tool whitelist.

Send one JSON object on stdin and close stdin:

```json
{
  "session_id": "dsh-session-id",
  "transcript_path": "",
  "cwd": "/absolute/session/workspace",
  "permission_mode": "auto",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {"command": "pwd"},
  "permission_suggestions": []
}
```

Required fields: `hook_event_name` exactly `PermissionRequest`, nonblank string
`cwd` and `tool_name`, and object-valued `tool_input`. Input is capped at 8 MiB.
The current DSH caller supplies no thread title.
The caller can send a native approval wrapper:

```json
{
  "native_approval": {
    "reason": "Native permission reason",
    "requestedMode": "workspace-write"
  },
  "tool_arguments": {"command": "pwd", "description": "Inspect files"}
}
```

Both approval fields are optional; `requestedMode`, when supplied,
must be `read-only`, `workspace-write`, or `danger-full-access`.
The native scope and reason remain in the request JSON,
without an additional explanation block above the content.
For valid wrappers, the normal view shows only the tool arguments,
using the tool-specific formatter when available and JSON otherwise.
The full wrapper is available in **Show request details**.
When there is no distinct tool justification, the explanation uses the native reason.
The original flat `tool_input` format remains supported.

The heading uses a nonblank description from `tool_arguments` (or the flat input),
falling back to the generic tool-permission heading when it is absent or invalid.
DSH never queries Codex/Claude session storage.
The caller may map bash/edit/write to Bash/Edit/Write for presentation, or pass
the lowercase names. Bash displays its exact command; Edit and Write show the
path and exact snippets or proposed complete content; `run_code` shows the exact
program. The explanation shows a nonblank justification distinct from the heading,
limited to three lines with the full explanation in its tooltip.
When the description is the heading and no distinct justification is available,
the explanation is hidden rather than repeating the heading.
**Show request details** switches the same scrollable source view to the complete
tool-input JSON, including the native approval wrapper, sandbox permissions, working directory, timeout,
background execution, and both explanation fields.
**Show command / content** restores the exact command, file operation, or program.
Bash retains shell highlighting in the normal view.
Unknown tool names, unknown fields, and
malformed known controls fall back to complete JSON, preserving every value.
This DSH-only presentation does not alter Codex/Claude parsing or responses.

The DSH window has **three actions**:

- **Auto review**: button, Return/keypad Enter, or the displayed
  global shortcut. Returns no decision so the DSH caller continues Auto review.
- **Authorize**: button or Control-Return/keypad Enter. Explicitly approves
  this action without Auto review; downstream sandbox restrictions still apply.
- **Deny**: button, Escape, Command-W, window close, or timeout. All deny.

The global shortcut returns no decision in all three host modes.
The DSH window starts with a deny decision until the user chooses an action.
All hosts share the queue lock; do not
run them with different `TMPDIR` values if they must share that queue.

Auto-review handoff response: exit 0 with empty stdout, matching Codex.

Direct-approval response (one JSON line on stdout, exit 0):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

The DSH caller interprets `allow` as direct approval and empty stdout as an
Auto-review handoff. Update the popup and caller together: older callers used
`allow` for Auto review and `allow_direct` for direct approval.

Deny response (one JSON line on stdout, exit 0):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the native permission popup."}}}
```

Timeout preserves the existing explanatory timeout/away message. Invalid DSH
input and queue failures return explicit denial with an infrastructure reason.
Incorrect CLI arguments exit nonzero. A successful exit with zero-byte stdout
means **no decision**, including when the tray toggle is disabled; the DSH caller
continues Auto review and never treats this as direct authorization or denial.
The caller **must fail closed** for malformed output (including whitespace-only
output), wrong events, unsupported decisions, nonzero exits, crashes,
cancellation, spawn errors, and outer timeouts. Successful no-decision output
enters Auto review; `allow` permits the caller to skip that reviewer for this
action. The popup cannot enforce that
the caller actually invokes Auto review or keeps the tool sandboxed.

The existing 540-second popup/queue deadline and environment-variable precedence
are unchanged. Give the external runner a longer timeout (normally 600 seconds)
and terminate/drain the helper on cancellation. Denials restore the originating
GUI app using the same best-effort ancestry lookup as Claude; no hardcoded DSH
app is launched. A missing focus target does not prevent the denial response.

Trust boundary: **popup process = trusted host-side authorization UI; pending
tool process = sandboxed DSH action.** This repo neither executes pending tools
nor changes sandbox permissions. The DSH plugin, official Auto reviewer, and
workspace-write/approval-never enforcement belong to the DSH repo and are not
implemented here. No global hooks are installed by building this helper.

## Display safety

Shell commands and patches are displayed without rewriting their content.
JSON tool input is pretty-printed. The native text view adds syntax highlighting
and soft wrapping, and expands control, bidirectional, and zero-width characters
as visible `⟦U+XXXX⟧` markers.

Claude Edit displays the path, replace-all scope, and exact before/after
snippets, not a fabricated whole-file diff. Write displays the path and proposed
complete content without reading or modifying the destination. Unrecognized or
malformed fields in tool-input objects fall back to JSON. Invalid hook envelopes
(including a non-object Claude `tool_input`) return no decision to the host.

## Menu-bar toggle

The standalone native app in [`tray/`](tray/) writes
`~/.config/permission-popup/config.json`:

```json
{"enabled": false}
```

Left-click its icon to enable or disable the popup. Right-click for Quit.
Quitting the tray app does not change the saved setting. A missing, unreadable,
or invalid setting keeps the popup enabled; only a JSON Boolean `false` disables it.
`PERMISSION_POPUP_CONFIG` can select an absolute file path for both programs.

When disabled, new popup invocations exit successfully with no stdout, for all
hosts. This is **no decision**, not an approval. The host continues its normal
permission processing. The DSH Semi Auto caller continues Auto review;
it must not mistake empty output for either direct authorization or a denial.
Already-visible windows are unchanged. Queued requests check the setting again
before opening a window. Enabling restores the existing popup behavior.

The installed helper must be updated to a build that reads this setting.
Building or launching the tray app alone does not replace the installed helper,
install hooks, or add a login item. See the tray README for build instructions.

## Build and test

```sh
mkdir -p build
/usr/bin/swiftc \
  -O -parse-as-library \
  -framework AppKit -framework Carbon \
  -lsqlite3 \
  -module-cache-path build/module-cache \
  PermissionRequestPopup.swift ClaudeThreadTitle.swift ClaudeHostApplication.swift \
  -o build/permission-popup
build/permission-popup --self-test
python3 test_sandbox.py build/permission-popup
python3 test_dsh.py build/permission-popup
```

Before the DSH patch, the unchanged self-test and all 9 `test_sandbox.py`
tests passed on baseline commit `d8dd7bb7a2ac55202d508e0418fc66f9b26ecc2a`.
`test_dsh.py` compiles temporary baseline/candidate drivers and compares parsing,
eligibility, decision bytes, key predicates, and environment precedence. The
baseline is pinned to that commit, not the moving HEAD; an explicit
`PERMISSION_POPUP_BASELINE_REV` override is available for maintenance.
It also tests DSH parsing, rendering, malformed-input denial through the real
executable, and no-abstention control policy. No test bypass is added to the
production CLI, and the existing self-test and `test_sandbox.py` are unchanged.
These headless tests do not prove window focus or the external DSH pipeline.

For a manual Claude preview after allowing GUI testing, pipe this synthetic
request to the workspace binary. It displays a request only; it does not execute
the command. The default Codex path requires a matching auto-review transcript.

```sh
printf '%s' '{
  "hook_event_name": "PreToolUse",
  "permission_mode": "auto",
  "session_id": "preview",
  "turn_id": "preview",
  "cwd": "/tmp/example",
  "tool_name": "Bash",
  "tool_input": {
    "command": "printf hello",
    "dangerouslyDisableSandbox": true,
    "description": "Preview a permission request"
  }
}' | build/permission-popup --host claude
```

The global shortcut can be changed with, for example:

```sh
CODEX_PERMISSION_HOTKEY=control+option+command+a \
  build/permission-popup
```

Supported shortcut keys are `A` through `Z`, `Return`, and `Space`. Supported
modifiers are Control, Option, Shift, and Command.

## Hook configuration

After copying the compiled binary to a stable path such as
`~/.agents/hooks/agent-permission-popup`, merge this group into the
existing `PermissionRequest` hooks:

```json
{
  "matcher": "^(Bash|apply_patch)$",
  "hooks": [
    {
      "type": "command",
      "command": "/Users/bryan/.agents/hooks/agent-permission-popup",
      "timeout": 600,
      "statusMessage": "Waiting for approval in the native popup"
    }
  ]
}
```

The matcher intentionally covers executable shell requests and patches. Omitting
it would also place MCP and other permission requests behind the same global
review shortcut. Review and trust the new hook definition with `/hooks`
after wiring it in.

### Claude TUI wiring

Installed on 2026-10-24 in `~/.claude/settings.json`, inside `hooks.PreToolUse`.
The previous settings are backed up at
`~/.claude/backups/settings.before-agent-popup-20261024.json`.

```json
{
  "matcher": "^Bash$",
  "hooks": [{
    "type": "command",
    "command": "/Users/bryan/.agents/hooks/agent-permission-popup --host claude",
    "timeout": 600,
    "statusMessage": "Waiting for Agent Permission Request"
  }]
}
```

Headless tests validate routing, serialization, formatting, metadata failure
handling, and Codex regressions. They do not prove live Claude classifier
ordering, mode changes while a popup is open, audible sound, or window focus.
Both apps also use `/bin/sh ~/.agents/hooks/auto-jj-init.sh` for SessionStart
(`startup|resume`, timeout 10 seconds) and
`/bin/sh ~/.agents/hooks/jj-status-before-tool.sh` for every PreToolUse
(timeout 2 seconds). The scripts run in the hook process's working directory.
The 2026-10-24 shared-path migration preserved the scripts and popup bytes;
both prior configurations are in `~/.agents/backups/shared-hooks-20261024/`.
Review and trust the changed Codex paths in `/hooks`; trust hashes were not
edited. The redundant Claude helper was moved to trash after verification.

Installation and synthetic hook checks passed; a live TUI end-to-end test is
still needed. Test auto→manual→auto in one real Claude session, all three
decisions, timeout messages, renamed titles, and concurrent Codex/Claude requests.
