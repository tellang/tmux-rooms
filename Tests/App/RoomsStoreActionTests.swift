import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("production focusability routing", .serialized)
@MainActor
struct RoomsStoreActionTests {
    @Test("verified sole client reaches the handler")
    func soleClientRoutes() async throws {
        let snapshot = appSnapshot(clientCount: 1)
        let client = snapshot.rooms[0].interactiveClients[0]
        let handler = RecordingRoomActionHandler(snapshot: snapshot, focusable: [client.key])
        let store = RoomsStore(snapshot: .noServer, isFixture: false, handler: handler)

        store.refresh()
        await appEventually { store.phase == .idle && store.snapshot == snapshot }
        #expect(store.focusability(for: client).isFocusable)
        store.open(snapshot.rooms[0])
        await appEventually { handler.intents.count == 2 }

        guard case let .open(token, .sole(key)) = handler.intents.last else {
            Issue.record("verified sole client did not reach handler")
            return
        }
        #expect(token == snapshot.rooms[0].token)
        #expect(key == client.key)
    }

    @Test("chooser routes only a verified selected client")
    func chosenClientRoutes() async throws {
        let snapshot = appSnapshot(clientCount: 2)
        let unavailable = snapshot.rooms[0].interactiveClients[0]
        let focusable = snapshot.rooms[0].interactiveClients[1]
        let handler = RecordingRoomActionHandler(snapshot: snapshot, focusable: [focusable.key])
        let store = RoomsStore(snapshot: .noServer, isFixture: false, handler: handler)

        store.refresh()
        await appEventually { store.phase == .idle && store.snapshot == snapshot }
        store.open(snapshot.rooms[0])
        #expect(store.chooser != nil)
        store.select(unavailable, in: snapshot.rooms[0])
        #expect(handler.intents.count == 1)
        #expect(store.chooser != nil)
        store.select(focusable, in: snapshot.rooms[0])
        await appEventually { handler.intents.count == 2 }

        guard case let .open(_, .chosen(key)) = handler.intents.last else {
            Issue.record("verified chooser client did not reach handler")
            return
        }
        #expect(key == focusable.key)
    }

    @Test("unsupported sole client stays fail closed")
    func unsupportedSoleClientIsDisabled() async throws {
        let snapshot = appSnapshot(clientCount: 1)
        let client = snapshot.rooms[0].interactiveClients[0]
        let handler = RecordingRoomActionHandler(snapshot: snapshot, focusable: [])
        let store = RoomsStore(snapshot: .noServer, isFixture: false, handler: handler)

        store.refresh()
        await appEventually { store.phase == .idle && store.snapshot == snapshot }
        #expect(!store.focusability(for: client).isFocusable)
        store.open(snapshot.rooms[0])
        #expect(handler.intents.count == 1)
        #expect(store.issue?.kind == .terminalUnavailable)
    }

    @Test("recovery routes the exact candidate nonce without selecting an arbitrary room")
    func exactRecoveryCandidateRoutes() async throws {
        let snapshot = appSnapshot(clientCount: 0)
        let handler = RecordingRoomActionHandler(snapshot: snapshot, focusable: [])
        let store = RoomsStore(snapshot: snapshot, isFixture: false, handler: handler)
        let nonce = "ExactRecoveryCandidate001"

        store.resolve(candidateNonce: nonce, as: .cleanUp)
        await appEventually { handler.intents.count == 1 }

        guard case let .resolveManaged(actualNonce, resolution) = handler.intents[0] else {
            Issue.record("exact recovery intent was not routed")
            return
        }
        #expect(actualNonce == nonce)
        #expect(resolution == .cleanUp)
    }

    @Test("cadence refresh preserves an existing action failure")
    func cadencePreservesActionFailure() async throws {
        let snapshot = appSnapshot(clientCount: 0)
        let handler = ScriptedRoomActionHandler(results: [
            .failed(.other("open failed")),
            .succeeded(snapshot: snapshot, focusableClients: [])
        ])
        let store = RoomsStore(snapshot: snapshot, isFixture: false, handler: handler)

        store.duplicate(snapshot.rooms[0])
        await appEventually { store.issue?.message == "open failed" }
        store.automaticRefresh()
        await appEventually { handler.intents.count == 2 && store.phase == .idle }

        #expect(store.issue?.message == "open failed")
        #expect(handler.intents.last == .automaticRefresh(revalidateRecovery: false))
    }

    @Test("cadence refresh keeps revalidated recovery candidates")
    func cadenceKeepsRecoveryCandidates() async throws {
        let snapshot = appSnapshot(clientCount: 0)
        let first = recoveryCandidate(nonce: "RecoveryCandidate00000001", snapshot: snapshot)
        let refreshed = recoveryCandidate(nonce: "RecoveryCandidate00000002", snapshot: snapshot)
        let handler = ScriptedRoomActionHandler(results: [
            .failed(.ambiguousManaged([refreshed]))
        ])
        let store = RoomsStore(
            snapshot: snapshot,
            issue: recoveryIssue([first]),
            isFixture: false,
            handler: handler
        )

        store.automaticRefresh()
        await appEventually { store.phase == .idle && handler.intents.count == 1 }

        #expect(store.issue?.recoveryCandidates == [refreshed])
        #expect(handler.intents.last == .automaticRefresh(revalidateRecovery: true))
    }

