#!/bin/sh
set -eu

tray_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$tray_dir/../build"
app_dir="$build_dir/AgentControl.app"
mkdir -p "$app_dir/Contents/MacOS" "$build_dir/module-cache"
/usr/bin/swiftc -O -parse-as-library -framework AppKit \
    -module-cache-path "$build_dir/module-cache" \
    "$tray_dir/Settings.swift" "$tray_dir/PopupToggle.swift" \
    -o "$app_dir/Contents/MacOS/AgentControl"
cp "$tray_dir/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
printf 'Built %s\n' "$app_dir"
