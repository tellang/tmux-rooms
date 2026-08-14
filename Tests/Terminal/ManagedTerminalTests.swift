import Foundation
import Testing
@testable import TmuxRoomsCore

private let managedServer = ServerIdentity(canonicalSocketPath: "/tmp/test-socket", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
private let managedToken = SessionToken(server: managedServer, sessionID: "$1", createdAtUnixSeconds: 5)
private let managedReference = ManagedTerminalReference(windowID: 8, tabIndex: 1, sessionGUID: "GUID-1", tty: "/dev/ttys099")
private let managedKey = ClientKey(server: managedServer, clientName: "/dev/ttys099", tty: "/dev/ttys099", clientPID: 40, createdAtUnixSeconds: 6)

private func managedSnapshot(key: ClientKey = managedKey, readOnly: Bool = false) -> RoomSnapshot {
    .init(server: managedServer, rooms: [.init(token: managedToken, name: "room", lastActivityAtUnixSeconds: 1, panes: [], clients: [
        .init(key: key, lastActivityAtUnixSeconds: 1, flags: readOnly ? ["read-only"] : [], isReadOnly: readOnly, terminalName: "iTerm2", isControlMode: false)
    ])])
}

@MainActor
private final class FakeManagedAutomation: ManagedITermAutomating {
    enum Create { case immediate(Result<ManagedTerminalReference, SmokeAutomationError>), suspended }
    var create: Create
    var evidence: [ManagedSessionEvidence]
    private(set) var createCalls = 0
    private var continuation: CheckedContinuation<Result<ManagedTerminalReference, SmokeAutomationError>, Never>?

    init(create: Create = .immediate(.success(managedReference)), evidence: [ManagedSessionEvidence] = []) { self.create = create; self.evidence = evidence }
    func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError> { .success(evidence.map(\.terminal)) }
    func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError> { .success(evidence) }
    func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        createCalls += 1
        switch create {
        case let .immediate(value): return value
        case .suspended: return await withCheckedContinuation { continuation = $0 }
        }
    }
    func focusManagedSession(_ reference: ManagedTerminalReference, nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> { .success(reference) }
    func focusExactSession(_ reference: ManagedTerminalReference) async -> Result<ManagedTerminalReference, SmokeAutomationError> { .success(reference) }
    func complete(_ result: Result<ManagedTerminalReference, SmokeAutomationError>) { continuation?.resume(returning: result); continuation = nil }
}

private func temporaryJournal() throws -> (ManagedClientJournal, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-managed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return (.init(root: root), root)
}

@Test("managed ownership promotes only exact GUID nonce TTY and live ClientKey")
@MainActor
func exactManagedOwnership() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    var record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .written, state: .completedNeedsReconcile, terminal: managedReference)
    try journal.write(record)
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let reconciled = try await TerminalController(automation: fake, journal: journal).reconcile(snapshot: managedSnapshot())
    record = try #require(reconciled.first)
    #expect(record.state == .complete)
    #expect(record.liveClientKey == managedKey)
    #expect(record.configurationState == .handshakeObserved)
}

@Test("nonce, terminal identity, live key mismatches and ambiguous evidence fail closed")
@MainActor
func ownershipMismatchFailsClosed() async throws {
    for mode in 0..<4 {
        let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let nonce = ManagedNonce.generate(), otherNonce = ManagedNonce.generate()
        let otherReference = ManagedTerminalReference(windowID: 9, tabIndex: 1, sessionGUID: "GUID-2", tty: managedReference.tty)
        var record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .written, state: .completedNeedsReconcile, terminal: mode == 1 ? otherReference : managedReference)
        if mode == 2 { record.liveClientKey = ClientKey(server: managedServer, clientName: "stale", tty: managedReference.tty, clientPID: 99, createdAtUnixSeconds: 99) }
        try journal.write(record)
        let rows: [ManagedSessionEvidence] = mode == 0 ? [.init(terminal: managedReference, nonce: otherNonce)] : mode == 3 ? [.init(terminal: managedReference, nonce: nonce), .init(terminal: managedReference, nonce: nonce)] : [.init(terminal: managedReference, nonce: nonce)]
        _ = try await TerminalController(automation: FakeManagedAutomation(evidence: rows), journal: journal).reconcile(snapshot: managedSnapshot())
        let loaded = try journal.read(nonce: nonce)
        let after = try #require(loaded)
        #expect(after.liveClientKey == nil || after.liveClientKey != managedKey)
        if mode == 1 || mode == 3 { #expect(after.state == .ambiguous) }
    }
}

@Test("provisional config and handshake recovery survive journal reconstruction")
@MainActor
func crashBoundaryRecovery() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let provisional = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .preview, requestedSessionToken: managedToken, readOnly: true)
    try journal.write(provisional)
    #expect(try ManagedClientJournal(root: root).read(nonce: nonce)?.state == .provisional)
    try journal.writeConfiguration(.init(nonce: nonce, destination: managedToken, readOnly: true))
    #expect(try ManagedClientJournal(root: root).readConfiguration(nonce: nonce).readOnly)
    var launching = provisional; launching.configurationState = .written; launching.state = .launching; launching.terminal = managedReference; try journal.write(launching)
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 50, childPID: 51, destination: managedToken, readOnly: true), to: journal.handshakeURL(nonce))
    let previewSnapshot = managedSnapshot(readOnly: true)
    let recovered = try await TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: ManagedClientJournal(root: root)).reconcile(snapshot: previewSnapshot)
    #expect(recovered.first?.state == .recovered)
    #expect(recovered.first?.liveClientKey == managedKey)
    #expect(recovered.first?.supervisorPID == 50)
    #expect(recovered.first?.childPID == 51)
}

