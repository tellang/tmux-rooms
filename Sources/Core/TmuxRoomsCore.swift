import Foundation

/// The tmux binary every component runs unless a caller injects another.
public enum TmuxExecutable {
    public static let defaultPath = "/opt/homebrew/bin/tmux"
    public static var defaultURL: URL { URL(fileURLWithPath: defaultPath) }
}

public enum LauncherContract {
    public static let executableName = "tmuxrooms-launch"
}
