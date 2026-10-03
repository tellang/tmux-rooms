# Managed clients

Why Tmux Rooms opens rooms through tmux clients it owns, instead of moving
tmux clients that already exist.

## The problem

Opening a room in an existing terminal tab would mean telling tmux to move a
client: `switch-client -c <client> -t <session>`. That is only safe if, in the
same server-side step, tmux confirms three things:

- the client is the one the app saw (name, TTY, PID, creation time);
- the session is the one the user clicked (`session_id` and
  `session_created`, because tmux reuses ids such as `$0` after a session is
  killed and recreated);
- the server is the one the app read (PID, start time, and the device and
  inode of its socket file, because a restarted server can reuse the socket
  path).

## The tmux limitation

tmux cannot do all of that in one command.

- `if-shell -F` evaluates a format condition and runs the branch in the same
  server turn, so it can compare the client, the session, the server PID, and
  the start time.
- No format exposes the socket's device and inode. On tmux 3.6b and 3.7c,
  `display-message -p '#{socket_device}|#{socket_inode}'` prints `|`.
- A shell condition could call `stat(2)` on the socket, but tmux runs shell
  conditions as asynchronous jobs. The branch runs later, so the server could
  change between the check and the switch.
- Checking before and after the switch does not help: a wrong client or
  session has already been moved by the time the second check fails.

So the app never mutates a tmux client it did not start.

## The design

The app owns its own tmux client processes and replaces them instead of
moving them.

- The app opens an iTerm tab that runs the bundled helper,
  `Contents/Helpers/tmuxrooms-launch --supervise <nonce>`. The nonce is also
  stored in the iTerm session variable `user.tmuxRoomsNonce`, so the app can
  find exactly that tab again.
- The helper is a supervisor (`ManagedTmuxSupervisor`). It starts one tmux
  client as its child process and records a handshake with its own PID, the
  child PID, and the destination.
- Before every attach, the supervisor checks the destination from outside
  tmux: `lstat` on the socket for device and inode, then `display-message`
  for server PID, start time, `session_id`, and `session_created`.
- The attach itself is gated:
  `tmux -S <socket> -f /dev/null if-shell -F <condition> "attach-session -t <id>" ""`.
  The condition repeats the server PID, start time, `session_id`, and
  `session_created` check in the same server turn, so a session recreated
  under the same id after validation is never attached.
- To move a managed tab to another room, the app asks the supervisor to
  switch. The supervisor validates the new destination, stops its child
  (SIGTERM, then SIGKILL, each bounded to 500 ms), and starts a new gated
  attach. If validation fails, the old child keeps running and the request
  is rejected.
- Every wait has a deadline. A stale endpoint or session fails closed before
  anything is relaunched.

The app and the supervisor talk through files under
`~/Library/Application Support/Tmux Rooms/ManagedClients`: one record per
managed tab, the supervisor configuration, the handshake, and request and
response files. `TerminalController` owns these records and is the only code
that changes their state. `ManagedClientJournal` reads and writes them
atomically.

## How the room actions use it

Each managed record has a launch kind and, for reusable tabs, a role.

| Action | What happens |
|---|---|
| Open, room has no client | Uses the one reusable `primary` tab: launches it if there is none, otherwise asks its supervisor to switch to this room. |
| Open, room has clients | Focuses the existing client in iTerm by exact TTY. Nothing in tmux changes. |
| Preview | Same as the primary tab, but with the one reusable `preview` tab, attached read-only and titled `READ ONLY · <room>`. |
| Close Preview | Asks the preview supervisor to detach. Its child exits, the supervisor stops, and iTerm closes the tab. |
| Duplicate | Always launches a new `explicitDuplicate` tab. Duplicates are never reused or switched. |

Recovery covers records the app cannot attribute with certainty, for example
two records that both claim the primary role, a tab found without a role, or a
launch that timed out while iTerm was still working on it. The app lists
these candidates and lets the user choose one as Primary or Preview, or clean
it up. Cleaning up detaches through the supervisor, or, when every process
the record names is provably gone, just retires the record. A closed window
with no live supervisor, child, or client is retired automatically on the
next Open or Preview, so ordinary window closing does not end in the recovery
panel.

## Clients the app does not own

Clients started outside the app are shown with their TTY, terminal, and
session, and can be focused. The app offers no Detach for them, for the same
reason as above: `detach-client` cannot be bound to a full client identity, and
a TTY can be reused by a new client between the check and the detach.

## Supported tmux versions

The parser accepts tmux 3.6b and later (`TmuxParser.minimumSupportedVersion`,
compared through `TmuxVersion`). Pinning one exact version turned an ordinary
Homebrew upgrade into a total outage, so newer releases are accepted as long
as the snapshot format still parses. Client flags are treated as an open set,
so a new flag such as 3.7c's `ignore-size` does not break parsing.

## Tests

`Tests/Integration/ManagedMutationRaceTests.swift` runs against a real tmux
server on a private socket. It checks that the socket device and inode formats
are still missing, then runs the strongest single-command switch and the gated
initial attach while injecting each race before the command: the source client
exits, a new client takes its place, the destination disappears, and the
server is replaced with a session recreated under the same id. In every case
nothing is attached or switched to the wrong place.
`ManagedSupervisorIntegrationTests` covers the supervisor: relaunching its own
child, read-only Preview, stale destinations, and handshake failures. See
[testing.md](../testing.md) for how to run them.
