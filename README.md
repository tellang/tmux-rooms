# Tmux Rooms

Tmux Rooms is a native macOS menu-bar application scaffold for the reviewed Core v1 plan. T2 intentionally contains no tmux mutation, iTerm automation, or room lifecycle policy.

## Bootstrap

```bash
xcodegen generate
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRooms -configuration Debug build
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRooms -configuration Debug test
```

The canonical project definition is `project.yml`; the generated `TmuxRooms.xcodeproj` is committed for reproducible local opening. The app uses the fixed bundle identifier `com.tellang.tmuxrooms`, and the bundled helper executable is always named `tmuxrooms-launch`.

## Local Release install

```bash
scripts/install-local.sh --dry-run --non-interactive
scripts/install-local.sh
```

The installer builds Release, verifies the app, helper, signature, hardened runtime, and Apple Events entitlement, then installs to `/Applications/Tmux Rooms.app`. It refuses to replace an existing installation unless an interactive user types `replace` or `--yes` is supplied explicitly.

See `docs/verification/bootstrap.md` for exact validation commands. Deferred features remain only in `TODOS.md`.
