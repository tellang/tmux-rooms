import Foundation

public struct ServerIdentity: Sendable, Hashable {
    public let canonicalSocketPath: String
    public let socketDevice: UInt64
    public let socketInode: UInt64
    public let serverPID: Int32
    public let startedAtUnixSeconds: Int64
    public init(canonicalSocketPath: String, socketDevice: UInt64, socketInode: UInt64, serverPID: Int32, startedAtUnixSeconds: Int64) {
        self.canonicalSocketPath = canonicalSocketPath; self.socketDevice = socketDevice; self.socketInode = socketInode
        self.serverPID = serverPID; self.startedAtUnixSeconds = startedAtUnixSeconds
    }
}

public struct SessionToken: Sendable, Hashable {
    public let server: ServerIdentity
    public let sessionID: String
    public let createdAtUnixSeconds: Int64
    public init(server: ServerIdentity, sessionID: String, createdAtUnixSeconds: Int64) { self.server = server; self.sessionID = sessionID; self.createdAtUnixSeconds = createdAtUnixSeconds }
}

public struct ClientKey: Sendable, Hashable {
    public let server: ServerIdentity
    public let clientName: String
    public let tty: String?
    public let clientPID: Int32
    public let createdAtUnixSeconds: Int64
    public init(server: ServerIdentity, clientName: String, tty: String?, clientPID: Int32, createdAtUnixSeconds: Int64) {
        self.server = server; self.clientName = clientName; self.tty = tty; self.clientPID = clientPID; self.createdAtUnixSeconds = createdAtUnixSeconds
    }
}

public struct SessionRoom: Sendable, Hashable {
    public struct Pane: Sendable, Hashable {
        public let windowID: String; public let paneID: String; public let panePID: Int32
        public let currentPath: String; public let title: String; public let currentCommand: String
        public let isActive: Bool; public let isDead: Bool
        public init(windowID: String, paneID: String, panePID: Int32, currentPath: String, title: String, currentCommand: String, isActive: Bool, isDead: Bool) {
            self.windowID = windowID; self.paneID = paneID; self.panePID = panePID; self.currentPath = currentPath
            self.title = title; self.currentCommand = currentCommand; self.isActive = isActive; self.isDead = isDead
        }
    }
    public struct Client: Sendable, Hashable {
        public let key: ClientKey; public let lastActivityAtUnixSeconds: Int64; public let flags: [String]
        public let isReadOnly: Bool; public let terminalName: String; public let isControlMode: Bool
        public var clientName: String { key.clientName }; public var tty: String? { key.tty }
        public init(key: ClientKey, lastActivityAtUnixSeconds: Int64, flags: [String], isReadOnly: Bool, terminalName: String, isControlMode: Bool) {
            self.key = key; self.lastActivityAtUnixSeconds = lastActivityAtUnixSeconds; self.flags = flags
            self.isReadOnly = isReadOnly; self.terminalName = terminalName; self.isControlMode = isControlMode
        }
    }
    public let token: SessionToken; public let name: String; public let lastActivityAtUnixSeconds: Int64
    public let panes: [Pane]; public let clients: [Client]
    public var interactiveClients: [Client] { clients.filter { !$0.isControlMode && !$0.isReadOnly } }
    public var readOnlyClients: [Client] { clients.filter { !$0.isControlMode && $0.isReadOnly } }
    public init(token: SessionToken, name: String, lastActivityAtUnixSeconds: Int64, panes: [Pane], clients: [Client]) {
        self.token = token; self.name = name; self.lastActivityAtUnixSeconds = lastActivityAtUnixSeconds; self.panes = panes; self.clients = clients
    }
}

public struct RoomSnapshot: Sendable, Hashable {
    public let server: ServerIdentity?; public let rooms: [SessionRoom]
    public init(server: ServerIdentity?, rooms: [SessionRoom]) { self.server = server; self.rooms = rooms }
    public static let noServer = RoomSnapshot(server: nil, rooms: [])
}

public enum RoomActionResult: Sendable, Hashable {
    case succeeded
    case alreadyGone
    case staleTarget
    case cancelled
    case tmuxFailure(TmuxFailure)
    case terminalFailure(TerminalFailure)
}
public enum TmuxFailure: Error, Sendable, Hashable {
    case malformedOutput(String); case unsupportedVersion(String); case commandFailed(exitCode: Int32, stderr: String)
    case timedOut; case cancelled; case outputLimitExceeded; case endpointChanged; case endpointPermissionDenied; case launchFailed(String)
}
public enum TerminalFailure: Error, Sendable, Hashable { case permissionDenied; case timeout; case staleTarget; case notFound; case ambiguous; case invalidReply; case scriptFailure(number: Int?) }
