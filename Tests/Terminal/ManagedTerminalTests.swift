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
    private(set) var createdNonces: [String] = []
    var createProbe: (() -> Void)?
    private(set) var titleUpdates: [(ManagedTerminalReference, String, String)] = []
    var titleResults: [Result<ManagedTerminalReference, SmokeAutomationError>] = []
    private var continuation: CheckedContinuation<Result<ManagedTerminalReference, SmokeAutomationError>, Never>?

    init(create: Create = .immediate(.success(managedReference)), evidence: [ManagedSessionEvidence] = []) { self.create = create; self.evidence = evidence }
    func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError> { .success(evidence.map(\.terminal)) }
    func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError> { .success(evidence) }
    func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        createCalls += 1
        createdNonces.append(nonce)
        createProbe?()
        switch create {
        case let .immediate(value): return value
        case .suspended: return await withCheckedContinuation { continuation = $0 }
        }
    }
    func setManagedSessionTitle(_ reference: ManagedTerminalReference, nonce: String, title: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        titleUpdates.append((reference, nonce, title))
        return titleResults.isEmpty ? .success(reference) : titleResults.removeFirst()
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

@Test("an unassigned reusable candidate blocks both managed role launches without side effects")
@MainActor
func unassignedReusableCandidateFailsClosed() async throws {
    for role in [ManagedRole.primary, .preview] {
        let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let unresolved = ManagedClientRecord(nonce: ManagedNonce.generate(), launchKind: .reusableRole, role: nil, requestedSessionToken: managedToken, readOnly: role == .preview, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, liveClientKey: managedKey)
        try journal.write(unresolved)
        let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: unresolved.nonce)])
        let supervisor = FakeSupervisorClient()

        let outcome = try await TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
            .ensureManaged(role: role, destination: managedToken, readOnly: role == .preview, snapshot: managedSnapshot(readOnly: role == .preview), softDeadline: .milliseconds(10))

        guard case let .ambiguous(records) = outcome else { Issue.record("unassigned reusable ownership must fail closed"); continue }
        #expect(records.map(\.nonce) == [unresolved.nonce])
        #expect(fake.createCalls == 0)
        #expect(await supervisor.count == 0)
    }
}

@Test("recovery exposes exact conflicting identities and promotes only the chosen revalidated record")
@MainActor
func exactManagedRecoverySelection() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let firstNonce = ManagedNonce.generate(), secondNonce = ManagedNonce.generate()
    let secondReference = ManagedTerminalReference(windowID: 9, tabIndex: 2, sessionGUID: "GUID-2", tty: "/dev/ttys100")
    let secondKey = ClientKey(server: managedServer, clientName: "/dev/ttys100", tty: secondReference.tty, clientPID: 41, createdAtUnixSeconds: 7)
    let snapshot = recoverySnapshot(keys: [(managedKey, false), (secondKey, false)])
    try journal.write(ManagedClientRecord(nonce: firstNonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey))
    try journal.write(ManagedClientRecord(nonce: secondNonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: secondReference, supervisorPID: 12, childPID: 13, liveClientKey: secondKey))
    let controller = TerminalController(
        automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: firstNonce), .init(terminal: secondReference, nonce: secondNonce)]),
        journal: journal
    )

    let candidates = try await controller.managedRecoveryCandidates(snapshot: snapshot)
    #expect(candidates.map(\.nonce) == [firstNonce, secondNonce].sorted())
    #expect(candidates.first(where: { $0.nonce == secondNonce })?.terminal == secondReference)
    #expect(candidates.first(where: { $0.nonce == secondNonce })?.liveClientKey == secondKey)

    let remaining = try await controller.resolveManagedCandidate(nonce: secondNonce, as: .primary, snapshot: snapshot)
    #expect(try journal.read(nonce: secondNonce)?.role == .primary)
    #expect(try journal.read(nonce: firstNonce)?.role == nil)
    #expect(remaining.map(\.nonce) == [firstNonce])
}

