import Foundation

/// Advisory activity comes from the agent's registry or visible screen, never
/// from the executable name that proves its presence.
public enum AgentActivityState: String, Sendable, Hashable {
    case busy
    case idle
    case unknown

    public static func claudeStatus(_ status: String?) -> Self {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty else { return .unknown }
        return status.lowercased() == "busy" ? .busy : .idle
    }

    public static func visibleScreen(_ text: String) -> Self {
        text.localizedCaseInsensitiveContains("esc to interrupt") ? .busy : .idle
    }
}

public struct PaneAgentInfo: Sendable, Hashable {
    public let kind: AgentKind?
    public let pid: Int32
    public let sessionID: String?
    public let name: String?
    public let state: AgentActivityState

    public init(kind: AgentKind?, pid: Int32, sessionID: String? = nil, name: String? = nil, state: AgentActivityState = .unknown) {
        self.kind = kind
        self.pid = pid
        self.sessionID = sessionID
        self.name = name
        self.state = state
    }
}

public struct AgentProbeSnapshot: Sendable {
    public let presence: [String: AgentPresence]
    public let panes: [String: PaneAgentInfo]

    public init(presence: [String: AgentPresence], panes: [String: PaneAgentInfo]) {
        self.presence = presence
        self.panes = panes
    }
}
