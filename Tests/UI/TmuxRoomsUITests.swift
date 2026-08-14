import XCTest

@MainActor
final class TmuxRoomsUITests: XCTestCase {
    func testFixtureLaunchesPlaceholderApp() {
        let app = XCUIApplication()
        app.launchEnvironment["TMUX_ROOMS_UI_FIXTURE"] = "1"
        app.launch()
        let foreground = app.wait(for: .runningForeground, timeout: 5)
        XCTAssertTrue(foreground || app.state == .runningBackground)
    }
}