@Test("recovering an exact Preview candidate restores its visible room title")
@MainActor
func previewRecoveryRestoresExactTitle() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: nil, requestedSessionToken: managedToken, readOnly: true, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let snapshot = RoomSnapshot(server: managedServer, rooms: [.init(token: managedToken, name: "recovered\nroom", lastActivityAtUnixSeconds: 1, panes: [], clients: [
        .init(key: managedKey, lastActivityAtUnixSeconds: 1, flags: ["read-only"], isReadOnly: true, terminalName: "iTerm2", isControlMode: false)
    ])])

    let remaining = try await TerminalController(automation: fake, journal: journal)
        .resolveManagedCandidate(nonce: nonce, as: .preview, snapshot: snapshot)

    #expect(remaining.isEmpty)
    #expect(fake.titleUpdates.count == 1)
    #expect(fake.titleUpdates.first?.0 == managedReference)
    #expect(fake.titleUpdates.first?.1 == nonce)
    #expect(fake.titleUpdates.first?.2 == "READ ONLY · recovered room")
    #expect(try journal.read(nonce: nonce)?.role == .preview)
}

@Test("ambiguous terminal evidence cannot be promoted")
@MainActor
func ambiguousEvidenceCannotBePromoted() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    try journal.write(ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey))
    let evidence = [ManagedSessionEvidence(terminal: managedReference, nonce: nonce), .init(terminal: managedReference, nonce: nonce)]
    let controller = TerminalController(automation: FakeManagedAutomation(evidence: evidence), journal: journal)

    await #expect(throws: ManagedTerminalError.staleOwnership) {
        try await controller.resolveManagedCandidate(nonce: nonce, as: .primary, snapshot: managedSnapshot())
    }
    #expect(try journal.read(nonce: nonce)?.state == .ambiguous)
}

@Test("cleanup sends one typed exact-nonce detach and retires artifacts only after completed evidence")
@MainActor
func exactManagedCleanup() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: nil, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    try journal.writeConfiguration(.init(nonce: nonce, destination: managedToken, readOnly: false))
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 11, destination: managedToken, readOnly: false), to: journal.handshakeURL(nonce))
    let supervisor = FakeSupervisorClient()
    let controller = TerminalController(automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]), journal: journal, supervisorClient: supervisor)

    #expect(try await controller.cleanUpManagedCandidate(nonce: nonce, snapshot: managedSnapshot()).isEmpty)
    let requests = await supervisor.requests
    #expect(requests.count == 1)
    #expect(requests[0].nonce == nonce)
    #expect(requests[0].action == .detach)
    #expect(try journal.read(nonce: nonce) == nil)
    #expect(!FileManager.default.fileExists(atPath: journal.handshakeURL(nonce).path))
}

@Test("a false-failed partial launch with exact live evidence remains detachable")
@MainActor
func falseFailedPartialLaunchCleanup() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(
        nonce: nonce,
        launchKind: .reusableRole,
        role: .preview,
        requestedSessionToken: managedToken,
        readOnly: true,
        configurationState: .written,
        state: .failed
    )
    try journal.write(record)
    try journal.writeConfiguration(.init(nonce: nonce, destination: managedToken, readOnly: true))
    try journal.atomicWrite(
        ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 50, childPID: 51, destination: managedToken, readOnly: true),
        to: journal.handshakeURL(nonce)
    )
    let supervisor = FakeSupervisorClient()
    let automation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let controller = TerminalController(automation: automation, journal: journal, supervisorClient: supervisor)

    #expect(try await controller.cleanUpManagedCandidate(nonce: nonce, snapshot: managedSnapshot(readOnly: true)).isEmpty)
    let requests = await supervisor.requests
    #expect(requests.count == 1)
    #expect(requests[0].nonce == nonce)
    #expect(requests[0].action == .detach)
    #expect(try journal.read(nonce: nonce) == nil)
    #expect(!FileManager.default.fileExists(atPath: journal.handshakeURL(nonce).path))
}

@Test("rejected detach keeps the exact candidate and its journal evidence")
@MainActor
func rejectedManagedCleanupKeepsArtifacts() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: nil, requestedSessionToken: managedToken, readOnly: false, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    try journal.atomicWrite(ManagedSupervisorHandshake(nonce: nonce, supervisorPID: 10, childPID: 11, destination: managedToken, readOnly: false), to: journal.handshakeURL(nonce))
    let controller = TerminalController(
        automation: FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)]),
        journal: journal,
        supervisorClient: FixedSupervisorClient(status: .rejected, childPID: 11)
    )

    await #expect(throws: ManagedTerminalError.staleOwnership) {
        try await controller.cleanUpManagedCandidate(nonce: nonce, snapshot: managedSnapshot())
    }
    let retained = try #require(try journal.read(nonce: nonce))
    #expect(retained.nonce == record.nonce)
    #expect(retained.terminal == record.terminal)
    #expect(retained.liveClientKey == record.liveClientKey)
    #expect(FileManager.default.fileExists(atPath: journal.handshakeURL(nonce).path))
}

