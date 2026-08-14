import SwiftUI
import TmuxRoomsCore

@main
struct TmuxRoomsApp: App {
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
