import Foundation
import Testing
@testable import TmuxRoomsCore

private let titleReference = ManagedTerminalReference(
    windowID: 41,
    tabIndex: 2,
    sessionGUID: "GUID-TITLE-1",
    tty: "/dev/ttys077"
)

@Test("iTerm title helper uses the supported Python profile and tab APIs")
func pythonTitleHelperContract() {
    let source = ITermPythonTitleScript.source
    #expect(source.contains("LocalWriteOnlyProfile"))
    #expect(source.contains("set_allow_title_setting(False)"))
    #expect(source.contains("set_name(label)"))
    #expect(source.contains("async_set_profile_properties"))
    #expect(source.contains("async_get_variable(\"user.tmuxRoomsNonce\")"))
    #expect(source.contains("async_set_variable(\"user.tmuxRoomsTitle\", label)"))
    #expect(source.contains("async_set_title(r\"\\(user.tmuxRoomsTitle)\")"))
    #expect(source.contains("async_set_variable(\"user.tmuxRoomsTitleApplied\", request_id)"))
    #expect(!source.contains("osascript"))
}

@Test("title helper installs atomically at the fixed iTerm Scripts path")
func pythonTitleHelperInstall() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let installed = try ITermPythonTitleScript.install(homeDirectory: root)
    #expect(installed == root.appending(path: "Library/Application Support/iTerm2/Scripts/com.tellang.tmuxrooms-title.py"))
    #expect(try String(contentsOf: installed, encoding: .utf8) == ITermPythonTitleScript.source)
    let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    let firstModification = try #require(attributes[.modificationDate] as? Date)
    let second = try ITermPythonTitleScript.install(homeDirectory: root)
    #expect(second == installed)
    #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate] as? Date == firstModification)
}

@Test("title launch and status AppleScripts compile and preserve exact ownership fields")
@MainActor
func pythonTitleAppleScriptsCompile() throws {
    let nonce = ManagedNonce.generate()
    let requestID = ManagedNonce.generate()
    let title = "READ ONLY · room \\\"quoted\\\""
    let scripts = [
        try ITermPythonTitleScripts.launch(
            titleReference,
            nonce: nonce,
            title: title,
            requestID: requestID,
            scriptName: ITermPythonTitleScript.name
        ),
        try ITermPythonTitleScripts.status(
            titleReference,
            nonce: nonce,
            title: title,
            requestID: requestID
        )
    ]

    for source in scripts {
        var error: NSDictionary?
        let script = try #require(NSAppleScript(source: source))
        let compiled = script.compileAndReturnError(&error)
        let diagnostic = error.map(String.init(describing:)) ?? "compile failed"
        #expect(compiled, Comment(rawValue: diagnostic))
        #expect(error == nil)
        #expect(source.contains(titleReference.sessionGUID))
        #expect(source.contains(titleReference.tty))
        #expect(source.contains(nonce))
    }
    #expect(scripts[0].contains("launch API script named"))
    #expect(scripts[0].contains(requestID))
    #expect(scripts[1].contains("user.tmuxRoomsTitleApplied"))
}

@Test("Python title transport waits for exact applied evidence")
@MainActor
func pythonTitleTransportSuccess() async throws {
    let nonce = ManagedNonce.generate()
    let runner = CapturingTitleRunner([
        .success(.list([.string("launched")])),
        .success(.list([.string("pending")])),
        .success(.list([.integer(41), .integer(2), .string("GUID-TITLE-1"), .string("/dev/ttys077"), .string(nonce)]))
    ])
    let home = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-success-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let transport = ITermPythonTitleTransport(runner: runner, homeDirectory: home, pollInterval: .zero, maxPollAttempts: 3)

    #expect(await transport.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .success(titleReference))
    #expect(runner.sources.count == 3)
    #expect(runner.sources[0].contains("launch API script named"))
    #expect(runner.sources[1].contains("user.tmuxRoomsTitleApplied"))
}

@Test("Python title transport retries bounded iTerm script discovery")
@MainActor
func pythonTitleTransportRetriesScriptDiscovery() async {
    let nonce = ManagedNonce.generate()
    let runner = CapturingTitleRunner([
        .failure(number: 2, message: "Script not found"),
        .failure(number: 2, message: "Script not found"),
        .success(.list([.string("launched")])),
        .success(.list([.integer(41), .integer(2), .string("GUID-TITLE-1"), .string("/dev/ttys077"), .string(nonce)]))
    ])
    let home = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-discovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let transport = ITermPythonTitleTransport(
        runner: runner,
        homeDirectory: home,
        pollInterval: .zero,
        maxPollAttempts: 1,
        maxLaunchAttempts: 3
    )

    #expect(await transport.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .success(titleReference))
    #expect(runner.sources.count == 4)
    #expect(runner.sources.prefix(3).allSatisfy { $0.contains("launch API script named") })
}

