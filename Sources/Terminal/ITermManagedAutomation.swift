import Foundation

@MainActor
public protocol ManagedITermAutomating: Sendable {
    func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError>
    func enumerateSessionTTYs() async -> Result<[String], SmokeAutomationError>
    func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError>
    func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError>
    func requestManagedSessionTitle(_ reference: ManagedTerminalReference, nonce: String, title: String) async -> Result<String, SmokeAutomationError>
    func confirmManagedSessionTitle(_ reference: ManagedTerminalReference, nonce: String, title: String, requestID: String) async -> Result<Bool, SmokeAutomationError>
    func focusExactSession(_ reference: ManagedTerminalReference) async -> Result<ManagedTerminalReference, SmokeAutomationError>
    func focusManagedSession(_ reference: ManagedTerminalReference, nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError>
}

public struct ManagedSessionEvidence: Sendable, Equatable {
    public let terminal: ManagedTerminalReference
    public let nonce: String
    public init(terminal: ManagedTerminalReference, nonce: String) { self.terminal = terminal; self.nonce = nonce }
}

public struct ITermBundledHelperPath: Sendable, Equatable {
    public let path: String
    private init(path: String) { self.path = path }

    public static func resolve(bundleURL: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        let actual = bundleURL.standardizedFileURL.path
        let allowed = [
            URL(fileURLWithPath: "/Applications/Tmux Rooms.app").standardizedFileURL.path,
            homeDirectory.appending(path: "Applications/Tmux Rooms.app").standardizedFileURL.path
        ]
        guard allowed.contains(actual) else { throw ManagedTerminalError.invalidRecord }
        return .init(path: bundleURL.appending(path: "Contents/Helpers/tmuxrooms-launch").standardizedFileURL.path)
    }
}

public enum ITermManagedScripts {
    public static let nonceVariable = "user.tmuxRoomsNonce"

    public static func command(nonce: String, helperPath: ITermBundledHelperPath) throws -> String {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        return "'\(helperPath.path)' --supervise \(nonce)"
    }

    /// Ownership evidence, so a window that vanishes mid-loop is counted instead
    /// of failing the script or, worse, silently shrinking the evidence. A
    /// record is demoted when its window is absent from this list, and that
    /// conclusion may only be drawn from a complete pass.
    public static let enumerate = """
    with timeout of 5 seconds
        tell application id "com.googlecode.iterm2"
            set resultRows to {}
            set skippedCount to 0
            repeat with targetWindow in windows
                try
                    set targetWindowID to id of targetWindow
                    set targetTabIndex to 0
                    repeat with targetTab in tabs of targetWindow
                        set targetTabIndex to targetTabIndex + 1
                        try
                            repeat with targetSession in sessions of targetTab
                                try
                                    set targetNonce to variable targetSession named "user.tmuxRoomsNonce"
                                    if targetNonce is not missing value and targetNonce is not "" then set end of resultRows to {targetWindowID, targetTabIndex, unique ID of targetSession, tty of targetSession, targetNonce}
                                end try
                            end repeat
                        on error
                            set skippedCount to skippedCount + 1
                        end try
                    end repeat
                on error
                    set skippedCount to skippedCount + 1
                end try
            end repeat
            return {resultRows, skippedCount}
        end tell
    end timeout
    """

