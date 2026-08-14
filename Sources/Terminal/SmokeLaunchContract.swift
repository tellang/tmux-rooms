import Foundation

public enum SmokeLaunchDecision: Sendable, Equatable { case normal, smoke(UUID) }
public enum SmokeLaunchError: Error, Sendable, Equatable { case invalidArguments, unavailableBuild, unsafeEnvironment, wrongBundle }

public enum SmokeLaunchContract {
    public static func resolve(arguments: [String], environment: [String: String], bundleURL: URL, bundleIdentifier: String?, releaseEnabled: Bool) throws -> SmokeLaunchDecision {
        guard arguments.contains("--iterm-automation-smoke") else { return .normal }
        guard releaseEnabled else { throw SmokeLaunchError.unavailableBuild }
        guard environment["TMUX_ROOMS_UI_FIXTURE"] == nil, environment["XCTestConfigurationFilePath"] == nil else { throw SmokeLaunchError.unsafeEnvironment }
        let expected = URL(fileURLWithPath: "/Applications/Tmux Rooms.app").resolvingSymlinksInPath().standardizedFileURL.path
        guard bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == expected,
              bundleIdentifier == "com.tellang.tmuxrooms" else { throw SmokeLaunchError.wrongBundle }
        guard arguments.count == 3, arguments[0] == "--iterm-automation-smoke", arguments[1] == "--smoke-run-id", let id = UUID(uuidString: arguments[2]) else {
            throw SmokeLaunchError.invalidArguments
        }
        return .smoke(id)
    }
}
