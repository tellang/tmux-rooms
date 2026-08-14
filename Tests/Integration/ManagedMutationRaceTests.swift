import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("managed tmux mutation feasibility", .serialized)
struct ManagedMutationRaceTests {
    @Test("tmux 3.6b exposes no socket inode formats or target-client selector on if-shell")
    func unsupportedAtomicIdentitySurface() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let started = try await h.command(["start-server", ";", "set-option", "-g", "exit-empty", "off"])
            #expect(started.exitCode == 0)

            let formats = try await h.command(["display-message", "-p", "#{socket_device}|#{socket_inode}"])
            #expect(formats.exitCode == 0)
            #expect(formats.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "|")

            let ifShell = try await h.localCommand(["list-commands", "-F", "#{command_list_usage}", "if-shell"])
            let switchClient = try await h.localCommand(["list-commands", "-F", "#{command_list_usage}", "switch-client"])
            #expect(ifShell.stdoutString.contains("[-t target-pane]"))
            #expect(!ifShell.stdoutString.contains("target-client"))
            #expect(switchClient.stdoutString.contains("[-c target-client]"))
        }
    }

    @Test("best command switches an exact live normal or read-only PTY source", arguments: [false, true])
    func baselineCandidate(readOnly: Bool) async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let fixture = try await Fixture.make(in: h, readOnly: readOnly)
            let result = try await h.command(Candidate.switchArguments(socketPath: h.socket.path, source: fixture.client.key, destination: fixture.destination.token))
            #expect(result.exitCode == 0)
            let snapshot = try await h.waitForClients(1)
            #expect(snapshot.rooms.first(where: { $0.token == fixture.destination.token })?.clients.map(\.key) == [fixture.client.key])
            #expect(snapshot.rooms.flatMap(\.clients).first?.isReadOnly == readOnly)
        }
    }

    @Test("source exit and replacement client do not inherit a stale ClientKey")
    func sourceReplacement() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let fixture = try await Fixture.make(in: h)
            h.stopClient(fixture.process)
            _ = try await h.waitForClients(0)
            let exitedResult = try await h.command(Candidate.switchArguments(socketPath: h.socket.path, source: fixture.client.key, destination: fixture.destination.token))
            #expect(exitedResult.exitCode == 0)
            #expect((try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)).rooms.flatMap(\.clients).isEmpty)

            let replacementProcess = try h.startPTYClient(arguments: ["attach-session", "-t", fixture.source.token.sessionID])
            let replacementSnapshot = try await h.waitForClients(1)
            let replacement = try #require(replacementSnapshot.rooms.flatMap(\.interactiveClients).first)
            #expect(replacement.key != fixture.client.key)

            let result = try await h.command(Candidate.switchArguments(socketPath: h.socket.path, source: fixture.client.key, destination: fixture.destination.token))
            #expect(result.exitCode == 0)
            let after = try await h.waitForClients(1)
            #expect(after.rooms.first(where: { $0.token == fixture.source.token })?.clients.map(\.key) == [replacement.key])
            h.stopClient(replacementProcess)
        }
    }

    @Test("destination disappearance fails closed")
    func destinationDisappearance() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let fixture = try await Fixture.make(in: h)
            let killed = try await h.command(["kill-session", "-t", fixture.destination.token.sessionID])
            #expect(killed.exitCode == 0)

            let result = try await h.command(Candidate.switchArguments(socketPath: h.socket.path, source: fixture.client.key, destination: fixture.destination.token))
            #expect(result.exitCode == 0)
            let after = try await h.waitForClients(1)
            #expect(after.rooms.first(where: { $0.token == fixture.source.token })?.clients.map(\.key) == [fixture.client.key])
        }
    }

    @Test("server replacement with the same session ID and a new creation time rejects old tokens")
    func serverAndSessionReplacement() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let fixture = try await Fixture.make(in: h)
            let oldInode = try h.socketIdentity().inode
            h.stopClient(fixture.process)
            _ = try await h.waitForClients(0)
            try await h.waitUntilNextUnixSecond(after: fixture.destination.token.createdAtUnixSeconds)
            await h.replaceServer()
            let recreated = try await h.command(["new-session", "-d", "-s", "replacement", "/bin/sleep", "60"])
            #expect(recreated.exitCode == 0)
            let newSnapshot = try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)
            let newRoom = try #require(newSnapshot.rooms.first)
            #expect(newRoom.token.sessionID == fixture.destination.token.sessionID)
            #expect(newRoom.token.createdAtUnixSeconds != fixture.destination.token.createdAtUnixSeconds)
            #expect(newRoom.token.server != fixture.destination.token.server)
            #expect(try h.socketIdentity().inode != oldInode)

            let replacementProcess = try h.startPTYClient(arguments: ["attach-session", "-t", newRoom.token.sessionID])
            let replacementClient = try #require((try await h.waitForClients(1)).rooms[0].interactiveClients.first)
            let result = try await h.command(Candidate.switchArguments(socketPath: h.socket.path, source: fixture.client.key, destination: fixture.destination.token))
            #expect(result.exitCode == 0)
            let after = try await h.waitForClients(1)
            #expect(after.rooms[0].token == newRoom.token)
            #expect(after.rooms[0].clients.map(\.key) == [replacementClient.key])
            h.stopClient(replacementProcess)
        }
    }

    @Test("initial attach is destination-token gated and rejects an old token after recreation")
    func initialAttachTokenGate() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let created = try await h.command(["new-session", "-d", "-s", "destination", "/bin/sleep", "60"])
            #expect(created.exitCode == 0)
            let oldRoom = try #require((try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)).rooms.first)

            let attached = try h.startPTYClient(arguments: Candidate.initialAttachArguments(socketPath: h.socket.path, destination: oldRoom.token))
            _ = try await h.waitForClients(1)
            h.stopClient(attached)
            _ = try await h.waitForClients(0)

            try await h.waitUntilNextUnixSecond(after: oldRoom.token.createdAtUnixSeconds)
            await h.replaceServer()
            let recreated = try await h.command(["new-session", "-d", "-s", "replacement", "/bin/sleep", "60"])
            #expect(recreated.exitCode == 0)
            let newRoom = try #require((try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)).rooms.first)
            #expect(newRoom.token.sessionID == oldRoom.token.sessionID)
            #expect(newRoom.token.createdAtUnixSeconds != oldRoom.token.createdAtUnixSeconds)

            let rejected = try h.startPTYClient(arguments: Candidate.initialAttachArguments(socketPath: h.socket.path, destination: oldRoom.token))
            try await h.waitForExit(rejected)
            let after = try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)
            #expect(after.rooms[0].clients.isEmpty)
        }
    }
}

