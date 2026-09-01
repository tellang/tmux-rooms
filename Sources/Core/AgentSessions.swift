import Foundation

/// A coding agent CLI that can be running inside a tmux pane.
public enum AgentKind: String, Sendable, Hashable, CaseIterable {
    case claude
    case codex

    /// The label shown when the agent is present but unnamed.
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Matches the executable name `ps` reports for this agent.
    ///
    /// tmux reports `#{pane_current_command}` as the Claude Code release string
    /// (`2.1.247`) because the binary lives in a version-named directory, so the
    /// pane's own command column cannot identify the agent. The process table is
    /// the only place the executable name survives.
    static func matching(command: String) -> AgentKind? {
        let name = command.split(separator: "/").last.map(String.init) ?? command
        return AgentKind(rawValue: name.lowercased())
    }
}

/// One live agent session as its own CLI records it.
public struct AgentSessionRecord: Sendable, Hashable {
    public let kind: AgentKind
    public let pid: Int32
    public let sessionID: String
    public let name: String
    /// `true` when the CLI generated the name itself rather than taking it from
    /// a rename or a conversation title. Derived names are handles such as
    /// `tmux-rooms-4a`, which say less than the room already does.
    public let nameIsDerived: Bool
    public let paneID: String?
    public let tmuxSessionName: String?
    public let currentPath: String

    public init(
        kind: AgentKind,
        pid: Int32,
        sessionID: String = "",
        name: String,
        nameIsDerived: Bool,
        paneID: String?,
        tmuxSessionName: String?,
        currentPath: String
    ) {
        self.kind = kind
        self.pid = pid
        self.sessionID = sessionID
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.paneID = paneID
        self.tmuxSessionName = tmuxSessionName
        self.currentPath = currentPath
    }
}

/// What a room can say about the agent inside it.
public enum AgentPresence: Sendable, Hashable {
    /// The agent's own session name, taken from its registry.
    case named(AgentKind, String)
    /// The agent is proven to be running but did not publish a usable name.
    case detected(AgentKind)
    /// No agent process was found in any of the room's panes.
    case absent

    public var kind: AgentKind? {
        switch self {
        case let .named(kind, _): kind
        case let .detected(kind): kind
        case .absent: nil
        }
    }

    /// The room title this presence earns, or `nil` to keep the tmux name.
    public var title: String? {
        switch self {
        case let .named(_, name): name
        case let .detected(kind): kind.displayName
        case .absent: nil
        }
    }
}

/// Reads `~/.claude/sessions/<pid>.json`, the registry Claude Code keeps for
/// every live session.
///
/// Each file carries the session's display name, the name a `/rename` sets, and
/// the `session:@window.%pane` coordinate of the pane it occupies. Files outlive
/// their processes, so every record is proven against the process table before
/// it is trusted.
public enum ClaudeSessionRegistry {
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)
    }

    private struct Payload: Decodable {
        let pid: Int32
        let sessionId: String?
        let name: String?
        let nameSource: String?
        let tmux: String?
        let cwd: String?
    }

    /// Decodes one registry file. Returns `nil` for a record that names no pane,
    /// which is every background job and every non-tmux session.
    public static func record(fromJSON data: Data) -> AgentSessionRecord? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard payload.pid > 0 else { return nil }
        guard let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard let coordinate = payload.tmux.flatMap(TmuxPaneCoordinate.init) else { return nil }
        return AgentSessionRecord(
            kind: .claude,
            pid: payload.pid,
            sessionID: payload.sessionId ?? "",
            name: name,
            nameIsDerived: payload.nameSource == "derived",
            paneID: coordinate.paneID,
            tmuxSessionName: coordinate.sessionName,
            currentPath: payload.cwd ?? ""
        )
    }

    /// Loads every readable record in `directory`.
    ///
    /// Unreadable and malformed files are skipped rather than failing the scan:
    /// a room list must still render when one agent writes a partial file.
    public static func records(
        in directory: URL = defaultDirectory,
        projectsDirectory: URL? = ClaudeConversationTitles.defaultProjectsDirectory
    ) -> [AgentSessionRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
            guard let record = record(fromJSON: data) else { return nil }
            guard record.nameIsDerived, let projectsDirectory else { return record }
            return record.titled(from: projectsDirectory)
        }
    }
}

private extension AgentSessionRecord {
    /// Replaces a generated handle with the session's conversation title when
    /// one has been recorded. A session nobody renamed still carries the title
    /// Claude Code derived for it, and that is the name shown in its terminal.
    func titled(from projectsDirectory: URL) -> AgentSessionRecord {
        guard let title = ClaudeConversationTitles.title(forSessionID: sessionID, projectsDirectory: projectsDirectory) else { return self }
        return AgentSessionRecord(
            kind: kind,
            pid: pid,
            sessionID: sessionID,
            name: title,
            nameIsDerived: false,
            paneID: paneID,
            tmuxSessionName: tmuxSessionName,
            currentPath: currentPath
        )
    }
}

