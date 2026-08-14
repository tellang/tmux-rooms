import Foundation
import TmuxRoomsCore

enum OpenRoute: Sendable, Hashable {
    case detached
    case sole(ClientKey)
    case chosen(ClientKey)
}

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
    case succeeded(snapshot: RoomSnapshot?)
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
            deleter: TmuxDeleteExecutor(snapshotLoader: loader)
        )
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        switch intent {
        case .refresh:
            controller.requestRefresh()
            await waitUntilIdle()
            if let failure = controller.refreshError { return .failed(.tmux(failure)) }
            return .succeeded(snapshot: controller.snapshot)
        case .delete(let token):
            guard controller.delete(token) else {
                return .failed(.other("Another room action is still running."))
            }
            await waitUntilIdle()
            return map(controller.lastActionResult, snapshot: controller.snapshot)
        case .open, .preview, .duplicateWindow, .resolveManaged:
            // T7 replaces this explicit seam with TerminalBridge wiring.
            return .unavailable(.terminalWiringPending)
        }
    }

    private func waitUntilIdle() async {
        while controller.phase != .idle {
            await Task.yield()
        }
    }

    private func map(_ result: RoomActionResult?, snapshot: RoomSnapshot) -> AppActionResult {
        switch result {
        case .succeeded, .alreadyGone: .succeeded(snapshot: snapshot)
        case .staleTarget: .failed(.staleTarget)
        case .cancelled: .failed(.other("The action was cancelled."))
        case .tmuxFailure(let failure): .failed(.tmux(failure))
        case .terminalFailure(.permissionDenied): .failed(.automationDenied)
        case .terminalFailure(.staleTarget), .terminalFailure(.notFound): .failed(.staleTarget)
        case .terminalFailure(.timeout): .failed(.timeout(underlyingOperationRunning: false))
        case .terminalFailure(.ambiguous): .failed(.ambiguousManaged)
        case .terminalFailure(let failure): .failed(.terminal(failure))
        case nil: .failed(.other("The action completed without a result."))
        }
    }
}