    public static func create(nonce: String, helperPath: ITermBundledHelperPath) throws -> String {
        let nonceLiteral = try AppleScriptLiteral.string(nonce)
        let commandLiteral = try AppleScriptLiteral.string(command(nonce: nonce, helperPath: helperPath))
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set createdWindow to create window with default profile command \(commandLiteral)
                set createdTab to current tab of createdWindow
            set createdSession to current session of createdTab
            set variable createdSession named "user.tmuxRoomsNonce" to \(nonceLiteral)
            return {id of createdWindow, 1, unique ID of createdSession, tty of createdSession, variable createdSession named "user.tmuxRoomsNonce"}
            end tell
        end timeout
        """
    }

    /// Focuses the exact session by addressing it, rather than searching for it.
    ///
    /// The reference already names the window, tab, session GUID, and TTY, so
    /// walking every window to find it again only costs Apple Event round
    /// trips, and each one freezes the app. Addressing is also no weaker: a
    /// session GUID is unique, and every identifying field is verified after
    /// the lookup, so anything that moved comes back as not found.
    public static func focus(_ reference: ManagedTerminalReference, nonce: String) throws -> String {
        let guid = try AppleScriptLiteral.string(reference.sessionGUID)
        let tty = try AppleScriptLiteral.string(reference.tty)
        let nonce = try AppleScriptLiteral.string(nonce)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                try
                    set matchedWindow to window id \(reference.windowID)
                    set matchedTab to tab \(reference.tabIndex) of matchedWindow
                    set matchedSession to session id \(guid) of matchedTab
                    if tty of matchedSession is not \(tty) then return {"not-found"}
                    if (variable matchedSession named "user.tmuxRoomsNonce") is not \(nonce) then return {"not-found"}
                on error
                    return {"not-found"}
                end try
                select matchedSession
                select matchedTab
                select matchedWindow
                activate
                set actualTabIndex to 0
                repeat with candidateTab in tabs of matchedWindow
                    set actualTabIndex to actualTabIndex + 1
                    if candidateTab is matchedTab then exit repeat
                end repeat
                return {id of matchedWindow, actualTabIndex, unique ID of matchedSession, tty of matchedSession, variable matchedSession named "user.tmuxRoomsNonce"}
            end tell
        end timeout
        """
    }

}

@MainActor
public struct ITermManagedAutomation: ManagedITermAutomating {
    private let runner: any AppleScriptRunning
    private let helperPath: ITermBundledHelperPath?
    private let titleTransport: ITermPythonTitleTransport
    public init(runner: any AppleScriptRunning = FoundationAppleScriptRunner(), bundleURL: URL = Bundle.main.bundleURL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.helperPath = try? .resolve(bundleURL: bundleURL, homeDirectory: homeDirectory)
        self.titleTransport = .init(runner: runner, homeDirectory: homeDirectory)
    }
    public init(
        runner: any AppleScriptRunning,
        helperPath: ITermBundledHelperPath,
        titleHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        titlePollInterval: Duration = .milliseconds(100),
        titleMaxLaunchAttempts: Int = 30,
        titleOverallTimeout: Duration = .seconds(8)
    ) {
        self.runner = runner
        self.helperPath = helperPath
        self.titleTransport = .init(
            runner: runner,
            homeDirectory: titleHomeDirectory,
            pollInterval: titlePollInterval,
            maxLaunchAttempts: titleMaxLaunchAttempts,
            overallTimeout: titleOverallTimeout
        )
    }

    public func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError> {
        await enumerate(source: ITermSmokeScripts.enumerate) { value in
            guard case let .list(items) = value, items.count == 3,
                  case let .list(rows) = items[1], case let .integer(skipped) = items[2] else { return nil }
            let references = rows.compactMap(Self.decodeReference)
            guard references.count == rows.count else { return nil }
            return (references, skipped)
        }
    }

    /// Every session TTY, without the window and tab walk. See
    /// `ITermSmokeScripts.enumerateTTYs` for why this exists.
    public func enumerateSessionTTYs() async -> Result<[String], SmokeAutomationError> {
        switch await runner.execute(source: ITermSmokeScripts.enumerateTTYs) {
        case let .failure(number, _): return .failure(map(number))
        case let .success(.list(items)):
            guard items.count == 2, case let .list(rows) = items[1] else { return .failure(.invalidReply) }
            return .success(Self.flattenStrings(rows))
        case .success: return .failure(.invalidReply)
        }
    }

    public func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError> {
        await enumerate(source: ITermManagedScripts.enumerate) { value in
            guard case let .list(items) = value, items.count == 2,
                  case let .list(rows) = items[0], case let .integer(skipped) = items[1] else { return nil }
            let values = rows.compactMap(Self.decodeEvidence)
            guard values.count == rows.count else { return nil }
            return (values, skipped)
        }
    }

    /// Runs an enumeration and, when the script had to skip a window or tab,
    /// runs it once more before giving up.
    ///
    /// Skips come from iTerm mutating its own window list while a window opens
    /// or closes, which settles in milliseconds. A second clean pass is worth
    /// far more than reporting an incomplete terminal, and a still-dirty pass
    /// is reported as a stale target rather than passed off as the truth.
    private func enumerate<Value>(
        source: String,
        decode: @escaping (AppleScriptValue) -> (values: [Value], skipped: Int)?
    ) async -> Result<[Value], SmokeAutomationError> {
        var lastSkipped = 0
        for attempt in 0..<2 {
            switch await runner.execute(source: source) {
            case let .failure(number, _): return .failure(map(number))
            case let .success(value):
                guard let decoded = decode(value) else { return .failure(.invalidReply) }
                guard decoded.skipped > 0 else { return .success(decoded.values) }
                lastSkipped = decoded.skipped
                if attempt == 0 {
                    RoomsLog.terminal.notice("iterm.enumeration_retry skipped=\(decoded.skipped, privacy: .public)")
                }
            }
        }
        RoomsLog.terminal.error("iterm.enumeration_incomplete skipped=\(lastSkipped, privacy: .public)")
        return .failure(.staleTarget)
    }

