# Testing

How to build Tmux Rooms and run each test suite from the repository root.

## Requirements

- Xcode with Swift 6. The deployment target is macOS 15.
- tmux at `/opt/homebrew/bin/tmux`, version 3.6b or later, for the
  integration tests.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change
  `project.yml`. The generated `TmuxRooms.xcodeproj` is committed, so
  regenerate it with `xcodegen generate` after editing `project.yml`.

## Schemes

| Scheme | Builds | Tests |
|---|---|---|
| `TmuxRooms` | the app and its bundled helper | unit, integration, and UI tests |
| `tmuxrooms-cli` | the `tmuxrooms` command | - |
| `TmuxRoomsUnitTests` | the test bundle | unit and integration tests |
| `TmuxRoomsUITests` | the app and the UI test runner | UI tests |

## Build

```bash
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRooms -configuration Debug build
xcodebuild -project TmuxRooms.xcodeproj -scheme tmuxrooms-cli -configuration Debug build
```

Debug builds are signed ad hoc and need no signing identity.

## Unit and integration tests

```bash
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRoomsUnitTests -configuration Debug test
```

The unit and integration tests share one test bundle, `TmuxRoomsTests`.
The integration tests start their own tmux server on a private socket under
`/tmp/tr-*` and run it with `-f /dev/null`. They never connect to your default
tmux server, read your tmux configuration, or touch your sessions. They fail
if tmux is missing from `/opt/homebrew/bin/tmux`.

To run only the integration suites:

```bash
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRoomsUnitTests -configuration Debug test \
  -only-testing:TmuxRoomsTests/TmuxSnapshotIntegrationTests \
  -only-testing:TmuxRoomsTests/ManagedSupervisorIntegrationTests \
  -only-testing:TmuxRoomsTests/ManagedMutationRaceTests \
  -only-testing:TmuxRoomsTests/DeleteTests
```

## UI tests

```bash
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRoomsUITests -configuration Debug test
```

The UI tests launch the app against a fixture window with made-up rooms, not
your real tmux server. They still drive the real screen: XCUITest moves the
pointer and sends keystrokes, so leave the Mac alone while they run. The first
run makes macOS ask for permission for the test runner under System Settings,
Privacy & Security (Automation, and Accessibility if asked). Grant it and run
the tests again.

To look at the app with made-up rooms yourself, run a Debug build with
`TMUX_ROOMS_UI_FIXTURE=readme-demo`. It puts the menu-bar icon up with five
sample rooms, which is how `docs/images/tray.gif` was recorded, and never reads
your tmux server.

## Installer tests

```bash
bash scripts/test-installer.sh
```

This builds small signed fixture apps and runs `scripts/install-local.sh`
against temporary destinations: destination safety checks, signature and
entitlement checks, the signing options, dry runs, and recovery of an
interrupted install. It needs the code-signing identity named
`Tmux Rooms Local Development` in your Keychain, because it signs the
fixtures with it.

To build and verify the Release app without installing it:

```bash
scripts/install-local.sh --dry-run --non-interactive
scripts/install-local.sh --ad-hoc --dry-run --non-interactive
```

## Release bundle checks

After a Release build, the helper must exist only under `Contents/Helpers`,
and the entitlements must match the allow list the installer enforces.

```bash
app="DerivedData/Build/Products/Release/Tmux Rooms.app"
test -x "$app/Contents/Helpers/tmuxrooms-launch"
test ! -e "$app/Contents/Resources/tmuxrooms-launch"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app"
codesign -d --entitlements :- "$app/Contents/Helpers/tmuxrooms-launch"
```

The app should carry only `com.apple.security.automation.apple-events`, and the
helper should carry no entitlements.
