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
                        set end of resultRows to {targetWindowID, targetTabIndex, unique ID of targetSession, tty of targetSession}
                    end repeat
                end repeat
            end repeat
            return {version, resultRows}
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

    public static func focus(_ reference: ITermSessionReference) throws -> String {
        let guid = try AppleScriptLiteral.string(reference.sessionGUID)
        let tty = try AppleScriptLiteral.string(reference.tty)
        return """
        with timeout of 5 seconds
            tell application id "com.googlecode.iterm2"
                set exactMatches to {}
                repeat with targetWindow in windows
                    if id of targetWindow is \(reference.windowID) then
                        set targetTabIndex to 0
                        repeat with targetTab in tabs of targetWindow
                            set targetTabIndex to targetTabIndex + 1
                            if targetTabIndex is \(reference.tabIndex) then
                                repeat with targetSession in sessions of targetTab
                                    if unique ID of targetSession is \(guid) and tty of targetSession is \(tty) then
                                        set end of exactMatches to {targetWindow, targetTab, targetSession}
                                    end if
                                end repeat
                            end if
                        end repeat
                    end if
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
