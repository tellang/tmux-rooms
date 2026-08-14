import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("safe delete", .serialized)
struct DeleteTests {
    @Test("delete argv is static and rejects invalid machine tokens")
    func argvGolden() throws {
        let server = ServerIdentity(canonicalSocketPath: "/tmp/sock", socketDevice: 1, socketInode: 2, serverPID: 42, startedAtUnixSeconds: 99)
        let valid = SessionToken(server: server, sessionID: "$7", createdAtUnixSeconds: 123)
        let argv = try TmuxDeleteCommand.arguments(for: valid)
        #expect(argv.prefix(4) == ["-S", "/tmp/sock", "-N", "-u"])
        #expect(!argv.contains(where: { $0.contains("new-session") || $0.contains("/bin/sh") }))
        #expect(argv.joined(separator: " ").contains("$7"))
        #expect(argv.joined(separator: " ").contains("123"))
        let invalid = SessionToken(server: server, sessionID: "display name", createdAtUnixSeconds: 123)
        #expect(throws: TmuxFailure.self) { try TmuxDeleteCommand.arguments(for: invalid) }
        let leadingZero = SessionToken(server: server, sessionID: "$07", createdAtUnixSeconds: 123)
        #expect(throws: TmuxFailure.self) { try TmuxDeleteCommand.arguments(for: leadingZero) }
    }

    @Test("runner failures remain typed after exact preflight")
    func runnerFailure() async {
        let server = ServerIdentity(canonicalSocketPath: "/tmp/sock", socketDevice: 1, socketInode: 2, serverPID: 42, startedAtUnixSeconds: 99)
        let token = SessionToken(server: server, sessionID: "$7", createdAtUnixSeconds: 123)
        let room = SessionRoom(token: token, name: "never command syntax", lastActivityAtUnixSeconds: 0, panes: [], clients: [])
        let executor = TmuxDeleteExecutor(snapshotLoader: FixedLoader(.init(server: server, rooms: [room])), runner: ThrowingRunner())
        #expect(await executor.delete(token) == .tmuxFailure(.timedOut))
    }

    @Test("exact, already gone, recreated token, and server replacement are fail closed")
    func lifecycle() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            _ = try await h.command(["new-session", "-d", "-s", "unsafe display ; name", "/bin/sleep", "60"])
            _ = try await h.command(["new-session", "-d", "-s", "keeper", "/bin/sleep", "60"])
            let loader = TmuxSnapshotLoader(executableURL: h.tmux)
            let before = try await loader.load(socketURL: h.socket)
            let original = try #require(before.rooms.first(where: { $0.name == "unsafe display ; name" }))
            let executor = TmuxDeleteExecutor(snapshotLoader: loader, executableURL: h.tmux)
            #expect(await executor.delete(original.token) == .succeeded)
            let afterDelete = try await loader.load(socketURL: h.socket)
            #expect(before.rooms.count == 2)
            #expect(afterDelete.rooms.count == 1)
            #expect(afterDelete.rooms[0].name == "keeper")
            #expect(await executor.delete(original.token) == .alreadyGone)

            await h.replaceServer()
            _ = try await h.command(["new-session", "-d", "-s", "server-replacement", "/bin/sleep", "60"])
            let afterRestart = try #require((try await loader.load(socketURL: h.socket)).rooms.first)
            #expect(await executor.delete(afterDelete.rooms[0].token) == .staleTarget)
            #expect((try await loader.load(socketURL: h.socket)).rooms[0].token == afterRestart.token)
        }
    }

    @Test("replacement with the same session id during delete survives the atomic condition")
    func raceReplacement() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            _ = try await h.command(["new-session", "-d", "-s", "target", "/bin/sleep", "60"])
            let loader = TmuxSnapshotLoader(executableURL: h.tmux)
            let original = try #require((try await loader.load(socketURL: h.socket)).rooms.first)
            try await h.waitUntilNextUnixSecond(after: original.token.createdAtUnixSeconds)
            let executor = TmuxDeleteExecutor(snapshotLoader: loader, runner: ReplacingRunner(h), executableURL: h.tmux)
            #expect(await executor.delete(original.token) == .staleTarget)
            let replacement = try #require((try await loader.load(socketURL: h.socket)).rooms.first)
            #expect(replacement.token.sessionID == original.token.sessionID)
            #expect(replacement.token.createdAtUnixSeconds != original.token.createdAtUnixSeconds)
            #expect(replacement.name == "replacement")
        }
    }
}

private struct FixedLoader: TmuxSnapshotLoading {
    let snapshot: RoomSnapshot
    init(_ snapshot: RoomSnapshot) { self.snapshot = snapshot }
    func load(socketURL: URL) async throws -> RoomSnapshot { snapshot }
}

private struct ThrowingRunner: TmuxCommandRunning {
    func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput { throw TmuxFailure.timedOut }
}

private actor ReplacingRunner: TmuxCommandRunning {
    let harness: IsolatedTmuxHarness
    init(_ harness: IsolatedTmuxHarness) { self.harness = harness }
    func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput {
        await harness.replaceServer()
        let created = try await harness.command(["new-session", "-d", "-s", "replacement", "/bin/sleep", "60"])
        guard created.exitCode == 0 else { throw TmuxFailure.commandFailed(exitCode: created.exitCode, stderr: String(decoding: created.stderr, as: UTF8.self)) }
        return try await ProcessTmuxCommandRunner().run(invocation)
    }
}
