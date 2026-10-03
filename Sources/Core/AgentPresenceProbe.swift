import Foundation

/// Collects the agent labels for a room list.
///
/// The probe is advisory: it never fails a refresh. A missing registry, a denied
/// directory, or a `ps` that will not run all resolve to "no agent known", and
/// the rooms keep their tmux names.
public protocol AgentPresenceProbing: Sendable {
    func presence(for rooms: [SessionRoom]) async -> [String: AgentPresence]
}

public struct AgentPresenceProbe: AgentPresenceProbing, Sendable {
    /// How many panes run their lsof and capture-pane commands at once.
    static let paneConcurrency = 4

    private let runner: any TmuxCommandRunning
    private let registryDirectory: URL
    private let projectsDirectory: URL?
    private let codexRegistryDirectory: URL
    private let codexHome: URL
    private let homeDirectory: URL
    private let psExecutableURL: URL
    private let lsofExecutableURL: URL
    private let tmuxExecutableURL: URL
    private let socketPath: String?
    private let allowLsofFallback: Bool

    public init(
        runner: any TmuxCommandRunning = ProcessTmuxCommandRunner(),
        registryDirectory: URL = ClaudeSessionRegistry.defaultDirectory,
        psExecutableURL: URL = URL(fileURLWithPath: "/bin/ps"),
        lsofExecutableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        projectsDirectory: URL? = ClaudeConversationTitles.defaultProjectsDirectory,
        codexRegistryDirectory: URL = CodexSessionRegistry.defaultDirectory(),
        codexHome: URL = CodexSessionIndex.defaultHome(),
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        tmuxExecutableURL: URL = TmuxExecutable.defaultURL,
        socketPath: String? = nil,
        allowLsofFallback: Bool = false
    ) {
        self.runner = runner
        self.registryDirectory = registryDirectory
        self.psExecutableURL = psExecutableURL
        self.lsofExecutableURL = lsofExecutableURL
        self.projectsDirectory = projectsDirectory
        self.codexRegistryDirectory = codexRegistryDirectory
        self.codexHome = codexHome
        self.homeDirectory = homeDirectory
        self.tmuxExecutableURL = tmuxExecutableURL
        self.socketPath = socketPath
        self.allowLsofFallback = allowLsofFallback
    }

    public func presence(for rooms: [SessionRoom]) async -> [String: AgentPresence] {
        await inspect(for: rooms).presence
    }

    /// Extra process and screen reads are opt-in so the menu-bar refresh stays
    /// cheap. A single inspection shares the same process proof across rooms
    /// and their pane metadata.
    public func inspect(for rooms: [SessionRoom], capturePaneState: Bool = false) async -> AgentProbeSnapshot {
        guard !rooms.isEmpty else { return AgentProbeSnapshot(presence: [:], panes: [:]) }
        let names = CodexSessionIndex.names(in: codexHome)
        let records = ClaudeSessionRegistry.records(in: registryDirectory, projectsDirectory: projectsDirectory)
            + CodexSessionRegistry.records(in: codexRegistryDirectory, names: names)
        let table = await processTable()
        var seen: Set<String> = []
        let live = rooms.flatMap(\.panes).filter { !$0.isDead && seen.insert($0.paneID).inserted }
        // Results are keyed by pane, so completion order cannot change them.
        var infos: [String: PaneAgentInfo] = [:]
        await withTaskGroup(of: (String, PaneAgentInfo).self) { group in
            var next = 0
            func enqueue() {
                guard next < live.count else { return }
                let pane = live[next]
                next += 1
                group.addTask { (pane.paneID, await inspect(pane, records: records, table: table, names: names, capturePaneState: capturePaneState)) }
            }
            for _ in 0..<Self.paneConcurrency { enqueue() }
            for await (paneID, info) in group {
                infos[paneID] = info
                enqueue()
            }
        }
        var presence: [String: AgentPresence] = [:]
        for room in rooms {
            let found = AgentPresenceResolver.presence(for: room, infos: infos)
            if found != .absent { presence[room.token.sessionID] = found }
        }
        return AgentProbeSnapshot(presence: presence, panes: infos)
    }

    /// One pane's agent. The process tree is walked once and shared by the
    /// record match, the Codex fallbacks, and the final answer.
    private func inspect(_ pane: SessionRoom.Pane, records: [AgentSessionRecord], table: ProcessTable?, names: [String: String], capturePaneState: Bool) async -> PaneAgentInfo {
        let tree = table?.tree(of: pane.panePID)
        var records = records
        if let table, let tree, let found = table.agent(among: tree), found.kind == .codex,
           AgentPresenceResolver.matchingRecord(for: pane, records: records, table: table, tree: tree) == nil,
           let record = await codexFallbackRecord(for: pane, nativePID: found.pid, names: names, table: table) {
            records.append(record)
        }
        let info = AgentPresenceResolver.agent(for: pane, records: records, table: table, tree: tree)
        guard capturePaneState, let kind = info.kind, kind == .codex || kind == .agy else { return info }
        let state = await screenState(paneID: pane.paneID, kind: kind)
        return PaneAgentInfo(kind: info.kind, pid: info.pid, sessionID: info.sessionID, name: info.name, state: state)
    }

    /// The rollout the Codex process holds open is its current thread, so it
    /// outranks an OMX file that a `/new` or `/resume` has left behind. The
    /// menu-bar refresh never runs lsof and reads OMX alone.
    private func codexFallbackRecord(for pane: SessionRoom.Pane, nativePID: Int32, names: [String: String], table: ProcessTable) async -> AgentSessionRecord? {
        if allowLsofFallback, let record = await rolloutRecord(for: pane, nativePID: nativePID, names: names) { return record }
        return CodexOMXSession.record(for: pane, nativePID: nativePID, names: names, homeDirectory: homeDirectory, table: table)
    }

    private func rolloutRecord(for pane: SessionRoom.Pane, nativePID: Int32, names: [String: String]) async -> AgentSessionRecord? {
        guard let output = await output(of: lsofExecutableURL, ["-p", String(nativePID), "-Fn"]),
              let id = CodexRolloutSession.sessionID(lsofOutput: output, codexHome: codexHome),
              let name = names[id] else { return nil }
        return AgentSessionRecord(kind: .codex, pid: nativePID, sessionID: id, name: name, nameIsDerived: false, paneID: pane.paneID, tmuxSessionName: nil, currentPath: pane.currentPath)
    }

    private func screenState(paneID: String, kind: AgentKind) async -> AgentActivityState {
        let endpoint = socketPath.map { ["-S", $0] } ?? []
        guard let output = await output(of: tmuxExecutableURL, endpoint + ["-N", "capture-pane", "-p", "-t", paneID]) else { return .unknown }
        return .visibleScreen(output, kind: kind)
    }

    private func processTable() async -> ProcessTable? {
        guard let output = await output(of: psExecutableURL, ["-eo", "pid=,ppid=,comm="], deadline: .seconds(3), stdoutLimit: 4_194_304) else { return nil }
        return ProcessTable(psOutput: output)
    }

    /// Runs one bounded helper command. Anything but a clean exit 0 is `nil`.
    private func output(of executable: URL, _ arguments: [String], deadline: Duration = .seconds(1), stdoutLimit: Int = 1_048_576) async -> String? {
        let invocation = TmuxCommandInvocation(executableURL: executable, arguments: arguments, deadline: deadline, stdoutLimit: stdoutLimit, stderrLimit: 65_536)
        guard let output = try? await runner.run(invocation), output.exitCode == 0, output.termination == .exit else { return nil }
        return String(decoding: output.stdout, as: UTF8.self)
    }
}
