import Foundation

public enum AppleScriptLiteral {
    public static func string(_ value: String) throws -> String {
        guard value.utf8.count <= 4096,
              !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw SmokeAutomationError.invalidReply
        }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum ITermSmokeScripts {
    /// Windows and tabs are read defensively because iTerm mutates both lists
    /// while a window opens or closes, and an index that goes invalid mid-loop
    /// fails the whole script with -1719. A skipped element is counted rather
    /// than hidden: the caller decides whether a partial enumeration can be
    /// used, and never mistakes one for an empty terminal.
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
                                set end of resultRows to {targetWindowID, targetTabIndex, unique ID of targetSession, tty of targetSession}
                            end repeat
                        on error
                            set skippedCount to skippedCount + 1
                        end try
                    end repeat
                on error
                    set skippedCount to skippedCount + 1
                end try
            end repeat
            return {version, resultRows, skippedCount}
        end tell
    end timeout
    """

    /// Every session TTY on the machine, in one bulk fetch.
    ///
    /// The focusability map only asks how many sessions share a TTY, so it
    /// never needed the window and tab walk that `enumerate` performs. Asking
    /// for one plural property is a single round trip instead of three per
    /// session, and every round trip here holds the main thread.
    public static let enumerateTTYs = """
    with timeout of 5 seconds
        tell application id "com.googlecode.iterm2"
            return {version, tty of every session of every tab of every window}
        end tell
    end timeout
    """

    public static let create = """
    with timeout of 5 seconds
        tell application id "com.googlecode.iterm2"
            set createdWindow to create window with default profile
            set createdTab to current tab of createdWindow
            set createdSession to current session of createdTab
            return {id of createdWindow, 1, unique ID of createdSession, tty of createdSession}
        end tell
    end timeout
    """

    /// Focuses an external session by addressing it directly. Same reasoning as
    /// `ITermManagedScripts.focus`: the reference already names the target, and
    /// searching for it again costs round trips that freeze the app.
    public static func focus(_ reference: ITermSessionReference) throws -> String {
        let guid = try AppleScriptLiteral.string(reference.sessionGUID)
        let tty = try AppleScriptLiteral.string(reference.tty)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                try
                    set matchedWindow to window id \(reference.windowID)
                    set matchedTab to tab \(reference.tabIndex) of matchedWindow
                    set matchedSession to session id \(guid) of matchedTab
                    if tty of matchedSession is not \(tty) then return {"not-found"}
                on error
                    return {"not-found"}
                end try
                select matchedSession
                select matchedTab
                select matchedWindow
                activate
                repeat with pollIndex from 1 to 20
                    if frontmost and current window is matchedWindow and current tab of matchedWindow is matchedTab and current session of matchedTab is matchedSession then exit repeat
                    delay 0.05
                end repeat
                set actualWindow to current window
                set actualTab to current tab of actualWindow
                set actualSession to current session of actualTab
                set actualTabIndex to 0
                repeat with candidateTab in tabs of actualWindow
                    set actualTabIndex to actualTabIndex + 1
                    if candidateTab is actualTab then exit repeat
                end repeat
                return {{id of actualWindow, actualTabIndex, unique ID of actualSession, tty of actualSession}, frontmost}
            end tell
        end timeout
        """
    }
}
