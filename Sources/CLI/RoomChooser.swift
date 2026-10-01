import Darwin
import Foundation

enum ChooserResult {
    case picked(CLIRoom)
    case cancelled
    /// stdin or stderr is not a terminal, so nothing can be drawn or read key by key.
    case unavailable
}

/// Single-key terminal mode. The saved settings come back when this is released,
/// so every exit path from the chooser restores the terminal.
private final class SingleKeyTerminal {
    private var saved = termios()

    init?() {
        guard isatty(STDIN_FILENO) != 0, isatty(STDERR_FILENO) != 0,
              tcgetattr(STDIN_FILENO, &saved) == 0
        else { return nil }
        var raw = saved
        // ISIG is off so Ctrl-C arrives as a key and this class gets to restore.
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { controls in
            controls[Int(VMIN)] = 1
            controls[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    }

    deinit {
        var restored = saved
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
    }

    /// One read of whatever bytes are waiting, or `nil` at end of input.
    func readChunk() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 32)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 { return Array(buffer[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }
}

enum RoomChooser {
    private static let escape = "\u{1B}"

    /// Draws the room list on stderr and reads keys until a room is picked or the
    /// chooser is cancelled. stdout stays untouched.
    static func run(
        rooms: [CLIRoom],
        home: String,
        initial: Int,
        program: String,
        readOnly: Bool
    ) -> ChooserResult {
        guard let terminal = SingleKeyTerminal() else { return .unavailable }
        let size = terminalSize()
        let visible = max(1, min(rooms.count, size.rows - 3))
        let rows = RoomFormat.chooserRows(rooms, home: home)
        let depth = ColorDepth.detect(environment: ProcessInfo.processInfo.environment)
        let header = "\(program)  ↑/↓ move  1-9 attach  Enter attach  q quit" + (readOnly ? "  [read-only]" : "")
        var state = ChooserState(count: rooms.count, cursor: initial)

        write("\(escape)[?25l")
        defer { write("\(escape)[?25h") }

        var drawn = 0
        func redraw() {
            var frame = drawn > 0 ? "\(escape)[\(drawn)A" : ""
            var lines = [dim(TextWidth.truncate(header, to: size.columns - 1))]
            for index in state.window(rows: visible) {
                let selected = index == state.cursor
                let text = (selected ? "> " : "  ") + rows[index]
                let fitted = TextWidth.pad(TextWidth.truncate(text, to: size.columns - 1), to: size.columns - 1)
                lines.append(AgentStyle.paint(fitted, kind: rooms[index].agent, selected: selected, depth: depth))
            }
            lines.append(dim(TextWidth.truncate(RoomFormat.chooserDetail(rooms[state.cursor]), to: size.columns - 1)))
            for line in lines { frame += "\r\(escape)[2K\(line)\n" }
            write(frame)
            drawn = lines.count
        }

        func erase() {
            write("\(escape)[\(drawn)A\(escape)[J")
        }

        redraw()
        while true {
            guard let chunk = terminal.readChunk() else {
                erase()
                return .cancelled
            }
            for key in ChooserInput.decode(chunk) {
                switch state.apply(key) {
                case .none:
                    continue
                case .select(let index):
                    erase()
                    return .picked(rooms[index])
                case .cancel:
                    erase()
                    return .cancelled
                }
            }
            redraw()
        }
    }

    private static func dim(_ text: String) -> String {
        "\(escape)[2m\(text)\(escape)[0m"
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func terminalSize() -> (rows: Int, columns: Int) {
        var size = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        return (24, 80)
    }
}
