# Contributing

Bug reports and pull requests are welcome. For anything larger than a small fix,
open an issue first so we can agree on the approach before you spend time on it.

## Setup

You need an Apple Silicon Mac with macOS 15, Xcode 16 or later, Homebrew tmux
3.6b or later, and iTerm2 if you work on the app. `project.yml` is the source of
truth for the Xcode project. If you add, remove, or rename files, run
`xcodegen generate` (2.46) and commit the regenerated `TmuxRooms.xcodeproj`.

## Tests

Run the unit tests before sending a pull request:

```bash
xcodebuild -project TmuxRooms.xcodeproj -scheme TmuxRoomsUnitTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

If you change the installer, also run `bash scripts/test-installer.sh`. If you
change the menu-bar UI, run the UI tests described in
[docs/testing.md](docs/testing.md). They take over the screen for a while.

New behavior needs a test, and a bug fix needs a test that fails without the
fix.

## Style

- Match the code around you: naming, comment density, and how errors are
  handled.
- Comments say what the code does and why. Leave history to git.
- Subprocesses get an argument array and a fixed executable path, never a shell
  string.
- Commit messages start with a lowercase type (`feat:`, `fix:`, `docs:`,
  `refactor:`, `test:`, `build:`) followed by a plain sentence. Use the body to
  explain why.

## Scope

Tmux Rooms is for people who use tmux inside iTerm2. Support for other
terminals is on the roadmap in [TODOS.md](TODOS.md), but each one needs its own
way to find and focus the exact tab, so talk it through in an issue first.
