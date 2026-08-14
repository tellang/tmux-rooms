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

The installer builds Release and enforces an exact app/helper signature and entitlement allowlist before installation. It accepts only a normalized, non-symlink `Tmux Rooms.app` destination and uses verified staging plus backup/rollback renames rather than deleting an existing app first. A dry run never requires replacement approval; a real replacement requires an interactive `replace` response or explicit `--yes`.

See `docs/verification/bootstrap.md` for exact validation commands. Deferred features remain only in `TODOS.md`.