@Test("only a proven-dead non-running provisional artifact can be cleared without detach")
@MainActor
func provenDeadArtifactCleanup() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    try journal.write(ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .primary, requestedSessionToken: managedToken, readOnly: false, state: .provisional))
    let supervisor = FakeSupervisorClient()
    let controller = TerminalController(automation: FakeManagedAutomation(), journal: journal, supervisorClient: supervisor)

    #expect(try await controller.cleanUpManagedCandidate(nonce: nonce, snapshot: .noServer).isEmpty)
    #expect(await supervisor.requests.isEmpty)
    #expect(try journal.read(nonce: nonce) == nil)
}

private func recoverySnapshot(keys: [(ClientKey, Bool)]) -> RoomSnapshot {
    .init(server: managedServer, rooms: [.init(token: managedToken, name: "recovery-room", lastActivityAtUnixSeconds: 1, panes: [], clients: keys.map { key, readOnly in
        .init(key: key, lastActivityAtUnixSeconds: 1, flags: readOnly ? ["read-only"] : [], isReadOnly: readOnly, terminalName: "iTerm2", isControlMode: false)
    })])
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
    #expect(fake.createdNonces.count == 1)
    #expect(await supervisor.count == 0)
    #expect(try journal.reusableRecords(role: .primary).count == 1)
}

@Test("Preview launch persists its title marker before ownership-only Automation")
@MainActor
func previewLaunchCarriesRoomTitle() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation()
    let room = SessionRoom(token: managedToken, name: "ops \\\"blue\\\" \\\\ desk", lastActivityAtUnixSeconds: 1, panes: [], clients: managedSnapshot(readOnly: true).rooms[0].clients)
    let snapshot = RoomSnapshot(server: managedServer, rooms: [room])
    var titleMarkerObservedAtCreate: String?
    fake.createProbe = {
        titleMarkerObservedAtCreate = try? journal.reusableRecords(role: .preview).first?.pendingPreviewTitle
    }

    _ = try await TerminalController(automation: fake, journal: journal)
        .ensureManaged(role: .preview, destination: managedToken, readOnly: true, snapshot: snapshot, softDeadline: .seconds(1))

    let configuration = try #require(try journal.reusableRecords(role: .preview).first)
    #expect(fake.createdNonces == [configuration.nonce])
    #expect(titleMarkerObservedAtCreate == "READ ONLY · ops \\\"blue\\\" \\\\ desk")
    #expect(configuration.requestedSessionToken == managedToken)
    #expect(configuration.readOnly)
    #expect(configuration.pendingPreviewTitle == "READ ONLY · ops \\\"blue\\\" \\\\ desk")

    fake.evidence = [.init(terminal: managedReference, nonce: configuration.nonce)]
    let reconciled = try await TerminalController(automation: fake, journal: journal)
        .reconcile(snapshot: snapshot)
    #expect(reconciled.first?.state == .complete)
    #expect(fake.titleUpdates.first?.2 == "READ ONLY · ops \\\"blue\\\" \\\\ desk")
    #expect(try journal.read(nonce: configuration.nonce)?.pendingPreviewTitle == nil)
}

@Test("Preview title normalizes unsafe multiline room names and stays bounded")
@MainActor
func previewTitleNormalizesUnsafeRoomName() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation()
    let unsafe = "line1\nline2\rline3\0" + String(repeating: "🚀", count: 2_000)
    let room = SessionRoom(token: managedToken, name: unsafe, lastActivityAtUnixSeconds: 1, panes: [], clients: [])

    _ = try await TerminalController(automation: fake, journal: journal)
        .ensureManaged(role: .preview, destination: managedToken, readOnly: true, snapshot: .init(server: managedServer, rooms: [room]), softDeadline: .seconds(1))

    let title = try #require(try journal.reusableRecords(role: .preview).first?.pendingPreviewTitle)
    #expect(title.hasPrefix("READ ONLY · line1 line2 line3 "))
    #expect(!title.contains("\n"))
    #expect(!title.contains("\r"))
    #expect(!title.contains("\0"))
    #expect(title.utf8.count < 4_096)
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

