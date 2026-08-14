# T5 decision: managed-client control

**Verdict: FAIL** for server-side mutation of an existing app-owned tmux client.

Tested on `/opt/homebrew/bin/tmux` **3.6b** using a unique short `-S` socket and
real PTY clients created by `/usr/bin/script`. No default tmux endpoint was used.

## Why it fails

The strongest foreground candidate uses `if-shell -F`, an `L:` client loop, an
`S:` session loop, then `switch-client -c ... -t ...`. It can compare:

- source: `client_name`, `client_tty`, `client_pid`, `client_created`;
- destination: `session_id`, `session_created`;
- server: `socket_path`, `pid`, `start_time`.

It cannot compare the complete server identity. On tmux 3.6b,
`display-message -p '#{socket_device}|#{socket_inode}'` returns `|`. Neither
format appears in the 3.6b format surface. `if-shell` accepts only
`-t target-pane`; only `switch-client` has `-c target-client`. `display-message`
can select a client with `-c`, but its result cannot be fed into the same
foreground conditional command.

The exact local command surface is:

```text
if-shell [-bF] [-t target-pane] shell-command command [command]
switch-client [-ElnprZ] [-c target-client] [-t target-session] [-T key-table]
display-message [-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]
run-shell [-bCE] [-c start-directory] [-d delay] [-t target-pane] [shell-command]
```

A shell-mode `if-shell` could call `stat(2)`, but it waits for an asynchronous
job before inserting the branch. That creates exactly the validation-to-mutation
gap T5 forbids. Pre/post endpoint validation is therefore not a PASS.

## Deterministic race matrix

`ManagedMutationRaceTests` schedules the state change explicitly before the
single foreground candidate; the baseline schedules it after successful tuple
capture. Every process and wait has a deadline.

| Case | Observed result |
| --- | --- |
| Exact live source and destination | Best partial candidate switches the intended client only. |
| Source exits | Old `ClientKey` no longer matches; no mutation. |
| Replacement PTY client | Different PID/created tuple does not inherit the stale key; no mutation. |
| Destination disappears | Old `SessionToken` no longer matches; source remains attached. |
| Server kill/restart and socket inode change | Old server tuple rejects; no mutation. |
| Same `$0` recreated with different `session_created` | Old token rejects; replacement session is not selected. |
| Initial attach after `$0` recreation | Destination-gated one-shot exits without attaching. |

Observed wrong-client/wrong-session mutations: **0**. This does not upgrade the
verdict because PASS requires binding *all* `ServerIdentity` fields in the same
server-side mutation turn, and the socket device/inode fields are unavailable.

## T6 executor

Choose the **terminal-side supervisor** fallback; do not implement a production
tmux controller from this spike.

- The app-owned primary/Preview tab runs a supervisor that owns its exact tmux
  child process (PID/process group).
- A typed switch or detach request boundedly terminates that owned child and
  relaunches tmux with the destination-token-gated initial attach.
- `TerminalBridge` remains the journal owner and records intent/result.
- The supervisor may not target or mutate arbitrary existing tmux clients.
- Every wait and termination escalation is bounded; a stale endpoint or token
  fails closed before relaunch.

The initial-attach `if-shell -F` template may be retained only as the one-shot
`session_id` + `session_created` recreation gate demonstrated by the test. It is
not a substitute for full `ServerIdentity` validation.

## Reproduction

Static probe and exact partial command template:
`Spikes/TmuxMutation/README.md` and `Spikes/TmuxMutation/probe.sh`.

Dynamic proof:

```sh
xcodebuild -project TmuxRooms.xcodeproj \
  -scheme TmuxRoomsUnitTests -configuration Debug \
  -derivedDataPath DerivedDataT5 \
  test -only-testing:TmuxRoomsTests/ManagedMutationRaceTests
```
