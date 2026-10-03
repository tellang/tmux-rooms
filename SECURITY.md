# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's
Security tab and choose "Report a vulnerability". Do not open a public issue for
them.

Include what you ran, what happened, and the macOS, tmux, and iTerm2 versions.
I will reply in the advisory thread.

## Supported versions

Only the latest 0.x release gets fixes.

## What Tmux Rooms touches

Tmux Rooms runs as your user, on your Mac, with no network access. Knowing what
it reads and runs helps when judging a report:

- It runs `/opt/homebrew/bin/tmux`, `/bin/ps`, and `/usr/sbin/lsof` with fixed
  argument lists, never through a shell.
- It reads session files written by Claude Code, Codex, triflux, and
  oh-my-codex (listed in the README). It only opens regular files, caps how much
  it reads, and does not follow a symlink at the final path component, because
  some of those paths sit inside repositories you cloned.
- It controls iTerm2 through Apple Events and installs one iTerm2 Python script
  for tab titles.
- The bundled helper `tmuxrooms-launch` reads a configuration file that the app
  writes under `~/Library/Application Support/Tmux Rooms/`. The helper only
  accepts a file owned by you with no group or other permissions, and only runs
  tmux from a fixed list of paths.
- `tmr` strips control characters from names and paths before printing them, so
  a session or directory name cannot send escape sequences to your terminal.

Builds are signed ad hoc or with a local certificate. They are not notarized.
