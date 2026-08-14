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

@Test("reusable role conflicts and unresolved records fail closed without side effects")
@MainActor
func reusableRoleConflictFailsClosed() async throws {
    enum Expected { case ambiguous, pending, failed }
    let cases: [([ManagedClientRecord], Expected)] = [
        ([roleRecord(state: .ambiguous), roleRecord(state: .ambiguous)], .ambiguous),
        ([roleRecord(state: .complete), roleRecord(state: .complete)], .ambiguous),
        ([roleRecord(state: .ambiguous, liveKey: managedKey)], .ambiguous),
        ([roleRecord(state: .launching), roleRecord(state: .complete)], .ambiguous),
        ([roleRecord(state: .timedOutButRunning)], .pending),
        ([roleRecord(state: .failed)], .failed),
        ([roleRecord(state: .complete, liveKey: ClientKey(server: managedServer, clientName: "stale", tty: managedReference.tty, clientPID: 99, createdAtUnixSeconds: 99))], .failed)
    ]

    for (seed, expected) in cases {
        let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
        for record in seed { try journal.write(record) }
        let fake = FakeManagedAutomation(evidence: seed.map { .init(terminal: managedReference, nonce: $0.nonce) })
        let supervisor = FakeSupervisorClient()
        let outcome = try await TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
            .ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .milliseconds(10))
        switch (expected, outcome) {
        case (.ambiguous, .ambiguous), (.pending, .pending), (.failed, .failed): break
        default: Issue.record("unexpected fail-closed outcome: \(outcome)")
        }
        #expect(fake.createCalls == 0)
        #expect(await supervisor.count == 0)
        let after = try journal.reusableRecords(role: .primary)
        #expect(after.count == seed.count)
        #expect(Set(after.map(\.nonce)) == Set(seed.map(\.nonce)))
    }
}

@Test("initial empty reusable role launches exactly once")
@MainActor
func initialReusableRoleLaunchesOnce() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation()
    let supervisor = FakeSupervisorClient()
    _ = try await TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
        .ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .seconds(1))
    #expect(fake.createCalls == 1)
    #expect(await supervisor.count == 0)
    #expect(try journal.reusableRecords(role: .primary).count == 1)
}

@Test("initial Automation launch failure preserves its typed cause")
@MainActor
func initialAutomationFailurePreservesCause() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(create: .immediate(.failure(.permissionDenied)))
    do {
        _ = try await TerminalController(automation: fake, journal: journal)
            .ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .seconds(1))
        Issue.record("expected typed Automation failure")
    } catch let error as ManagedTerminalError {
        #expect(error == .automation(.permissionDenied))
    }
    #expect(try journal.reusableRecords(role: .primary).first?.state == .failed)
}

private func roleRecord(state: ManagedRecordState, liveKey: ClientKey? = nil) -> ManagedClientRecord {
    ManagedClientRecord(nonce: ManagedNonce.generate(), launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .written, state: state, terminal: managedReference, liveClientKey: liveKey)
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

@Test("rejected switch after terminating the old child fails without a stale owner")
@MainActor
func rejectedSwitchAfterTerminateFailsClosed() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot().rooms[0], .init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let supervisor = FixedSupervisorClient(status: .rejected, childPID: nil)
    let automation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let controller = TerminalController(automation: automation, journal: journal, supervisorClient: supervisor)

    let outcome = try await controller.ensureManaged(role: .primary, destination: destination, readOnly: false, snapshot: beforeSwitch, softDeadline: .milliseconds(10))

    guard case let .failed(rejected) = outcome else { Issue.record("rejected switch without a child must fail closed"); return }
    #expect(rejected.requestedSessionToken == managedToken)
    #expect(rejected.childPID == nil)
    #expect(rejected.liveClientKey == nil)
    #expect(rejected.pendingSwitch == nil)
    #expect(rejected.requestID != nil)
    #expect(automation.createCalls == 0)
    #expect(await supervisor.count == 1)
    #expect(try journal.allRecords().count == 1)
    let stillFailed = try await controller.reconcile(snapshot: managedSnapshot())
    #expect(stillFailed.first?.state == .failed)
    #expect(stillFailed.first?.liveClientKey == nil)
}

