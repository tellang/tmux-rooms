import Foundation

@MainActor
public protocol ManagedITermAutomating: Sendable {
    func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError>
    func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError>
    func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError>
    func focusExactSession(_ reference: ManagedTerminalReference) async -> Result<ManagedTerminalReference, SmokeAutomationError>
    func focusManagedSession(_ reference: ManagedTerminalReference, nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError>
}

public struct ManagedSessionEvidence: Sendable, Equatable {
    public let terminal: ManagedTerminalReference
    public let nonce: String
    public init(terminal: ManagedTerminalReference, nonce: String) { self.terminal = terminal; self.nonce = nonce }
}

public enum ITermManagedScripts {
    public static let helperPath = "/Applications/Tmux Rooms.app/Contents/Helpers/tmuxrooms-launch"
    public static let nonceVariable = "user.tmuxRoomsNonce"

    public static func command(nonce: String) throws -> String {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        return "'\(helperPath)' --supervise \(nonce)"
    }

    public static let enumerate = """
    with timeout of 5 seconds
        tell application id "com.googlecode.iterm2"
            set resultRows to {}
            repeat with targetWindow in windows
                set targetWindowID to id of targetWindow
                set targetTabIndex to 0
                repeat with targetTab in tabs of targetWindow
                    set targetTabIndex to targetTabIndex + 1
                    repeat with targetSession in sessions of targetTab
                        try
                            set targetNonce to variable named "user.tmuxRoomsNonce" of targetSession
                            if targetNonce is not missing value and targetNonce is not "" then set end of resultRows to {targetWindowID, targetTabIndex, unique ID of targetSession, tty of targetSession, targetNonce}
                        end try
                    end repeat
                end repeat
            end repeat
            return resultRows
        end tell
    end timeout
    """

    public static func create(nonce: String) throws -> String {
        let nonceLiteral = try AppleScriptLiteral.string(nonce)
        let commandLiteral = try AppleScriptLiteral.string(command(nonce: nonce))
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set createdWindow to create window with default profile command \(commandLiteral)
                set createdTab to current tab of createdWindow
                set createdSession to current session of createdTab
                set variable named "user.tmuxRoomsNonce" of createdSession to \(nonceLiteral)
                return {id of createdWindow, 1, unique ID of createdSession, tty of createdSession, variable named "user.tmuxRoomsNonce" of createdSession}
            end tell
        end timeout
        """
    }

    public static func focus(_ reference: ManagedTerminalReference, nonce: String) throws -> String {
        let guid = try AppleScriptLiteral.string(reference.sessionGUID), tty = try AppleScriptLiteral.string(reference.tty), nonce = try AppleScriptLiteral.string(nonce)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set exactMatches to {}
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetSession in sessions of targetTab
                            try
                                if unique ID of targetSession is \(guid) and tty of targetSession is \(tty) and variable named "user.tmuxRoomsNonce" of targetSession is \(nonce) then set end of exactMatches to {targetWindow, targetTab, targetSession}
                            end try
                        end repeat
                    end repeat
                end repeat
                if (count of exactMatches) is 0 then return {"not-found"}
                if (count of exactMatches) is greater than 1 then return {"ambiguous"}
                set exactMatch to item 1 of exactMatches
                set matchedWindow to item 1 of exactMatch
                set matchedTab to item 2 of exactMatch
                set matchedSession to item 3 of exactMatch
                select matchedSession
                select matchedTab
                select matchedWindow
                activate
                set actualTabIndex to 0
                repeat with candidateTab in tabs of matchedWindow
                    set actualTabIndex to actualTabIndex + 1
                    if candidateTab is matchedTab then exit repeat
                end repeat
                return {id of matchedWindow, actualTabIndex, unique ID of matchedSession, tty of matchedSession, variable named "user.tmuxRoomsNonce" of matchedSession}
            end tell
        end timeout
        """
    }
}

@MainActor
public struct ITermManagedAutomation: ManagedITermAutomating {
    private let runner: any AppleScriptRunning
    public init(runner: any AppleScriptRunning = FoundationAppleScriptRunner()) { self.runner = runner }

    public func enumerateSessions() async -> Result<[ManagedTerminalReference], SmokeAutomationError> {
        switch await runner.execute(source: ITermSmokeScripts.enumerate) {
        case let .failure(number, _): return .failure(map(number))
        case let .success(.list(items)):
            guard items.count == 2, case let .list(rows) = items[1] else { return .failure(.invalidReply) }
            let references = rows.compactMap(Self.decodeReference)
            return references.count == rows.count ? .success(references) : .failure(.invalidReply)
        case .success: return .failure(.invalidReply)
        }
    }

    public func enumerateManagedSessions() async -> Result<[ManagedSessionEvidence], SmokeAutomationError> {
        switch await runner.execute(source: ITermManagedScripts.enumerate) {
        case let .failure(number, _): return .failure(map(number))
        case let .success(.list(rows)):
            let values = rows.compactMap(Self.decodeEvidence)
            return values.count == rows.count ? .success(values) : .failure(.invalidReply)
        case .success: return .failure(.invalidReply)
        }
    }

    public func createManagedSession(nonce: String) async -> Result<ManagedTerminalReference, SmokeAutomationError> {
        do {
            switch await runner.execute(source: try ITermManagedScripts.create(nonce: nonce)) {
            case let .failure(number, _): return .failure(map(number))
            case let .success(value):
                guard let evidence = Self.decodeEvidence(value), evidence.nonce == nonce else { return .failure(.invalidReply) }
                return .success(evidence.terminal)
            }
        } catch { return .failure(.invalidReply) }
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