/// The `session:@window.%pane` coordinate Claude Code writes into its registry.
struct TmuxPaneCoordinate: Equatable {
    let sessionName: String
    let windowID: String
    let paneID: String

    /// tmux allows `:` and `.` inside a session name, so the coordinate is split
    /// from the right at the `:@` and `.%` that only the window and pane ids can
    /// introduce.
    init?(_ text: String) {
        guard let windowSeparator = text.range(of: ":@", options: .backwards) else { return nil }
        let sessionName = String(text[text.startIndex..<windowSeparator.lowerBound])
        let target = text[windowSeparator.lowerBound..<text.endIndex].dropFirst()
        guard let paneSeparator = target.range(of: ".%", options: .backwards) else { return nil }
        let windowID = String(target[target.startIndex..<paneSeparator.lowerBound])
        let paneID = String(target[paneSeparator.lowerBound..<target.endIndex].dropFirst())
        guard !sessionName.isEmpty, windowID.count > 1, paneID.count > 1 else { return nil }
        self.sessionName = sessionName
        self.windowID = windowID
        self.paneID = paneID
    }
}

/// A snapshot of `ps -eo pid=,ppid=,comm=`.
///
/// A pane's own process is often a shell that launched the agent, so identifying
/// the agent means walking down from the pane pid rather than reading one row.
public struct ProcessTable: Sendable, Hashable {
    private let parents: [Int32: Int32]
    private let commands: [Int32: String]
    private let children: [Int32: [Int32]]

    /// The depth a pane's process tree is walked before giving up. A pane runs a
    /// shell, which runs the agent, which may run a wrapper; anything deeper is
    /// the agent's own work rather than the pane's occupant.
    static let searchDepth = 4

    public init(psOutput: String) {
        var parents: [Int32: Int32] = [:]
        var commands: [Int32: String] = [:]
        var children: [Int32: [Int32]] = [:]
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            let command = fields[2].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            parents[pid] = ppid
            commands[pid] = command
            children[ppid, default: []].append(pid)
        }
        self.parents = parents
        self.commands = commands
        self.children = children
    }

    public func isRunning(_ pid: Int32) -> Bool { parents[pid] != nil }

    public func command(of pid: Int32) -> String? { commands[pid] }

    /// The agent running at or below `pid`, searching breadth-first so a pane's
    /// own process wins over anything it spawned.
    public func agentKind(inTreeOf pid: Int32) -> AgentKind? {
        var frontier = [pid]
        var visited: Set<Int32> = [pid]
        var depth = 0
        while !frontier.isEmpty, depth < Self.searchDepth {
            var next: [Int32] = []
            for candidate in frontier {
                if let command = commands[candidate], let kind = AgentKind.matching(command: command) { return kind }
                for child in children[candidate] ?? [] where visited.insert(child).inserted {
                    next.append(child)
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }
}

/// Decides what a room should be called once its agent is known.
public enum AgentPresenceResolver {
    /// Resolves one room.
    ///
    /// A record is only believed when its pane and its pid both match a live
    /// pane in this room, which rules out both a stale registry file and a
    /// recycled pid. A room whose agent is running but unnamed still reports
    /// `.detected`, so the caller can label it without inventing a name.
    public static func presence(
        for room: SessionRoom,
        records: [AgentSessionRecord],
        table: ProcessTable?
    ) -> AgentPresence {
        var fallback: AgentPresence = .absent
        for pane in orderedPanes(of: room) {
            if let record = records.first(where: { $0.paneID == pane.paneID && $0.pid == pane.panePID }),
               !record.nameIsDerived,
               table.map({ $0.agentKind(inTreeOf: pane.panePID) == record.kind }) ?? true {
                return .named(record.kind, record.name)
            }
            if case .absent = fallback {
                if let table {
                    // The process table is the stronger witness. When it says the
                    // pane runs something else, a record naming that pane is a
                    // stale file or a recycled pid and earns no label at all.
                    if let kind = table.agentKind(inTreeOf: pane.panePID) { fallback = .detected(kind) }
                } else if let record = records.first(where: { $0.paneID == pane.paneID && $0.pid == pane.panePID }) {
                    fallback = .detected(record.kind)
                }
            }
        }
        return fallback
    }

    /// Resolves every room, keyed by tmux session id.
    public static func presence(
        for rooms: [SessionRoom],
        records: [AgentSessionRecord],
        table: ProcessTable?
    ) -> [String: AgentPresence] {
        var resolved: [String: AgentPresence] = [:]
        for room in rooms {
            let presence = presence(for: room, records: records, table: table)
            guard presence != .absent else { continue }
            resolved[room.token.sessionID] = presence
        }
        return resolved
    }

    /// Active pane first: it is the one a person looking at the room would see.
    private static func orderedPanes(of room: SessionRoom) -> [SessionRoom.Pane] {
        let live = room.panes.filter { !$0.isDead }
        return live.filter(\.isActive) + live.filter { !$0.isActive }
    }
}