@Test("rejected switch preserving the old child waits for fresh exact reconciliation")
@MainActor
func rejectedSwitchPreservingChildRequiresFreshReconcile() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot().rooms[0], .init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let supervisor = FixedSupervisorClient(status: .rejected, childPID: 11)
    let automation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let controller = TerminalController(automation: automation, journal: journal, supervisorClient: supervisor)

    let outcome = try await controller.ensureManaged(role: .primary, destination: destination, readOnly: false, snapshot: beforeSwitch, softDeadline: .milliseconds(10))

    guard case let .pending(rejected) = outcome else { Issue.record("preserved child still requires fresh reconciliation"); return }
    #expect(rejected.state == .completedNeedsReconcile)
    #expect(rejected.requestedSessionToken == managedToken)
    #expect(rejected.childPID == 11)
    #expect(rejected.liveClientKey == nil)
    let intent = try #require(rejected.pendingSwitch)
    let unverified = try await controller.reconcile(snapshot: managedSnapshot())
    #expect(unverified.first?.state == .completedNeedsReconcile)
    #expect(unverified.first?.liveClientKey == nil)
    #expect(unverified.first?.pendingSwitch == intent)
    try journal.atomicWrite(ManagedSupervisorResponse(requestID: intent.requestID, status: .rejected, childPID: 11), to: journal.responsesDirectory.appending(path: "\(intent.requestID.uuidString).json"))
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 11, destination: managedToken, readOnly: false), to: journal.handshakeURL(nonce))

    let reconciled = try await controller.reconcile(snapshot: managedSnapshot())
    #expect(reconciled.first?.state == .complete)
    #expect(reconciled.first?.childPID == 11)
    #expect(reconciled.first?.liveClientKey == managedKey)
    #expect(automation.createCalls == 0)
    #expect(await supervisor.count == 1)
    #expect(try journal.allRecords().count == 1)
}

@Test("concurrent managed switches persist one intent and send exactly one request")
@MainActor
func concurrentSwitchSingleFlight() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot().rooms[0], .init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let supervisor = SuspendedSupervisorClient()
    let controller = TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: journal, supervisorClient: supervisor)
    let first = Task { @MainActor in try await controller.ensureManaged(role: .primary, destination: destination, readOnly: false, snapshot: beforeSwitch, softDeadline: .seconds(1)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await supervisor.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await supervisor.count == 1)
    let durableRecords = try journal.reusableRecords(role: .primary)
    let persisted = try #require(durableRecords.first)
    #expect(persisted.pendingSwitch?.destination == destination)
    let second = try await controller.ensureManaged(role: .primary, destination: destination, readOnly: false, snapshot: beforeSwitch, softDeadline: .milliseconds(10))
    guard case .pending = second else { Issue.record("concurrent ensure must observe pending switch"); return }
    #expect(await supervisor.count == 1)
    await supervisor.complete(status: .completed, childPID: 77)
    guard case .pending = try await first.value else { Issue.record("fresh snapshot is required after switch"); return }
    #expect(await supervisor.count == 1)
}

@Test("pending switch recovers from durable response and matching handshake after crash")
@MainActor
func switchCrashRecovery() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate(), requestID = UUID()
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let destinationKey = ClientKey(server: managedServer, clientName: managedKey.clientName, tty: managedKey.tty, clientPID: 77, createdAtUnixSeconds: 8)
    let intent = ManagedSwitchIntent(requestID: requestID, destination: destination, readOnly: false, previousSessionToken: managedToken, previousReadOnly: false, previousChildPID: 11, previousLiveClientKey: managedKey, previousState: .complete)
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .launching, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey, requestID: requestID, pendingSwitch: intent)
    try journal.write(record)
    try journal.atomicWrite(ManagedSupervisorResponse(requestID: requestID, status: .completed, childPID: 77), to: journal.responsesDirectory.appending(path: "\(requestID.uuidString).json"))
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 77, destination: destination, readOnly: false), to: journal.handshakeURL(nonce))
    let snapshot = RoomSnapshot(server: managedServer, rooms: [.init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [.init(key: destinationKey, lastActivityAtUnixSeconds: 1, flags: [], isReadOnly: false, terminalName: "iTerm2", isControlMode: false)])])
    let recovered = try await TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: journal).reconcile(snapshot: snapshot)
    #expect(recovered.first?.requestedSessionToken == destination)
    #expect(recovered.first?.childPID == 77)
    #expect(recovered.first?.liveClientKey == destinationKey)
    #expect(recovered.first?.pendingSwitch == nil)
    #expect(recovered.first?.state == .complete)
}

