import Foundation
import Testing
@testable import TmuxRoomsCore

private actor FakeAppleScriptRunner: AppleScriptRunning {
    private var replies: [AppleScriptExecution]
    private(set) var sources: [String] = []

    init(_ replies: [AppleScriptExecution]) { self.replies = replies }

    func execute(source: String) async -> AppleScriptExecution {
        sources.append(source)
        return replies.removeFirst()
    }

    func callCount() -> Int { sources.count }
}

private let beforeRef = ITermSessionReference(windowID: 12, tabIndex: 2, sessionGUID: "before-guid", tty: "/dev/ttys001")
private let createdRef = ITermSessionReference(windowID: 13, tabIndex: 1, sessionGUID: "created-guid", tty: "/dev/ttys002")

private func descriptor(_ reference: ITermSessionReference) -> AppleScriptValue {
    .list([.integer(reference.windowID), .integer(reference.tabIndex), .string(reference.sessionGUID), .string(reference.tty)])
}

private func enumeration(_ references: [ITermSessionReference]) -> AppleScriptExecution {
    .success(.list([.string("3.5.14"), .list(references.map(descriptor))]))
}

private func focus(_ reference: ITermSessionReference, frontmost: Bool = true) -> AppleScriptExecution {
    .success(.list([descriptor(reference), .boolean(frontmost)]))
}

@Test("Foundation runner decodes an empty AppleScript list")
func foundationRunnerDecodesEmptyList() async {
    let result = await FoundationAppleScriptRunner().execute(source: "return {}")
    #expect(result == .success(.list([])))
}

@Test("Foundation runner decodes a nested empty AppleScript list")
func foundationRunnerDecodesNestedEmptyList() async {
    let result = await FoundationAppleScriptRunner().execute(source: "return {{}}")
    #expect(result == .success(.list([.list([])])))
}

@Test("smoke completes the fixed enumerate, create, and focus sequence")
func smokeSuccess() async throws {
    let fake = FakeAppleScriptRunner([enumeration([beforeRef]), .success(descriptor(createdRef)), focus(createdRef)])
    let result = await ITermAutomationSmoke(runner: fake).run()
    #expect(result.finalResult == .success)
    #expect(result.before == [beforeRef])
    #expect(result.created == createdRef)
    #expect(result.actual == createdRef)
    #expect(await fake.callCount() == 3)
}

@Test("permission denial stops before create")
func permissionDeniedStops() async {
    let fake = FakeAppleScriptRunner([.failure(number: -1743, message: "not authorized")])
    let result = await ITermAutomationSmoke(runner: fake).run()
    #expect(result.finalResult == .failure(.permissionDenied))
    #expect(await fake.callCount() == 1)
}

@Test("timeout is typed and never retried")
func timeoutStopsWithoutRetry() async {
    let fake = FakeAppleScriptRunner([enumeration([]), .failure(number: -1712, message: "timed out")])
    let result = await ITermAutomationSmoke(runner: fake).run()
    #expect(result.finalResult == .failure(.timeout))
    #expect(await fake.callCount() == 2)
}

@Test(arguments: [
    AppleScriptExecution.success(.list([.string("not-found")])),
    focus(ITermSessionReference(windowID: 99, tabIndex: 1, sessionGUID: "other", tty: "/dev/ttys009"))
])
func createdTargetDisappearanceOrMismatchIsStale(reply: AppleScriptExecution) async {
    let fake = FakeAppleScriptRunner([enumeration([]), .success(descriptor(createdRef)), reply])
    let result = await ITermAutomationSmoke(runner: fake).run()
    #expect(result.finalResult == .failure(.staleTarget))
}

@Test("focus distinguishes an unknown missing target from a stale created target")
func unknownTargetIsNotFound() async {
    let fake = FakeAppleScriptRunner([.success(.list([.string("not-found")]))])
    let result = await ITermAutomationSmoke(runner: fake).focus(reference: createdRef, provenance: .external)
    #expect(result == .failure(.notFound))
}

@Test("focus reports multiple exact matches")
func ambiguousTarget() async {
    let fake = FakeAppleScriptRunner([.success(.list([.string("ambiguous")]))])
    let result = await ITermAutomationSmoke(runner: fake).focus(reference: createdRef, provenance: .external)
    #expect(result == .failure(.ambiguous))
}

@Test("invalid descriptors and general AppleScript failures are typed")
func invalidRepliesAndFailures() async {
    let invalid = FakeAppleScriptRunner([.success(.integer(4))])
    let invalidReport = await ITermAutomationSmoke(runner: invalid).run()
    #expect(invalidReport.finalResult == .failure(.invalidReply))
    #expect(invalidReport.steps.first?.outcome == .failure(.invalidReply))
    let failed = FakeAppleScriptRunner([.failure(number: -10000, message: "event failed")])
    #expect((await ITermAutomationSmoke(runner: failed).run()).finalResult == .failure(.scriptFailure(number: -10000)))
}

