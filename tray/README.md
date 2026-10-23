# AgentControl

A standalone native macOS menu-bar app. It only reads and writes the popup setting.
It does not launch the popup, modify hooks, or start at login.

- Left-click: toggle Ask/Auto. A monochrome raised hand means Ask (popup enabled); a filled coral-red (`#FF6257`) lightning bolt means Auto (continue without the popup).
- Right-click: show **Quit AgentControl**. Quitting does not change the setting.
- External setting changes appear on the icon within two seconds.
- A failed save shows a native error alert. The icon reflects the saved setting.

The default file is `~/.config/permission-popup/config.json`:

```json
{"enabled": true}
```

Missing or invalid files default to enabled. Only JSON `false` disables the popup.
Writes are atomic and preserve other keys in a valid JSON object.
`PERMISSION_POPUP_CONFIG` can select a different **absolute** file path. Set the
same path for the popup and tray process; relative overrides are ignored.

Build from this directory with `sh build.sh`. Open `../build/AgentControl.app`
to run it. The popup must also be rebuilt with config support; an old installed
popup cannot read this setting. Disabling the popup means **no decision**, not
direct approval. Requests already open are not changed.

Headless settings test, from this directory:

```sh
/usr/bin/swiftc -parse-as-library -module-cache-path ../build/module-cache \
  Settings.swift test_settings.swift -o ../build/tray-settings-test
../build/tray-settings-test
```
