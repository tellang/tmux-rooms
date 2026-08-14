import Foundation

public protocol TmuxDeleting: Sendable {
    func delete(_ token: SessionToken) async -> RoomActionResult
}

public enum TmuxDeleteCommand {
    public static let deletedMarker = "TMUXROOMS_DELETED"
    public static let alreadyGoneMarker = "TMUXROOMS_ALREADY_GONE"
    public static let staleMarker = "TMUXROOMS_STALE"

    public static func arguments(for token: SessionToken) throws -> [String] {
        guard validIdentifier(token.sessionID), token.createdAtUnixSeconds >= 0,
              token.server.socketDevice > 0, token.server.socketInode > 0,
              token.server.serverPID > 0, token.server.startedAtUnixSeconds >= 0 else {
            throw TmuxFailure.malformedOutput("invalid delete token")
        }

        let server = token.server
        let serverMatches = "#{&&:#{==:#{pid},\(server.serverPID)},#{==:#{start_time},\(server.startedAtUnixSeconds)}}"
        let idMatches = sessionLoop("#{==:#{session_id},\(token.sessionID)}")
        let tokenMatches = sessionLoop("#{&&:#{==:#{session_id},\(token.sessionID)},#{==:#{session_created},\(token.createdAtUnixSeconds)}}")
        let deleted = "kill-session -t '\(token.sessionID)' ; display-message -p '\(deletedMarker)'"
        let missingOrStale = "if-shell -F '\(idMatches)' \"display-message -p '\(staleMarker)'\" \"display-message -p '\(alreadyGoneMarker)'\""
        let escapedMissingOrStale = missingOrStale.replacingOccurrences(of: "\"", with: "\\\"")
        let matchingServer = "if-shell -F '\(tokenMatches)' \"\(deleted)\" \"\(escapedMissingOrStale)\""
        return ["-S", server.canonicalSocketPath, "-N", "-u", "if-shell", "-F", serverMatches, matchingServer, "display-message -p '\(staleMarker)'"]
    }

    private static func sessionLoop(_ predicate: String) -> String {
        "#{m:*1*,#{S:#{?\(predicate),1,}}}"
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard value.first == "$", value.count > 1 else { return false }
        let digits = value.dropFirst()
        return digits.allSatisfy(\.isASCIIWholeNumber) && (digits == "0" || digits.first != "0")
    }
}

public struct TmuxDeleteExecutor: TmuxDeleting, Sendable {
    private let snapshotLoader: any TmuxSnapshotLoading
    private let runner: any TmuxCommandRunning
    private let executableURL: URL

    public init(snapshotLoader: any TmuxSnapshotLoading, runner: any TmuxCommandRunning = ProcessTmuxCommandRunner(), executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")) {
        self.snapshotLoader = snapshotLoader
        self.runner = runner
        self.executableURL = executableURL
    }

    public func delete(_ token: SessionToken) async -> RoomActionResult {
        do {
            _ = try TmuxDeleteCommand.arguments(for: token)
            let snapshot = try await snapshotLoader.load(socketURL: URL(fileURLWithPath: token.server.canonicalSocketPath))
            guard let server = snapshot.server else { return .alreadyGone }
            guard server == token.server else { return .staleTarget }
            guard let room = snapshot.rooms.first(where: { $0.token.sessionID == token.sessionID }) else { return .alreadyGone }
            guard room.token == token else { return .staleTarget }

            let invocation = TmuxCommandInvocation(executableURL: executableURL, arguments: try TmuxDeleteCommand.arguments(for: token))
            let output = try await runner.run(invocation)
            guard output.exitCode == 0, output.termination == .exit else {
                return .tmuxFailure(.commandFailed(exitCode: output.exitCode, stderr: String(decoding: output.stderr, as: UTF8.self)))
            }
            switch String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
            case TmuxDeleteCommand.deletedMarker: return .succeeded
            case TmuxDeleteCommand.alreadyGoneMarker: return .alreadyGone
            case TmuxDeleteCommand.staleMarker: return .staleTarget
            default: return .tmuxFailure(.malformedOutput("delete marker"))
            }
        } catch let failure as TmuxFailure {
            return .tmuxFailure(failure)
        } catch {
            return .tmuxFailure(.launchFailed(String(describing: error)))
        }
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first!.value >= 48 && unicodeScalars.first!.value <= 57
    }
}
