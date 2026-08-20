import Foundation
import TmuxRoomsCore

typealias OpenRoute = TmuxOpenRoute

enum RoomActionIntent: Sendable, Hashable {
    case refresh
    case refreshRecovery
    case automaticRefresh(revalidateRecovery: Bool)
    case open(session: SessionToken, route: OpenRoute)
    case preview(session: SessionToken)
    case duplicateWindow(session: SessionToken)
    case delete(session: SessionToken)
    case resolveManaged(candidateNonce: String, resolution: ManagedRecoveryResolution)

    var fixtureSummary: String {
        switch self {
        case .refresh: "refresh"
        case .refreshRecovery: "refresh-recovery"
        case .automaticRefresh(let revalidate): "automatic-refresh recovery=\(revalidate)"
        case .open(_, let route):
            switch route {
            case .detached: "open route=detached"
            case .sole(let client): "open route=sole client=\(client.clientName)"
            case .chosen(let client): "open route=chosen client=\(client.clientName)"
            }
        case .preview: "preview"
        case .duplicateWindow: "duplicate-window"
        case .delete: "delete"
        case .resolveManaged(let nonce, let resolution): "recover \(resolution.rawValue) candidate=\(nonce)"
        }
    }
}

enum ManagedRecoveryResolution: String, Sendable, Hashable {
    case choosePrimary = "choose-primary"
    case choosePreview = "choose-preview"
    case cleanUp = "clean-up"
}

enum AppActionUnavailable: Sendable, Hashable {
    case clientCannotBeFocused
}

enum AppActionFailure: Sendable, Hashable {
    case automationDenied
    case staleTarget
    case timeout(underlyingOperationRunning: Bool)
    case ambiguousManaged([ManagedRecoveryCandidate])
    case tmux(TmuxFailure)
    case terminal(TerminalFailure)
    case other(String)
}

enum AppActionResult: Sendable, Hashable {
    case succeeded(snapshot: RoomSnapshot?, focusableClients: Set<ClientKey>?)
    case unavailable(AppActionUnavailable)
    case failed(AppActionFailure)
}

@MainActor
protocol RoomActionHandling: AnyObject {
    func perform(_ intent: RoomActionIntent) async -> AppActionResult
}

@MainActor
final class ProductionRoomActionHandler: RoomActionHandling {
    private let controller: TmuxController
    private let terminal: TerminalController
    private let idleDeadline: Duration

    init(controller: TmuxController, terminal: TerminalController, idleDeadline: Duration) {
        self.controller = controller
        self.terminal = terminal
        self.idleDeadline = idleDeadline
    }

    init() {
        idleDeadline = .seconds(30)
        let loader = TmuxSnapshotLoader()
        let socket: URL
        do {
            socket = try DefaultTmuxEndpointResolver.resolve()
        } catch {
            socket = URL(fileURLWithPath: "/tmp/tmux-\(getuid())/default")
        }
        let terminal = TerminalController()
        self.terminal = terminal
        controller = TmuxController(
            socketURL: socket,
            loader: loader,
            deleter: TmuxDeleteExecutor(snapshotLoader: loader),
            terminal: terminal
        )
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        switch intent {
        case .refresh, .refreshRecovery, .automaticRefresh:
            controller.requestRefresh()
            guard await waitUntilIdle() else { return stillRunningResult() }
            if let failure = controller.refreshError { return .failed(.tmux(failure)) }
            let snapshot = controller.snapshot
            return await Self.refreshResult(
                intent: intent,
                snapshot: snapshot,
                loadRecovery: { try await terminal.managedRecoveryCandidates(snapshot: snapshot) },
                loadFocusableClients: { await controller.focusableClientKeys() }
            )
        case .delete(let token):
            guard controller.delete(token) else {
                return .failed(.other("Another room action is still running."))
            }
            guard await waitUntilIdle() else { return stillRunningResult() }
            if let failure = controller.refreshError {
                return .failed(.tmux(failure))
            }
            return await map(controller.lastActionResult, snapshot: controller.snapshot)
        case let .open(token, route):
            guard controller.open(token, route: route) else { return busyResult() }
            return await completedAction()
        case let .preview(token):
            guard controller.preview(token) else { return busyResult() }
            return await completedAction()
        case let .duplicateWindow(token):
            guard controller.duplicateWindow(token) else { return busyResult() }
            return await completedAction()
        case let .resolveManaged(nonce, resolution):
            do {
                controller.requestRefresh()
                guard await waitUntilIdle() else { return stillRunningResult() }
                if let failure = controller.refreshError { return .failed(.tmux(failure)) }
                let candidates: [ManagedRecoveryCandidate]
                switch resolution {
                case .choosePrimary:
                    _ = try await terminal.resolveManagedCandidate(nonce: nonce, as: .primary, snapshot: controller.snapshot)
                case .choosePreview:
                    _ = try await terminal.resolveManagedCandidate(nonce: nonce, as: .preview, snapshot: controller.snapshot)
                case .cleanUp:
                    _ = try await terminal.cleanUpManagedCandidate(nonce: nonce, snapshot: controller.snapshot)
                }
                controller.requestRefresh()
                guard await waitUntilIdle() else { return stillRunningResult() }
                if let failure = controller.refreshError { return .failed(.tmux(failure)) }
                candidates = try await terminal.managedRecoveryCandidates(snapshot: controller.snapshot)
                return candidates.isEmpty
                    ? await success(snapshot: controller.snapshot)
                    : .failed(.ambiguousManaged(candidates))
            } catch {
                return await mapRecovery(error)
            }
        }
    }

