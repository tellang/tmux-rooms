import Foundation

public enum ManagedRole: String, Sendable, Codable, CaseIterable {
    case primary
    case preview
}

public enum ManagedLaunchKind: String, Sendable, Codable {
    case reusableRole
    case explicitDuplicate
}

public enum ManagedRecordState: String, Sendable, Codable {
    case provisional
    case launching
    case timedOutButRunning
    case completedNeedsReconcile
    case recovered
    case complete
    case ambiguous
    case failed
}

public enum ManagedConfigurationState: String, Sendable, Codable {
    case absent
    case written
    case handshakeObserved
}

public struct ManagedTerminalReference: Sendable, Codable, Equatable {
    public let windowID: Int
    public let tabIndex: Int
    public let sessionGUID: String
    public let tty: String

    public init(windowID: Int, tabIndex: Int, sessionGUID: String, tty: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.sessionGUID = sessionGUID
        self.tty = tty
    }
}

public struct ManagedSwitchIntent: Sendable, Codable, Equatable {
    public let requestID: UUID
    public let destination: SessionToken
    public let readOnly: Bool
    public let previousSessionToken: SessionToken
    public let previousReadOnly: Bool
    public let previousChildPID: Int32?
    public let previousLiveClientKey: ClientKey?
    public let previousState: ManagedRecordState

    public init(requestID: UUID, destination: SessionToken, readOnly: Bool, previousSessionToken: SessionToken, previousReadOnly: Bool, previousChildPID: Int32?, previousLiveClientKey: ClientKey?, previousState: ManagedRecordState) {
        self.requestID = requestID; self.destination = destination; self.readOnly = readOnly
        self.previousSessionToken = previousSessionToken; self.previousReadOnly = previousReadOnly
        self.previousChildPID = previousChildPID; self.previousLiveClientKey = previousLiveClientKey; self.previousState = previousState
    }
}

public struct ManagedClientRecord: Sendable, Codable, Equatable {
    public var nonce: String
    public var launchKind: ManagedLaunchKind
    public var role: ManagedRole?
    public var requestedSessionToken: SessionToken
    public var readOnly: Bool
    public var configurationState: ManagedConfigurationState
    public var state: ManagedRecordState
    public var terminal: ManagedTerminalReference?
    public var supervisorPID: Int32?
    public var childPID: Int32?
    public var liveClientKey: ClientKey?
    public var requestID: UUID?
    public var pendingSwitch: ManagedSwitchIntent?
    public var updatedAt: Date

    public init(
        nonce: String,
        launchKind: ManagedLaunchKind,
        role: ManagedRole?,
        requestedSessionToken: SessionToken,
        readOnly: Bool,
        configurationState: ManagedConfigurationState = .absent,
        state: ManagedRecordState = .provisional,
        terminal: ManagedTerminalReference? = nil,
        supervisorPID: Int32? = nil,
        childPID: Int32? = nil,
        liveClientKey: ClientKey? = nil,
        requestID: UUID? = nil,
        pendingSwitch: ManagedSwitchIntent? = nil,
        updatedAt: Date = Date()
    ) {
        self.nonce = nonce
        self.launchKind = launchKind
        self.role = role
        self.requestedSessionToken = requestedSessionToken
        self.readOnly = readOnly
        self.configurationState = configurationState
        self.state = state
        self.terminal = terminal
        self.supervisorPID = supervisorPID
        self.childPID = childPID
        self.liveClientKey = liveClientKey
        self.requestID = requestID
        self.pendingSwitch = pendingSwitch
        self.updatedAt = updatedAt
    }
}

public enum ManagedTerminalOutcome: Sendable, Equatable {
    case ready(ManagedClientRecord)
    case pending(ManagedClientRecord)
    case failed(ManagedClientRecord)
    case ambiguous([ManagedClientRecord])
}

public enum TerminalFocusResult: Sendable, Equatable {
    case managed(ManagedClientRecord)
    case external(reference: ManagedTerminalReference, clientKey: ClientKey)
}

public enum ManagedTerminalError: Error, Sendable, Equatable {
    case invalidNonce
    case invalidRecord
    case automation(SmokeAutomationError)
    case notFound
    case ambiguous
    case staleOwnership
    case journal(String)
    case corruptRecord(path: String)
}

extension ServerIdentity: Codable {
    private enum CodingKeys: String, CodingKey { case canonicalSocketPath, socketDevice, socketInode, serverPID, startedAtUnixSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(canonicalSocketPath: try c.decode(String.self, forKey: .canonicalSocketPath),
                  socketDevice: try c.decode(UInt64.self, forKey: .socketDevice),
                  socketInode: try c.decode(UInt64.self, forKey: .socketInode),
                  serverPID: try c.decode(Int32.self, forKey: .serverPID),
                  startedAtUnixSeconds: try c.decode(Int64.self, forKey: .startedAtUnixSeconds))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canonicalSocketPath, forKey: .canonicalSocketPath); try c.encode(socketDevice, forKey: .socketDevice)
        try c.encode(socketInode, forKey: .socketInode); try c.encode(serverPID, forKey: .serverPID)
        try c.encode(startedAtUnixSeconds, forKey: .startedAtUnixSeconds)
    }
}

extension SessionToken: Codable {
    private enum CodingKeys: String, CodingKey { case server, sessionID, createdAtUnixSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(server: try c.decode(ServerIdentity.self, forKey: .server), sessionID: try c.decode(String.self, forKey: .sessionID), createdAtUnixSeconds: try c.decode(Int64.self, forKey: .createdAtUnixSeconds))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(server, forKey: .server); try c.encode(sessionID, forKey: .sessionID); try c.encode(createdAtUnixSeconds, forKey: .createdAtUnixSeconds)
    }
}

extension ClientKey: Codable {
    private enum CodingKeys: String, CodingKey { case server, clientName, tty, clientPID, createdAtUnixSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(server: try c.decode(ServerIdentity.self, forKey: .server), clientName: try c.decode(String.self, forKey: .clientName), tty: try c.decodeIfPresent(String.self, forKey: .tty), clientPID: try c.decode(Int32.self, forKey: .clientPID), createdAtUnixSeconds: try c.decode(Int64.self, forKey: .createdAtUnixSeconds))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(server, forKey: .server); try c.encode(clientName, forKey: .clientName); try c.encodeIfPresent(tty, forKey: .tty)
        try c.encode(clientPID, forKey: .clientPID); try c.encode(createdAtUnixSeconds, forKey: .createdAtUnixSeconds)
    }
}
