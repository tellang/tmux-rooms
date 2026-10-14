import Foundation

/// A coding agent CLI that can be running inside a tmux pane.
public enum AgentKind: String, Sendable, Hashable, CaseIterable {
    case claude
    case codex
    /// Antigravity's command line, which installs as `agy`.
    case agy

    /// The label shown when the agent is present but unnamed.
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .agy: "Antigravity"
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
    public let state: AgentActivityState

    public init(
        kind: AgentKind,
        pid: Int32,
        sessionID: String = "",
        name: String,
        nameIsDerived: Bool,
        paneID: String?,
        tmuxSessionName: String?,
        currentPath: String,
        state: AgentActivityState = .unknown
    ) {
        self.kind = kind
        self.pid = pid
        self.sessionID = sessionID
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.paneID = paneID
        self.tmuxSessionName = tmuxSessionName
        self.currentPath = currentPath
        self.state = state
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
        configDirectory().appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Claude Code's configuration directory: `CLAUDE_CONFIG_DIR` when it holds
    /// an absolute path, as Claude Code itself honors it, otherwise `~/.claude`.
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
    }

    private struct Payload: Decodable {
        let pid: Int32
        let sessionId: String?
        let name: String?
        let nameSource: String?
        let tmux: String?
        let cwd: String?
        let status: String?
    }

    /// Decodes one registry file. Returns `nil` for a record that names no pane,
    /// which is every background job and every non-tmux session.
    public static func record(fromJSON data: Data) -> AgentSessionRecord? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard payload.pid > 0 else { return nil }
        guard let name = payload.name.map(TerminalText.sanitized)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard let coordinate = payload.tmux.flatMap(TmuxPaneCoordinate.init) else { return nil }
        return AgentSessionRecord(
            kind: .claude,
            pid: payload.pid,
            sessionID: payload.sessionId ?? "",
            name: name,
            nameIsDerived: payload.nameSource == "derived",
            paneID: coordinate.paneID,
            tmuxSessionName: coordinate.sessionName,
            currentPath: payload.cwd ?? "",
            state: .claudeStatus(payload.status)
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
            guard let data = BoundedFileReader.read(directory.appending(path: name), limit: BoundedFileReader.jsonStateLimit) else { return nil }
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
            currentPath: currentPath,
            state: state
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
        agent(inTreeOf: pid)?.kind
    }

    /// Returns the executable's pid, not a shell or Node wrapper above it.
    public func agent(inTreeOf pid: Int32) -> (kind: AgentKind, pid: Int32)? {
        agent(among: tree(of: pid))
    }

    /// The first agent in an already walked tree, so a caller that needs the
    /// tree for other checks walks it once.
    func agent(among tree: [Int32]) -> (kind: AgentKind, pid: Int32)? {
        for candidate in tree {
            if let kind = kind(of: candidate) { return (kind, candidate) }
        }
        return nil
    }

    func kind(of pid: Int32) -> AgentKind? {
        commands[pid].flatMap(AgentKind.matching(command:))
    }

    public func contains(_ candidate: Int32, inTreeOf pid: Int32) -> Bool {
        tree(of: pid).contains(candidate)
    }

    /// The pane process and its descendants, breadth-first, to `searchDepth`.
    func tree(of pid: Int32) -> [Int32] {
        var frontier = [pid]
        var visited: Set<Int32> = [pid]
        var result: [Int32] = []
        var depth = 0
        while !frontier.isEmpty, depth < Self.searchDepth {
            result.append(contentsOf: frontier)
            var next: [Int32] = []
            for candidate in frontier {
                for child in children[candidate] ?? [] where visited.insert(child).inserted {
                    next.append(child)
                }
            }
            frontier = next
            depth += 1
        }
        return result
    }
}

/// Reads the name Claude Code wrote into its pane's title.
///
/// A background session shown through `claude agents` keeps a registry record
/// with no tmux coordinate, so the pane it is viewed in has no record to match.
/// Claude Code still titles that terminal with the conversation's name, behind
/// a status glyph: `✳` when idle, a Braille spinner while working.
public enum PaneTitle {
    /// The usable name in `title`, or `nil` when it is only a default: empty,
    /// Claude Code's own placeholder, or the host name tmux gives a new pane.
    public static func agentName(from title: String, hostName: String = localHostName) -> String? {
        let scalars = TerminalText.sanitized(title).unicodeScalars.drop(while: isLeadingMarker)
        let name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folded = name.lowercased()
        guard folded != "claude", folded != "claude code" else { return nil }
        let host = hostName.lowercased()
        if !host.isEmpty, folded == host || folded == host.split(separator: ".").first.map(String.init) { return nil }
        return name
    }

