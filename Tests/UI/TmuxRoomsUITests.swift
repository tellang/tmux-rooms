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
        let id = roomID(2)
        XCTAssertTrue(app.staticTexts["room.\(id)"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["room.\(id).status"]).contains("Detached"))
        XCTAssertTrue(app.buttons["room.\(id).open"].isEnabled)
    }

    func testOneClientAndReadOnlyPreviewCopy() {
        launch("v1-one-focusable")
        let oneID = roomID(3)
        XCTAssertTrue(app.staticTexts["room.\(oneID)"].waitForExistence(timeout: 5))
        app.buttons["room.\(oneID).open"].click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("route=sole"))

        app.terminate()
        launch("v1-read-only-preview")
        let previewID = roomID(5)
        XCTAssertTrue(app.staticTexts["room.\(previewID).preview-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: app.staticTexts["room.\(previewID).status"]).contains("1 interactive"))
    }

    func testTwoClientsRequireChooserAndCancelDoesNothing() {
        launch("v1-two-mixed")
        let open = app.buttons["room.\(roomID(4)).open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        XCTAssertTrue(app.staticTexts["client-chooser.title"].waitForExistence(timeout: 3))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.count"]), "0")
        XCTAssertFalse(app.buttons["client.tty-b.select"].isEnabled)
        app.buttons["client-chooser.cancel"].click()
        XCTAssertTrue(waitForValue("0", at: "fixture.action.count"))

        open.click()
        app.buttons["client.tty-a.select"].click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("tty-a"))
    }

    func testDetachedPreviewAndDuplicateRecordExactTypedIntents() {
        launch("v1-detached")
        let id = roomID(2)
        app.buttons["room.\(id).open"].click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.last"]), "open route=detached")

        app.terminate()
        launch("v1-detached")
        app.buttons["room.\(id).preview"].click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.last"]), "preview")

        app.terminate()
        launch("v1-detached")
        let duplicate = app.buttons["room.\(id).duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.last"]), "duplicate-window")
    }

    func testRapidActivationRemainsSingleFlight() {
        launch("v1-single-flight")
        let open = app.buttons["room.\(roomID(9)).open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        let activationPoint = open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        activationPoint.click()

        XCTAssertTrue(waitForValue("pending", at: "fixture.action.pending"))
        XCTAssertFalse(open.isEnabled)
        activationPoint.click()
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.count"]), "1")
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.max-concurrent"]).hasSuffix("1"))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.last"]), "open route=detached")

        app.buttons["fixture.action.complete"].click()
        XCTAssertTrue(waitForValue("idle", at: "fixture.action.pending"))
        XCTAssertEqual(text(of: app.staticTexts["fixture.action.count"]), "1")
    }

    func testRoomMetadataVoiceOverLabelsAndKeyboardActivation() {
        launch("v1-one-focusable")
        let id = roomID(3)
        let paneCount = app.staticTexts["room.\(id).pane-count"]
        let command = app.staticTexts["room.\(id).active-command"]
        let path = app.staticTexts["room.\(id).active-path"]
        let open = app.buttons["room.\(id).open"]

        XCTAssertTrue(paneCount.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: paneCount).contains("1 pane"))
        XCTAssertTrue(text(of: command).contains("zsh"))
        XCTAssertTrue(text(of: path).contains("/Users/fixture/Projects/tmux-rooms"))
        XCTAssertEqual(open.label, "Open existing room one-focusable")
        XCTAssertTrue(open.isEnabled && open.isHittable)
        XCTAssertTrue(app.buttons["room.\(id).preview"].isHittable)

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("route=sole"))
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
        let delete = app.buttons["room.\(roomID(7)).delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()

        XCTAssertTrue(app.staticTexts["delete-confirmation.title"].waitForExistence(timeout: 3))
        XCTAssertTrue(text(of: app.staticTexts["delete-confirmation.name"]).contains("attached-delete"))
        XCTAssertTrue(text(of: app.staticTexts["delete-confirmation.clients"]).contains("2"))
        app.buttons["delete-confirmation.cancel"].click()
        XCTAssertTrue(waitForValue("0", at: "fixture.action.count"))

        delete.click()
        app.buttons["delete-confirmation.confirm"].click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(text(of: app.staticTexts["fixture.action.last"]).contains("delete"))
    }

    func testLongUnicodeRoomHasStableAccessibilityAndActions() {
        launch("v1-long-unicode")
        let id = roomID(8)
        let room = app.staticTexts["room.\(id)"]
        XCTAssertTrue(room.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: room).contains("한국어"))
        XCTAssertTrue(text(of: room).contains("🚀"))
        XCTAssertTrue(app.buttons["room.\(id).open"].isHittable)
        XCTAssertTrue(app.buttons["refresh"].exists)
    }

    private func launch(_ fixture: String) {
        app = XCUIApplication()
        app.launchEnvironment["TMUX_ROOMS_UI_FIXTURE"] = fixture
        app.launchArguments += ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.windows["Tmux Rooms Fixture"].waitForExistence(timeout: 5))
    }

    private func waitForValue(_ value: String, at identifier: String) -> Bool {
        let element = app.staticTexts[identifier]
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 3) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func roomID(_ numericSessionID: Int) -> String {
        "session-\(numericSessionID)-1700000100"
    }
}
