import Foundation

/// Advisory activity comes from the agent's registry or visible screen, never
/// from the executable name that proves its presence.
public enum AgentActivityState: String, Sendable, Hashable {
    case busy
    case idle
    case unknown

    /// Codex's status line while a turn runs, as in `Working (12s • esc to interrupt)`.
    static let interruptMarker = "esc to interrupt"
    /// Codex's composer prompt, seen live on 2026-10-03 as `» Ask Codex to do anything`.
    static let codexPromptMarkers: Set<Character> = ["›", "»"]
    /// Only the bottom of the screen is current; scrollback above it is history.
    static let screenTailLineCount = 6

    /// `busy` and `idle` are the only values seen in `~/.claude/sessions`.
    /// Anything else is not guessed at.
    public static func claudeStatus(_ status: String?) -> Self {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "busy": .busy
        case "idle": .idle
        default: .unknown
        }
    }

    /// Reads the last non-blank lines of a captured pane. A screen that shows
    /// neither marker says nothing, so it is `.unknown` rather than idle. Only
    /// Codex has a verified idle marker.
    public static func visibleScreen(_ text: String, kind: AgentKind) -> Self {
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .suffix(screenTailLineCount)
        if lines.contains(where: { $0.containsASCIICaseInsensitive(interruptMarker) }) { return .busy }
        if kind == .codex, lines.contains(where: { $0.drop(while: \.isWhitespace).first.map(codexPromptMarkers.contains) == true }) {
            return .idle
        }
        return .unknown
    }
}

extension StringProtocol {
    /// Folds only ASCII letters, so a marker never matches through locale or
    /// Unicode case rules.
    func containsASCIICaseInsensitive(_ needle: String) -> Bool {
        func folded(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
        let haystack = utf8.map(folded)
        let pattern = needle.utf8.map(folded)
        guard !pattern.isEmpty else { return true }
        guard haystack.count >= pattern.count else { return false }
        return (0...(haystack.count - pattern.count)).contains { start in
            haystack[start..<(start + pattern.count)].elementsEqual(pattern)
        }
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