    /// tmux titles a new pane with `gethostname(3)`.
    public static let localHostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }()

    /// Whitespace, Dingbats such as `✳`, and Braille spinner frames.
    private static func isLeadingMarker(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
            || (0x2700...0x27BF).contains(scalar.value)
            || (0x2800...0x28FF).contains(scalar.value)
    }
}

/// Decides what a room should be called once its agent is known.
public enum AgentPresenceResolver {
    /// Resolves one room.
    ///
    /// A record is only believed when its pane matches and its pid is the live
    /// pane process or a bounded descendant in this room. The process table
    /// rules out stale files and recycled pids. A room whose agent is running but unnamed still reports
    /// `.detected`, so the caller can label it without inventing a name.
    public static func presence(
        for room: SessionRoom,
        records: [AgentSessionRecord],
        table: ProcessTable?
    ) -> AgentPresence {
        var infos: [String: PaneAgentInfo] = [:]
        for pane in room.panes where !pane.isDead {
            infos[pane.paneID] = agent(for: pane, records: records, table: table)
        }
        return presence(for: room, infos: infos)
    }

    /// Resolves one room from pane results that are already known.
    static func presence(for room: SessionRoom, infos: [String: PaneAgentInfo]) -> AgentPresence {
        var fallback: AgentPresence = .absent
        for pane in orderedPanes(of: room) {
            guard let info = infos[pane.paneID] else { continue }
            if let kind = info.kind, let name = info.name { return .named(kind, name) }
            if case .absent = fallback, let kind = info.kind { fallback = .detected(kind) }
        }
        return fallback
    }

    /// The pane coordinate and bounded process ancestry must agree before a
    /// registry can enrich the pane. A process name alone supplies no state.
    public static func matchingRecord(for pane: SessionRoom.Pane, records: [AgentSessionRecord], table: ProcessTable?) -> AgentSessionRecord? {
        matchingRecord(for: pane, records: records, table: table, tree: table?.tree(of: pane.panePID))
    }

    /// A record's pid must be in the pane's tree and still run the program the
    /// record names, whether it is the pane process itself or a descendant.
    /// When several records qualify, the one naming the shallowest agent wins,
    /// then the first in record order, which follows sorted file names.
    static func matchingRecord(for pane: SessionRoom.Pane, records: [AgentSessionRecord], table: ProcessTable?, tree: [Int32]?) -> AgentSessionRecord? {
        guard !pane.isDead else { return nil }
        let candidates = records.filter { record in
            guard record.paneID == pane.paneID else { return false }
            guard let table, let tree else { return record.pid == pane.panePID }
            return tree.contains(record.pid) && table.kind(of: record.pid) == record.kind
        }
        guard candidates.count > 1, let tree, let shallowest = table?.agent(among: tree)?.pid else { return candidates.first }
        return candidates.first { $0.pid == shallowest } ?? candidates.first
    }

    public static func agent(for pane: SessionRoom.Pane, records: [AgentSessionRecord], table: ProcessTable?) -> PaneAgentInfo {
        agent(for: pane, records: records, table: table, tree: table?.tree(of: pane.panePID))
    }

    static func agent(for pane: SessionRoom.Pane, records: [AgentSessionRecord], table: ProcessTable?, tree: [Int32]?) -> PaneAgentInfo {
        guard !pane.isDead else { return PaneAgentInfo(kind: nil, pid: pane.panePID) }
        if let record = matchingRecord(for: pane, records: records, table: table, tree: tree) {
            return PaneAgentInfo(kind: record.kind, pid: record.pid,
                                 sessionID: record.sessionID.isEmpty ? nil : record.sessionID,
                                 name: record.nameIsDerived ? nil : record.name,
                                 state: record.state)
        }
        let found = tree.flatMap { table?.agent(among: $0) }
        let name = found?.kind == .claude ? PaneTitle.agentName(from: pane.title) : nil
        return PaneAgentInfo(kind: found?.kind, pid: found?.pid ?? pane.panePID, name: name)
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