@Test("pending switch recovers from a matching supervisor handshake without a response")
@MainActor
func switchCrashRecoveryFromHandshakeOnly() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate(), requestID = UUID()
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let destinationKey = ClientKey(server: managedServer, clientName: managedKey.clientName, tty: managedKey.tty, clientPID: 78, createdAtUnixSeconds: 8)
    let intent = ManagedSwitchIntent(requestID: requestID, destination: destination, readOnly: false, previousSessionToken: managedToken, previousReadOnly: false, previousChildPID: 11, previousLiveClientKey: managedKey, previousState: .complete)
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .launching, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey, requestID: requestID, pendingSwitch: intent)
    try journal.write(record)
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 78, destination: destination, readOnly: false), to: journal.handshakeURL(nonce))
    let snapshot = RoomSnapshot(server: managedServer, rooms: [.init(token: destination, name: "two", lastActivityAtUnixSeconds: 1, panes: [], clients: [.init(key: destinationKey, lastActivityAtUnixSeconds: 1, flags: [], isReadOnly: false, terminalName: "iTerm2", isControlMode: false)])])
    let recovered = try await TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: journal).reconcile(snapshot: snapshot)
    #expect(recovered.first?.requestedSessionToken == destination)
    #expect(recovered.first?.childPID == 78)
    #expect(recovered.first?.liveClientKey == destinationKey)
    #expect(recovered.first?.pendingSwitch == nil)
}

@Test("rejected durable switch restores the previous live owner")
@MainActor
func rejectedSwitchRollback() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate(), requestID = UUID()
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let intent = ManagedSwitchIntent(requestID: requestID, destination: destination, readOnly: false, previousSessionToken: managedToken, previousReadOnly: false, previousChildPID: 11, previousLiveClientKey: managedKey, previousState: .complete)
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .launching, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey, requestID: requestID, pendingSwitch: intent)
    try journal.write(record)
    try journal.atomicWrite(ManagedSupervisorResponse(requestID: requestID, status: .rejected, childPID: 11), to: journal.responsesDirectory.appending(path: "\(requestID.uuidString).json"))
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 11, destination: managedToken, readOnly: false), to: journal.handshakeURL(nonce))
    let recovered = try await TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: journal).reconcile(snapshot: managedSnapshot())
    #expect(recovered.first?.requestedSessionToken == managedToken)
    #expect(recovered.first?.liveClientKey == managedKey)
    #expect(recovered.first?.pendingSwitch == nil)
    #expect(recovered.first?.state == .complete)
}

@Test("malformed durable role record blocks creation and identifies its path")
@MainActor
func corruptJournalFailsClosed() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let records = root.appending(path: "records", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    let corrupt = records.appending(path: "broken.json")
    try Data("not-json".utf8).write(to: corrupt)
    let fake = FakeManagedAutomation()
    do {
        _ = try await TerminalController(automation: fake, journal: journal).ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .milliseconds(10))
        Issue.record("corrupt durable record must throw")
    } catch let ManagedTerminalError.corruptRecord(path) {
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == corrupt.resolvingSymlinksInPath())
    }
    #expect(fake.createCalls == 0)
    #expect(try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil).count == 1)
}

@Test("arbitrary live client focus uses unique exact TTY to GUID without tmux mutation")
@MainActor
func genericClientFocus() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: ManagedNonce.generate())])
    let result = try await TerminalController(automation: fake, journal: journal).focus(clientKey: managedKey, snapshot: managedSnapshot())
    #expect(result == .external(reference: managedReference, clientKey: managedKey))
}

@Test("focusability resolves only a unique exact local iTerm TTY")
@MainActor
func exactLocalFocusability() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let unique = TerminalController(
        automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: ManagedNonce.generate())]),
        journal: journal
    )
    #expect(try await unique.focusableClientKeys(snapshot: managedSnapshot()) == [managedKey])

    let ambiguous = TerminalController(
        automation: FakeManagedAutomation(evidence: [
            .init(terminal: managedReference, nonce: ManagedNonce.generate()),
            .init(terminal: managedReference, nonce: ManagedNonce.generate())
        ]),
        journal: journal
    )
    #expect(try await ambiguous.focusableClientKeys(snapshot: managedSnapshot()).isEmpty)
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
    await controller.waitForPendingOperation(nonce: timedOut.nonce)
    #expect(try journal.read(nonce: timedOut.nonce)?.state == .recovered)
    #expect(fake.createCalls == 1)
}

