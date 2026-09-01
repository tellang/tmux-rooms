import Foundation
import OSLog

/// The app's one logging surface.
///
/// Every category writes to the `com.tellang.tmuxrooms` subsystem, so a whole
/// session reads back with:
///
///     log show --last 30m --predicate 'subsystem == "com.tellang.tmuxrooms"' --style compact
///
/// **Event names.** Every line starts with a `domain.action` token and carries
/// the rest as `key=value` pairs, so one kind of event is greppable on its own:
///
///     log show --predicate 'subsystem == "com.tellang.tmuxrooms" AND eventMessage BEGINSWITH "action.finished"'
///
/// **Levels.** `.notice` and above are kept in the durable log store, `.debug`
/// only in the memory buffer. Anything a user could be asked about after the
/// fact is therefore `.notice` or `.error`, never `.debug`.
///
/// **Privacy.** Structural values carry `.public` because they are the whole
/// point of the line: events, intents, results, record states, roles, counts,
/// nonces, tmux session ids, trace ids. Room names, window titles, paths, and
/// TTYs stay at the default redaction, so the log can be handed over without
/// carrying what the user was working on.
public enum RoomsLog {
    /// What the UI asked for and what came back.
    public static let actions = Logger(subsystem: subsystem, category: "actions")
    /// Managed window ownership: launches, switches, detaches, state transitions.
    public static let terminal = Logger(subsystem: subsystem, category: "terminal")
    /// Errors the app deliberately absorbs so the UI can stay usable.
    public static let swallowed = Logger(subsystem: subsystem, category: "swallowed")
    /// Release automation smoke evidence.
    public static let smoke = Logger(subsystem: subsystem, category: "smoke")

    private static let subsystem = "com.tellang.tmuxrooms"
}

/// The id every line of one user action shares, plus how long that action took.
///
/// The store runs one action at a time: `RoomsStore.perform` drops anything that
/// arrives while another action is in flight, and every layer under it is main
/// actor bound. So the current trace can live here instead of being threaded
/// through `TmuxController`, `TerminalController`, and the supervisor client,
/// which would put a logging parameter on a dozen ownership-critical signatures.
@MainActor
public final class ActionTrace {
    /// The action in flight, or `nil` between actions.
    public private(set) static var current: ActionTrace?

    /// The id to stamp on a line, including lines emitted between actions.
    public static var currentID: String { current?.id ?? "none" }

    public let id: String
    private let started: ContinuousClock.Instant

    private init() {
        self.started = ContinuousClock.now
        var value = UInt32.random(in: 0...UInt32.max)
        value ^= UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
        self.id = String(format: "%06x", value & 0xFF_FFFF)
    }

    public var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - started
        let components = elapsed.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// Starts a trace and makes it current until `finish()`.
    public static func begin() -> ActionTrace {
        let trace = ActionTrace()
        current = trace
        return trace
    }

    /// Clears the current trace, unless a later action already replaced it.
    public func finish() {
        guard Self.current === self else { return }
        Self.current = nil
    }
}
