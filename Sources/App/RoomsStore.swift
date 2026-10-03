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
    var recoveryCandidates: [ManagedRecoveryCandidate] = []
    var id: String { kind.rawValue }

    var clearsOnAutomaticInventorySuccess: Bool {
        guard case .enabled(.refresh) = retry else { return false }
        return true
    }
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
    /// The agent occupying each room, keyed by tmux session id. Rooms without a
    /// coding agent are absent from the dictionary and keep their tmux name.
    @Published private(set) var agentPresence: [String: AgentPresence]
    /// The room the app-owned Preview window is showing, if any. Only that room
    /// offers Close Preview, because there is exactly one Preview window.
    @Published private(set) var previewTarget: SessionToken?
    #if DEBUG
    @Published private(set) var fixtureIdentifier: String?
    #endif

    let isFixture: Bool
    private let agentTracker: AgentPresenceTracker?
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
        agentPresence: [String: AgentPresence] = [:],
        agentTracker: AgentPresenceTracker? = nil,
        previewTarget: SessionToken? = nil,
        handler: any RoomActionHandling
    ) {
        self.snapshot = snapshot
        self.phase = phase
        self.issue = issue
        self.agentPresence = agentPresence
        self.agentTracker = agentTracker
        self.previewTarget = previewTarget
        self.focusability = focusability
        self.fixtureDefaultFocusability = fixtureDefaultFocusability
        self.fixtureBlocksActions = fixtureBlocksActions
        #if DEBUG
        self.fixtureIdentifier = fixtureIdentifier
        #endif
        self.isFixture = isFixture
        self.handler = handler
        observeActionProgress()
    }

    /// An action reports the Preview window as soon as it owns one, seconds
    /// before the whole action finishes, so the button stops lying while the
    /// launch settles.
    private func observeActionProgress() {
        handler.previewProgress = { [weak self] state in
            guard let self else { return }
            switch state {
            case .absent: self.previewTarget = nil
            case let .active(token): self.previewTarget = token
            }
        }
    }

    static func production() -> RoomsStore {
        let store = RoomsStore(
            snapshot: .noServer,
            isFixture: false,
            agentTracker: AgentPresenceTracker(),
            handler: ProductionRoomActionHandler()
        )
        Task { await store.perform(.refresh) }
        return store
    }

    /// The label a room has earned from the agent running inside it.
    func presence(for room: SessionRoom) -> AgentPresence {
        agentPresence[room.token.sessionID] ?? .absent
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

    /// Whether this room is the one the Preview window is currently showing.
    func isPreviewing(_ room: SessionRoom) -> Bool {
        previewTarget == room.token
    }

    func closePreview(_ room: SessionRoom) {
        Task { await perform(.closePreview(session: room.token)) }
    }

    func duplicate(_ room: SessionRoom) {
        Task { await perform(.duplicateWindow(session: room.token)) }
    }

    func refresh() {
        let intent: RoomActionIntent = issue?.kind == .ambiguousManaged ? .refreshRecovery : .refresh
        Task { await perform(intent) }
    }

    func automaticRefresh() {
        Task { await perform(.automaticRefresh(revalidateRecovery: issue?.kind == .ambiguousManaged)) }
    }

    func retry(_ intent: RoomActionIntent) {
        Task { await perform(intent) }
    }

    func resolve(candidateNonce: String, as resolution: ManagedRecoveryResolution) {
        Task { await perform(.resolveManaged(candidateNonce: candidateNonce, resolution: resolution)) }
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
        agentPresence = replacement.agentPresence
        previewTarget = replacement.previewTarget
        chooser = nil
        deleteConfirmation = nil
        handler = replacement.handler
        observeActionProgress()
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
        guard phase == .idle else {
            RoomsLog.actions.notice(
                """
                action.dropped trace=\(ActionTrace.currentID, privacy: .public) \
                intent=\(intent.fixtureSummary, privacy: .public) \
                phase=\(String(describing: self.phase), privacy: .public)
                """
            )
            return
        }
        let issueBeforeRefresh = issue
        let previewBefore = previewTarget
        let trace = ActionTrace.begin()
        defer { trace.finish() }
        if !isAutomaticRefresh(intent) {
            RoomsLog.actions.notice(
                "action.requested trace=\(trace.id, privacy: .public) intent=\(intent.fixtureSummary, privacy: .public)"
            )
        }
        let generation = fixtureGeneration
        if isFixture {
            fixtureActionCount += 1
            fixtureLastAction = intent.fixtureSummary
            fixtureActiveActions += 1
            fixtureMaxConcurrentActions = max(fixtureMaxConcurrentActions, fixtureActiveActions)
        }
        phase = isRefresh(intent) ? .loading : .acting
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
        case let .succeeded(updated, focusableClients, preview):
            if let updated {
                snapshot = updated
                await refreshAgentPresence(for: updated.rooms, generation: generation)
            }
            if let focusableClients {
                focusability = Dictionary(uniqueKeysWithValues: focusableClients.map { ($0, .focusable) })
            }
            switch preview {
            case .absent: previewTarget = nil
            case let .active(token): previewTarget = token
            case nil: break
            }
            issue = issueAfterSuccessfulRefresh(intent, previous: issueBeforeRefresh)
            log(intent, trace: trace, outcome: "succeeded", previewBefore: previewBefore)
        case .unavailable(.clientCannotBeFocused):
            issue = AppIssue(kind: .terminalUnavailable, title: "Client unavailable", message: "The selected client cannot be focused.", diagnostics: nil, retry: .none)
            log(intent, trace: trace, outcome: "unavailable(clientCannotBeFocused)", previewBefore: previewBefore)
        case .failed(let failure):
            if isAutomaticRefresh(intent),
               case .tmux = failure,
               let issueBeforeRefresh {
                issue = issueBeforeRefresh
            } else {
                issue = Self.issue(for: failure, retrying: intent)
            }
            log(intent, trace: trace, outcome: "failed(\(failure))", previewBefore: previewBefore)
        }
        if isFixture { fixtureActiveActions -= 1 }
        phase = .idle
    }

    /// Relabels the rooms after a snapshot lands. The probe is advisory, so a
    /// tracker that finds nothing leaves every room on its tmux name.
    private func refreshAgentPresence(for rooms: [SessionRoom], generation: Int) async {
        guard let agentTracker else { return }
        guard await agentTracker.refresh(rooms: rooms) else { return }
        guard generation == fixtureGeneration else { return }
        agentPresence = agentTracker.presence
    }

    /// One line per finished action.
    ///
    /// The cadence fires an automatic refresh every second, so those stay quiet
    /// unless they actually moved something. Everything a person triggered is
    /// recorded either way, because that is the line worth having later.
    private func log(_ intent: RoomActionIntent, trace: ActionTrace, outcome: String, previewBefore: SessionToken?) {
        let previewChanged = previewBefore != previewTarget
        guard !isAutomaticRefresh(intent) || previewChanged || issue != nil else { return }
        RoomsLog.actions.notice(
            """
            action.finished trace=\(trace.id, privacy: .public) \
            intent=\(intent.fixtureSummary, privacy: .public) \
            outcome=\(outcome, privacy: .public) \
            ms=\(trace.elapsedMilliseconds, privacy: .public) \
            rooms=\(self.snapshot.rooms.count, privacy: .public) \
            focusable=\(self.focusability.values.filter(\.isFocusable).count, privacy: .public) \
            preview=\(self.previewTarget?.sessionID ?? "none", privacy: .public) \
            previewChanged=\(previewChanged, privacy: .public) \
            issue=\(self.issue?.kind.rawValue ?? "none", privacy: .public)
            """
        )
    }

    private func isRefresh(_ intent: RoomActionIntent) -> Bool {
        switch intent {
        case .refresh, .refreshRecovery, .automaticRefresh: true
        default: false
        }
    }

    private func isAutomaticRefresh(_ intent: RoomActionIntent) -> Bool {
        if case .automaticRefresh = intent { true } else { false }
    }

    private func issueAfterSuccessfulRefresh(_ intent: RoomActionIntent, previous: AppIssue?) -> AppIssue? {
        guard isAutomaticRefresh(intent), let previous else { return nil }
        if previous.kind == .ambiguousManaged {
            guard case .automaticRefresh(revalidateRecovery: true) = intent else { return previous }
            return nil
        }
        return previous.clearsOnAutomaticInventorySuccess ? nil : previous
    }

    private static func issue(for failure: AppActionFailure, retrying intent: RoomActionIntent) -> AppIssue {
        switch failure {
        case .automationDenied:
            AppIssue(kind: .automationDenied, title: "Automation access denied", message: "Allow Tmux Rooms to control iTerm in System Settings → Privacy & Security → Automation.", diagnostics: nil, retry: .none)
        case .staleTarget:
            AppIssue(kind: .staleTarget, title: "The room changed", message: "The original server-scoped target is stale. Refresh before choosing the room again.", diagnostics: nil, retry: .enabled(.refresh))
        case .timeout(let running):
            AppIssue(kind: .timeout, title: "iTerm is taking longer than expected", message: running ? "The underlying request is still running; its late result will be reconciled." : "The request timed out.", diagnostics: nil, retry: running ? .blockedWhileRunning : .enabled(intent))
        case .ambiguousManaged(let candidates):
            AppIssue(
                kind: .ambiguousManaged,
                title: "Managed windows need recovery",
                message: candidates.isEmpty
                    ? "Candidate ownership could not be revalidated. Refresh before trying again."
                    : "Choose an exact candidate owner or clean up that exact extra before opening another.",
                diagnostics: candidates.isEmpty ? "No revalidated candidates" : "\(candidates.count) revalidated candidate(s)",
                retry: .none,
                recoveryCandidates: candidates
            )
        case .tmux(let failure):
            AppIssue(kind: .general, title: "Could not refresh tmux", message: "The last good room list is still shown.", diagnostics: String(describing: failure), retry: .enabled(.refresh))
        case .terminal(let failure):
            AppIssue(kind: .general, title: "Terminal action failed", message: "No new tmux session was created.", diagnostics: String(describing: failure), retry: .enabled(intent))
        case .other(let detail):
            AppIssue(kind: .general, title: "Action failed", message: detail, diagnostics: nil, retry: .enabled(intent))
        }
    }
}
