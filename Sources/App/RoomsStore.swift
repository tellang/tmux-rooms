import Foundation
import TmuxRoomsCore

enum ClientFocusability: Sendable, Hashable {
    case focusable
    case unavailable(reason: String)

    var isFocusable: Bool {
        if case .focusable = self { true } else { false }
    }
}

enum AppPhase: Sendable, Hashable {
    case idle
    case loading
    case acting
}

struct AppIssue: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case automationDenied = "automation-denied"
        case staleTarget = "stale"
        case timeout
        case ambiguousManaged = "ambiguous-managed"
        case general
        case terminalUnavailable = "terminal-unavailable"
    }

    enum Retry: Sendable, Hashable {
        case none
        case enabled(RoomActionIntent)
        case blockedWhileRunning
    }

    let kind: Kind
    let title: String
    let message: String
    let diagnostics: String?
    let retry: Retry
    var id: String { kind.rawValue }
}

struct ClientChooserContext: Identifiable {
    let room: SessionRoom
    var id: SessionToken { room.token }
}

struct DeleteContext: Identifiable {
    let room: SessionRoom
    var id: SessionToken { room.token }
}

@MainActor
final class RoomsStore: ObservableObject {
    @Published private(set) var snapshot: RoomSnapshot
    @Published private(set) var phase: AppPhase
    @Published var issue: AppIssue?
    @Published var chooser: ClientChooserContext?
    @Published var deleteConfirmation: DeleteContext?
    @Published private(set) var fixtureActionCount = 0
    @Published private(set) var fixtureLastAction = "none"
    @Published private(set) var fixtureActionPending = false
    @Published private(set) var fixtureMaxConcurrentActions = 0
    #if DEBUG
    @Published private(set) var fixtureIdentifier: String?
    #endif

    let isFixture: Bool
    private var handler: any RoomActionHandling
    private var focusability: [ClientKey: ClientFocusability]
    private var fixtureDefaultFocusability: ClientFocusability?
    private var fixtureBlocksActions: Bool
    private var fixtureActiveActions = 0
    private var fixtureGate: CheckedContinuation<Void, Never>?
    private var fixtureGeneration = 0

    init(
        snapshot: RoomSnapshot,
        phase: AppPhase = .idle,
        issue: AppIssue? = nil,
        focusability: [ClientKey: ClientFocusability] = [:],
        fixtureDefaultFocusability: ClientFocusability? = nil,
        fixtureBlocksActions: Bool = false,
        fixtureIdentifier: String? = nil,
        isFixture: Bool,
        handler: any RoomActionHandling
    ) {
        self.snapshot = snapshot
        self.phase = phase
        self.issue = issue
        self.focusability = focusability
        self.fixtureDefaultFocusability = fixtureDefaultFocusability
        self.fixtureBlocksActions = fixtureBlocksActions
        #if DEBUG
        self.fixtureIdentifier = fixtureIdentifier
        #endif
        self.isFixture = isFixture
        self.handler = handler
    }

    static func production() -> RoomsStore {
        let store = RoomsStore(snapshot: .noServer, isFixture: false, handler: ProductionRoomActionHandler())
        Task { await store.perform(.refresh) }
        return store
    }

    func focusability(for client: SessionRoom.Client) -> ClientFocusability {
        focusability[client.key]
            ?? fixtureDefaultFocusability
            ?? .unavailable(reason: "Terminal mapping has not been verified yet")
    }

    func open(_ room: SessionRoom) {
        let clients = room.interactiveClients
        switch clients.count {
        case 0:
            Task { await perform(.open(session: room.token, route: .detached)) }
        case 1:
            let client = clients[0]
            guard focusability(for: client).isFocusable else {
                issue = AppIssue(
                    kind: .terminalUnavailable,
                    title: "This client cannot be focused",
                    message: "Its terminal target is unavailable. Use Duplicate Window only if you want another view of this same room.",
                    diagnostics: nil,
                    retry: .none
                )
                return
            }
            Task { await perform(.open(session: room.token, route: .sole(client.key))) }
        default:
            chooser = ClientChooserContext(room: room)
        }
    }

    func select(_ client: SessionRoom.Client, in room: SessionRoom) {
        guard focusability(for: client).isFocusable else { return }
        chooser = nil
        Task { await perform(.open(session: room.token, route: .chosen(client.key))) }
    }

    func cancelChooser() {
        chooser = nil
    }

    func requestDelete(_ room: SessionRoom) {
        deleteConfirmation = DeleteContext(room: room)
    }

    func cancelDelete() {
        deleteConfirmation = nil
    }

    func confirmDelete() {
        guard let room = deleteConfirmation?.room else { return }
        deleteConfirmation = nil
        Task { await perform(.delete(session: room.token)) }
    }

    func preview(_ room: SessionRoom) {
        Task { await perform(.preview(session: room.token)) }
    }

