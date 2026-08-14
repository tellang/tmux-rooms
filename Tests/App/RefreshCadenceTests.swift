import Foundation
import Testing

@Suite("automatic refresh cadence", .serialized)
@MainActor
struct RefreshCadenceTests {
    @Test("foreground and background use the required intervals")
    func lifecycleIntervals() async {
        let clock = ManualRefreshCadenceClock()
        var refreshCount = 0
        let cadence = RefreshCadence(isEnabled: true, clock: clock) {
            refreshCount += 1
        }

        cadence.start(activity: .background)
        await cadenceEventually { await clock.requestedDurations() == [.seconds(10)] }

        cadence.update(activity: .foreground, refreshImmediately: true)
        #expect(refreshCount == 1)
        await cadenceEventually {
            await clock.requestedDurations().last == .seconds(1)
        }

        await clock.fireNext()
        await cadenceEventually { refreshCount == 2 }
        await cadenceEventually {
            await clock.requestedDurations().last == .seconds(1)
        }
        cadence.stop()
    }

    @Test("repeated starts keep one pending tick")
    func startIsSingleFlight() async {
        let clock = ManualRefreshCadenceClock()
        let cadence = RefreshCadence(isEnabled: true, clock: clock) {}

        cadence.start(activity: .foreground)
        cadence.start(activity: .foreground)
        cadence.start(activity: .foreground)

        await cadenceEventually { await clock.pendingCount() == 1 }
        #expect(await clock.requestedDurations() == [.seconds(1)])
        cadence.stop()
    }

    @Test("fixture-disabled cadence never schedules or refreshes")
    func disabledCadenceDoesNothing() async {
        let clock = ManualRefreshCadenceClock()
        var refreshCount = 0
        let cadence = RefreshCadence(isEnabled: false, clock: clock) {
            refreshCount += 1
        }

        cadence.start(activity: .foreground)
        cadence.update(activity: .foreground, refreshImmediately: true)
        for _ in 0..<20 { await Task.yield() }

        #expect(await clock.requestedDurations().isEmpty)
        #expect(refreshCount == 0)
    }
}

private actor ManualRefreshCadenceClock: RefreshCadenceClock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                durations.append(duration)
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func pendingCount() -> Int {
        waiters.count
    }

    func fireNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }
}

@MainActor
private func cadenceEventually(
    _ predicate: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<2_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("cadence did not reach expected state")
}
