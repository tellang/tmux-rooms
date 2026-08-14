import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("T7 room action policy", .serialized)
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
        let loader = ActionSequenceLoader([fresh, fresh])
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
}

@MainActor
private func makeActionController(loader: ActionSequenceLoader, terminal: FakeActionTerminal) -> TmuxController {
    TmuxController(
        socketURL: URL(fileURLWithPath: "/tmp/t7-controller"),
        loader: loader,
        deleter: ActionNoopDeleter(),
        terminal: terminal
    )
}

private struct ActionNoopDeleter: TmuxDeleting {
    func delete(_ token: SessionToken) async -> RoomActionResult { .succeeded }
}

private func actionSnapshot(interactiveCount: Int) -> RoomSnapshot {
    let server = ServerIdentity(canonicalSocketPath: "/tmp/t7-controller", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
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
        await Task.yield()
    }
    Issue.record("condition did not become true")
}
