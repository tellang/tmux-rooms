import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("room action policy", .serialized)
@MainActor
struct TmuxControllerActionTests {
    @Test("Open revalidates detached, sole, and chosen route provenance")
    func strictOpenRoutes() async throws {
        for testCase in OpenCase.allCases {
            let terminal = FakeActionTerminal()
            let fresh = actionSnapshot(interactiveCount: testCase.freshCount)
            let loader = ActionSequenceLoader([fresh, fresh])
            let controller = makeActionController(loader: loader, terminal: terminal)
            let room = fresh.rooms[0]
            let route: TmuxOpenRoute
            switch testCase {
            case .detachedValid: route = .detached
            case .detachedStale: route = .detached
            case .soleValid: route = .sole(room.interactiveClients[0].key)
            case .soleStaleCount: route = .sole(room.interactiveClients[0].key)
            case .soleStaleKey: route = .sole(staleKey(for: room.token.server))
            case .chosenValid: route = .chosen(room.interactiveClients[1].key)
            case .chosenStaleCount: route = .chosen(room.interactiveClients[0].key)
            case .chosenStaleKey: route = .chosen(staleKey(for: room.token.server))
            }

            #expect(controller.open(room.token, route: route))
            await actionEventually { controller.phase == .idle }
            #expect(controller.lastActionResult == (testCase.valid ? .succeeded : .staleTarget))
            #expect(terminal.ensureCalls == (testCase == .detachedValid ? 1 : 0))
            #expect(terminal.focusCalls.count == (testCase.focuses ? 1 : 0))
            #expect(await loader.callCount == 2)
        }
    }

    @Test("Preview reuses one managed role and Duplicate is the only explicit extra launch")
    func previewAndDuplicatePolicy() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let terminal = FakeActionTerminal()
        let loader = ActionSequenceLoader(Array(repeating: fresh, count: 6))
        let controller = makeActionController(loader: loader, terminal: terminal)
        let token = fresh.rooms[0].token

        #expect(controller.preview(token)); await actionEventually { controller.phase == .idle }
        #expect(controller.preview(token)); await actionEventually { controller.phase == .idle }
        #expect(terminal.ensureCalls == 2)
        #expect(terminal.ensureRoles == [.preview, .preview])
        #expect(terminal.duplicateCalls == 0)

