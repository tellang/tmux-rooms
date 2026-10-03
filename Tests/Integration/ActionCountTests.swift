import Foundation
import Testing
@testable import TmuxRoomsCore

@Test("repeated Open and Preview preserve counts while explicit Duplicate adds one client")
func actionCountInvariants() async throws {
    try await IsolatedTmuxHarness.withHarness { harness in
        try await runActionCountInvariants(harness)
    }
}

@MainActor
private func runActionCountInvariants(_ harness: IsolatedTmuxHarness) async throws {
        _ = try await harness.command(["new-session", "-d", "-s", "actions", "sleep", "30"])
        let loader = TmuxSnapshotLoader(executableURL: harness.tmux)
        let initial = try await loader.load(socketURL: harness.socket)
        let token = try #require(initial.rooms.first?.token)
        let terminal = HarnessActionTerminal(harness: harness)
        let controller = TmuxController(socketURL: harness.socket, loader: loader, deleter: IntegrationNoopDeleter(), terminal: terminal)

        #expect(controller.open(token, route: .detached, softDeadline: .seconds(2)))
        await integrationEventually { controller.phase == .idle }
        var live = try await loader.load(socketURL: harness.socket)
        #expect(live.rooms.count == 1)
        #expect(live.rooms[0].interactiveClients.count == 1)
        #expect(live.rooms[0].readOnlyClients.isEmpty)

        let primaryKey = try #require(live.rooms[0].interactiveClients.first?.key)
        #expect(controller.open(token, route: .sole(primaryKey), softDeadline: .seconds(2)))
        await integrationEventually { controller.phase == .idle }
        live = try await loader.load(socketURL: harness.socket)
        #expect(live.rooms.count == 1)
        #expect(live.rooms[0].interactiveClients.count == 1)

        #expect(controller.preview(token, softDeadline: .seconds(2)))
        await integrationEventually { controller.phase == .idle }
        #expect(controller.preview(token, softDeadline: .seconds(2)))
        await integrationEventually { controller.phase == .idle }
        live = try await loader.load(socketURL: harness.socket)
        #expect(live.rooms.count == 1)
        #expect(live.rooms[0].interactiveClients.count == 1)
        #expect(live.rooms[0].readOnlyClients.count == 1)

        #expect(controller.duplicateWindow(token, softDeadline: .seconds(2)))
        await integrationEventually { controller.phase == .idle }
        live = try await loader.load(socketURL: harness.socket)
        #expect(live.rooms.count == 1)
        #expect(live.rooms[0].interactiveClients.count == 2)
        #expect(live.rooms[0].readOnlyClients.count == 1)
        #expect(terminal.primaryLaunches == 1)
        #expect(terminal.previewLaunches == 1)
        #expect(terminal.duplicateLaunches == 1)
}

private struct IntegrationNoopDeleter: TmuxDeleting {
    func delete(_ token: SessionToken) async -> RoomActionResult { .succeeded }
}

@MainActor
private final class HarnessActionTerminal: TerminalControlling {
    let harness: IsolatedTmuxHarness
    var records: [String: ManagedClientRecord] = [:]
    var primaryLaunches = 0
    var previewLaunches = 0
    var duplicateLaunches = 0

    init(harness: IsolatedTmuxHarness) { self.harness = harness }

    func ensureManaged(role: ManagedRole, destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        if let record = records.values.first(where: { $0.role == role }) { return .ready(record) }
        var arguments = ["attach-session"]
        if role == .preview { arguments.append("-r") }
        arguments += ["-t", destination.sessionID]
        _ = try harness.startPTYClient(arguments: arguments)
        if role == .preview { previewLaunches += 1 } else { primaryLaunches += 1 }
        let expected = snapshot.rooms.reduce(0) { $0 + $1.clients.count } + 1
        let live = try await harness.waitForClients(expected)
        let client = try #require(live.rooms.flatMap(\.clients).first { $0.isReadOnly == (role == .preview) })
        let nonce = role == .preview ? "PREVIEW234" : "PRIMARY234"
        let record = ManagedClientRecord(nonce: nonce, launchKind: .reusableRole, role: role, requestedSessionToken: destination, readOnly: role == .preview, configurationState: .handshakeObserved, state: .complete, liveClientKey: client.key)
        records[nonce] = record
        return .ready(record)
    }

    func launchDuplicate(destination: SessionToken, readOnly: Bool, snapshot: RoomSnapshot, softDeadline: Duration) async throws -> ManagedTerminalOutcome {
        _ = try harness.startPTYClient(arguments: ["attach-session", "-t", destination.sessionID])
        duplicateLaunches += 1
        let expected = snapshot.rooms.reduce(0) { $0 + $1.clients.count } + 1
        let live = try await harness.waitForClients(expected)
        let known = Set(records.values.compactMap(\.liveClientKey))
        let key = try #require(live.rooms.flatMap(\.interactiveClients).map(\.key).first { !known.contains($0) })
        let nonce = "DUPLICATE\(duplicateLaunches)"
        let record = ManagedClientRecord(nonce: nonce, launchKind: .explicitDuplicate, role: nil, requestedSessionToken: destination, readOnly: false, configurationState: .handshakeObserved, state: .complete, liveClientKey: key)
        records[nonce] = record
        return .ready(record)
    }

    func focus(clientKey: ClientKey, snapshot: RoomSnapshot) async throws -> TerminalFocusResult {
        .external(reference: .init(windowID: 1, tabIndex: 1, sessionGUID: "integration", tty: clientKey.tty ?? ""), clientKey: clientKey)
    }

    func reconcile(snapshot: RoomSnapshot) async throws -> [ManagedClientRecord] {
        Array(records.values)
    }

    func focusableClientKeys(snapshot: RoomSnapshot) async throws -> Set<ClientKey> {
        Set(snapshot.rooms.flatMap(\.interactiveClients).map(\.key))
    }

    func waitForPendingOperation(nonce: String) async {}
}

@MainActor
private func integrationEventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<3_000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("controller did not return to idle")
}
