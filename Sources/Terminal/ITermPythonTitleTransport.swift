import Foundation

enum ITermPythonTitleScript {
    static let name = "com.tellang.tmuxrooms-title.py"
    static let source = #"""
#!/usr/bin/env python3
import sys
import iterm2

guid, nonce, label, request_id = sys.argv[1:5]

async def main(connection):
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(guid)
    if session is None:
        raise RuntimeError("session-not-found")
    actual_nonce = await session.async_get_variable("user.tmuxRoomsNonce")
    if actual_nonce != nonce:
        raise RuntimeError("nonce-mismatch")

    update = iterm2.LocalWriteOnlyProfile()
    update.set_allow_title_setting(False)
    update.set_name(label)
    await session.async_set_profile_properties(update)
    await session.tab.async_set_variable("user.tmuxRoomsTitle", label)
    await session.tab.async_set_title(r"\(user.tmuxRoomsTitle)")
    await session.async_set_variable("user.tmuxRoomsTitleApplied", request_id)

iterm2.run_until_complete(main)
"""#

    static func install(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = homeDirectory.appending(path: "Library/Application Support/iTerm2/Scripts", directoryHint: .isDirectory)
        let destination = directory.appending(path: name)
        let bytes = Data(source.utf8)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.contents(atPath: destination.path) == bytes {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            }
            return destination
        }

        try bytes.write(to: destination, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }
}

enum ITermPythonTitleScripts {
    static func launch(
        _ reference: ManagedTerminalReference,
        nonce: String,
        title: String,
        requestID: String,
        scriptName: String
    ) throws -> String {
        let fields = try literals(reference, nonce: nonce, title: title, requestID: requestID)
        let script = try AppleScriptLiteral.string(scriptName)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set exactMatches to {}
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetSession in sessions of targetTab
                            try
                                set targetNonce to variable targetSession named "user.tmuxRoomsNonce"
                                if unique ID of targetSession is \(fields.guid) and tty of targetSession is \(fields.tty) and targetNonce is \(fields.nonce) then set end of exactMatches to targetSession
                            end try
                        end repeat
                    end repeat
                end repeat
                if (count of exactMatches) is 0 then return {"not-found"}
                if (count of exactMatches) is greater than 1 then return {"ambiguous"}
                launch API script named \(script) arguments {\(fields.guid), \(fields.nonce), \(fields.title), \(fields.requestID)}
                return {"launched"}
            end tell
        end timeout
        """
    }

    static func status(
        _ reference: ManagedTerminalReference,
        nonce: String,
        title: String,
        requestID: String
    ) throws -> String {
        let fields = try literals(reference, nonce: nonce, title: title, requestID: requestID)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set exactMatches to {}
                repeat with targetWindow in windows
                    set targetTabIndex to 0
                    repeat with targetTab in tabs of targetWindow
                        set targetTabIndex to targetTabIndex + 1
                        repeat with targetSession in sessions of targetTab
                            try
                                set targetNonce to variable targetSession named "user.tmuxRoomsNonce"
                                if unique ID of targetSession is \(fields.guid) and tty of targetSession is \(fields.tty) and targetNonce is \(fields.nonce) then set end of exactMatches to {targetWindow, targetTabIndex, targetTab, targetSession}
                            end try
                        end repeat
                    end repeat
                end repeat
                if (count of exactMatches) is 0 then return {"not-found"}
                if (count of exactMatches) is greater than 1 then return {"ambiguous"}
                set exactMatch to item 1 of exactMatches
                set matchedWindow to item 1 of exactMatch
                set matchedTabIndex to item 2 of exactMatch
                set matchedTab to item 3 of exactMatch
                set matchedSession to item 4 of exactMatch
                set appliedRequest to missing value
                try
                    set appliedRequest to variable matchedSession named "user.tmuxRoomsTitleApplied"
                end try
                if appliedRequest is \(fields.requestID) and title of matchedTab is \(fields.title) then
                    return {id of matchedWindow, matchedTabIndex, unique ID of matchedSession, tty of matchedSession, variable matchedSession named "user.tmuxRoomsNonce"}
                end if
                return {"pending"}
            end tell
        end timeout
        """
    }

    private static func literals(
        _ reference: ManagedTerminalReference,
        nonce: String,
        title: String,
        requestID: String
    ) throws -> (guid: String, tty: String, nonce: String, title: String, requestID: String) {
        guard reference.windowID > 0,
              reference.tabIndex > 0,
              !reference.sessionGUID.isEmpty,
              !reference.tty.isEmpty,
              ManagedNonce.isValid(nonce),
              ManagedNonce.isValid(requestID)
        else { throw ManagedTerminalError.invalidRecord }
        return (
            try AppleScriptLiteral.string(reference.sessionGUID),
            try AppleScriptLiteral.string(reference.tty),
            try AppleScriptLiteral.string(nonce),
            try AppleScriptLiteral.string(title),
            try AppleScriptLiteral.string(requestID)
        )
    }
}

@MainActor
struct ITermPythonTitleTransport {
    private let runner: any AppleScriptRunning
    private let homeDirectory: URL
    private let pollInterval: Duration
    private let maxLaunchAttempts: Int
    private let overallTimeout: Duration

    init(
        runner: any AppleScriptRunning,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pollInterval: Duration = .milliseconds(100),
        maxLaunchAttempts: Int = 30,
        overallTimeout: Duration = .seconds(8)
    ) {
        self.runner = runner
        self.homeDirectory = homeDirectory
        self.pollInterval = pollInterval
        self.maxLaunchAttempts = max(1, maxLaunchAttempts)
        self.overallTimeout = max(.zero, overallTimeout)
    }

    /// Hands iTerm the title and returns the id identifying this attempt.
    ///
    /// It does not wait for the title to land. Waiting costs one Apple Event
    /// per poll, each one walking every window and tab, and each one freezing
    /// the app for its whole round trip.
    func requestTitle(
        _ reference: ManagedTerminalReference,
        nonce: String,
        title: String
    ) async -> Result<String, SmokeAutomationError> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: overallTimeout)
        guard isActive(clock: clock, deadline: deadline) else { return .failure(.timeout) }

        let scriptURL: URL
        do {
            scriptURL = try ITermPythonTitleScript.install(homeDirectory: homeDirectory)
        } catch {
            return .failure(.scriptInstallFailed)
        }

        do {
            let requestID = ManagedNonce.generate()
            let launchSource = try ITermPythonTitleScripts.launch(
                reference,
                nonce: nonce,
                title: title,
                requestID: requestID,
                scriptName: scriptURL.lastPathComponent
            )

            for attempt in 0..<maxLaunchAttempts {
                guard isActive(clock: clock, deadline: deadline) else { return .failure(.timeout) }
                let execution = await runner.execute(source: launchSource)
                guard isActive(clock: clock, deadline: deadline) else { return .failure(.timeout) }
                switch execution {
                case .success(.list([.string("launched")])):
                    return .success(requestID)
                case .success(.list([.string("not-found")])):
                    return .failure(.notFound)
                case .success(.list([.string("ambiguous")])):
                    return .failure(.ambiguous)
                case let .failure(number, _) where number == 2 && attempt + 1 < maxLaunchAttempts:
                    guard await pause(clock: clock, until: deadline) else { return .failure(.timeout) }
                    continue
                case let .failure(number, _):
                    return .failure(map(number))
                case .success:
                    return .failure(.invalidReply)
                }
            }
            return .failure(.timeout)
        } catch {
            return .failure(.invalidReply)
        }
    }

    /// One check of whether a requested title landed on the exact session.
    /// `.success(nil)` means iTerm has not applied it yet.
    func confirmTitle(
        _ reference: ManagedTerminalReference,
        nonce: String,
        title: String,
        requestID: String
    ) async -> Result<ManagedTerminalReference?, SmokeAutomationError> {
        let statusSource: String
        do {
            statusSource = try ITermPythonTitleScripts.status(reference, nonce: nonce, title: title, requestID: requestID)
        } catch {
            return .failure(.invalidReply)
        }
        switch await runner.execute(source: statusSource) {
        case let .success(value) where decodeEvidence(value, nonce: nonce) == reference:
            return .success(reference)
        case .success(.list([.string("pending")])):
            return .success(nil)
        case .success(.list([.string("not-found")])):
            return .failure(.notFound)
        case .success(.list([.string("ambiguous")])):
            return .failure(.ambiguous)
        case let .failure(number, _):
            return .failure(map(number))
        case .success:
            return .failure(.staleTarget)
        }
    }

    private func isActive(clock: ContinuousClock, deadline: ContinuousClock.Instant) -> Bool {
        !Task.isCancelled && clock.now < deadline
    }

    private func pause(clock: ContinuousClock, until deadline: ContinuousClock.Instant) async -> Bool {
        guard isActive(clock: clock, deadline: deadline) else { return false }
        do {
            try await Task.sleep(for: pollInterval)
        } catch {
            return false
        }
        return isActive(clock: clock, deadline: deadline)
    }

    private func decodeEvidence(_ value: AppleScriptValue, nonce: String) -> ManagedTerminalReference? {
        guard case let .list(items) = value,
              items.count == 5,
              case let .integer(windowID) = items[0],
              case let .integer(tabIndex) = items[1],
              case let .string(guid) = items[2],
              case let .string(tty) = items[3],
              case let .string(actualNonce) = items[4],
              actualNonce == nonce,
              windowID > 0,
              tabIndex > 0,
              !guid.isEmpty,
              !tty.isEmpty
        else { return nil }
        return .init(windowID: windowID, tabIndex: tabIndex, sessionGUID: guid, tty: tty)
    }

    private func map(_ number: Int?) -> SmokeAutomationError {
        switch number {
        case -1743: .permissionDenied
        case -1712: .timeout
        default: .scriptFailure(number: number)
        }
    }
}