        #expect(controller.duplicateWindow(token)); await actionEventually { controller.phase == .idle }
        #expect(terminal.duplicateCalls == 1)
        #expect(terminal.lastDuplicateReadOnly == false)
        #expect(await loader.callCount == 6)
    }

    @Test("actions are single-flight and still-pending launch blocks retry")
    func singleFlightPending() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let record = actionRecord(token: fresh.rooms[0].token, role: .preview, state: .timedOutButRunning)
        let terminal = FakeActionTerminal(outcome: .pending(record), reconciled: [record])
        let loader = ActionSequenceLoader(Array(repeating: fresh, count: 20))
        let controller = makeActionController(loader: loader, terminal: terminal)
        let token = fresh.rooms[0].token

        #expect(controller.preview(token))
        #expect(controller.preview(token) == false)
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .terminalFailure(.operationPending))
        #expect(terminal.ensureCalls == 1)
    }

    @Test("immediate Automation errors remain typed")
    func typedAutomationError() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let terminal = FakeActionTerminal(error: ManagedTerminalError.automation(.permissionDenied))
        let loader = ActionSequenceLoader([fresh, fresh])
        let controller = makeActionController(loader: loader, terminal: terminal)

        #expect(controller.open(fresh.rooms[0].token, route: .detached))
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .terminalFailure(.permissionDenied))
    }

    @Test("failed managed role enters recovery instead of a stale-target loop")
    func failedManagedRoleRequiresRecovery() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let record = actionRecord(token: fresh.rooms[0].token, role: .primary, state: .failed)
        let terminal = FakeActionTerminal(outcome: .failed(record), reconciled: [record])
        let controller = makeActionController(loader: ActionSequenceLoader([fresh, fresh]), terminal: terminal)

        #expect(controller.open(fresh.rooms[0].token, route: .detached))
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .terminalFailure(.managedRecoveryRequired))
    }

    @Test("deferred Duplicate owns the flight until late completion and never launches twice")
    func deferredDuplicateSingleFlight() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let terminal = DeferredDuplicateTerminal(token: fresh.rooms[0].token)
        let loader = ActionSequenceLoader([fresh, fresh, fresh])
        let controller = TmuxController(
            socketURL: URL(fileURLWithPath: "/tmp/action-controller"),
            loader: loader,
            deleter: ActionNoopDeleter(),
            terminal: terminal,
            terminalPolling: .init(interval: .milliseconds(1), deadline: .milliseconds(50))
        )
        let token = fresh.rooms[0].token

        #expect(controller.duplicateWindow(token, softDeadline: .milliseconds(1)))
        await actionEventually { terminal.waiting }
        #expect(controller.phase == .reconciling)
        #expect(controller.duplicateWindow(token, softDeadline: .milliseconds(1)) == false)
        #expect(terminal.launchCalls == 1)

        terminal.complete()
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .succeeded)
        #expect(terminal.launchCalls == 1)
        #expect(await loader.callCount == 3)
    }

    @Test("Duplicate remains single-flight across delayed tmux ownership polling")
    func duplicatePollsUntilOwned() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let terminal = DelayedOwnershipTerminal(token: fresh.rooms[0].token, role: nil, completeOnReconcile: 4)
        let loader = ActionSequenceLoader(Array(repeating: fresh, count: 10))
        let controller = TmuxController(
            socketURL: URL(fileURLWithPath: "/tmp/action-controller"), loader: loader,
            deleter: ActionNoopDeleter(), terminal: terminal,
            terminalPolling: .init(interval: .milliseconds(20), deadline: .seconds(1))
        )

        #expect(controller.duplicateWindow(fresh.rooms[0].token, softDeadline: .milliseconds(1)))
        await actionEventually { terminal.waiting }
        terminal.completeAutomation()
        await actionEventually { terminal.reconcileCalls >= 2 }
        #expect(controller.phase == .reconciling)
        #expect(controller.duplicateWindow(fresh.rooms[0].token) == false)
        #expect(terminal.launchCalls == 1)
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .succeeded)
        #expect(terminal.launchCalls == 1)
        #expect(terminal.reconcileCalls >= 4)
    }

    @Test("late Preview ownership focuses exactly once after polling")
    func previewPollsThenFocusesOnce() async throws {
        let fresh = actionSnapshot(interactiveCount: 0)
        let terminal = DelayedOwnershipTerminal(token: fresh.rooms[0].token, role: .preview, completeOnReconcile: 3)
        let loader = ActionSequenceLoader(Array(repeating: fresh, count: 8))
        let controller = TmuxController(
            socketURL: URL(fileURLWithPath: "/tmp/action-controller"), loader: loader,
            deleter: ActionNoopDeleter(), terminal: terminal,
            terminalPolling: .init(interval: .milliseconds(5), deadline: .seconds(1))
        )

        #expect(controller.preview(fresh.rooms[0].token, softDeadline: .milliseconds(1)))
        await actionEventually { terminal.waiting }
        terminal.completeAutomation()
        await actionEventually { controller.phase == .idle }
        #expect(controller.lastActionResult == .succeeded)
        #expect(terminal.ensureCalls == 1)
        #expect(terminal.focusCalls == 1)
    }
}

private enum OpenCase: CaseIterable {
    case detachedValid, detachedStale, soleValid, soleStaleCount, soleStaleKey, chosenValid, chosenStaleCount, chosenStaleKey
    var freshCount: Int {
        switch self {
        case .detachedValid: 0
        case .detachedStale, .soleValid, .soleStaleKey, .chosenStaleCount: 1
        case .soleStaleCount, .chosenValid, .chosenStaleKey: 2
        }
    }
    var valid: Bool { self == .detachedValid || self == .soleValid || self == .chosenValid }
    var focuses: Bool { self == .soleValid || self == .chosenValid }
}

private actor ActionSequenceLoader: TmuxSnapshotLoading {
    private var snapshots: [RoomSnapshot]
    private(set) var callCount = 0
    init(_ snapshots: [RoomSnapshot]) { self.snapshots = snapshots }
    func load(socketURL: URL) async throws -> RoomSnapshot {
        defer { callCount += 1 }
        return snapshots[callCount]
    }
}

@MainActor
private final class FakeActionTerminal: TerminalControlling {
    var ensureCalls = 0
    var ensureRoles: [ManagedRole] = []
    var duplicateCalls = 0
    var lastDuplicateReadOnly: Bool?
    var focusCalls: [ClientKey] = []
    var reconcileCalls = 0
    let outcome: ManagedTerminalOutcome?
    let reconciled: [ManagedClientRecord]?
    let error: ManagedTerminalError?
    var lastRecord: ManagedClientRecord?

    init(outcome: ManagedTerminalOutcome? = nil, reconciled: [ManagedClientRecord]? = nil, error: ManagedTerminalError? = nil) {
        self.outcome = outcome; self.reconciled = reconciled; self.error = error
    }