    @Test("cadence refresh clears recovery only after no candidate revalidates")
    func cadenceClearsResolvedRecovery() async throws {
        let snapshot = appSnapshot(clientCount: 0)
        let candidate = recoveryCandidate(nonce: "RecoveryCandidate00000003", snapshot: snapshot)
        let handler = ScriptedRoomActionHandler(results: [
            .succeeded(snapshot: snapshot, focusableClients: [])
        ])
        let store = RoomsStore(
            snapshot: snapshot,
            issue: recoveryIssue([candidate]),
            isFixture: false,
            handler: handler
        )

        store.automaticRefresh()
        await appEventually { store.phase == .idle && handler.intents.count == 1 }

        #expect(store.issue == nil)
        #expect(handler.intents.last == .automaticRefresh(revalidateRecovery: true))
    }

    @Test("cadence success clears a prior inventory refresh failure")
    func cadenceClearsInventoryFailure() async throws {
        let snapshot = appSnapshot(clientCount: 0)
        let handler = ScriptedRoomActionHandler(results: [
            .succeeded(snapshot: snapshot, focusableClients: [])
        ])
        let store = RoomsStore(
            snapshot: snapshot,
            issue: AppIssue(
                kind: .general,
                title: "Could not refresh tmux",
                message: "last good list",
                diagnostics: "timed out",
                retry: .enabled(.refresh)
            ),
            isFixture: false,
            handler: handler
        )

        store.automaticRefresh()
        await appEventually { store.phase == .idle && handler.intents.count == 1 }

        #expect(store.issue == nil)
        #expect(handler.intents.last == .automaticRefresh(revalidateRecovery: false))
    }

    @Test("candidate lookup permission denial is not hidden as an empty recovery list")
    func candidateLookupPermissionIsTyped() async {
        let result = await ProductionRoomActionHandler.recoveryCandidatesResult {
            throw ManagedTerminalError.automation(.permissionDenied)
        }

        #expect(result == .failed(.automationDenied))
    }

    @Test("candidate lookup journal errors become terminal diagnostics")
    func candidateLookupJournalErrorIsTyped() async {
        let result = await ProductionRoomActionHandler.recoveryCandidatesResult {
            throw ManagedTerminalError.journal("fixture journal failure")
        }

        #expect(result == .failed(.terminal(.invalidReply)))
    }

    @Test("candidate lookup invalid replies become terminal diagnostics")
    func candidateLookupInvalidReplyIsTyped() async {
        let result = await ProductionRoomActionHandler.recoveryCandidatesResult {
            throw ManagedTerminalError.automation(.invalidReply)
        }

        #expect(result == .failed(.terminal(.invalidReply)))
    }
}

@MainActor
private final class RecordingRoomActionHandler: RoomActionHandling {
    let snapshot: RoomSnapshot
    let focusable: Set<ClientKey>
    private(set) var intents: [RoomActionIntent] = []

    init(snapshot: RoomSnapshot, focusable: Set<ClientKey>) {
        self.snapshot = snapshot; self.focusable = focusable
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        intents.append(intent)
        return .succeeded(snapshot: snapshot, focusableClients: focusable)
    }
}

@MainActor
private final class ScriptedRoomActionHandler: RoomActionHandling {
    private var results: [AppActionResult]
    private(set) var intents: [RoomActionIntent] = []

    init(results: [AppActionResult]) {
        self.results = results
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        intents.append(intent)
        guard !results.isEmpty else { return .failed(.other("missing scripted result")) }
        return results.removeFirst()
    }
}

private func recoveryCandidate(nonce: String, snapshot: RoomSnapshot) -> ManagedRecoveryCandidate {
    ManagedRecoveryCandidate(
        record: ManagedClientRecord(
            nonce: nonce,
            launchKind: .reusableRole,
            role: .primary,
            requestedSessionToken: snapshot.rooms[0].token,
            readOnly: false,
            state: .ambiguous
        ),
        roomName: snapshot.rooms[0].name
    )
}

private func recoveryIssue(_ candidates: [ManagedRecoveryCandidate]) -> AppIssue {
    AppIssue(
        kind: .ambiguousManaged,
        title: "Managed windows need recovery",
        message: "fixture",
        diagnostics: nil,
        retry: .none,
        recoveryCandidates: candidates
    )
}

private func appSnapshot(clientCount: Int) -> RoomSnapshot {
    let server = ServerIdentity(canonicalSocketPath: "/tmp/app-routing", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
    let token = SessionToken(server: server, sessionID: "$1", createdAtUnixSeconds: 5)
    let clients = (0..<clientCount).map { index in
        SessionRoom.Client(
            key: .init(server: server, clientName: "client-\(index)", tty: "/dev/ttys\(index)", clientPID: Int32(10 + index), createdAtUnixSeconds: Int64(20 + index)),
            lastActivityAtUnixSeconds: 30,
            flags: [],
            isReadOnly: false,
            terminalName: "iTerm2",
            isControlMode: false
        )
    }
    return .init(server: server, rooms: [.init(token: token, name: "room", lastActivityAtUnixSeconds: 6, panes: [], clients: clients)])
}

@MainActor
private func appEventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<2_000 {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record("store did not reach expected state")
}