@Test("late Automation journal failure is surfaced instead of silently discarded")
@MainActor
func lateAutomationFailureIsSurfaced() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(create: .suspended)
    let diagnostics = LateFailureRecorder()
    let controller = TerminalController(automation: fake, journal: journal, lateFailureHandler: { message in diagnostics.record(message) })
    let outcome = try await controller.ensureManaged(role: .primary, destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .milliseconds(20))
    guard case let .pending(record) = outcome else { Issue.record("expected timed-out launch"); return }
    try Data("corrupt".utf8).write(to: root.appending(path: "records/\(record.nonce).json"), options: .atomic)
    fake.complete(.success(managedReference))
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while diagnostics.messages.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(diagnostics.messages.count == 1)
    #expect(diagnostics.messages.first?.contains(record.nonce) == true)
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
    let system = try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), homeDirectory: URL(fileURLWithPath: "/Users/tester"))
    let user = try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/Users/tester/Applications/Tmux Rooms.app"), homeDirectory: URL(fileURLWithPath: "/Users/tester"))
    #expect(try ManagedSupervisorCLI.parse(arguments: ["--supervise", nonce]) == nonce)
    #expect(try ITermManagedScripts.command(nonce: nonce, helperPath: system) == "'/Applications/Tmux Rooms.app/Contents/Helpers/tmuxrooms-launch' --supervise \(nonce)")
    #expect(try ITermManagedScripts.command(nonce: nonce, helperPath: user) == "'/Users/tester/Applications/Tmux Rooms.app/Contents/Helpers/tmuxrooms-launch' --supervise \(nonce)")
    #expect(throws: ManagedTerminalError.self) { try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/tmp/Tmux Rooms.app"), homeDirectory: URL(fileURLWithPath: "/Users/tester")) }
    for arguments in [["--supervise", "short"], ["--supervise", "bad/value________________"], ["--supervise", nonce, "extra"], ["--root", "/tmp"]] {
        #expect(throws: ManagedSupervisorFailure.self) { try ManagedSupervisorCLI.parse(arguments: arguments) }
    }
    let script = try ITermManagedScripts.create(nonce: nonce, helperPath: system)
    #expect(script.contains(ITermManagedScripts.nonceVariable))
    #expect(script.contains(system.path))
    #expect(script.contains("create window with default profile command"))
    #expect(!script.contains("write text"))
    #expect(!script.contains(managedToken.sessionID))
    #expect(!script.contains(managedToken.server.canonicalSocketPath))
}

@Test("managed AppleScript decoding requires returned nonce and fixed ownership fields")
@MainActor
func managedAppleScriptFake() async throws {
    let nonce = ManagedNonce.generate()
    let value: AppleScriptValue = .list([.integer(8), .integer(1), .string("GUID-1"), .string("/dev/ttys099"), .string(nonce)])
    let runner = ManagedScriptRunner([.success(value), .success(.list([value]))])
    let helper = try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"))
    let automation = ITermManagedAutomation(runner: runner, helperPath: helper)
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

private actor FixedSupervisorClient: ManagedSupervisorRequesting {
    let status: ManagedSupervisorResponseStatus
    let childPID: Int32?
    private(set) var count = 0
    init(status: ManagedSupervisorResponseStatus, childPID: Int32?) { self.status = status; self.childPID = childPID }
    func send(_ request: ManagedSupervisorRequest, deadline: Duration) async throws -> ManagedSupervisorResponse {
        count += 1
        return .init(requestID: request.id, status: status, childPID: childPID)
    }
}

private actor SuspendedSupervisorClient: ManagedSupervisorRequesting {
    private(set) var count = 0
    private var request: ManagedSupervisorRequest?
    private var continuation: CheckedContinuation<ManagedSupervisorResponse, Error>?
    func send(_ request: ManagedSupervisorRequest, deadline: Duration) async throws -> ManagedSupervisorResponse {
        count += 1; self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(status: ManagedSupervisorResponseStatus, childPID: Int32?) {
        guard let request else { return }
        continuation?.resume(returning: .init(requestID: request.id, status: status, childPID: childPID))
        continuation = nil
    }
}

@MainActor
private final class LateFailureRecorder {
    private(set) var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}