@Test("Preview A to B reuse updates the exact managed session and tab title")
@MainActor
func previewSwitchUpdatesExactTitle() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .preview, requestedSessionToken: managedToken, readOnly: true, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let destinationKey = ClientKey(server: managedServer, clientName: managedKey.clientName, tty: managedKey.tty, clientPID: 44, createdAtUnixSeconds: 8)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot(readOnly: true).rooms[0], .init(token: destination, name: "new \"room\" \\ blue\nline", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let afterSwitch = RoomSnapshot(server: managedServer, rooms: [.init(token: destination, name: "new \"room\" \\ blue\nline", lastActivityAtUnixSeconds: 1, panes: [], clients: [
        .init(key: destinationKey, lastActivityAtUnixSeconds: 1, flags: ["read-only"], isReadOnly: true, terminalName: "iTerm2", isControlMode: false)
    ])])
    let fake = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let supervisor = FakeSupervisorClient()

    let outcome = try await TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
        .ensureManaged(role: .preview, destination: destination, readOnly: true, snapshot: beforeSwitch, softDeadline: .milliseconds(10))

    guard case let .pending(switched) = outcome else { Issue.record("expected Preview switch pending fresh snapshot"); return }
    #expect(switched.nonce == nonce)
    #expect(switched.pendingPreviewTitle == "READ ONLY · new \"room\" \\ blue line")
    #expect(fake.createCalls == 0)
    #expect(fake.titleUpdates.isEmpty)
    let reconciled = try await TerminalController(automation: fake, journal: journal, supervisorClient: supervisor)
        .reconcile(snapshot: afterSwitch)
    #expect(reconciled.first?.liveClientKey == destinationKey)
    #expect(fake.titleUpdates.count == 1)
    #expect(fake.titleUpdates.first?.0 == managedReference)
    #expect(fake.titleUpdates.first?.1 == nonce)
    #expect(fake.titleUpdates.first?.2 == "READ ONLY · new \"room\" \\ blue line")
    #expect(try journal.read(nonce: nonce)?.pendingPreviewTitle == nil)
    #expect(await supervisor.count == 1)
}

@Test("failed Preview title update survives controller recreation and retries exact ownership")
@MainActor
func previewTitleRetrySurvivesControllerRecreation() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .preview, requestedSessionToken: managedToken, readOnly: true, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let destinationKey = ClientKey(server: managedServer, clientName: managedKey.clientName, tty: managedKey.tty, clientPID: 44, createdAtUnixSeconds: 8)
    let beforeSwitch = RoomSnapshot(server: managedServer, rooms: [managedSnapshot(readOnly: true).rooms[0], .init(token: destination, name: "retry room", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let afterSwitch = RoomSnapshot(server: managedServer, rooms: [.init(token: destination, name: "retry room", lastActivityAtUnixSeconds: 1, panes: [], clients: [
        .init(key: destinationKey, lastActivityAtUnixSeconds: 1, flags: ["read-only"], isReadOnly: true, terminalName: "iTerm2", isControlMode: false)
    ])])
    let firstAutomation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    firstAutomation.titleResults = [.failure(.scriptFailure(number: -10000))]
    let supervisor = FakeSupervisorClient()
    let first = TerminalController(automation: firstAutomation, journal: journal, supervisorClient: supervisor)
    _ = try await first.ensureManaged(role: .preview, destination: destination, readOnly: true, snapshot: beforeSwitch, softDeadline: .milliseconds(10))

    let firstReconciled = try await first.reconcile(snapshot: afterSwitch)
    let persisted = try #require(try journal.read(nonce: nonce))
    #expect(persisted.pendingSwitch == nil)
    #expect(persisted.pendingPreviewTitle == "READ ONLY · retry room")
    #expect(persisted.state == .complete)
    #expect(persisted.terminal == managedReference)
    #expect(persisted.liveClientKey == destinationKey)
    #expect(firstReconciled.first?.state == .complete)
    #expect(firstReconciled.first?.terminal == managedReference)
    #expect(firstReconciled.first?.liveClientKey == destinationKey)
    #expect(firstReconciled.first?.pendingPreviewTitle == "READ ONLY · retry room")
    #expect(firstAutomation.titleUpdates.count == 1)

    let retryAutomation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])
    let recreated = TerminalController(automation: retryAutomation, journal: ManagedClientJournal(root: root), supervisorClient: supervisor)
    let reconciled = try await recreated.reconcile(snapshot: afterSwitch)
    #expect(reconciled.first?.liveClientKey == destinationKey)
    #expect(retryAutomation.titleUpdates.count == 1)
    #expect(retryAutomation.titleUpdates.first?.0 == managedReference)
    #expect(retryAutomation.titleUpdates.first?.1 == nonce)
    #expect(retryAutomation.titleUpdates.first?.2 == "READ ONLY · retry room")
    #expect(try journal.read(nonce: nonce)?.pendingPreviewTitle == nil)
    #expect(await supervisor.count == 1)
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

@Test("rejected Preview switch rolls back and clears its durable title marker")
@MainActor
func rejectedPreviewSwitchClearsTitleMarker() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: .preview, requestedSessionToken: managedToken, readOnly: true, configurationState: .handshakeObserved, state: .complete, terminal: managedReference, supervisorPID: 10, childPID: 11, liveClientKey: managedKey)
    try journal.write(record)
    let destination = SessionToken(server: managedServer, sessionID: "$2", createdAtUnixSeconds: 7)
    let snapshot = RoomSnapshot(server: managedServer, rooms: [managedSnapshot(readOnly: true).rooms[0], .init(token: destination, name: "rejected room", lastActivityAtUnixSeconds: 1, panes: [], clients: [])])
    let supervisor = FixedSupervisorClient(status: .rejected, childPID: 11)
    let automation = FakeManagedAutomation(evidence: [.init(terminal: managedReference, nonce: nonce)])

    let outcome = try await TerminalController(automation: automation, journal: journal, supervisorClient: supervisor)
        .ensureManaged(role: .preview, destination: destination, readOnly: true, snapshot: snapshot, softDeadline: .milliseconds(10))

    guard case let .pending(rolledBack) = outcome else { Issue.record("expected rollback pending fresh reconciliation"); return }
    #expect(rolledBack.requestedSessionToken == managedToken)
    #expect(rolledBack.pendingPreviewTitle == nil)
    #expect(try journal.read(nonce: nonce)?.pendingPreviewTitle == nil)
    #expect(automation.titleUpdates.isEmpty)
    #expect(await supervisor.count == 1)
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
    _ = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .seconds(1))
    _ = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: managedSnapshot(), softDeadline: .seconds(1))
    let records = try journal.allRecords()
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.launchKind == .explicitDuplicate && $0.role == nil })
    #expect(fake.createCalls == 2)
}

