import XCTest

@MainActor
final class TmuxRoomsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureWindowTitle = "Tmux Rooms Fixture"
    private let fastTimeout: TimeInterval = 1
    private let diagnosticTimeout: TimeInterval = 8

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        terminateCurrentApp()
        try await super.tearDown()
    }

    func testNoServerAndDetachedRoomList() {
        launch("v1-no-server")
        XCTAssertTrue(waitForExistence(textElement("empty.no-server.title")))
        XCTAssertTrue(waitForExistence(textElement("empty.no-server.intent")))

        switchFixture(to: "v1-empty")
        XCTAssertTrue(waitForExistence(textElement("empty.rooms.title")))
        XCTAssertTrue(waitForExistence(textElement("empty.rooms.intent")))

        switchFixture(to: "v1-detached")
        let id = roomID(2)
        XCTAssertTrue(waitForExistence(textElement("room.\(id)")))
        XCTAssertTrue(text(of: textElement("room.\(id).status")).contains("Detached"))
        XCTAssertTrue(waitUntilReady(button("room.\(id).open")))
    }

    func testOneClientAndReadOnlyPreviewCopy() {
        launch("v1-one-focusable")
        let oneID = roomID(3)
        XCTAssertTrue(waitForExistence(textElement("room.\(oneID)")))
        clickButton("room.\(oneID).open")
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("route=sole", at: "fixture.action.last"))

        switchFixture(to: "v1-read-only-preview")
        let previewID = roomID(5)
        XCTAssertTrue(waitForExistence(textElement("room.\(previewID).preview-status")))
        XCTAssertTrue(text(of: textElement("room.\(previewID).status")).contains("1 interactive"))
    }

    func testTwoClientsRequireChooserAndCancelDoesNothing() {
        launch("v1-two-mixed")
        let openID = "room.\(roomID(4)).open"
        clickButton(openID)
        XCTAssertTrue(waitForExistence(textElement("client-chooser.title")))
        XCTAssertTrue(waitForValue("0", at: "fixture.action.count"))
        XCTAssertTrue(waitUntilDisabled(button("client.tty-b.select")))

        clickButton("client-chooser.cancel")
        XCTAssertTrue(waitForNonexistence(textElement("client-chooser.title")))
        XCTAssertTrue(waitForValue("0", at: "fixture.action.count"))

        clickButton(openID)
        XCTAssertTrue(waitForExistence(textElement("client-chooser.title")))
        clickButton("client.tty-a.select")
        XCTAssertTrue(waitForNonexistence(textElement("client-chooser.title")))
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("tty-a", at: "fixture.action.last"))
    }

    func testDetachedPreviewAndDuplicateRecordExactTypedIntents() {
        launch("v1-detached")
        let id = roomID(2)
        clickButton("room.\(id).open")
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValue("open route=detached", at: "fixture.action.last"))

        clickButton("room.\(id).preview")
        XCTAssertTrue(waitForValue("2", at: "fixture.action.count"))
        XCTAssertTrue(waitForValue("preview", at: "fixture.action.last"))

        revealMore(for: id)
        clickButton("room.\(id).duplicate")
        XCTAssertTrue(waitForValue("3", at: "fixture.action.count"))
        XCTAssertTrue(waitForValue("duplicate-window", at: "fixture.action.last"))
    }

    func testRapidActivationRemainsSingleFlight() {
        launch("v1-single-flight")
        let openID = "room.\(roomID(9)).open"
        XCTAssertTrue(waitUntilReady(button(openID)))
        button(openID).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(waitForValue("pending", at: "fixture.action.pending"))
        XCTAssertTrue(waitUntilDisabled(button(openID)))
        button(openID).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("1", at: "fixture.action.max-concurrent"))
        XCTAssertTrue(waitForValue("open route=detached", at: "fixture.action.last"))

        clickButton("fixture.action.complete")
        XCTAssertTrue(waitForValue("idle", at: "fixture.action.pending"))
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
    }

    func testRoomMetadataVoiceOverLabelsAndKeyboardActivation() {
        launch("v1-one-focusable")
        let id = roomID(3)
        let paneCount = textElement("room.\(id).pane-count")
        let command = textElement("room.\(id).origin")
        let path = textElement("room.\(id).active-path")
        let openID = "room.\(id).open"
        let previewID = "room.\(id).preview"

        XCTAssertTrue(waitForExistence(paneCount))
        XCTAssertTrue(text(of: paneCount).contains("1 pane"))
        XCTAssertTrue(text(of: command).contains("zsh"))
        XCTAssertTrue(text(of: path).contains("/Users/fixture/Projects/tmux-rooms"))
        XCTAssertTrue(waitUntilReady(button(openID)))
        XCTAssertEqual(button(openID).label, "Open existing room one-focusable")
        XCTAssertTrue(waitForExistence(button(previewID)))
        XCTAssertEqual(button(previewID).label, "Preview one-focusable read only")

        activateFixtureWindow()
        fixtureWindow.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("route=sole", at: "fixture.action.last"))
    }

    func testAgentSessionNameReplacesTheTmuxNameOnTheCard() {
        launch("v1-agent-named")
        let id = roomID(10)
        let title = textElement("room.\(id)")
        let origin = textElement("room.\(id).origin")

        XCTAssertTrue(waitForExistence(title))
        XCTAssertTrue(text(of: title).contains("9.1 배포 경계"))
        XCTAssertTrue(waitForExistence(origin))
        XCTAssertTrue(text(of: origin).contains("omc-tmux-rooms-core-v1-20260901023710"))
        XCTAssertFalse(text(of: origin).contains("2.1.247"))
        XCTAssertTrue(waitUntilReady(button("room.\(id).open")))
        XCTAssertEqual(button("room.\(id).open").label, "Open existing room omc-tmux-rooms-core-v1-20260901023710")
    }

    func testUnnamedAgentFallsBackToItsProductName() {
        launch("v1-agent-detected")
        let id = roomID(11)
        let title = textElement("room.\(id)")

        XCTAssertTrue(waitForExistence(title))
        XCTAssertTrue(text(of: title).contains("Codex"))
        XCTAssertTrue(text(of: textElement("room.\(id).origin")).contains("omc-projects-detached-20260826230948"))
    }

    func testRecoveryAndTimeoutRetryPolicy() {
        launch("v1-automation-denied")
        XCTAssertTrue(waitForExistence(textElement("issue.automation-denied")))
        XCTAssertTrue(waitForExistence(textElement("issue.automation-denied.guidance")))
        XCTAssertTrue(waitForNonexistence(button("issue.retry")))

        switchFixture(to: "v1-stale")
        XCTAssertTrue(waitForExistence(textElement("issue.stale")))
        XCTAssertTrue(waitUntilReady(button("issue.refresh")))
        XCTAssertTrue(waitForNonexistence(button("issue.retry")))

        switchFixture(to: "v1-ambiguous")
        XCTAssertTrue(waitForExistence(textElement("issue.ambiguous-managed")))
        XCTAssertTrue(waitForExistence(textElement("recovery.candidate.PrimaryCandidate00000001")))
        XCTAssertTrue(waitForExistence(textElement("recovery.candidate.PreviewCandidate00000001")))
        XCTAssertTrue(waitForExistence(button("recovery.PrimaryCandidate00000001.choose-primary")))
        XCTAssertTrue(waitForExistence(button("recovery.PreviewCandidate00000001.choose-preview")))
        XCTAssertTrue(waitForExistence(button("recovery.PrimaryCandidate00000001.clean-up")))
        button("recovery.PrimaryCandidate00000001.clean-up").click()
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("recover clean-up candidate=PrimaryCandidate00000001", at: "fixture.action.last"))

        switchFixture(to: "v1-timeout")
        XCTAssertTrue(waitForExistence(textElement("issue.timeout")))
        XCTAssertTrue(waitUntilDisabled(button("issue.retry")))
        XCTAssertTrue(waitForExistence(textElement("issue.timeout.running")))

        switchFixture(to: "v1-general-error")
        XCTAssertTrue(waitForExistence(textElement("issue.general")))
        XCTAssertTrue(waitUntilReady(button("issue.retry")))
    }

    func testDeleteConfirmationCancelAndConfirmSemantics() {
        launch("v1-delete-attached")
        let id = roomID(7)
        revealMore(for: id)
        clickButton("room.\(id).delete")

        XCTAssertTrue(waitForExistence(textElement("delete-confirmation.title")))
        XCTAssertTrue(waitForValueContaining("attached-delete", at: "delete-confirmation.name"))
        XCTAssertTrue(waitForValueContaining("2", at: "delete-confirmation.clients"))
        clickButton("delete-confirmation.cancel")
        XCTAssertTrue(waitForNonexistence(textElement("delete-confirmation.title")))
        XCTAssertTrue(waitForValue("0", at: "fixture.action.count"))

        revealMore(for: id)
        clickButton("room.\(id).delete")
        XCTAssertTrue(waitForExistence(textElement("delete-confirmation.title")))
        clickButton("delete-confirmation.confirm")
        XCTAssertTrue(waitForNonexistence(textElement("delete-confirmation.title")))
        XCTAssertTrue(waitForValue("1", at: "fixture.action.count"))
        XCTAssertTrue(waitForValueContaining("delete", at: "fixture.action.last"))
    }

    func testLongUnicodeRoomHasStableAccessibilityAndActions() {
        launch("v1-long-unicode")
        let id = roomID(8)
        let room = textElement("room.\(id)")
        XCTAssertTrue(waitForExistence(room))
        XCTAssertTrue(text(of: room).contains("한국어"))
        XCTAssertTrue(text(of: room).contains("🚀"))
        XCTAssertTrue(waitUntilReady(button("room.\(id).open")))
        XCTAssertTrue(waitForExistence(button("refresh")))
    }

    private var fixtureWindow: XCUIElement {
        app.windows[fixtureWindowTitle]
    }

    private func launch(_ fixture: String) {
        terminateCurrentApp()
        let launched = XCUIApplication()
        launched.launchEnvironment["TMUX_ROOMS_UI_FIXTURE"] = fixture
        launched.launchArguments += ["--ui-testing"]
        app = launched
        launched.launch()
        launched.activate()
        XCTAssertTrue(waitForExistence(fixtureWindow))
        XCTAssertTrue(launched.state == .runningForeground || launched.state == .runningBackground)
    }

    private func terminateCurrentApp() {
        guard let current = app else { return }
        if current.state != .notRunning {
            current.terminate()
            XCTAssertTrue(current.wait(for: .notRunning, timeout: diagnosticTimeout))
        }
        app = nil
    }

    private func activateFixtureWindow() {
        app.activate()
        XCTAssertTrue(waitForExistence(fixtureWindow))
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
    }

    private func switchFixture(to fixture: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.tellang.tmuxrooms.ui-fixture.switch"),
            object: fixture,
            userInfo: nil,
            deliverImmediately: true
        )
        XCTAssertTrue(waitForValue(fixture, at: "fixture.current"), "Fixture did not switch to \(fixture)")
    }

    private func revealMore(for roomID: String) {
        let deleteID = "room.\(roomID).delete"
        if button(deleteID).exists, button(deleteID).isHittable { return }
        clickButton("room.\(roomID).more")
    }

    private func clickButton(_ identifier: String) {
        let target = button(identifier)
        XCTAssertTrue(waitUntilReady(target), "Button not ready: \(identifier)")
        target.click()
    }

    private func button(_ identifier: String) -> XCUIElement {
        fixtureWindow.buttons[identifier]
    }

    private func textElement(_ identifier: String) -> XCUIElement {
        fixtureWindow.staticTexts[identifier]
    }

    private func waitForExistence(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        wait(element, predicate: NSPredicate(format: "exists == true"), timeout: timeout)
    }

    private func waitForNonexistence(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        wait(element, predicate: NSPredicate(format: "exists == false"), timeout: timeout)
    }

    private func waitUntilReady(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        wait(element, predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), timeout: timeout)
    }

    private func waitUntilDisabled(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        wait(element, predicate: NSPredicate(format: "exists == true AND enabled == false"), timeout: timeout)
    }

    private func waitForValue(_ value: String, at identifier: String) -> Bool {
        wait(textElement(identifier), predicate: NSPredicate(format: "value == %@", value), timeout: nil)
    }

    private func waitForValueContaining(_ value: String, at identifier: String) -> Bool {
        wait(textElement(identifier), predicate: NSPredicate(format: "value CONTAINS %@", value), timeout: nil)
    }

    private func wait(_ element: XCUIElement, predicate: NSPredicate, timeout customTimeout: TimeInterval?) -> Bool {
        if predicate.evaluate(with: element) { return true }

        let fastDeadline = Date().addingTimeInterval(customTimeout ?? fastTimeout)
        while Date() < fastDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
            if predicate.evaluate(with: element) { return true }
        }

        // Keep the common path fast, but retain XCTest's detailed UI hierarchy
        // diagnostics for a genuinely slow or failed transition.
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: diagnosticTimeout
        ) == .completed
    }

    private func text(of element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func roomID(_ numericSessionID: Int) -> String {
        "session-\(numericSessionID)-1700000100"
    }
}
