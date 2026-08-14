import SwiftUI
import TmuxRoomsCore

@main
struct TmuxRoomsApp: App {
    init() {
        #if !DEBUG
        let process = ProcessInfo.processInfo
        let arguments = Array(process.arguments.dropFirst())
        do {
            if case let .smoke(runID) = try SmokeLaunchContract.resolve(
                arguments: arguments,
                environment: process.environment,
                bundleURL: Bundle.main.bundleURL,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                releaseEnabled: true
            ) {
                Task {
                    await SmokeCoordinator(runner: FoundationAppleScriptRunner()) {
                        await MainActor.run { NSApplication.shared.terminate(nil) }
                    }.run(runID: runID)
                }
            }
        } catch where arguments.contains("--iterm-automation-smoke") {
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        } catch {
            // Normal app launches have no smoke argument and are handled above.
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra("Tmux Rooms", systemImage: "rectangle.stack") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tmux Rooms")
                    .font(.headline)
                Text("Core v1 bootstrap: \(TmuxRoomsCore.bootstrapMarker)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Quit Tmux Rooms") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
        .menuBarExtraStyle(.window)
    }
}
