import Foundation
import TmuxRoomsCore

/// One live pane and the agent session the probe could prove inside it.
struct CLIPane: Equatable, Sendable {
    let paneId: String
    let target: String
    let active: Bool
    let path: String
    let agent: AgentKind?
    let pid: Int32
    let sessionId: String?
    let name: String?
    let state: AgentActivityState
}

/// One room as the command line prints it: the tmux room joined with the label
/// the menu-bar app would give it.
struct CLIRoom: Equatable, Sendable {
    let sessionID: String
    let tmuxName: String
    let title: String
    let agent: AgentKind?
    let paths: [String]
    let interactiveClients: Int
    let readOnlyClients: Int
    let lastActivityAtUnixSeconds: Int64
    var panes: [CLIPane] = []

    /// `true` when the title is only the tmux name again, so printing both says
    /// nothing new.
    var titleIsTmuxName: Bool { title == tmuxName }
}

enum RoomQuery {
    /// Joins every room with its agent label, most recently active first.
    static func rooms(
        from snapshot: RoomSnapshot,
        presence: [String: AgentPresence],
        panes paneInfo: [String: PaneAgentInfo] = [:]
    ) -> [CLIRoom] {
        snapshot.rooms.map { room in
            let found = presence[room.token.sessionID] ?? .absent
            var paths: [String] = []
            for pane in room.panes where !paths.contains(pane.currentPath) {
                paths.append(pane.currentPath)
            }
            let livePanes = room.panes.filter { !$0.isDead }.map { pane in
                let info = paneInfo[pane.paneID]
                return CLIPane(
                    paneId: pane.paneID,
                    target: "\(room.name):\(pane.windowIndex).\(pane.paneIndex)",
                    active: pane.isActive,
                    path: pane.currentPath,
                    agent: info?.kind,
                    pid: info?.pid ?? pane.panePID,
                    sessionId: info?.sessionID,
                    name: info?.name,
                    state: info?.state ?? .unknown
                )
            }
            return CLIRoom(
                sessionID: room.token.sessionID,
                tmuxName: room.name,
                title: found.title ?? room.name,
                agent: found.kind,
                paths: paths,
                interactiveClients: room.interactiveClients.count,
                readOnlyClients: room.readOnlyClients.count,
                lastActivityAtUnixSeconds: room.lastActivityAtUnixSeconds,
                panes: livePanes
            )
        }
        .sorted { a, b in
            a.lastActivityAtUnixSeconds != b.lastActivityAtUnixSeconds
                ? a.lastActivityAtUnixSeconds > b.lastActivityAtUnixSeconds
                : a.tmuxName < b.tmuxName
        }
    }

    /// Narrows rooms to those with a pane in `directory` and whose title, tmux
    /// name, agent, or pane path contains `text`.
    ///
    /// A tmux name or session id that equals `text` outright wins over partial
    /// matches, so `cx-app` still picks its room while `cx-app-2` exists.
    static func filter(_ rooms: [CLIRoom], directory: String?, text: String?) -> [CLIRoom] {
        let inDirectory = rooms.filter { room in
            guard let directory else { return true }
            return room.paths.contains(directory)
        }
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return inDirectory
        }
        let exact = inDirectory.filter { $0.tmuxName == text || $0.sessionID == text }
        if !exact.isEmpty { return exact }
        return inDirectory.filter { room in
            let haystack = [room.title, room.tmuxName, room.agent?.displayName ?? "", room.agent?.rawValue ?? ""] + room.paths
            return haystack.contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    /// Where the chooser's highlight starts: the first room with a pane in
    /// `directory`, or the top of the list when none has.
    static func initialCursor(_ rooms: [CLIRoom], directory: String) -> Int {
        rooms.firstIndex { $0.paths.contains(directory) } ?? 0
    }
}

/// The command word, with its aliases folded so every later decision reads
/// one spelling.
enum CLICommand: Equatable {
    case list
    case attach

    init?(word: String) {
        switch word {
        case "ls", "list": self = .list
        case "attach", "a": self = .attach
        default: return nil
        }
    }

    /// Screen captures cost a subprocess per agent pane, and only the JSON
    /// listing prints pane state.
    func capturesPaneState(json: Bool) -> Bool {
        self == .list && json
    }
}

enum AttachCommand {
    enum Failure: Error, Equatable {
        /// tmux cannot open a second, read-only view from inside a client
        /// without nesting tmux, and nesting is never what a room jump wants.
        case readOnlyInsideTmux
    }

    /// The tmux arguments that put this terminal in front of a room.
    ///
    /// The target is the session id, which tmux never reuses within a server's
    /// lifetime, so a room renamed or replaced between listing and attaching
    /// cannot send the terminal to a different session.
    static func arguments(sessionID: String, readOnly: Bool, insideTmux: Bool) throws -> [String] {
        if insideTmux {
            if readOnly { throw Failure.readOnlyInsideTmux }
            return ["switch-client", "-t", sessionID]
        }
        return ["attach-session"] + (readOnly ? ["-r"] : []) + ["-t", sessionID]
    }
}
