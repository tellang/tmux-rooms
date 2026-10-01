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

## Room names

A room that holds a coding agent is titled by that agent's own session name
rather than by its tmux name, which is usually a launcher-generated string such
as `omc-tmux-rooms-core-v1-20260901023710`. The tmux name moves to the metadata
line so nothing is lost.

The name comes from the live registry Claude Code keeps at
`~/.claude/sessions/<pid>.json`, which records what `/rename` sets along with the
`session:@window.%pane` coordinate of the pane holding it. A record is believed
only when both its pane and its pid match a live pane in that room, so a
registry file outliving its process cannot name a room. A session nobody renamed
falls back to the conversation title in its transcript.

An agent that publishes no usable name is labelled by product alone, `Claude`,
`Codex`, or `Antigravity` (its `agy` command), and a room with no agent in it
keeps its tmux name and pane command exactly as before. Only Claude Code keeps a
session registry, so Codex and Antigravity are identified by process and never
by name.

## Command line

`tmr` (also installed as `tmuxrooms`) lists and attaches to the same rooms the
menu-bar app shows, with the same agent titles, from any terminal. Bare `tmr`
draws the room list and waits for a key.

```bash
tmr                   # choose among every room
tmr --here            # choose among the rooms with a pane in this directory
tmr -r billing        # read-only, rooms matching "billing"
tmr ls --here --json  # print instead of attach; --json for scripts
tmr -help             # the full help
```

In the chooser, Up and Down (or `k` and `j`) move the highlight and wrap around,
Home and End jump to the ends, and Enter attaches. A number key attaches to that
room at once; with ten or more rooms, type both digits or one digit and Enter.
`q`, Esc, and Ctrl-C cancel. The highlight starts on the first room that has a
pane in the current directory. The list is drawn on stderr, so stdout stays clean.

Rooms running `claude`, `codex`, or `agy` show that word in an AGENT column and
take that agent's color: orange, white, and blue, the same ones the tfx HUD
uses (Antigravity shares Gemini's blue there). The highlighted row swaps text and
background, so the bar takes the agent's color and the text the terminal's own
background, on dark and light themes alike. Colors need `COLORTERM=truecolor` or
a `256color` `TERM`, and `NO_COLOR` turns them off, leaving a plain reverse
highlight. The values are written out in `Sources/CLI/AgentStyle.swift`.

`<text>` matches case-insensitively against a room's title, tmux name, agent
(`claude`, `codex`, `agy`), and pane paths. A tmux name or session id that
equals it exactly wins over partial matches. When one room is left `tmr`
attaches without asking. With no match it exits 1 and never creates a session.
Without a terminal it prints the numbered list to stderr and exits 1.

Unlike the app's Open, attaching behaves like `tmux attach-session`: it adds a
client, so a room already open in another terminal then has two. Inside tmux it
switches the current client instead, and `-r` is refused there because a
read-only view would need a nested tmux.

Exit codes: 0 success, 1 no match or cancelled, 2 usage, 3 tmux unreadable.

```bash
scripts/install-cli.sh        # builds Release, installs ~/.local/bin/tmuxrooms and the short link tmr
```

`tmuxrooms attach` and `tmuxrooms ls` remain as explicit spellings. The short
name is `tmr` rather than `tr` because `tr` is the standard character-translation
utility and `~/.local/bin` comes before `/usr/bin` on `PATH`.

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
