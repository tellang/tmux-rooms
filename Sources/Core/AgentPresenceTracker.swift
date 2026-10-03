import Foundation

/// Keeps the room list's agent labels current without probing on every refresh.
///
/// The room list refreshes once a second in the foreground, but an agent's name
/// only changes when someone renames a session. Probing at the room list's own
/// cadence would spawn a `ps` every second for a label that is nearly always the
/// same, so the tracker probes when the panes change and otherwise on a slower
/// beat.
@MainActor
public final class AgentPresenceTracker {
    /// Refreshes between probes when the panes are unchanged: five seconds at the foreground cadence.
    public static let refreshesBetweenProbes = 5

    private let probe: any AgentPresenceProbing
    /// Counts refreshes since the last probe. A first refresh, and the first
    /// refresh after an empty room list, probes because the pane fingerprint is
    /// unset rather than because this counter is primed.
    private var refreshesSinceProbe = 0
    private var lastPaneFingerprint: String?

    public private(set) var presence: [String: AgentPresence] = [:]

    public init(probe: any AgentPresenceProbing = AgentPresenceProbe()) {
        self.probe = probe
    }

    public func presence(for room: SessionRoom) -> AgentPresence {
        presence[room.token.sessionID] ?? .absent
    }

    /// Updates the labels for `rooms`, probing only when it is due.
    ///
    /// Returns `true` when a probe ran, which tells tests and callers the labels
    /// they are reading are freshly measured rather than carried over.
    @discardableResult
    public func refresh(rooms: [SessionRoom]) async -> Bool {
        guard !rooms.isEmpty else {
            presence = [:]
            lastPaneFingerprint = nil
            refreshesSinceProbe = 0
            return false
        }
        let fingerprint = Self.fingerprint(of: rooms)
        let panesChanged = fingerprint != lastPaneFingerprint
        refreshesSinceProbe += 1
        guard panesChanged || refreshesSinceProbe >= Self.refreshesBetweenProbes else { return false }
        lastPaneFingerprint = fingerprint
        refreshesSinceProbe = 0
        presence = await probe.presence(for: rooms)
        return true
    }

    /// Identifies which processes occupy which panes. A change here means a pane
    /// was opened, closed, or handed to a different process, so the labels are
    /// stale no matter how recently they were measured.
    private static func fingerprint(of rooms: [SessionRoom]) -> String {
        rooms
            .flatMap { room in room.panes.map { "\(room.token.sessionID)\u{1}\($0.paneID)\u{1}\($0.panePID)\u{1}\($0.isDead)" } }
            .sorted()
            .joined(separator: "\u{2}")
    }
}
