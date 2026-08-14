import XCTest

@MainActor
final class TmuxRoomsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testNoServerAndDetachedRoomList() {
        launch("v1-no-server")
        XCTAssertTrue(app.staticTexts["empty.no-server.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["empty.no-server.intent"].exists)

        app.terminate()
        launch("v1-empty")
        XCTAssertTrue(app.staticTexts["empty.rooms.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["empty.rooms.intent"].exists)

        app.terminate()
        launch("v1-detached")
        XCTAssertTrue(app.staticTexts["room.detached-shell"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["room.detached-shell.status"]).contains("Detached"))
        XCTAssertTrue(app.buttons["room.detached-shell.open"].isEnabled)
    }

    func testOneClientAndReadOnlyPreviewCopy() {
        launch("v1-one-focusable")
        XCTAssertTrue(app.staticTexts["room.one-focusable"].waitForExistence(timeout: 5))
        app.buttons["room.one-focusable.open"].click()
        XCTAssertTrue(waitForLabel("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("route=sole"))

        app.terminate()
        launch("v1-read-only-preview")
        XCTAssertTrue(app.staticTexts["room.preview-room.preview-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["room.preview-room.status"]).contains("1 interactive"))
    }

    func testTwoClientsRequireChooserAndCancelDoesNothing() {
        launch("v1-two-mixed")
        let open = app.buttons["room.multi-client.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.staticTexts["client-chooser.title"].waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.count"]), "0")
        XCTAssertFalse(app.buttons["client.tty-b.select"].isEnabled)
        app.buttons["client-chooser.cancel"].click()
        XCTAssertTrue(waitForLabel("0", at: "fixture.action.count"))

        open.click()
        app.buttons["client.tty-a.select"].click()
        XCTAssertTrue(waitForLabel("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("tty-a"))
    }

    func testRecoveryAndTimeoutRetryPolicy() {
        launch("v1-automation-denied")
        XCTAssertTrue(app.staticTexts["issue.automation-denied"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["issue.automation-denied.guidance"].exists)
        XCTAssertFalse(app.buttons["issue.retry"].exists)

        app.terminate()
        launch("v1-stale")
        XCTAssertTrue(app.staticTexts["issue.stale"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["issue.refresh"].isEnabled)
        XCTAssertFalse(app.buttons["issue.retry"].exists)

        app.terminate()
        launch("v1-ambiguous")
        XCTAssertTrue(app.staticTexts["issue.ambiguous-managed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recovery.choose-primary"].exists)
        XCTAssertTrue(app.buttons["recovery.choose-preview"].exists)
        XCTAssertTrue(app.buttons["recovery.clean-up"].exists)

        app.terminate()
        launch("v1-timeout")
        XCTAssertTrue(app.staticTexts["issue.timeout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["issue.retry"].exists)
        XCTAssertFalse(app.buttons["issue.retry"].isEnabled)
        XCTAssertTrue(app.staticTexts["issue.timeout.running"].exists)

        app.terminate()
        launch("v1-general-error")
        XCTAssertTrue(app.staticTexts["issue.general"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["issue.retry"].isEnabled)
    }

    func testDeleteConfirmationCancelAndConfirmSemantics() {
        launch("v1-delete-attached")
        revealMore(for: "attached-delete")
        app.buttons["room.attached-delete.delete"].click()

        XCTAssertTrue(app.staticTexts["delete-confirmation.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(text(of: app.staticTexts["delete-confirmation.name"]).contains("attached-delete"))
        XCTAssertTrue(text(of: app.staticTexts["delete-confirmation.clients"]).contains("2"))
        app.buttons["delete-confirmation.cancel"].click()
        XCTAssertTrue(waitForLabel("0", at: "fixture.action.count"))

        revealMore(for: "attached-delete")
        app.buttons["room.attached-delete.delete"].click()
        app.buttons["delete-confirmation.confirm"].click()
        XCTAssertTrue(waitForLabel("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("delete"))
    }

    func testLongUnicodeRoomHasStableAccessibilityAndActions() {
        launch("v1-long-unicode")
        let room = app.staticTexts["room.long-unicode"]
        XCTAssertTrue(room.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: room).contains("한국어"))
        XCTAssertTrue(text(of: room).contains("🚀"))
        XCTAssertTrue(app.buttons["room.long-unicode.open"].isHittable)
        XCTAssertTrue(app.buttons["refresh"].exists)
    }

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchEnvironment["TMUX_ROOMS_UI_FIXTURE"] = fixture
        app.launchArguments += ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.windows["Tmux Rooms Fixture"].waitForExistence(timeout: 5))
    }

    private func revealMore(for roomID: String) {
        let delete = app.buttons["room.\(roomID).delete"]
        if delete.exists { return }
        let more = app.buttons["room.\(roomID).more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.click()
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
    }

    private func waitForLabel(_ value: String, at identifier: String) -> Bool {
        let element = app.staticTexts[identifier]
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }
}
