import AppKit
import SwiftUI
import TmuxRoomsCore

@main
struct TmuxRoomsApp: App {
    @StateObject private var store: RoomsStore
    @State private var menuBarExtraInserted: Bool
    private let fixtureWindowEnabled: Bool

    init() {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["TMUX_ROOMS_UI_FIXTURE"] {
            let fixtureStore = UIFixture(rawValue: value)?.makeStore() ?? UIFixture.invalidStore(value)
            _store = StateObject(wrappedValue: fixtureStore)
            _menuBarExtraInserted = State(initialValue: false)
            fixtureWindowEnabled = true
        } else {
            _store = StateObject(wrappedValue: RoomsStore.production())
            _menuBarExtraInserted = State(initialValue: true)
            fixtureWindowEnabled = false
        }
        #else
        // Release intentionally does not read TMUX_ROOMS_UI_FIXTURE.
        _store = StateObject(wrappedValue: RoomsStore.production())
        _menuBarExtraInserted = State(initialValue: true)
        fixtureWindowEnabled = false
        configureReleaseAutomationSmoke()
        #endif
    }

    @SceneBuilder
    var body: some Scene {
        MenuBarExtra("Tmux Rooms", systemImage: "rectangle.stack", isInserted: $menuBarExtraInserted) {
            RoomsRootView(store: store)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        FixtureWindowScene(store: store, isEnabled: fixtureWindowEnabled)
        #endif
    }

    #if !DEBUG
    private func configureReleaseAutomationSmoke() {
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
                Task { @MainActor in
                    _ = await SmokeCoordinator(runner: FoundationAppleScriptRunner()) {
                        await MainActor.run { NSApplication.shared.terminate(nil) }
                    }.run(runID: runID)
                }
            }
        } catch where arguments.contains("--iterm-automation-smoke") {
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        } catch {
            // Normal app launches have no smoke argument.
        }
    }
    #endif
}

#if DEBUG
private let fixtureSwitchNotification = Notification.Name("com.tellang.tmuxrooms.ui-fixture.switch")

private struct FixtureWindowScene: Scene {
    @ObservedObject var store: RoomsStore
    let isEnabled: Bool

    var body: some Scene {
        Window("Tmux Rooms Fixture", id: "ui-fixture") {
            Group {
                if isEnabled {
                    RoomsRootView(store: store)
                        .onAppear {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                        .onReceive(DistributedNotificationCenter.default().publisher(for: fixtureSwitchNotification)) { notification in
                            guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                                  let rawValue = notification.object as? String,
                                  let fixture = UIFixture(rawValue: rawValue)
                            else { return }
                            store.resetFixture(with: fixture.makeStore())
                        }
                } else {
                    EmptyView()
                }
            }
        }
        .defaultSize(width: 480, height: 660)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(isEnabled ? .presented : .suppressed)
    }
}
#endif
