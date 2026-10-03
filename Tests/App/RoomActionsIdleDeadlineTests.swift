import Foundation
import Testing
@testable import TmuxRoomsCore

/// Never finishes, so the controller it drives never returns to `.idle`.
private struct StallingSnapshotLoader: TmuxSnapshotLoading {
    func load(socketURL: URL) async throws -> RoomSnapshot {
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}

private struct UnusedDeleter: TmuxDeleting {
    func delete(_ token: SessionToken) async -> RoomActionResult { .cancelled }
}

@MainActor
private func stalledHandler(idleDeadline: Duration) -> ProductionRoomActionHandler {
    let journalRoot = FileManager.default.temporaryDirectory
        .appending(path: "tmux-rooms-idle-deadline-\(UUID().uuidString)", directoryHint: .isDirectory)
    let controller = TmuxController(
        socketURL: URL(fileURLWithPath: "/tmp/unused.sock"),
        loader: StallingSnapshotLoader(),
        deleter: UnusedDeleter(),
        terminal: nil
    )
    return ProductionRoomActionHandler(
        controller: controller,
        terminal: TerminalController(journal: ManagedClientJournal(root: journalRoot)),
        idleDeadline: idleDeadline
    )
}

private func settles(_ predicate: @escaping @MainActor () -> Bool) async {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < end {
        if await MainActor.run(body: predicate) { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("the idle wait is bounded", .serialized)
@MainActor
struct RoomActionsIdleDeadlineTests {
    @Test("a controller that never goes idle surfaces a still-running timeout instead of waiting forever")
    func stalledRefreshTimesOut() async {
        let handler = stalledHandler(idleDeadline: .milliseconds(200))

        let started = ContinuousClock.now
        let result = await handler.perform(.refresh)
        let elapsed = started.duration(to: ContinuousClock.now)

        #expect(result == .failed(.timeout(underlyingOperationRunning: true)))
        #expect(elapsed < .seconds(5))
    }

    @Test("the wait suspends rather than blocking, so other main-actor work still runs")
    func waitingLeavesTheMainActorSchedulable() async {
        let handler = stalledHandler(idleDeadline: .milliseconds(400))

        var ticks = 0
        async let result = handler.perform(.refresh)
        let end = ContinuousClock.now.advanced(by: .milliseconds(300))
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
            ticks += 1
        }

        // Guards against the wait ever becoming a synchronous block. It does
        // not distinguish polling from a `Task.yield()` spin. That spin also
        // yields; it just burns a core doing it.
        #expect(ticks >= 10)
        #expect(await result == .failed(.timeout(underlyingOperationRunning: true)))
    }

    @Test("the store leaves acting phase so later actions are not silently dropped")
    func storeReturnsToIdleAfterAStalledAction() async {
        let handler = stalledHandler(idleDeadline: .milliseconds(200))
        let store = RoomsStore(snapshot: .noServer, isFixture: false, handler: handler)

        store.refresh()
        await settles { store.phase == .idle }

        #expect(store.issue?.kind == .timeout)
    }
}
