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
    private let psExecutableURL: URL

    public init(
        runner: any TmuxCommandRunning = ProcessTmuxCommandRunner(),
        registryDirectory: URL = ClaudeSessionRegistry.defaultDirectory,
        psExecutableURL: URL = URL(fileURLWithPath: "/bin/ps")
    ) {
        self.runner = runner
        self.registryDirectory = registryDirectory
        self.psExecutableURL = psExecutableURL
    }

    public func presence(for rooms: [SessionRoom]) async -> [String: AgentPresence] {
        guard !rooms.isEmpty else { return [:] }
        let records = ClaudeSessionRegistry.records(in: registryDirectory)
        let table = await processTable()
        guard !records.isEmpty || table != nil else { return [:] }
        return AgentPresenceResolver.presence(for: rooms, records: records, table: table)
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