@Test("unresolved explicit Duplicate reuses one nonce and multiple unresolved records fail closed")
@MainActor
func unresolvedDuplicateDeduplication() async throws {
    let (journal, root) = try temporaryJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let fake = FakeManagedAutomation(create: .suspended)
    let controller = TerminalController(automation: fake, journal: journal)
    let first = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: .noServer, softDeadline: .milliseconds(10))
    guard case let .pending(original) = first else { Issue.record("expected pending Duplicate"); return }

    let second = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: .noServer, softDeadline: .milliseconds(10))
    guard case let .pending(reused) = second else { Issue.record("expected reused pending Duplicate"); return }
    #expect(reused.nonce == original.nonce)
    #expect(fake.createCalls == 1)

    let conflicting = ManagedClientRecord(nonce: ManagedNonce.generate(), launchKind: .explicitDuplicate, role: nil, requestedSessionToken: managedToken, readOnly: false, state: .completedNeedsReconcile)
    try journal.write(conflicting)
    let third = try await controller.launchDuplicate(destination: managedToken, readOnly: false, snapshot: .noServer, softDeadline: .milliseconds(10))
    guard case let .ambiguous(records) = third else { Issue.record("multiple pending Duplicates must fail closed"); return }
    #expect(records.count == 2)
    #expect(fake.createCalls == 1)
    fake.complete(.failure(.timeout))
    await controller.waitForPendingOperation(nonce: original.nonce)
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
    #expect(!script.contains("set name of createdSession"))
    #expect(!script.contains("set title of createdTab"))
    #expect(!script.contains("write text"))
    #expect(!script.contains(managedToken.sessionID))
    #expect(!script.contains(managedToken.server.canonicalSocketPath))
}

@Test("all generated managed iTerm scripts compile against the installed dictionary")
@MainActor
func managedScriptsCompile() throws {
    let nonce = ManagedNonce.generate()
    let helper = try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"))
    let scripts = [
        ITermManagedScripts.enumerate,
        try ITermManagedScripts.create(nonce: nonce, helperPath: helper),
        try ITermManagedScripts.focus(managedReference, nonce: nonce)
    ]
    for source in scripts {
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: source))
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, Comment(rawValue: error.map(String.init(describing:)) ?? "AppleScript compilation failed"))
        #expect(error == nil)
    }
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
    private(set) var requests: [ManagedSupervisorRequest] = []
    func send(_ request: ManagedSupervisorRequest, deadline: Duration) async throws -> ManagedSupervisorResponse {
        count += 1
        requests.append(request)
        return .init(requestID: request.id, status: .completed, childPID: request.action == .detach ? nil : 77)
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