    private func completedAction() async -> AppActionResult {
        guard await waitUntilIdle() else { return stillRunningResult() }
        if let failure = controller.refreshError { return .failed(.tmux(failure)) }
        return await map(controller.lastActionResult, snapshot: controller.snapshot)
    }

    private func busyResult() -> AppActionResult {
        .failed(.other("Another room action is still running."))
    }

    /// Waits for the controller to finish its current flight.
    ///
    /// Every stage the controller runs is individually bounded — snapshot loads,
    /// terminal soft deadlines, supervisor round trips — so this only has to
    /// outlast their sum. It still keeps its own deadline: an unbounded wait
    /// leaves `RoomsStore.phase` stuck outside `.idle`, and that store drops
    /// every later action on the floor, so one stalled flight would take the
    /// whole app down with it. Polling rather than yield-spinning also stops
    /// the wait from burning a core for its whole duration.
    private func waitUntilIdle() async -> Bool {
        let end = ContinuousClock.now.advanced(by: idleDeadline)
        while controller.phase != .idle {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The controller is still working; its late result reconciles on its own.
    private func stillRunningResult() -> AppActionResult {
        .failed(.timeout(underlyingOperationRunning: true))
    }

    private func success(snapshot: RoomSnapshot) async -> AppActionResult {
        .succeeded(snapshot: snapshot, focusableClients: await controller.focusableClientKeys())
    }

    private func map(_ result: RoomActionResult?, snapshot: RoomSnapshot) async -> AppActionResult {
        switch result {
        case .succeeded, .alreadyGone: await success(snapshot: snapshot)
        case .staleTarget: .failed(.staleTarget)
        case .cancelled: .failed(.other("The action was cancelled."))
        case .tmuxFailure(let failure): .failed(.tmux(failure))
        case .terminalFailure(.permissionDenied): .failed(.automationDenied)
        case .terminalFailure(.staleTarget), .terminalFailure(.notFound): .failed(.staleTarget)
        case .terminalFailure(.timeout): .failed(.timeout(underlyingOperationRunning: false))
        case .terminalFailure(.operationPending): .failed(.timeout(underlyingOperationRunning: true))
        case .terminalFailure(.ambiguous):
            await Self.recoveryCandidatesResult {
                try await terminal.managedRecoveryCandidates(snapshot: snapshot)
            }
        case .terminalFailure(.managedRecoveryRequired):
            await Self.recoveryCandidatesResult {
                try await terminal.managedRecoveryCandidates(snapshot: snapshot)
            }
        case .terminalFailure(let failure): .failed(.terminal(failure))
        case nil: .failed(.other("The action completed without a result."))
        }
    }

    private func mapRecovery(_ error: Error) async -> AppActionResult {
        if let failure = error as? ManagedTerminalError {
            switch failure {
            case .staleOwnership, .notFound: return .failed(.staleTarget)
            case .ambiguous:
                return await Self.recoveryCandidatesResult {
                    try await terminal.managedRecoveryCandidates(snapshot: controller.snapshot)
                }
            case .automation(.permissionDenied): return .failed(.automationDenied)
            case .automation(.timeout): return .failed(.timeout(underlyingOperationRunning: false))
            default: return .failed(.terminal(.invalidReply))
            }
        }
        return .failed(.other(String(describing: error)))
    }

    static func recoveryCandidatesResult(
        load: () async throws -> [ManagedRecoveryCandidate]
    ) async -> AppActionResult {
        do {
            let candidates = try await load()
            return candidates.isEmpty
                ? .succeeded(snapshot: nil, focusableClients: nil)
                : .failed(.ambiguousManaged(candidates))
        } catch let failure as ManagedTerminalError {
            return .failed(candidateLookupFailure(failure))
        } catch {
            return .failed(.other(String(describing: error)))
        }
    }

    static func refreshResult(
        intent: RoomActionIntent,
        snapshot: RoomSnapshot,
        loadRecovery: () async throws -> [ManagedRecoveryCandidate],
        loadFocusableClients: () async -> Set<ClientKey>
    ) async -> AppActionResult {
        if case .automaticRefresh(revalidateRecovery: false) = intent {
            return .succeeded(snapshot: snapshot, focusableClients: nil)
        }

        switch intent {
        case .refreshRecovery, .automaticRefresh(revalidateRecovery: true):
            let recovery = await recoveryCandidatesResult(load: loadRecovery)
            if case .failed = recovery { return recovery }
        case .refresh:
            break
        default:
            return .failed(.other("A non-refresh action reached the refresh result policy."))
        }
        return .succeeded(snapshot: snapshot, focusableClients: await loadFocusableClients())
    }

    private static func candidateLookupFailure(_ failure: ManagedTerminalError) -> AppActionFailure {
        switch failure {
        case .automation(.permissionDenied): .automationDenied
        case .automation(.timeout): .timeout(underlyingOperationRunning: false)
        case .automation(.staleTarget), .automation(.notFound), .notFound, .staleOwnership: .staleTarget
        case .automation(.scriptFailure(let number)): .terminal(.scriptFailure(number: number))
        case .automation(.ambiguous), .ambiguous: .terminal(.ambiguous)
        case .automation(.activationNotVerified), .automation(.invalidReply), .automation(.scriptInstallFailed),
             .invalidNonce, .invalidRecord, .journal, .corruptRecord:
            .terminal(.invalidReply)
        }
    }
}
