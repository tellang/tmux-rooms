import Foundation
import TmuxRoomsCore

typealias OpenRoute = TmuxOpenRoute

enum RoomActionIntent: Sendable, Hashable {
    case refresh
    case open(session: SessionToken, route: OpenRoute)
    case preview(session: SessionToken)
    case duplicateWindow(session: SessionToken)
    case delete(session: SessionToken)
    case resolveManaged(session: SessionToken, resolution: ManagedRecoveryResolution)

    var fixtureSummary: String {
        switch self {
        case .refresh: "refresh"
        case .open(_, let route):
            switch route {
            case .detached: "open route=detached"
            case .sole(let client): "open route=sole client=\(client.clientName)"
            case .chosen(let client): "open route=chosen client=\(client.clientName)"
            }
        case .preview: "preview"
        case .duplicateWindow: "duplicate-window"
        case .delete: "delete"
        case .resolveManaged(_, let resolution): "recover \(resolution.rawValue)"
        }
    }
}

enum ManagedRecoveryResolution: String, Sendable, Hashable {
    case choosePrimary = "choose-primary"
    case choosePreview = "choose-preview"
    case cleanUp = "clean-up"
}

enum AppActionUnavailable: Sendable, Hashable {
    case terminalWiringPending
    case clientCannotBeFocused
}

enum AppActionFailure: Sendable, Hashable {
    case automationDenied
    case staleTarget
    case timeout(underlyingOperationRunning: Bool)
    case ambiguousManaged
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

    init() {
        let loader = TmuxSnapshotLoader()
        let socket: URL
        do {
            socket = try DefaultTmuxEndpointResolver.resolve()
        } catch {
            socket = URL(fileURLWithPath: "/tmp/tmux-\(getuid())/default")
        }
        controller = TmuxController(
            socketURL: socket,
            loader: loader,
            deleter: TmuxDeleteExecutor(snapshotLoader: loader),
            terminal: TerminalController()
        )
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        switch intent {
        case .refresh:
            controller.requestRefresh()
            await waitUntilIdle()
            if let failure = controller.refreshError { return .failed(.tmux(failure)) }
            return await success(snapshot: controller.snapshot)
        case .delete(let token):
            guard controller.delete(token) else {
                return .failed(.other("Another room action is still running."))
            }
            await waitUntilIdle()
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
        case .resolveManaged:
            return .unavailable(.terminalWiringPending)
        }
    }

    private func completedAction() async -> AppActionResult {
        await waitUntilIdle()
        if let failure = controller.refreshError { return .failed(.tmux(failure)) }
        return await map(controller.lastActionResult, snapshot: controller.snapshot)
    }

    private func busyResult() -> AppActionResult {
        .failed(.other("Another room action is still running."))
    }

    private func waitUntilIdle() async {
        while controller.phase != .idle {
            await Task.yield()
        }
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
        case .terminalFailure(.ambiguous): .failed(.ambiguousManaged)
        case .terminalFailure(let failure): .failed(.terminal(failure))
        case nil: .failed(.other("The action completed without a result."))
        }
    }
}
