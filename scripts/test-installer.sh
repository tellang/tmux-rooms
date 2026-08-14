#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$repo_root/scripts/install-local.sh"
identity="Tmux Rooms Local Development"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-rooms-installer.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

source_app="$tmp/source/Tmux Rooms.app"
destination="$tmp/destination/Tmux Rooms.app"
mkdir -p "$source_app/Contents/MacOS" "$source_app/Contents/Helpers" "$(dirname "$destination")"

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
print("fixture")
SWIFT
xcrun swiftc "$tmp/main.swift" -o "$source_app/Contents/MacOS/TmuxRooms"
cp "$source_app/Contents/MacOS/TmuxRooms" "$source_app/Contents/Helpers/tmuxrooms-launch"
cat > "$source_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TmuxRooms</string>
<key>CFBundleIdentifier</key><string>com.tellang.tmuxrooms.fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$tmp/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$identity" --options runtime --timestamp=none "$source_app/Contents/Helpers/tmuxrooms-launch"
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements "$tmp/entitlements.plist" "$source_app"

mkdir -p "$destination"
printf 'keep\n' > "$destination/existing-marker"

set +e
"$installer" --app-path "$source_app" --destination "$destination" --non-interactive --no-launch >"$tmp/refusal.log" 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { cat "$tmp/refusal.log" >&2; echo "FAIL: expected refusal exit 2, got $status" >&2; exit 1; }
[[ -f "$destination/existing-marker" ]] || { echo "FAIL: refusal mutated destination" >&2; exit 1; }

"$installer" --app-path "$source_app" --destination "$destination" --yes --dry-run --non-interactive --no-launch >/dev/null
[[ -f "$destination/existing-marker" ]] || { echo "FAIL: dry run mutated destination" >&2; exit 1; }

"$installer" --app-path "$source_app" --destination "$destination" --yes --non-interactive --no-launch >/dev/null
[[ -x "$destination/Contents/Helpers/tmuxrooms-launch" ]] || { echo "FAIL: approved install omitted helper" >&2; exit 1; }
[[ ! -e "$destination/existing-marker" ]] || { echo "FAIL: approved replacement retained old content" >&2; exit 1; }

echo "PASS: installer refuses implicit replacement, preserves dry-run state, and installs only with explicit approval"
