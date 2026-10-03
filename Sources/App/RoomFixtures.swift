#if DEBUG
import Foundation
import TmuxRoomsCore

@MainActor
final class FixtureRoomActionHandler: RoomActionHandling {
    var previewProgress: (@MainActor (ManagedPreviewState) -> Void)?

    private let snapshot: RoomSnapshot

    init(snapshot: RoomSnapshot) {
        self.snapshot = snapshot
    }

    func perform(_ intent: RoomActionIntent) async -> AppActionResult {
        .succeeded(
            snapshot: isRefresh(intent) || isDelete(intent) ? snapshot : nil,
            focusableClients: nil,
            preview: nil
        )
    }

    private func isRefresh(_ intent: RoomActionIntent) -> Bool {
        switch intent {
        case .refresh, .refreshRecovery, .automaticRefresh: true
        default: false
        }
    }

    private func isDelete(_ intent: RoomActionIntent) -> Bool {
        if case .delete = intent { true } else { false }
    }
}

enum UIFixture: String, CaseIterable {
    case noServer = "v1-no-server"
    case empty = "v1-empty"
    case loading = "v1-loading"
    case detached = "v1-detached"
    case oneFocusable = "v1-one-focusable"
    case twoMixed = "v1-two-mixed"
    case readOnlyPreview = "v1-read-only-preview"
    case foreignReadOnly = "v1-foreign-read-only"
    case automationDenied = "v1-automation-denied"
    case stale = "v1-stale"
    case timeout = "v1-timeout"
    case ambiguous = "v1-ambiguous"
    case deleteAttached = "v1-delete-attached"
    case longUnicode = "v1-long-unicode"
    case generalError = "v1-general-error"
    case singleFlight = "v1-single-flight"
    case agentNamed = "v1-agent-named"
    case agentDetected = "v1-agent-detected"

    @MainActor
    func makeStore() -> RoomsStore {
        let definition = definition
        return RoomsStore(
            snapshot: definition.snapshot,
            phase: definition.phase,
            issue: definition.issue,
            focusability: definition.focusability,
            fixtureDefaultFocusability: .focusable,
            fixtureBlocksActions: definition.blocksActions,
            fixtureIdentifier: rawValue,
            isFixture: true,
            agentPresence: definition.agentPresence,
            previewTarget: definition.previewTarget,
            handler: FixtureRoomActionHandler(snapshot: definition.snapshot)
        )
    }

    @MainActor
    static func invalidStore(_ value: String) -> RoomsStore {
        let snapshot = RoomSnapshot.noServer
        let issue = AppIssue(
            kind: .general,
            title: "Unknown UI fixture",
            message: "“\(value)” is not a supported versioned fixture. Live tmux and Automation remain disabled.",
            diagnostics: nil,
            retry: .none
        )
        return RoomsStore(
            snapshot: snapshot,
            issue: issue,
            fixtureIdentifier: value,
            isFixture: true,
            handler: FixtureRoomActionHandler(snapshot: snapshot)
        )
    }

    private var definition: Definition {
        let basic = Fixtures.room(name: "fixture-room", id: "$1")
        switch self {
        case .noServer:
            return Definition(snapshot: .noServer)
        case .empty:
            return Definition(snapshot: RoomSnapshot(server: Fixtures.server, rooms: []))
        case .loading:
            return Definition(snapshot: RoomSnapshot(server: Fixtures.server, rooms: [basic]), phase: .loading)
        case .detached:
            return Definition(snapshot: Fixtures.snapshot([Fixtures.room(name: "detached-shell", id: "$2")]))
        case .oneFocusable:
            let client = Fixtures.client(name: "tty-one", pid: 201)
            let room = Fixtures.room(name: "one-focusable", id: "$3", clients: [client])
            return Definition(snapshot: Fixtures.snapshot([room]), focusability: [client.key: .focusable])
        case .twoMixed:
            let first = Fixtures.client(name: "tty-a", pid: 301)
            let second = Fixtures.client(name: "tty-b", pid: 302)
            let room = Fixtures.room(name: "multi-client", id: "$4", clients: [first, second])
            return Definition(
                snapshot: Fixtures.snapshot([room]),
                focusability: [first.key: .focusable, second.key: .unavailable(reason: "iTerm tab was not found")]
            )
        case .readOnlyPreview:
            let interactive = Fixtures.client(name: "tty-edit", pid: 401)
            let preview = Fixtures.client(name: "preview-read-only", pid: 402, readOnly: true)
            let room = Fixtures.room(name: "preview-room", id: "$5", clients: [interactive, preview])
            return Definition(snapshot: Fixtures.snapshot([room]), previewTarget: room.token)
        case .foreignReadOnly:
            let interactive = Fixtures.client(name: "tty-edit", pid: 403)
            let foreign = Fixtures.client(name: "someone-elses-read-only", pid: 404, readOnly: true)
            let room = Fixtures.room(name: "foreign-preview-room", id: "$12", clients: [interactive, foreign])
            return Definition(snapshot: Fixtures.snapshot([room]))
        case .automationDenied:
            return Definition(snapshot: Fixtures.snapshot([basic]), issue: .automationDeniedFixture)
        case .stale:
            return Definition(snapshot: Fixtures.snapshot([basic]), issue: .staleFixture)
        case .timeout:
            return Definition(snapshot: Fixtures.snapshot([basic]), issue: .timeoutFixture)
        case .ambiguous:
            return Definition(snapshot: Fixtures.snapshot([basic]), issue: .ambiguousFixture)
        case .deleteAttached:
            let clients = [Fixtures.client(name: "delete-a", pid: 701), Fixtures.client(name: "delete-b", pid: 702)]
            return Definition(snapshot: Fixtures.snapshot([Fixtures.room(name: "attached-delete", id: "$7", clients: clients)]))
        case .longUnicode:
            let name = "한국어-작업실-🚀-é-非常に長いセッション名-" + String(repeating: "데이터-", count: 9)
            return Definition(snapshot: Fixtures.snapshot([Fixtures.room(name: name, id: "$8")]))
        case .generalError:
            return Definition(snapshot: Fixtures.snapshot([basic]), issue: .generalFixture)
        case .singleFlight:
            return Definition(snapshot: Fixtures.snapshot([Fixtures.room(name: "single-flight", id: "$9")]), blocksActions: true)
        case .agentNamed:
            let room = Fixtures.room(name: "agent-20260901023710", id: "$10", command: "2.1.247")
            return Definition(
                snapshot: Fixtures.snapshot([room]),
                agentPresence: ["$10": .named(.claude, "9.1 배포 경계")]
            )
        case .agentDetected:
            let room = Fixtures.room(name: "agent-detached-20260826230948", id: "$11", command: "codex")
            return Definition(
                snapshot: Fixtures.snapshot([room]),
                agentPresence: ["$11": .detected(.codex)]
            )
        }
    }

