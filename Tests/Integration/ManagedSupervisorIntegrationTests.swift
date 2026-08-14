import Darwin
import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("terminal-side managed supervisor", .serialized)
struct ManagedSupervisorIntegrationTests {
    @Test("initial handshake failure terminates the just-started child")
    func initialHandshakeFailureCleansUpChild() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            #expect((try await h.command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])).exitCode == 0)
            let snapshot = try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)
            let first = try #require(snapshot.rooms.first { $0.name == "first" })
            let (journal, stateRoot) = try supervisorJournal(); defer { try? FileManager.default.removeItem(at: stateRoot) }
            let writer = FailingHandshakeWriter(journal: journal, failOnWrite: 1)
            let pty = try SupervisorPTY(); defer { pty.close() }
            let supervisor = ManagedTmuxSupervisor(configuration: .init(nonce: ManagedNonce.generate(), tmuxExecutablePath: h.tmux.path, destination: first.token, readOnly: false), journal: journal, pollInterval: .milliseconds(20), io: pty.io, handshakeWriter: writer.write)

            await #expect(throws: InjectedHandshakeFailure.self) { try await supervisor.run() }

            #expect(supervisor.childPID == nil)
            #expect((try await h.waitForClients(0)).rooms.flatMap(\.clients).isEmpty)
            let launchedPID = try #require(writer.childPIDs.first)
            #expect(Darwin.kill(launchedPID, 0) == -1)
        }
    }

    @Test("switch handshake failure leaves neither the old nor new child alive")
    func switchHandshakeFailureCleansUpNewChild() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            #expect((try await h.command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])).exitCode == 0)
            #expect((try await h.command(["new-session", "-d", "-s", "second", "/bin/sleep", "60"])).exitCode == 0)
            let snapshot = try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)
            let first = try #require(snapshot.rooms.first { $0.name == "first" })
            let second = try #require(snapshot.rooms.first { $0.name == "second" })
            let (journal, stateRoot) = try supervisorJournal(); defer { try? FileManager.default.removeItem(at: stateRoot) }
            let nonce = ManagedNonce.generate()
            let writer = FailingHandshakeWriter(journal: journal, failOnWrite: 2)
            let pty = try SupervisorPTY(); defer { pty.close() }
            let supervisor = ManagedTmuxSupervisor(configuration: .init(nonce: nonce, tmuxExecutablePath: h.tmux.path, destination: first.token, readOnly: false), journal: journal, pollInterval: .milliseconds(20), io: pty.io, handshakeWriter: writer.write)
            let run = Task { try await supervisor.run() }
            do { _ = try await h.waitForClients(1) }
            catch { _ = await supervisor.handle(.init(nonce: nonce, action: .detach)); throw error }
            let oldChild = try #require(supervisor.childPID)

            let response = await supervisor.handle(.init(nonce: nonce, action: .switchSession(second.token, readOnly: false)))

            #expect(response.status == .rejected)
            #expect(response.childPID == nil)
            #expect(supervisor.childPID == nil)
            #expect((try await h.waitForClients(0)).rooms.flatMap(\.clients).isEmpty)
            let launchedPIDs = writer.childPIDs
            #expect(launchedPIDs.count == 2)
            #expect(launchedPIDs.first == oldChild)
            for pid in launchedPIDs { #expect(Darwin.kill(pid, 0) == -1) }
            #expect(await supervisor.handle(.init(nonce: nonce, action: .detach)).status == .completed)
            _ = try await run.value
        }
    }

    @Test("exact owned child relaunches, Preview is read-only, stale destination fails closed, and request IDs are idempotent")
    func exactChildLifecycle() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            #expect((try await h.command(["new-session", "-d", "-s", "first", "/bin/sleep", "60"])).exitCode == 0)
            #expect((try await h.command(["new-session", "-d", "-s", "second", "/bin/sleep", "60"])).exitCode == 0)
            let initial = try await TmuxSnapshotLoader(executableURL: h.tmux).load(socketURL: h.socket)
            let first = try #require(initial.rooms.first { $0.name == "first" })
            let second = try #require(initial.rooms.first { $0.name == "second" })
            let (journal, stateRoot) = try supervisorJournal(); defer { try? FileManager.default.removeItem(at: stateRoot) }
            let nonce = ManagedNonce.generate()
            let pty = try SupervisorPTY(); defer { pty.close() }
            let supervisor = ManagedTmuxSupervisor(configuration: .init(nonce: nonce, tmuxExecutablePath: h.tmux.path, destination: first.token, readOnly: true), journal: journal, pollInterval: .milliseconds(20), io: pty.io)
            let run = Task { try await supervisor.run() }

            let firstSnapshot: RoomSnapshot
            do { firstSnapshot = try await h.waitForClients(1) }
            catch {
                _ = await supervisor.handle(.init(nonce: nonce, action: .detach))
                throw error
            }
            let preview = try #require(firstSnapshot.rooms.first { $0.token == first.token }?.clients.first)
            #expect(preview.isReadOnly)
            let oldChild = try #require(supervisor.childPID)

            let switchRequest = ManagedSupervisorRequest(nonce: nonce, action: .switchSession(second.token, readOnly: false))
            try journal.atomicWrite(switchRequest, to: journal.requestsDirectory.appending(path: "\(switchRequest.id.uuidString).json"))
            let switched = try await waitForResponse(switchRequest.id, journal: journal)
            #expect(switched.status == .completed)
            let newChild = try #require(switched.childPID)
            #expect(newChild != oldChild)
            let secondSnapshot = try await h.waitForClients(1)
            #expect(secondSnapshot.rooms.first { $0.token == second.token }?.interactiveClients.count == 1)
            #expect(Darwin.kill(oldChild, 0) == -1)

            try journal.atomicWrite(switchRequest, to: journal.requestsDirectory.appending(path: "\(switchRequest.id.uuidString).json"))
            try await Task.sleep(for: .milliseconds(80))
            let repeated = try await waitForResponse(switchRequest.id, journal: journal)
            #expect(repeated == switched)
            #expect(supervisor.childPID == newChild)

            let staleToken = SessionToken(server: second.token.server, sessionID: second.token.sessionID, createdAtUnixSeconds: second.token.createdAtUnixSeconds - 1)
            let stale = ManagedSupervisorRequest(nonce: nonce, action: .switchSession(staleToken, readOnly: false))
            try journal.atomicWrite(stale, to: journal.requestsDirectory.appending(path: "\(stale.id.uuidString).json"))
            let rejected = try await waitForResponse(stale.id, journal: journal)
            #expect(rejected.status == .rejected)
            #expect(supervisor.childPID == newChild)
            #expect((try await h.waitForClients(1)).rooms.first { $0.token == second.token }?.interactiveClients.count == 1)

            let detach = ManagedSupervisorRequest(nonce: nonce, action: .detach)
            try journal.atomicWrite(detach, to: journal.requestsDirectory.appending(path: "\(detach.id.uuidString).json"))
            #expect(try await waitForResponse(detach.id, journal: journal).status == .completed)
            _ = try await run.value
            #expect((try await h.waitForClients(0)).rooms.flatMap(\.clients).isEmpty)
        }
    }

    @Test("initial attach arguments carry Preview -r and stale token gate")
    func initialArguments() {
        let server = ServerIdentity(canonicalSocketPath: "/tmp/s", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
        let token = SessionToken(server: server, sessionID: "$9", createdAtUnixSeconds: 5)
        let arguments = ManagedTmuxSupervisor.initialAttachArguments(.init(nonce: ManagedNonce.generate(), destination: token, readOnly: true))
        #expect(arguments.prefix(4) == ["-S", "/tmp/s", "-f", "/dev/null"])
        #expect(arguments.contains { $0.contains("attach-session -r") })
        #expect(arguments.contains { $0.contains("#{session_created},5") })
    }
}