@Test("managed role switch reuses the supervisor and journal record")
@MainActor
func managedRoleSwitchReuse() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    var record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let destinationKey = ClientKey(server: managedServer, clientName: managedKey.clientName, tty: managedKey.tty, clientPID: 44, createdAtUnixSeconds: 8)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot().rooms[0], .init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let destinationSnapshot = RoomSnapshot(server: managedServer, rooms: [.init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [.init(key: destinationKey, lastActivityAtUnixSeconds: 1, flags: [], isReadOnly: false, terminalName: "iTerm2", isControlMode: false)])])
    let supervisor = FakeSupervisorClient()
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let controller = TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
    let outcome = try await controller.ensureManaged(role: .primary, destination: destination, readOnly: false, snapshot: beforeSwitch, softDeadline: .milliseconds(10))
    guard case let .pending(switched) = outcome else { Issue.record("expected switch pending fresh snapshot"); return }
    #expect(switched.nonce == nonce)
    #expect(switched.requestedSessionToken == destination)
    #expect(switched.childPID == 77)
    #expect(switched.liveClientKey == nil)
    #expect(await supervisor.count == 1)
    let allRecords = try journal.allRecords()
    record = try #require(allRecords.first)
    #expect(record.nonce == nonce)
    let reconciled = try await controller.reconcile(snapshot: destinationSnapshot)
    #expect(reconciled.first?.liveClientKey == destinationKey)
    #expect(reconciled.first?.state == .complete)
}

@Test("arbitrary live client focus uses unique exact TTY to GUID without tmux mutation")
@MainActor
func genericClientFocus() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: ManagedNonce.generate())])
    let result = try await TerminalController(automation: fake, journal: journal).focus(clientKey: managedKey, snapshot: managedSnapshot())
    #expect(result == .external(reference: managedReference, clientKey: managedKey))
}

@Test("soft timeout keeps one Automation call alive, blocks retry, and absorbs late success")
@MainActor
func timeoutLateSuccessSingleFlight() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(create: .suspended)
    let controller = TerminalController(automation: fake, journal: journal)
    let first = try await controller.ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .milliseconds(20))
    guard case let .pending(timedOut) = first else { Issue.record("expected pending"); return }
    #expect(timedOut.state == .timedOutButRunning)
    let second = try await controller.ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .milliseconds(20))
    guard case .pending = second else { Issue.record("retry should be blocked"); return }
    #expect(fake.createCalls == 1)
    fake.complete(.success(managedReference))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline, try journal.read(nonce: timedOut.nonce)?.state != .recovered { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try journal.read(nonce: timedOut.nonce)?.state == .recovered)
    #expect(fake.createCalls == 1)
}

@Test("explicit duplicates are separate records while managed roles remain reusable")
@MainActor
func duplicatePolicyBoundary() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation()
    let controller = TerminalController(automation: fake, journal: journal)
    _ = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: .noServer, softDeadline: .seconds(1))
    _ = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: .noServer, softDeadline: .seconds(1))
    let records = try journal.allRecords()
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.launchKind == .explicitDuplicate && $0.role == nil })
    #expect(fake.createCalls == 2)
}

@Test("helper CLI and golden command admit only a fixed path plus alphanumeric nonce")
func helperCommandContract() throws {
    let nonce = "A1b2C3d4E5f6G7h8I9j0K1L2"
    #expect(try ManagedSupervisorCLI.parse(arguments: ["--supervise", nonce]) == nonce)
    #expect(try ITermManagedScripts.command(nonce: nonce) == "'/Applications/Tmux Rooms.app/Contents/Helpers/tmuxrooms-launch' --supervise \(nonce)")
    for arguments in [["--supervise", "short"], ["--supervise", "bad/value________________"], ["--supervise", nonce, "extra"], ["--root", "/tmp"]] {
        #expect(throws: ManagedSupervisorFailure.self) { try ManagedSupervisorCLI.parse(arguments: arguments) }
    }
    let script = try ITermManagedScripts.create(nonce: nonce)
    #expect(script.contains(ITermManagedScripts.nonceVariable))
    #expect(script.contains(ITermManagedScripts.helperPath))
    #expect(script.contains("create window with default profile command"))
    #expect(!script.contains("write text"))
    #expect(!script.contains(managedToken.sessionID))
    #expect(!script.contains(managedToken.server.canonicalSocketPath))
}

@Test("managed AppleScript decoding requires returned nonce and fixed ownership fields")
@MainActor
func managedAppleScriptFake() async {
    let nonce = ManagedNonce.generate()
    let value: AppleScriptValue = .list([.integer(8), .integer(1), .string("GUID-1"), .string("/dev/ttys099"), .string(nonce)])
    let runner = ManagedScriptRunner([.success(value), .success(.list([value]))])
    let automation = ITermManagedAutomation(runner: runner)
    #expect(await automation.createManagedSession(nonce: nonce) == .success(managedReference))
    #expect(await automation.enumerateManagedSessions() == .success([.init(terminal: managedReference, nonce: nonce)]))
}

@MainActor
private final class ManagedScriptRunner: AppleScriptRunning {
    var replies: [AppleScriptExecution]
    init(_ replies: [AppleScriptExecution]) { self.replies = replies }
    func execute(source: String) async -> AppleScriptExecution { replies.removeFirst() }
}

private actor FakeSupervisorClient: ManagedSupervisorRequesting {
    private(set) var count = 0
    func send(_ request: ManagedSupervisorRequest, deadline: Duration) async throws -> ManagedSupervisorResponse {
        count += 1
        return .init(requestID: request.id, status: .completed, childPID: 77)
    }
}