    public func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        do {
            guard let helperPath else { return .failure(.invalidReply) }
            switch await runner.execute(source: try ITermManagedScripts.create(nonce: nonce, helperPath: helperPath)) {
            case let .failure(number, _): return .failure(map(number))
            case let .success(value):
                guard let evidence = Self.decodeEvidence(value), evidence.nonce == nonce else { return .failure(.invalidReply) }
                return .success(evidence.terminal)
            }
        } catch { return .failure(.invalidReply) }
    }

    public func requestManagedSessionTitle(_ reference: ManagedTerminalReference, nonce: String, title: String) async -> Result<String, SmokeAutomationError> {
        await titleTransport.requestTitle(reference, nonce: nonce, title: title)
    }

    public func confirmManagedSessionTitle(_ reference: ManagedTerminalReference, nonce: String, title: String, requestID: String) async -> Result<Bool, SmokeAutomationError> {
        switch await titleTransport.confirmTitle(reference, nonce: nonce, title: title, requestID: requestID) {
        case let .success(applied): return .success(applied != nil)
        case let .failure(error): return .failure(error)
        }
    }

    public func focusManagedSession(_ reference: ManagedTerminalReference, nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        do {
            switch await runner.execute(source: try ITermManagedScripts.focus(reference, nonce: nonce)) {
            case let .failure(number, _): return .failure(map(number))
            case .success(.list([.string("not-found")])): return .failure(.notFound)
            case .success(.list([.string("ambiguous")])): return .failure(.ambiguous)
            case let .success(value):
                guard let evidence = Self.decodeEvidence(value), evidence.nonce == nonce, evidence.terminal == reference else { return .failure(.staleTarget) }
                return .success(reference)
            }
        } catch { return .failure(.invalidReply) }
    }

    public func focusExactSession(_ reference: ManagedTerminalReference) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        let smokeReference = ITermSessionReference(windowID: reference.windowID, tabIndex: reference.tabIndex, sessionGUID: reference.sessionGUID, tty: reference.tty)
        switch await ITermAutomationSmoke(runner: runner).focus(reference: smokeReference, provenance: .external) {
        case let .success(actual): return .success(.init(windowID: actual.windowID, tabIndex: actual.tabIndex, sessionGUID: actual.sessionGUID, tty: actual.tty))
        case let .failure(error): return .failure(error)
        }
    }

    /// A plural chain answers in the shape it was asked in: one list per
    /// window, one per tab inside it, then the session values. The TTY map only
    /// counts values, so the nesting is walked and the leaves collected. Empty
    /// values belong to sessions with no pty of their own and are dropped.
    private static func flattenStrings(_ values: [AppleScriptValue]) -> [String] {
        values.flatMap { value -> [String] in
            switch value {
            case let .string(text): text.isEmpty ? [] : [text]
            case let .list(nested): flattenStrings(nested)
            default: []
            }
        }
    }

    private static func decodeEvidence(_ value: AppleScriptValue) -> ManagedSessionEvidence? {
        guard case let .list(items) = value, items.count == 5,
              case let .integer(windowID) = items[0], case let .integer(tabIndex) = items[1],
              case let .string(guid) = items[2], case let .string(tty) = items[3], case let .string(nonce) = items[4],
              windowID > 0, tabIndex > 0, !guid.isEmpty, !tty.isEmpty, ManagedNonce.isValid(nonce) else { return nil }
        return .init(terminal: .init(windowID: windowID, tabIndex: tabIndex, sessionGUID: guid, tty: tty), nonce: nonce)
    }

    private static func decodeReference(_ value: AppleScriptValue) -> ManagedTerminalReference? {
        guard case let .list(items) = value, items.count == 4,
              case let .integer(windowID) = items[0], case let .integer(tabIndex) = items[1],
              case let .string(guid) = items[2], case let .string(tty) = items[3],
              windowID > 0, tabIndex > 0, !guid.isEmpty, !tty.isEmpty else { return nil }
        return .init(windowID: windowID, tabIndex: tabIndex, sessionGUID: guid, tty: tty)
    }

    private func map(_ number: Int?) -> SmokeAutomationError {
        switch number { case -1743: .permissionDenied; case -1712: .timeout; default: .scriptFailure(number: number) }
    }
}
