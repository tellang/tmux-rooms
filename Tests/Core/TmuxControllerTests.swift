import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("controller state machine", .serialized)
@MainActor
struct TmuxControllerTests {
    @Test("idle refresh publishes and malformed refresh keeps last known good")
    func refreshAndLastKnownGood() async throws {
        let loader = ControlledLoader()
        let controller = TmuxController(socketURL: URL(fileURLWithPath: "/tmp/controller"), loader: loader, deleter: ImmediateDeleter())
        controller.requestRefresh()
        await loader.waitForCalls(1)
        await loader.resolve(0, .success(snapshot(created: 1)))
        await eventually { controller.phase == .idle }
        #expect(controller.snapshot == snapshot(created: 1))

        controller.requestRefresh()
        await loader.waitForCalls(2)
        await loader.resolve(1, .failure(TmuxFailure.malformedOutput("bad")))
        await eventually { controller.phase == .idle }
        #expect(controller.snapshot == snapshot(created: 1))
        #expect(controller.refreshError == .malformedOutput("bad"))
    }

    @Test("refresh ticks coalesce to one follow-up")
    func coalescedRefresh() async throws {
        let loader = ControlledLoader()
        let controller = TmuxController(socketURL: URL(fileURLWithPath: "/tmp/controller"), loader: loader, deleter: ImmediateDeleter())
        controller.requestRefresh(); controller.requestRefresh(); controller.requestRefresh()
        await loader.waitForCalls(1)
        await loader.resolve(0, .success(snapshot(created: 1)))
        await loader.waitForCalls(2)
        await loader.resolve(1, .success(snapshot(created: 2)))
        await eventually { controller.phase == .idle }
        #expect(await loader.callCount == 2)
        #expect(controller.snapshot == snapshot(created: 2))
    }

    @Test("delete supersedes refresh, rejects a second action, reconciles, then runs one pending refresh")
    func actionOrdering() async throws {
        let loader = ControlledLoader(), deleter = ControlledDeleter()
        let controller = TmuxController(socketURL: URL(fileURLWithPath: "/tmp/controller"), loader: loader, deleter: deleter)
        let token = snapshot(created: 1).rooms[0].token
        controller.requestRefresh()
        await loader.waitForCalls(1)
        #expect(controller.delete(token) == true)
        #expect(controller.delete(token) == false)
        controller.requestRefresh()
        await deleter.waitForCalls(1)
        await loader.resolve(0, .success(snapshot(created: 99)))
        await deleter.resolve(.alreadyGone)
        await loader.waitForCalls(2)
        #expect(controller.phase == .reconciling)
        await loader.resolve(1, .success(snapshot(created: 2)))
        await loader.waitForCalls(3)
        await loader.resolve(2, .success(snapshot(created: 3)))
        await eventually { controller.phase == .idle }
        #expect(controller.snapshot == snapshot(created: 3))
        #expect(controller.lastActionResult == .alreadyGone)
        #expect(await loader.callCount == 3)
    }

    @Test("late superseded refresh error is ignored and reconcile error still returns idle")
    func lateRefreshAndRecovery() async throws {
        let loader = ControlledLoader(), deleter = ControlledDeleter()
        let controller = TmuxController(socketURL: URL(fileURLWithPath: "/tmp/controller"), loader: loader, deleter: deleter, initialSnapshot: snapshot(created: 1))
        let token = snapshot(created: 1).rooms[0].token
        controller.requestRefresh(); await loader.waitForCalls(1)
        #expect(controller.delete(token))
        await deleter.waitForCalls(1)
        await loader.resolve(0, .failure(TmuxFailure.timedOut))
        await deleter.resolve(.succeeded)
        await loader.waitForCalls(2)
        await loader.resolve(1, .failure(TmuxFailure.commandFailed(exitCode: 1, stderr: "reconcile")))
        await eventually { controller.phase == .idle }
        #expect(controller.snapshot == snapshot(created: 1))
        #expect(controller.refreshError == .commandFailed(exitCode: 1, stderr: "reconcile"))
    }
}

private actor ControlledLoader: TmuxSnapshotLoading {
    private var continuations: [CheckedContinuation<RoomSnapshot, Error>] = []
    var callCount: Int { continuations.count }
    func load(socketURL: URL) async throws -> RoomSnapshot {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func resolve(_ index: Int, _ result: Result<RoomSnapshot, Error>) { continuations[index].resume(with: result) }
    func waitForCalls(_ count: Int) async {
        while continuations.count < count { await Task.yield() }
    }
}

private actor ControlledDeleter: TmuxDeleting {
    private var continuation: CheckedContinuation<RoomActionResult, Never>?
    private(set) var calls = 0
    func delete(_ token: SessionToken) async -> RoomActionResult {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ result: RoomActionResult) { continuation?.resume(returning: result); continuation = nil }
    func waitForCalls(_ count: Int) async { while calls < count { await Task.yield() } }
}

private struct ImmediateDeleter: TmuxDeleting { func delete(_ token: SessionToken) async -> RoomActionResult { .succeeded } }

private func snapshot(created: Int64) -> RoomSnapshot {
    let server = ServerIdentity(canonicalSocketPath: "/tmp/controller", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
    let room = SessionRoom(token: .init(server: server, sessionID: "$1", createdAtUnixSeconds: created), name: "display \(created)", lastActivityAtUnixSeconds: created, panes: [], clients: [])
    return RoomSnapshot(server: server, rooms: [room])
}

@MainActor
private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
    for _ in 0..<1_000 { if predicate() { return }; await Task.yield() }
    Issue.record("condition did not become true")
}
