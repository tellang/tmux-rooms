import Foundation
import TmuxRoomsCore

let usage = """
Usage: tmuxrooms-launch --supervise <nonce>

Internal bundled helper for app-owned managed terminal sessions.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") {
    print(usage)
} else {
    do {
        let nonce = try ManagedSupervisorCLI.parse(arguments: arguments)
        let journal = ManagedClientJournal()
        let configuration = try journal.readConfiguration(nonce: nonce)
        try await ManagedTmuxSupervisor(configuration: configuration, journal: journal).run()
    } catch {
        FileHandle.standardError.write(Data("tmuxrooms-launch: rejected supervisor launch\n".utf8))
        exit(64)
    }
}
