# Changelog

## [0.1.0] - 2026-10-03

The first release.

### Menu-bar app

- Lists every session on the default tmux server as a room, with what is
  running, how many clients are attached, and when it was last active.
- Open brings the iTerm2 window that already shows a room to the front, or opens
  one window and reuses it. With several clients attached, it asks which one to
  focus.
- Preview opens a read-only view in a single reused iTerm2 tab labelled
  `READ ONLY`. Duplicate Window adds a second interactive client on purpose.
- Delete checks that the session is still the one you picked before killing it.
- Recovery cleans up or adopts iTerm2 clients the app opened before a crash.
- Rooms running Claude Code, Codex, or Antigravity are titled with the agent's
  own session name. Claude Code's files are found under `CLAUDE_CONFIG_DIR`
  when it is set.

### Command line

- `tmr`, also installed as `tmuxrooms`, lists and attaches to the same rooms
  from any terminal, with a keyboard picker, `--here`, text filtering, and
  `-r` for read-only.
- `tmr ls --json` prints rooms with a `panes` array: pane id, tmux target,
  agent, pid, session id, name, and a `busy`, `idle`, or `unknown` state.

### Install and uninstall

- `scripts/install-cli.sh` and `scripts/install-local.sh` build from source.
  Both take `--ad-hoc` or `--identity NAME`, so you do not need the author's
  certificate.
- `scripts/install-local.sh` restarts a running app after an upgrade, and
  `--login` or `--no-login` adds or removes start at login.
- `scripts/uninstall.sh` removes the app, the command line tool, the login
  item, and the files the app wrote. `--dry-run` shows the list first.

### Safety

- Agent session files are opened only as regular files, with a size cap and
  without following a final symlink, so a file inside a cloned repository
  cannot hang or flood the app.
- A session record names a room only when its pid really runs that agent in
  that pane.
- Names and paths are stripped of terminal control characters before `tmr`
  prints them.
- The bundled helper trusts its configuration file only when you own it and
  nobody else can write it, and it runs tmux only from fixed paths.
