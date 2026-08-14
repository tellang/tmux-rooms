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