private struct Fixture {
    let source: SessionRoom
    let destination: SessionRoom
    let process: IsolatedTmuxHarness.PTYClient
    let client: SessionRoom.Client

    static func make(in h: IsolatedTmuxHarness, readOnly:Bool = false) async throws -> Fixture {
        let destination = try await h.command(["new-session", "-d", "-s", "destination", "/bin/sleep", "60"])
        let source = try await h.command(["new-session", "-d", "-s", "source", "/bin/sleep", "60"])
        #expect(source.exitCode == 0)
        #expect(destination.exitCode == 0)
        var arguments=["attach-session"]
        if readOnly { arguments.append("-r") }
        arguments += ["-t","source"]
        let process = try h.startPTYClient(arguments: arguments)
        let snapshot = try await h.waitForClients(1)
        let sourceRoom = try #require(snapshot.rooms.first(where: { $0.name == "source" }))
        let destinationRoom = try #require(snapshot.rooms.first(where: { $0.name == "destination" }))
        let client = try #require(sourceRoom.clients.first)
        #expect(client.isReadOnly == readOnly)
        return Fixture(source: sourceRoom, destination: destinationRoom, process: process, client: client)
    }
}

private enum Candidate {
    static func switchArguments(socketPath: String, source: ClientKey, destination: SessionToken) -> [String] {
        let condition = commonCondition(socketPath: socketPath, server: source.server)
            + clientCondition(source)
            + sessionCondition(destination)
            + "}"
        return ["if-shell", "-F", condition, "switch-client -c '\(source.clientName)' -t '\(destination.sessionID)'", ""]
    }

    static func initialAttachArguments(socketPath: String, destination: SessionToken) -> [String] {
        let condition = commonCondition(socketPath: socketPath, server: destination.server)
            + sessionCondition(destination)
            + "}"
        return ["if-shell", "-F", condition, "attach-session -t '\(destination.sessionID)'", ""]
    }

    private static func commonCondition(socketPath: String, server: ServerIdentity) -> String {
        "#{&&:#{==:#{socket_path},\(socketPath)},#{==:#{pid},\(server.serverPID)},#{==:#{start_time},\(server.startedAtUnixSeconds)}"
    }

    private static func clientCondition(_ source: ClientKey) -> String {
        let tty = source.tty ?? ""
        let exact = "#{&&:#{==:#{client_name},\(source.clientName)},#{==:#{client_tty},\(tty)},#{==:#{client_pid},\(source.clientPID)},#{==:#{client_created},\(source.createdAtUnixSeconds)}}"
        return ",#{m:*1*,#{L:#{?\(exact),1,}}}"
    }

    private static func sessionCondition(_ destination: SessionToken) -> String {
        let exact = "#{&&:#{==:#{session_id},\(destination.sessionID)},#{==:#{session_created},\(destination.createdAtUnixSeconds)}}"
        return ",#{m:*1*,#{S:#{?\(exact),1,}}}"
    }
}

private extension TmuxCommandOutput {
    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}