    private struct Definition {
        let snapshot: RoomSnapshot
        var phase: AppPhase = .idle
        var issue: AppIssue?
        var focusability: [ClientKey: ClientFocusability] = [:]
        var blocksActions = false
        var agentPresence: [String: AgentPresence] = [:]
        var previewTarget: SessionToken?
    }
}

private enum Fixtures {
    static let server = ServerIdentity(
        canonicalSocketPath: "/fixture/tmux/default",
        socketDevice: 1,
        socketInode: 2,
        serverPID: 42,
        startedAtUnixSeconds: 1_700_000_000
    )

    static func snapshot(_ rooms: [SessionRoom]) -> RoomSnapshot {
        RoomSnapshot(server: server, rooms: rooms)
    }

    static func room(name: String, id: String, clients: [SessionRoom.Client] = [], command: String = "zsh") -> SessionRoom {
        SessionRoom(
            token: SessionToken(server: server, sessionID: id, createdAtUnixSeconds: 1_700_000_100),
            name: name,
            lastActivityAtUnixSeconds: 1_700_000_300,
            panes: [SessionRoom.Pane(
                windowID: "@1",
                paneID: "%1",
                panePID: 101,
                currentPath: "/Users/fixture/Projects/tmux-rooms",
                title: "editor",
                currentCommand: command,
                isActive: true,
                isDead: false,
                windowIndex: 0,
                paneIndex: 0
            )],
            clients: clients
        )
    }

    static func client(name: String, pid: Int32, readOnly: Bool = false) -> SessionRoom.Client {
        SessionRoom.Client(
            key: ClientKey(server: server, clientName: name, tty: "/dev/\(name)", clientPID: pid, createdAtUnixSeconds: 1_700_000_200),
            lastActivityAtUnixSeconds: 1_700_000_300,
            flags: readOnly ? ["read-only"] : [],
            isReadOnly: readOnly,
            terminalName: "xterm-256color",
            isControlMode: false
        )
    }
}

private extension AppIssue {
    static let automationDeniedFixture = AppIssue(
        kind: .automationDenied,
        title: "Automation access denied",
        message: "Allow Tmux Rooms to control iTerm in System Settings → Privacy & Security → Automation.",
        diagnostics: "Fixture: Apple Events permission denied",
        retry: .none
    )
    static let staleFixture = AppIssue(
        kind: .staleTarget,
        title: "The room changed",
        message: "This target is stale. Refresh and choose the current room; it will never retry by display name.",
        diagnostics: nil,
        retry: .enabled(.refresh)
    )
    static let timeoutFixture = AppIssue(
        kind: .timeout,
        title: "iTerm is taking longer than expected",
        message: "The underlying request is still running; its late result will be reconciled.",
        diagnostics: nil,
        retry: .blockedWhileRunning
    )
    static let ambiguousFixture = AppIssue(
        kind: .ambiguousManaged,
        title: "Managed windows need recovery",
        message: "Choose which candidate owns Primary or Preview, or clean up extras before continuing.",
        diagnostics: "2 Primary candidates · 2 Preview candidates",
        retry: .none,
        recoveryCandidates: [.primaryRecoveryFixture, .previewRecoveryFixture]
    )
    static let generalFixture = AppIssue(
        kind: .general,
        title: "Could not refresh tmux",
        message: "The last good room list is still shown.",
        diagnostics: "Fixture: malformed snapshot",
        retry: .enabled(.refresh)
    )
}

private extension ManagedRecoveryCandidate {
    static let primaryRecoveryFixture = ManagedRecoveryCandidate(
        record: ManagedClientRecord(
            nonce: "PrimaryCandidate00000001",
            launchKind: .reusableRole,
            role: .primary,
            requestedSessionToken: Fixtures.room(name: "fixture-room", id: "$1").token,
            readOnly: false,
            configurationState: .handshakeObserved,
            state: .complete,
            terminal: .init(windowID: 11, tabIndex: 1, sessionGUID: "GUID-PRIMARY", tty: "/dev/ttys011")
        ),
        roomName: "fixture-room"
    )

    static let previewRecoveryFixture = ManagedRecoveryCandidate(
        record: ManagedClientRecord(
            nonce: "PreviewCandidate00000001",
            launchKind: .reusableRole,
            role: .preview,
            requestedSessionToken: Fixtures.room(name: "fixture-room", id: "$1").token,
            readOnly: true,
            configurationState: .handshakeObserved,
            state: .complete,
            terminal: .init(windowID: 12, tabIndex: 1, sessionGUID: "GUID-PREVIEW", tty: "/dev/ttys012")
        ),
        roomName: "fixture-room"
    )
}
#endif