    func duplicate(_ room: SessionRoom) {
        Task { await perform(.duplicateWindow(session: room.token)) }
    }

    func refresh() {
        Task { await perform(.refresh) }
    }

    func retry(_ intent: RoomActionIntent) {
        Task { await perform(intent) }
    }

    func resolve(_ resolution: ManagedRecoveryResolution) {
        guard let room = snapshot.rooms.first else { return }
        Task { await perform(.resolveManaged(session: room.token, resolution: resolution)) }
    }

    func completeFixtureAction() {
        guard let fixtureGate else { return }
        self.fixtureGate = nil
        fixtureActionPending = false
        fixtureGate.resume()
    }

    #if DEBUG
    func resetFixture(with replacement: RoomsStore) {
        guard isFixture, replacement.isFixture else { return }

        fixtureGeneration += 1
        if let fixtureGate {
            self.fixtureGate = nil
            fixtureGate.resume()
        }
        snapshot = replacement.snapshot
        phase = replacement.phase
        issue = replacement.issue
        chooser = nil
        deleteConfirmation = nil
        handler = replacement.handler
        focusability = replacement.focusability
        fixtureDefaultFocusability = replacement.fixtureDefaultFocusability
        fixtureBlocksActions = replacement.fixtureBlocksActions
        fixtureActionCount = 0
        fixtureLastAction = "none"
        fixtureActionPending = false
        fixtureMaxConcurrentActions = 0
        fixtureActiveActions = 0
        fixtureIdentifier = replacement.fixtureIdentifier
    }
    #endif

    private func perform(_ intent: RoomActionIntent) async {
        guard phase == .idle else { return }
        let generation = fixtureGeneration
        if isFixture {
            fixtureActionCount += 1
            fixtureLastAction = intent.fixtureSummary
            fixtureActiveActions += 1
            fixtureMaxConcurrentActions = max(fixtureMaxConcurrentActions, fixtureActiveActions)
        }
        phase = intent == .refresh ? .loading : .acting
        if fixtureBlocksActions {
            await withCheckedContinuation { continuation in
                fixtureGate = continuation
                fixtureActionPending = true
            }
        }
        guard generation == fixtureGeneration else { return }
        let result = await handler.perform(intent)
        guard generation == fixtureGeneration else { return }
        switch result {
        case let .succeeded(updated, focusableClients):
            if let updated { snapshot = updated }
            if let focusableClients {
                focusability = Dictionary(uniqueKeysWithValues: focusableClients.map { ($0, .focusable) })
            }
            issue = nil
        case .unavailable(.terminalWiringPending):
            issue = AppIssue(
                kind: .terminalUnavailable,
                title: "Terminal action not connected yet",
                message: "Inventory and safe Delete work now. Open, Preview, and Duplicate connect through the T7 TerminalBridge seam.",
                diagnostics: nil,
                retry: .none
            )
        case .unavailable(.clientCannotBeFocused):
            issue = AppIssue(kind: .terminalUnavailable, title: "Client unavailable", message: "The selected client cannot be focused.", diagnostics: nil, retry: .none)
        case .failed(let failure):
            issue = Self.issue(for: failure, retrying: intent)
        }
        if isFixture { fixtureActiveActions -= 1 }
        phase = .idle
    }

    private static func issue(for failure: AppActionFailure, retrying intent: RoomActionIntent) -> AppIssue {
        switch failure {
        case .automationDenied:
            AppIssue(kind: .automationDenied, title: "Automation access denied", message: "Allow Tmux Rooms to control iTerm in System Settings → Privacy & Security → Automation.", diagnostics: nil, retry: .none)
        case .staleTarget:
            AppIssue(kind: .staleTarget, title: "The room changed", message: "The original server-scoped target is stale. Refresh before choosing the room again.", diagnostics: nil, retry: .enabled(.refresh))
        case .timeout(let running):
            AppIssue(kind: .timeout, title: "iTerm is taking longer than expected", message: running ? "The underlying request is still running; its late result will be reconciled." : "The request timed out.", diagnostics: nil, retry: running ? .blockedWhileRunning : .enabled(intent))
        case .ambiguousManaged:
            AppIssue(kind: .ambiguousManaged, title: "Managed windows need recovery", message: "More than one candidate could be the managed Primary or Preview. Choose an owner or clean up extras before opening another.", diagnostics: nil, retry: .none)
        case .tmux(let failure):
            AppIssue(kind: .general, title: "Could not refresh tmux", message: "The last good room list is still shown.", diagnostics: String(describing: failure), retry: .enabled(.refresh))
        case .terminal(let failure):
            AppIssue(kind: .general, title: "Terminal action failed", message: "No new tmux session was created.", diagnostics: String(describing: failure), retry: .enabled(intent))
        case .other(let detail):
            AppIssue(kind: .general, title: "Action failed", message: detail, diagnostics: nil, retry: .enabled(intent))
        }
    }
}
