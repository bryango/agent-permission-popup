# Native permission popup for Codex and Claude Code

One macOS AppKit helper supports Codex `PermissionRequest` and Claude Code
`PreToolUse` through explicit host selection. With no arguments it keeps the
existing Codex behavior. `--host claude` selects the Claude adapter; payload
shape is never used to guess the host.

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
```

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
