# Native permission popup for Codex, Claude Code, and DSH

One macOS AppKit helper supports Codex `PermissionRequest` and Claude Code
`PreToolUse` through explicit host selection. With no arguments it keeps the
existing Codex behavior. `--host claude` selects the Claude adapter; payload
shape is never used to guess the host.

`--host dsh` adds the human gate for DSH Semi Auto. It uses an independent
`PermissionRequest` parser and explicit allow/deny responses; it does not change
the no-argument Codex contract.

The previously installed Codex helper remains unchanged. The dual-host build
is a workspace-only candidate: it has not been installed or wired into Claude.

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
- **Continue in Codex**, pressing plain `Return` or keypad `Enter`, the global
  shortcut, or an internal failure returns no decision, so Codex falls back to
  auto-review or its normal approval prompt.

The default global Codex-review shortcut is `⌃⌥⌘↩`. It is registered only
while a request is visible and does not require Accessibility permission.
The window-local `⌃Return` approval binding is not registered globally.
Concurrent requests share a per-user lock and are shown one at a time, so one
shortcut press cannot advance multiple requests.

## Claude Code adapter (sandbox candidate)

Only `PreToolUse` requests for `Bash`, `Edit`, or `Write` whose incoming
`permission_mode` is exactly `auto` show a popup. Manual/default, plan,
acceptEdits, bypassPermissions, dontAsk, missing, and unknown modes return no
decision silently. Each invocation checks the payload anew, not session-start
settings. A mode change between invocations is therefore observed. The payload
is a snapshot: the helper cannot track a mode switch while its window is open.

`PreToolUse` creates a checkpoint for every matched call in auto mode, including
routine commands and file edits. This is intentionally different from
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

Both hosts retain the same queue lock and global shortcut. The window title
and Continue label identify the host. Generic `PERMISSION_POPUP_DEBUG`,
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
Optional metadata is not used to fabricate a transcript or title; DSH uses the
generic tool-permission heading and never queries Codex/Claude session storage.
The caller may map bash/edit/write to Bash/Edit/Write for presentation, or pass
the lowercase names. Unknown tool names and fields remain visible as JSON.
Bash specialization falls back to full JSON if additional arguments would
otherwise be hidden (such as `sandbox_permissions`).

The DSH window has **three actions**:

- **Proceed to Auto Review**: button, Return/keypad Enter, or the displayed
  global shortcut. Explicitly approves sending this action to the DSH Auto reviewer.
- **Directly Approve**: button or Control-Return/keypad Enter. Explicitly approves
  this action without Auto review; downstream sandbox restrictions still apply.
- **Deny**: button, Escape, Command-W, window close, or timeout. All deny.

There is no Continue/abstain route. Even an accidental internal abstention
serializes as deny in DSH mode. The same global shortcut still means Continue
(no decision) in Codex and Claude modes. All hosts share the queue lock; do not
run them with different `TMPDIR` values if they must share that queue.

Auto-review handoff response (one JSON line on stdout, exit 0; unchanged):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

Direct-approval response (DSH only):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow_direct"}}}
```

The DSH caller must explicitly support `allow_direct` to skip Auto review for
this action while preserving downstream gates and sandboxing. Older strict
callers reject this new value; `allow` is never reinterpreted as direct approval.
The caller integration is not implemented in this popup repository, so the new
button alone does not establish end-to-end direct approval in DSH.

Deny response (one JSON line on stdout, exit 0):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the native permission popup."}}}
```

Timeout preserves the existing explanatory timeout/away message. Invalid DSH
input and queue failures return explicit denial with an infrastructure reason.
Incorrect CLI arguments exit nonzero. The DSH caller **must fail closed** for
empty/malformed output, wrong events, unsupported decisions, nonzero exits,
crashes, cancellation, spawn errors, and outer timeouts. Only a valid explicit
`allow` permits calling the next Auto-review gate; `allow_direct` permits the
updated caller to skip that reviewer for this action. The popup cannot enforce that
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
permission processing. In particular, an existing strict DSH caller may reject
empty output; it must not mistake it for `allow` or `allow_direct`.
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
`~/.codex/hooks/codex-permission-popup`, merge this group into the
existing `PermissionRequest` hooks:

```json
{
  "matcher": "^(Bash|apply_patch)$",
  "hooks": [
    {
      "type": "command",
      "command": "~/.codex/hooks/codex-permission-popup",
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

### Future Claude wiring (not installed)

After live testing, a Claude `settings.json` hook could use the following entry
inside `hooks.PreToolUse`. Replace the path with the chosen installation path;
do not point global hooks at a transient build directory.

```json
{
  "matcher": "^(Bash|Edit|Write)$",
  "hooks": [{
    "type": "command",
    "command": "/absolute/stable/path/permission-popup --host claude",
    "timeout": 600,
    "statusMessage": "Waiting for the native permission popup"
  }]
}
```

Headless tests validate routing, serialization, formatting, metadata failure
handling, and Codex regressions. They do not prove live Claude classifier
ordering, mode changes while a popup is open, audible sound, or window focus.
Before deployment, test auto→manual→auto in one real Claude session, all three
decisions, timeout messages, renamed titles, and concurrent Codex/Claude requests.
