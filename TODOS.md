# Tmux Rooms roadmap

Work deferred from the current version.

## Attention badge in the menu bar

- Show how many agent rooms are waiting for input, for example `!N` next to
  the menu bar icon.
- Agent kind, names, and busy, idle, or unknown state already exist. What is
  missing is a verified "needs input" signal and the badge that counts it.
- Never infer attention from a process name. Missing, expired, or mismatched
  signals count as unknown, not as waiting.

## Menu bar panel that survives focus changes

- Replace `MenuBarExtra` with an app-owned `NSStatusItem` and `NSPanel`.
- Open, Preview, and Close Preview all end with iTerm in front, and the SwiftUI
  panel closes as soon as the app loses focus, so the list disappears after
  every action.
- The app would then own placement and dismissal (status item click, Escape,
  click outside), which SwiftUI handles today.

## Configurable tmux path

- tmux is fixed at `/opt/homebrew/bin/tmux`, the Apple silicon Homebrew path.
- Support Intel Homebrew (`/usr/local/bin/tmux`), MacPorts
  (`/opt/local/bin/tmux`), and a user setting.
- The supervisor and the integration tests use the same fixed path.

## More terminal adapters

- Exact-TTY focus for Terminal.app, Ghostty, and WezTerm. Only iTerm is
  supported now.
- Each adapter must find the exact tab by TTY, select and activate it, and
  verify the result.
- Clients in unsupported terminals stay visible and never fall back to
  Duplicate silently.

## Exact detach for existing clients

- Detach one client the app did not start, without touching the session or
  other clients.
- Blocked by tmux: `detach-client` cannot be bound to a full client identity,
  and a TTY alone can be reused by a new client in between. See
  [docs/design/managed-clients.md](docs/design/managed-clients.md).
- No broad session detach or best-effort approximation in the meantime.

## Public distribution hardening

- Developer ID signing, notarization, and a secure timestamp instead of the
  local signing identity and `--timestamp=none`.
- Review which TTYs, paths, and session names reach logs, and redact them.
- Before shipping an updater, secure its update feed and supply chain.
