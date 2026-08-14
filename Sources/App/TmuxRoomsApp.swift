import AppKit
import SwiftUI
import TmuxRoomsCore

@main
struct TmuxRoomsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: RoomsStore
    @State private var menuBarExtraInserted: Bool
    private let fixtureWindowEnabled: Bool
    private let refreshCadence: RefreshCadence

    init() {
        let store: RoomsStore
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["TMUX_ROOMS_UI_FIXTURE"] {
            store = UIFixture(rawValue: value)?.makeStore() ?? UIFixture.invalidStore(value)
            _menuBarExtraInserted = State(initialValue: false)
            fixtureWindowEnabled = true
        } else {
            store = RoomsStore.production()
            _menuBarExtraInserted = State(initialValue: true)
            fixtureWindowEnabled = false
        }
        #else
        // Release intentionally does not read TMUX_ROOMS_UI_FIXTURE.
        store = RoomsStore.production()
        _menuBarExtraInserted = State(initialValue: true)
        fixtureWindowEnabled = false
        #endif
        _store = StateObject(wrappedValue: store)
        refreshCadence = RefreshCadence(isEnabled: !store.isFixture) {
            store.automaticRefresh()
        }
        refreshCadence.start()
        #if !DEBUG
        configureReleaseAutomationSmoke()
        #endif
    }

    @SceneBuilder
    var body: some Scene {
        MenuBarExtra("Tmux Rooms", systemImage: "rectangle.stack", isInserted: $menuBarExtraInserted) {
            RoomsRootView(store: store)
                .onAppear {
                    refreshCadence.update(activity: .foreground, refreshImmediately: true)
                }
                .onDisappear {
                    refreshCadence.update(activity: .background)
                }
                .onChange(of: scenePhase) { _, phase in
                    refreshCadence.update(activity: cadenceActivity(for: phase))
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    refreshCadence.update(activity: .foreground, refreshImmediately: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    refreshCadence.update(activity: .background)
                }
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        FixtureWindowScene(store: store, isEnabled: fixtureWindowEnabled)
        #endif
    }

    private func cadenceActivity(for phase: ScenePhase) -> RefreshCadenceActivity {
        phase == .active ? .foreground : .background
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
