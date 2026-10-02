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
    private let runner: any TmuxCommandRunning
    private let registryDirectory: URL
    private let projectsDirectory: URL?
    private let codexRegistryDirectory: URL
    private let codexHome: URL
    private let homeDirectory: URL
    private let psExecutableURL: URL
    private let tmuxExecutableURL: URL
    private let socketPath: String?
    private let allowLsofFallback: Bool

    public init(
        runner: any TmuxCommandRunning = ProcessTmuxCommandRunner(),
        registryDirectory: URL = ClaudeSessionRegistry.defaultDirectory,
        psExecutableURL: URL = URL(fileURLWithPath: "/bin/ps"),
        projectsDirectory: URL? = ClaudeConversationTitles.defaultProjectsDirectory,
        codexRegistryDirectory: URL = CodexSessionRegistry.defaultDirectory(),
        codexHome: URL = CodexSessionIndex.defaultHome(),
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        tmuxExecutableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        socketPath: String? = nil,
        allowLsofFallback: Bool = false
    ) {
        self.runner = runner
        self.registryDirectory = registryDirectory
        self.psExecutableURL = psExecutableURL
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
        var records = ClaudeSessionRegistry.records(in: registryDirectory, projectsDirectory: projectsDirectory)
        records += CodexSessionRegistry.records(in: codexRegistryDirectory, names: names)
        let table = await processTable()
        let live = rooms.flatMap(\.panes).filter { !$0.isDead }
        var infos: [String: PaneAgentInfo] = [:]
        for pane in live where infos[pane.paneID] == nil {
            if let table, let found = table.agent(inTreeOf: pane.panePID), found.kind == .codex,
               AgentPresenceResolver.matchingRecord(for: pane, records: records, table: table) == nil {
                if let record = CodexOMXSession.record(for: pane, nativePID: found.pid, names: names, homeDirectory: homeDirectory, table: table) {
                    records.append(record)
                } else if allowLsofFallback, let record = await rolloutRecord(for: pane, nativePID: found.pid, names: names) {
                    records.append(record)
                }
            }
            var info = AgentPresenceResolver.agent(for: pane, records: records, table: table)
            if capturePaneState, info.kind == .codex || info.kind == .agy {
                let state = await screenState(paneID: pane.paneID)
                info = PaneAgentInfo(kind: info.kind, pid: info.pid, sessionID: info.sessionID, name: info.name, state: state)
            }
            infos[pane.paneID] = info
        }
        return AgentProbeSnapshot(presence: AgentPresenceResolver.presence(for: rooms, records: records, table: table), panes: infos)
    }

    private func rolloutRecord(for pane: SessionRoom.Pane, nativePID: Int32, names: [String: String]) async -> AgentSessionRecord? {
        let invocation = TmuxCommandInvocation(executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-p", String(nativePID), "-Fn"], deadline: .seconds(1), stdoutLimit: 1_048_576, stderrLimit: 65_536)
        guard let output = try? await runner.run(invocation), output.exitCode == 0, output.termination == .exit,
              let id = CodexRolloutSession.sessionID(lsofOutput: String(decoding: output.stdout, as: UTF8.self), codexHome: codexHome),
              let name = names[id] else { return nil }
        return AgentSessionRecord(kind: .codex, pid: nativePID, sessionID: id, name: name, nameIsDerived: false, paneID: pane.paneID, tmuxSessionName: nil, currentPath: pane.currentPath)
    }

    private func screenState(paneID: String) async -> AgentActivityState {
        let endpoint = socketPath.map { ["-S", $0] } ?? []
        let invocation = TmuxCommandInvocation(executableURL: tmuxExecutableURL, arguments: endpoint + ["-N", "capture-pane", "-p", "-t", paneID], deadline: .seconds(1), stdoutLimit: 1_048_576, stderrLimit: 65_536)
        guard let output = try? await runner.run(invocation), output.exitCode == 0, output.termination == .exit else { return .unknown }
        return .visibleScreen(String(decoding: output.stdout, as: UTF8.self))
    }

    private func processTable() async -> ProcessTable? {
        let invocation = TmuxCommandInvocation(
            executableURL: psExecutableURL,
            arguments: ["-eo", "pid=,ppid=,comm="],
            deadline: .seconds(3),
            stdoutLimit: 4_194_304,
            stderrLimit: 65_536
        )
        guard let output = try? await runner.run(invocation),
              output.exitCode == 0,
              case .exit = output.termination
        else { return nil }
        return ProcessTable(psOutput: String(decoding: output.stdout, as: UTF8.self))
    }
}