    func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        ensureCalls += 1; ensureRoles.append(role)
        if let error { throw error }
        if let outcome { return outcome }
        let record = actionRecord(token: destination, role: role, state: .complete)
        lastRecord = record
        return .ready(record)
    }

    func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        duplicateCalls += 1; lastDuplicateReadOnly = readOnly
        if let error { throw error }
        if let outcome { return outcome }
        let record = actionRecord(token: destination, role: nil, state: .complete, kind: .explicitDuplicate)
        lastRecord = record
        return .ready(record)
    }

    func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult {
        focusCalls.append(clientKey)
        if let error { throw error }
        return .external(reference: .init(windowID: 1, tabIndex: 1, sessionGUID: "guid", tty: clientKey.tty ?? "/dev/ttys1"), clientKey: clientKey)
    }

    func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord] {
        reconcileCalls += 1
        if let error { throw error }
        return reconciled ?? lastRecord.map { [$0] } ?? []
    }

    func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey> {
        Set(snapshot.rooms.flatMap(\.interactiveClients).map(\.key))
    }

    func waitForPendingOperation(nonce: String) async {}
}

@MainActor
private final class DeferredDuplicateTerminal: TerminalControlling {
    private var record: ManagedClientRecord
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var launchCalls = 0
    private(set) var waiting = false

    init(token: SessionToken) {
        record = actionRecord(token: token, role: nil, state: .timedOutButRunning, kind: .explicitDuplicate)
    }

    func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        .pending(record)
    }

    func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        launchCalls += 1
        return .pending(record)
    }

    func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult {
        .external(reference: .init(windowID: 1, tabIndex: 1, sessionGUID: "deferred", tty: clientKey.tty ?? ""), clientKey: clientKey)
    }

    func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord] { [record] }
    func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey> { [] }

    func waitForPendingOperation(nonce: String) async {
        guard record.state != .complete else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        waiting = false
    }

    func complete() {
        record.state = .complete
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DelayedOwnershipTerminal: TerminalControlling {
    private var record: ManagedClientRecord
    private var continuation: CheckedContinuation<Void, Never>?
    private let completeOnReconcile: Int
    private(set) var launchCalls = 0
    private(set) var ensureCalls = 0
    private(set) var focusCalls = 0
    private(set) var reconcileCalls = 0
    private(set) var waiting = false

    init(token: SessionToken, role: ManagedRole?, completeOnReconcile: Int) {
        self.completeOnReconcile = completeOnReconcile
        record = actionRecord(token: token, role: role, state: .completedNeedsReconcile, kind: role == nil ? .explicitDuplicate : .reusableRole)
    }

    func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        ensureCalls += 1
        return .pending(record)
    }

    func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        launchCalls += 1
        return .pending(record)
    }

    func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult {
        focusCalls += 1
        return .external(reference: .init(windowID: 1, tabIndex: 1, sessionGUID: "late", tty: clientKey.tty ?? ""), clientKey: clientKey)
    }

    func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord] {
        reconcileCalls += 1
        if reconcileCalls >= completeOnReconcile {
            record.state = .complete
            record.liveClientKey = staleKey(for: record.requestedSessionToken.server)
        }
        return [record]
    }

    func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey> { [] }

    func waitForPendingOperation(nonce: String) async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        waiting = false
    }

    func completeAutomation() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeActionController(loader: ActionSequenceLoader, terminal: FakeActionTerminal) -> TmuxController {
    TmuxController(
        socketURL: URL(fileURLWithPath: "/tmp/action-controller"),
        loader: loader,
        deleter: ActionNoopDeleter(),
        terminal: terminal,
        terminalPolling: .init(interval: .milliseconds(1), deadline: .milliseconds(3))
    )
}

private struct ActionNoopDeleter: TmuxDeleting {
    func delete(_ token: SessionToken) async -> RoomActionResult { .succeeded }
}

private func actionSnapshot(interactiveCount: Int) -> RoomSnapshot {
    let server = ServerIdentity(canonicalSocketPath: "/tmp/action-controller", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
    let token = SessionToken(server: server, sessionID: "$1", createdAtUnixSeconds: 5)
    let clients = (0..<interactiveCount).map { index in
        let key = ClientKey(server: server, clientName: "client-\(index)", tty: "/dev/ttys\(index)", clientPID: Int32(20 + index), createdAtUnixSeconds: Int64(30 + index))
        return SessionRoom.Client(key: key, lastActivityAtUnixSeconds: 40, flags: [], isReadOnly: false, terminalName: "iTerm2", isControlMode: false)
    }
    return RoomSnapshot(server: server, rooms: [.init(token: token, name: "room", lastActivityAtUnixSeconds: 6, panes: [], clients: clients)])
}

private func staleKey(for server: ServerIdentity) -> ClientKey {
    .init(server: server, clientName: "stale", tty: "/dev/ttys99", clientPID: 99, createdAtUnixSeconds: 99)
}

private func actionRecord(token: SessionToken, role: ManagedRole?, state: ManagedRecordState, kind: ManagedLaunchKind = .reusableRole) -> ManagedClientRecord {
    .init(nonce: "A2345678", launchKind: kind, role: role, requestedSessionToken: token, readOnly: role == .preview, configurationState: .handshakeObserved, state: state)
}

@MainActor
private func actionEventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<2_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("condition did not become true")
}