private enum InjectedHandshakeFailure: Error { case writeFailed }

private final class FailingHandshakeWriter: @unchecked Sendable {
    private let journal: ManagedClientJournal
    private let failOnWrite: Int
    private let lock = NSLock()
    private var writeCount = 0
    private var recordedPIDs: [Int32] = []

    init(journal: ManagedClientJournal, failOnWrite: Int) { self.journal = journal; self.failOnWrite = failOnWrite }

    var childPIDs: [Int32] { lock.withLock { recordedPIDs } }

    func write(_ handshake: ManagedSupervisorHandshake, to url: URL) throws {
        let shouldFail = lock.withLock {
            writeCount += 1
            recordedPIDs.append(handshake.childPID)
            return writeCount == failOnWrite
        }
        if shouldFail { throw InjectedHandshakeFailure.writeFailed }
        try journal.atomicWrite(handshake, to: url)
    }
}

private func supervisorJournal() throws -> (ManagedClientJournal, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "tr-supervisor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (.init(root: root), root)
}

private func waitForResponse(_ id: UUID, journal: ManagedClientJournal) async throws -> ManagedSupervisorResponse {
    let url = journal.responsesDirectory.appending(path: "\(id.uuidString).json")
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if let data = try? Data(contentsOf: url), let response = try? JSONDecoder().decode(ManagedSupervisorResponse.self, from: data) { return response }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TmuxFailure.timedOut
}

private final class SupervisorPTY {
    let master: FileHandle
    let slave: FileHandle
    let io: ManagedSupervisorIO
    init() throws {
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw POSIXError(.ENXIO) }
        master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        io = ManagedSupervisorIO(input: slave, output: slave, error: slave)
    }
    func close() { master.readabilityHandler = nil; try? master.close(); try? slave.close() }
}