@Test("scripts use the fixed iTerm application id and contain no command surface")
func scriptSafetyContract() throws {
    let scripts = [ITermSmokeScripts.enumerate, ITermSmokeScripts.create, try ITermSmokeScripts.focus(createdRef)]
    for script in scripts {
        #expect(script.contains("tell application id \"com.googlecode.iterm2\""))
        #expect(script.contains("with timeout of 5 seconds"))
        #expect(!script.contains("do shell script"))
        #expect(!script.contains("write "))
        #expect(!script.contains("close "))
    }
    #expect(ITermSmokeScripts.create.contains("create window with default profile"))
    #expect(scripts.allSatisfy { $0.contains("unique ID") })
}

@Test("dynamic AppleScript literals escape quotes and backslashes")
func literalEscaping() throws {
    let escaped = try AppleScriptLiteral.string("a\\b\"c")
    #expect(escaped == "\"a\\\\b\\\"c\"")
}

@Test(arguments: ["line\nbreak", "line\rbreak", "nul\0byte", String(repeating: "x", count: 4097)])
func unsafeLiteralsAreRejected(value: String) {
    #expect(throws: SmokeAutomationError.invalidReply) { try AppleScriptLiteral.string(value) }
}

@Test("launch contract accepts only exact installed Release invocation")
func launchContract() throws {
    let id = UUID()
    let decision = try SmokeLaunchContract.resolve(
        arguments: ["--iterm-automation-smoke", "--smoke-run-id", id.uuidString],
        environment: [:], bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"),
        bundleIdentifier: "com.tellang.tmuxrooms", releaseEnabled: true
    )
    #expect(decision == .smoke(id))
}

@Test(arguments: [
    ["--iterm-automation-smoke"],
    ["--iterm-automation-smoke", "--smoke-run-id", "bad"],
    ["--iterm-automation-smoke", "--smoke-run-id", UUID().uuidString, "--output", "/tmp/a"]
])
func invalidSmokeArgumentsAreRejected(arguments: [String]) {
    #expect(throws: SmokeLaunchError.self) {
        try SmokeLaunchContract.resolve(arguments: arguments, environment: [:], bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), bundleIdentifier: "com.tellang.tmuxrooms", releaseEnabled: true)
    }
}

@Test("noninstalled, wrong bundle id, fixture, XCTest, and non-Release contexts are rejected")
func unsafeLaunchContextsAreRejected() {
    let arguments = ["--iterm-automation-smoke", "--smoke-run-id", UUID().uuidString]
    let cases: [(URL, String?, [String: String], Bool)] = [
        (URL(fileURLWithPath: "/tmp/Tmux Rooms.app"), "com.tellang.tmuxrooms", [:], true),
        (URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), "wrong", [:], true),
        (URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), "com.tellang.tmuxrooms", ["TMUX_ROOMS_UI_FIXTURE": "1"], true),
        (URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), "com.tellang.tmuxrooms", ["XCTestConfigurationFilePath": "/tmp/test"], true),
        (URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), "com.tellang.tmuxrooms", [:], false)
    ]
    for item in cases {
        #expect(throws: SmokeLaunchError.self) {
            try SmokeLaunchContract.resolve(arguments: arguments, environment: item.2, bundleURL: item.0, bundleIdentifier: item.1, releaseEnabled: item.3)
        }
    }
}

@Test("evidence schema round trips and atomic writer leaves no temporary file")
func evidenceRoundTripAndAtomicWrite() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let evidence = SmokeEvidence.sample(runID: id, result: .success)
    let data = try JSONEncoder.smoke.encode(evidence)
    #expect(try JSONDecoder.smoke.decode(SmokeEvidence.self, from: data) == evidence)
    let url = try SmokeEvidenceWriter(rootDirectory: root).write(evidence)
    #expect(url.lastPathComponent == "\(id.uuidString).json")
    #expect(try Data(contentsOf: url) == data)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tmp") })
    let json = String(decoding: data, as: UTF8.self)
    for forbidden in ["terminalTitle", "terminalContent", "commandPayload"] { #expect(!json.contains(forbidden)) }
}

@Test("coordinator writes success and failure evidence and always terminates")
func coordinatorWritesEvidenceAndTerminates() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for replies in [
        [enumeration([]), .success(descriptor(createdRef)), focus(createdRef)],
        [.failure(number: -1743, message: "denied")]
    ] {
        let terminated = TerminationRecorder()
        let id = UUID()
        let coordinator = SmokeCoordinator(runner: FakeAppleScriptRunner(replies), writer: SmokeEvidenceWriter(rootDirectory: root), bundle: .test, terminate: { await terminated.record() })
        await coordinator.run(runID: id)
        #expect(await terminated.wasCalled)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(id.uuidString).json").path))
    }
}

private actor TerminationRecorder {
    private(set) var wasCalled = false
    func record() { wasCalled = true }
}

private extension SmokeEvidence {
    static func sample(runID: UUID, result: SmokeFinalResult) -> SmokeEvidence {
        SmokeEvidence(schemaVersion: 1, runID: runID, startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2), durationMilliseconds: 1000, bundle: .test, iTermVersion: "3.5.14", before: [beforeRef], created: createdRef, actual: createdRef, steps: [], finalResult: result)
    }
}

private extension SmokeBundleEvidence {
    static let test = SmokeBundleEvidence(path: "/Applications/Tmux Rooms.app", bundleIdentifier: "com.tellang.tmuxrooms", version: "1.0", build: "1", signingIdentifier: "com.tellang.tmuxrooms", teamIdentifier: nil, cdHash: nil)
}
