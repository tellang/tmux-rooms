import Foundation

enum RefreshCadenceActivity: Sendable, Equatable {
    case foreground
    case background

    var interval: Duration {
        switch self {
        case .foreground: .seconds(1)
        case .background: .seconds(10)
        }
    }
}

protocol RefreshCadenceClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemRefreshCadenceClock: RefreshCadenceClock {
    func sleep(for duration: Duration) async throws {
        try await Task<Never, Never>.sleep(for: duration)
    }
}

@MainActor
final class RefreshCadence {
    private let isEnabled: Bool
    private let clock: any RefreshCadenceClock
    private let refresh: @MainActor () -> Void
    private var activity: RefreshCadenceActivity = .background
    private var pendingTick: Task<Void, Never>?

    init(
        isEnabled: Bool,
        clock: any RefreshCadenceClock = SystemRefreshCadenceClock(),
        refresh: @escaping @MainActor () -> Void
    ) {
        self.isEnabled = isEnabled
        self.clock = clock
        self.refresh = refresh
    }

    func start(activity: RefreshCadenceActivity = .background) {
        guard isEnabled else { return }
        self.activity = activity
        guard pendingTick == nil else { return }
        scheduleNextTick()
    }

    func update(activity: RefreshCadenceActivity, refreshImmediately: Bool = false) {
        guard isEnabled else { return }
        let intervalChanged = self.activity != activity
        self.activity = activity

        if refreshImmediately {
            refresh()
        }
        if intervalChanged {
            pendingTick?.cancel()
            pendingTick = nil
            scheduleNextTick()
        } else if pendingTick == nil {
            scheduleNextTick()
        }
    }

    func stop() {
        pendingTick?.cancel()
        pendingTick = nil
    }

    private func scheduleNextTick() {
        let interval = activity.interval
        let clock = self.clock
        pendingTick = Task { [weak self] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingTick = nil
            self.refresh()
            self.scheduleNextTick()
        }
    }
}
