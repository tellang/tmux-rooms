import Foundation

enum HelpText {
    /// `-help` is accepted next to the usual spellings because it is what gets typed.
    static func isHelpFlag(_ argument: String) -> Bool {
        ["-h", "-help", "--help"].contains(argument)
    }

    /// One line for usage errors, so a typo does not scroll the full help past.
    static func short(program: String) -> String {
        "Usage: \(program) [ls|attach] [options] [<text>]   (\(program) -help for details)"
    }

    static func full(program: String) -> String {
        """
        \(program): jump into tmux rooms, titled by the coding agent inside each.

        Usage:
          \(program) [options] [<text>]       Pick a room from a list and attach to it.
          \(program) ls [options] [<text>]    Print the rooms without attaching.
          \(program) help                     Show this help. -h, -help, --help also work.

        Picking a room:
          Up, Down, k, j      Move the highlight (it wraps around).
          Home, End           First or last room.
          1-9                 Attach to that room at once. With ten or more rooms
                              type both digits, or one digit and Enter.
          Enter               Attach to the highlighted room.
          q, Esc, Ctrl-C      Cancel.
          The highlight starts on the first room with a pane in the current directory.

        Options:
          --here              Only rooms with a pane in the current directory.
          --json              (ls) Print JSON instead of a table.
          -r, --read-only     (attach) Attach read-only.

        Agents: rooms running claude, codex, or agy (Antigravity) get that word in the
        AGENT column and the color the tfx HUD gives it: claude orange, codex white,
        agy blue. The highlighted row swaps text and background, so the bar takes the
        agent's color. Colors need COLORTERM=truecolor or a 256color TERM. NO_COLOR
        turns them off, and the highlight is then a plain reverse.

        <text> narrows the list. It matches, ignoring case, a room's title, tmux name,
        agent (claude, codex, agy), or pane path. A tmux name or session id equal to
        <text> wins over partial matches. When one room is left, \(program) attaches
        without asking.

        Behavior:
          Never creates a tmux session. No match exits 1.
          Adds a client like tmux attach-session, so a room already open in another
          terminal then has two, sharing one screen.
          Inside tmux it switches the current client. -r is refused there because a
          read-only view would need a nested tmux.
          Without a terminal it prints the numbered list to stderr and exits 1.

        Exit codes: 0 success, 1 no match or cancelled, 2 usage, 3 tmux unreadable.

        Examples:
          \(program)                    Choose among every room.
          \(program) --here             Choose among the rooms in this directory.
          \(program) billing            Rooms whose title, name, or path mention billing.
          \(program) -r omx             Read-only view of a room whose name has omx in it.
          \(program) ls --here --json   Machine-readable list for this directory.
        """
    }
}
