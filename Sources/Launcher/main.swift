import Foundation

let usage = """
Usage: tmuxrooms-launch [--help]

Tmux Rooms launcher placeholder. Core lifecycle actions are not implemented in T2.
"""

if CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().contains("--help") {
    print(usage)
} else {
    FileHandle.standardError.write(Data("tmuxrooms-launch: no actions are implemented in T2\n".utf8))
    exit(64)
}
