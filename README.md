# Tmux Rooms

Tmux Rooms is a native macOS menu-bar app for viewing and controlling the
existing tmux server through iTerm. It never creates tmux sessions implicitly.

Room actions:

- **Open** focuses the sole existing interactive client or creates/reuses one
  app-owned Primary client when none exists.
- **Preview** creates/reuses one global app-owned `tmux attach-session -r`
  client and labels its iTerm tab `READ ONLY · <room>`.
- **Duplicate Window** is the only action that intentionally adds another
  interactive client.
- **Delete** revalidates the exact server/session token before killing only that
  session.
- **Recovery** exposes exact nonce-scoped promotion or cleanup for unresolved
  app-owned clients.

## Requirements

- macOS 15 or newer
- Xcode and XcodeGen for local builds
- Homebrew tmux at `/opt/homebrew/bin/tmux`
- iTerm with Automation allowed for `Tmux Rooms`
- iTerm **Settings → General → Magic → Enable Python API** enabled, including
  its one-time confirmation. Accept iTerm's Python runtime installation prompt
  if it appears on the first Preview.

The app keeps terminal ownership valid if title delivery is temporarily
unavailable. Re-enable the Python API and invoke Preview again to retry the
durable pending title.

## Build and test

```bash
xcodegen generate
xcodebuild -project TmuxRooms.xcodeproj \
  -scheme TmuxRoomsUnitTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' test
xcodebuild -project TmuxRooms.xcodeproj \
  -scheme TmuxRoomsUITests -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO test
```

The canonical project definition is `project.yml`; the generated
`TmuxRooms.xcodeproj` is committed for reproducible local opening. The fixed
bundle identifier is `com.tellang.tmuxrooms`, and the bundled helper is always
`tmuxrooms-launch`.

## Local Release install

```bash
scripts/install-local.sh --dry-run --non-interactive
scripts/install-local.sh
```

The installer builds Release and binds app/helper signatures to the single
matching Keychain identity fingerprint. It accepts only a normalized,
non-symlink `Tmux Rooms.app` destination. Existing installs use macOS
`RENAME_SWAP` with a same-parent hash journal for interrupted-transaction
recovery. `~/Applications/Tmux Rooms.app` is also supported. A dry run never
requires replacement approval; a real replacement requires an interactive
`replace` response or explicit `--yes`.

For direct tmux use, read-only attach is:

```bash
/opt/homebrew/bin/tmux attach-session -r -t '<session-name-or-id>'
```

`-r` makes the new client read-only; it does not reuse an existing client. Use
Tmux Rooms Preview when you want the app to focus/reuse its single managed
read-only client.

See `docs/verification/2026-08-14-t9-final.md` for final automated and live
evidence. Deferred local hardening remains in `TODOS.md`.