@Test("Python title transport preserves install failures")
@MainActor
func pythonTitleTransportInstallFailure() async throws {
    let nonce = ManagedNonce.generate()
    let home = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-install-failure-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: home)
    defer { try? FileManager.default.removeItem(at: home) }
    let runner = CapturingTitleRunner([])
    let transport = ITermPythonTitleTransport(runner: runner, homeDirectory: home)

    #expect(await transport.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .failure(.scriptInstallFailed))
    #expect(runner.sources.isEmpty)
}

@Test("Python title transport honors absolute deadline and cancellation")
@MainActor
func pythonTitleTransportDeadlineAndCancellation() async {
    let nonce = ManagedNonce.generate()
    let root = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let expiredRunner = CapturingTitleRunner([])
    let expired = ITermPythonTitleTransport(
        runner: expiredRunner,
        homeDirectory: root.appending(path: "expired"),
        overallTimeout: .zero
    )
    #expect(await expired.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .failure(.timeout))
    #expect(expiredRunner.sources.isEmpty)

    let cancelledRunner = CapturingTitleRunner([
        .failure(number: 2, message: "Script not found"),
        .failure(number: 2, message: "must not run")
    ])
    let cancelled = ITermPythonTitleTransport(
        runner: cancelledRunner,
        homeDirectory: root.appending(path: "cancelled"),
        pollInterval: .seconds(10),
        maxLaunchAttempts: 2,
        overallTimeout: .seconds(20)
    )
    let task = Task { @MainActor in
        await cancelled.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room")
    }
    while cancelledRunner.sources.isEmpty { await Task.yield() }
    task.cancel()
    #expect(await task.value == .failure(.timeout))
    #expect(cancelledRunner.sources.count == 1)
}

@Test("Python title transport fails closed on stale targets and bounded pending status")
@MainActor
func pythonTitleTransportFailureModes() async {
    let nonce = ManagedNonce.generate()
    let home = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    let missing = CapturingTitleRunner([.success(.list([.string("not-found")]))])
    let missingTransport = ITermPythonTitleTransport(runner: missing, homeDirectory: home, pollInterval: .zero, maxPollAttempts: 1)
    #expect(await missingTransport.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .failure(.notFound))

    let pending = CapturingTitleRunner([
        .success(.list([.string("launched")])),
        .success(.list([.string("pending")]))
    ])
    let pendingTransport = ITermPythonTitleTransport(runner: pending, homeDirectory: home, pollInterval: .zero, maxPollAttempts: 1)
    #expect(await pendingTransport.setTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .failure(.timeout))
}

@Test("managed iTerm automation routes titles through the Python transport")
@MainActor
func managedAutomationUsesPythonTitleTransport() async throws {
    let nonce = ManagedNonce.generate()
    let runner = CapturingTitleRunner([
        .success(.list([.string("launched")])),
        .success(.list([.integer(41), .integer(2), .string("GUID-TITLE-1"), .string("/dev/ttys077"), .string(nonce)]))
    ])
    let home = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-title-automation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let helper = try ITermBundledHelperPath.resolve(bundleURL: URL(fileURLWithPath: "/Applications/Tmux Rooms.app"), homeDirectory: home)
    let automation = ITermManagedAutomation(
        runner: runner,
        helperPath: helper,
        titleHomeDirectory: home,
        titlePollInterval: .zero,
        titleMaxPollAttempts: 1,
        titleMaxLaunchAttempts: 1
    )

    #expect(await automation.setManagedSessionTitle(titleReference, nonce: nonce, title: "READ ONLY · room") == .success(titleReference))
    #expect(runner.sources.count == 2)
    #expect(runner.sources.allSatisfy { !$0.contains("set title of matchedTab") })
}

@MainActor
private final class CapturingTitleRunner: AppleScriptRunning {
    var replies: [AppleScriptExecution]
    private(set) var sources: [String] = []

    init(_ replies: [AppleScriptExecution]) { self.replies = replies }

    func execute(source: String) async -> AppleScriptExecution {
        sources.append(source)
        return replies.removeFirst()
    }
}
