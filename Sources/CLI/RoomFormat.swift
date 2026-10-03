import Foundation
import TmuxRoomsCore

/// Terminal column widths, counting Hangul and other East Asian wide scalars as
/// two cells so padded columns stay aligned for Korean room names.
enum TextWidth {
    static func of(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            true
        default:
            false
        }
    }

    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - of(text)))
    }

    /// Cuts `text` to at most `width` cells, ending in `…` when it was cut.
    static func truncate(_ text: String, to width: Int) -> String {
        guard of(text) > width else { return text }
        var kept = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let cells = isWide(scalar) ? 2 : 1
            if used + cells > width - 1 { break }
            kept.unicodeScalars.append(scalar)
            used += cells
        }
        return kept + "…"
    }
}

enum RoomFormat {
    static let titleWidth = 28

    /// Text output never carries a control character from a room's names or
    /// paths. JSON output is left raw because the encoder escapes it.
    static func display(_ text: String) -> String {
        TerminalText.sanitized(text)
    }

    /// Swaps a leading home directory for `~`.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return display("~" + path.dropFirst(home.count)) }
        return display(path)
    }

    static func lastActivity(_ unixSeconds: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    static func clients(_ room: CLIRoom) -> String {
        room.readOnlyClients > 0
            ? "\(room.interactiveClients) (+\(room.readOnlyClients) ro)"
            : "\(room.interactiveClients)"
    }

    /// The first pane path, plus how many more distinct paths the room has.
    static func location(_ room: CLIRoom, home: String) -> String {
        guard let first = room.paths.first else { return "-" }
        let shown = abbreviate(first, home: home)
        return room.paths.count > 1 ? "\(shown) +\(room.paths.count - 1)" : shown
    }

    /// The aligned listing `tmuxrooms ls` prints. The tmux name goes last and is
    /// never cut, so it can be copied whole.
    static func table(
        _ rooms: [CLIRoom], home: String, timeZone: TimeZone = .current, depth: ColorDepth = .none
    ) -> String {
        let header = ["TITLE", "AGENT", "CLIENTS", "LAST", "PATH", "TMUX"]
        let body = rooms.map { room in
            [
                TextWidth.truncate(display(room.title), to: titleWidth),
                AgentStyle.tag(for: room.agent),
                clients(room),
                lastActivity(room.lastActivityAtUnixSeconds, timeZone: timeZone),
                location(room, home: home),
                room.titleIsTmuxName ? "-" : display(room.tmuxName),
            ]
        }
        let last = header.count - 1
        let widths = (0..<last).map { column in
            ([header] + body).map { TextWidth.of($0[column]) }.max() ?? 0
        }
        let lines = ([header] + body).map { row in
            (0..<last).map { TextWidth.pad(row[$0], to: widths[$0]) }.joined(separator: "  ") + "  " + row[last]
        }
        return lines.enumerated().map { offset, line in
            offset == 0 ? line : AgentStyle.paint(line, kind: rooms[offset - 1].agent, selected: false, depth: depth)
        }
        .joined(separator: "\n")
    }

    /// One line of the attach chooser.
    static func chooserLine(index: Int, room: CLIRoom, home: String, timeZone: TimeZone = .current) -> String {
        var parts = [
            "  \(index)) \(TextWidth.truncate(display(room.title), to: titleWidth))",
            lastActivity(room.lastActivityAtUnixSeconds, timeZone: timeZone),
            location(room, home: home),
        ]
        if !room.titleIsTmuxName { parts.append(display(room.tmuxName)) }
        if room.interactiveClients > 0 { parts.append("[attached]") }
        return parts.joined(separator: "  ")
    }

    /// The chooser's aligned rows, one per room, numbered from 1 and without the
    /// cursor marker so the caller can style the highlighted one.
    static func chooserRows(_ rooms: [CLIRoom], home: String, timeZone: TimeZone = .current) -> [String] {
        let indexWidth = String(rooms.count).count
        let titles = rooms.map { TextWidth.truncate(display($0.title), to: titleWidth) }
        let tags = rooms.map { AgentStyle.tag(for: $0.agent) }
        let places = rooms.map { location($0, home: home) }
        let titleColumn = titles.map(TextWidth.of).max() ?? 0
        let tagColumn = tags.map(TextWidth.of).max() ?? 0
        let placeColumn = places.map(TextWidth.of).max() ?? 0
        return rooms.indices.map { offset in
            let number = String(offset + 1)
            var row = String(repeating: " ", count: indexWidth - number.count) + number
            row += "  " + TextWidth.pad(titles[offset], to: titleColumn)
            row += "  " + TextWidth.pad(tags[offset], to: tagColumn)
            row += "  " + lastActivity(rooms[offset].lastActivityAtUnixSeconds, timeZone: timeZone)
            row += "  " + TextWidth.pad(places[offset], to: placeColumn)
            if rooms[offset].interactiveClients > 0 { row += "  [attached]" }
            return row
        }
    }

    /// What the chooser's footer says about the highlighted room: the parts the
    /// row had to leave out.
    static func chooserDetail(_ room: CLIRoom) -> String {
        "tmux: \(display(room.tmuxName))  (\(display(room.sessionID)))"
    }

    private struct JSONRoom: Encodable {
        let id: String
        let name: String
        let title: String
        let agent: String?
        let paths: [String]
        let interactiveClients: Int
        let readOnlyClients: Int
        let lastActivity: Int64
        let panes: [JSONPane]
    }

    private struct JSONPane: Encodable {
        let paneId: String
        let target: String
        let active: Bool
        let path: String
        let agent: String?
        let pid: Int32
        let sessionId: String?
        let name: String?
        let state: String

        init(_ pane: CLIPane) {
            paneId = pane.paneId
            target = pane.target
            active = pane.active
            path = pane.path
            agent = pane.agent?.rawValue
            pid = pane.pid
            sessionId = pane.sessionId
            name = pane.name
            state = pane.state.rawValue
        }

        private enum CodingKeys: String, CodingKey {
            case paneId, target, active, path, agent, pid, sessionId, name, state
        }

        /// The pane schema keeps nullable keys visible to JSON consumers.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(paneId, forKey: .paneId)
            try container.encode(target, forKey: .target)
            try container.encode(active, forKey: .active)
            try container.encode(path, forKey: .path)
            if let agent { try container.encode(agent, forKey: .agent) }
            else { try container.encodeNil(forKey: .agent) }
            try container.encode(pid, forKey: .pid)
            if let sessionId { try container.encode(sessionId, forKey: .sessionId) }
            else { try container.encodeNil(forKey: .sessionId) }
            if let name { try container.encode(name, forKey: .name) }
            else { try container.encodeNil(forKey: .name) }
            try container.encode(state, forKey: .state)
        }
    }

    static func json(_ rooms: [CLIRoom]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload = rooms.map { room in
            JSONRoom(
                id: room.sessionID,
                name: room.tmuxName,
                title: room.title,
                agent: room.agent?.rawValue,
                paths: room.paths,
                interactiveClients: room.interactiveClients,
                readOnlyClients: room.readOnlyClients,
                lastActivity: room.lastActivityAtUnixSeconds,
                panes: room.panes.map(JSONPane.init)
            )
        }
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}
