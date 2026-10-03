import Foundation
import Testing
@testable import TmuxRoomsCore

private actor AgentFixtureRunner: TmuxCommandRunning {
    var invocations: [TmuxCommandInvocation] = []
    var capturesInFlight = 0
    var mostCapturesInFlight = 0
    let ps: String
    let lsof: String
    let screen: String
    let failCapture: Bool
    let lsofExit: Int32
    let captureExit: Int32
    let captureDelay: Duration?
    init(ps: String, lsof: String = "", screen: String = "Ready", failCapture: Bool = false, lsofExit: Int32 = 0, captureExit: Int32 = 0, captureDelay: Duration? = nil) {
        self.ps = ps; self.lsof = lsof; self.screen = screen; self.failCapture = failCapture
        self.lsofExit = lsofExit; self.captureExit = captureExit; self.captureDelay = captureDelay
    }
    func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput {
        invocations.append(invocation)
        let executable = invocation.executableURL.lastPathComponent
        if executable == "tmux" {
            if failCapture { throw TmuxFailure.timedOut }
            capturesInFlight += 1
            mostCapturesInFlight = max(mostCapturesInFlight, capturesInFlight)
            if let captureDelay { try await Task.sleep(for: captureDelay) }
            capturesInFlight -= 1
        }
        let text = executable == "ps" ? ps : executable == "lsof" ? lsof : screen
        let exitCode = executable == "lsof" ? lsofExit : executable == "tmux" ? captureExit : 0
        return TmuxCommandOutput(exitCode: exitCode, termination: .exit, stdout: Data(text.utf8), stderr: Data())
    }
}

private struct AgentFixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tmr-agent-\(UUID().uuidString)")
    var codexHome: URL { root.appending(path: ".codex") }
    var registry: URL { root.appending(path: "registry") }
    var checkout: URL { root.appending(path: "repo/sub") }
    init() throws { try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true) }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func probe(_ runner: AgentFixtureRunner, lsof: Bool = false) -> AgentPresenceProbe {
        AgentPresenceProbe(runner: runner, registryDirectory: root.appending(path: "claude"), projectsDirectory: nil, codexRegistryDirectory: registry, codexHome: codexHome, homeDirectory: root, socketPath: "/fixture/tmux.sock", allowLsofFallback: lsof)
    }
    var room: SessionRoom { room(panes: [(paneID: "%228", panePID: 100)]) }
    func room(panes: [(paneID: String, panePID: Int32)]) -> SessionRoom {
        let server = ServerIdentity(canonicalSocketPath: "/fixture/tmux.sock", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4)
        let panes = panes.enumerated().map { index, pane in
            SessionRoom.Pane(windowID: "@0", paneID: pane.paneID, panePID: pane.panePID, currentPath: checkout.path, title: "", currentCommand: "node", isActive: index == 0, isDead: false, windowIndex: 0, paneIndex: index)
        }
        return SessionRoom(token: SessionToken(server: server, sessionID: "$0", createdAtUnixSeconds: 5), name: "room", lastActivityAtUnixSeconds: 6, panes: panes, clients: [])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test("registry outranks OMX and refresh never invokes lsof or capture")
func probeRegistryPriorityAndRefreshBoundary() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    try fixture.write("{\"id\":\"registry\",\"thread_name\":\"Registry\"}\n{\"id\":\"omx\",\"thread_name\":\"OMX\"}", to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"version":1,"writer":"triflux","pid":102,"sessionId":"registry","tmuxPane":"%228"}"#, to: fixture.registry.appending(path: "102.json"))
    try fixture.write(#"{"native_session_id":"omx","pid":100,"tmux_pane_id":"%228","tmux_session_name":"room"}"#, to: fixture.root.appending(path: "repo/.omx/state/session.json"))
    let runner = AgentFixtureRunner(ps: "100 1 node\n101 100 node\n102 101 codex")
    let result = await fixture.probe(runner).inspect(for: [fixture.room])
    #expect(result.presence["$0"] == .named(.codex, "Registry"))
    #expect(result.panes["%228"]?.pid == 102 && result.panes["%228"]?.sessionID == "registry")
    #expect(result.panes["%228"]?.state == .unknown)
    #expect(await runner.invocations.map { $0.executableURL.lastPathComponent } == ["ps"])
}

@Test("stale registry allows ancestor OMX fallback and JSON screen capture is bounded")
func probeOMXFallbackAndCapture() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    try fixture.write(#"{"id":"omx","thread_name":"OMX"}"#, to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"version":1,"writer":"triflux","pid":999,"sessionId":"omx","tmuxPane":"%228"}"#, to: fixture.registry.appending(path: "999.json"))
    try fixture.write(#"{"native_session_id":"omx","pid":100,"tmux_pane_id":"%228","tmux_session_name":"room"}"#, to: fixture.root.appending(path: "repo/.omx/state/session.json"))
    let runner = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", screen: "Working: esc to interrupt")
    let result = await fixture.probe(runner, lsof: true).inspect(for: [fixture.room], capturePaneState: true)
    #expect(result.presence["$0"] == .named(.codex, "OMX"))
    #expect(result.panes["%228"]?.state == .busy)
    let invocations = await runner.invocations
    #expect(invocations.map { $0.executableURL.lastPathComponent } == ["ps", "lsof", "tmux"])
    #expect(invocations.last?.arguments == ["-S", "/fixture/tmux.sock", "-N", "capture-pane", "-p", "-t", "%228"])
    #expect(invocations.last?.deadline == .seconds(1))
}

@Test("CLI lsof chooses the newest user rollout and excludes subagents and external files")
func probeLsofSelection() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    let sessions = fixture.codexHome.appending(path: "sessions/2026/10/02")
    let older = sessions.appending(path: "rollout-old.jsonl")
    let newer = sessions.appending(path: "rollout-new.jsonl")
    let child = sessions.appending(path: "rollout-child.jsonl")
    let external = fixture.root.appending(path: "rollout-external.jsonl")
    try fixture.write("{\"id\":\"old\",\"thread_name\":\"Old\"}\n{\"id\":\"new\",\"thread_name\":\"New\"}", to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"type":"session_meta","payload":{"id":"old","thread_source":"user"}}"#, to: older)
    try fixture.write("{\"type\":\"session_meta\",\"payload\":{\"id\":\"new\",\"thread_source\":\"user\"}}\nnot JSON conversation body", to: newer)
    try fixture.write(#"{"type":"session_meta","payload":{"id":"child","thread_source":"user","parent_thread_id":"new"}}"#, to: child)
    try fixture.write(#"{"type":"session_meta","payload":{"id":"external","thread_source":"user"}}"#, to: external)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: newer.path)
    let output = [older, newer, child, external].map { "n" + $0.path }.joined(separator: "\n")
    let runner = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: output)
    let result = await fixture.probe(runner, lsof: true).inspect(for: [fixture.room])
    #expect(result.presence["$0"] == .named(.codex, "New"))
    #expect(result.panes["%228"]?.pid == 102 && result.panes["%228"]?.sessionID == "new")
    let invocations = await runner.invocations
    #expect(invocations.last?.executableURL.path == "/usr/sbin/lsof")
    #expect(invocations.last?.arguments == ["-p", "102", "-Fn"])
    #expect(invocations.last?.deadline == .seconds(1))
}

@Test("unnamed Codex remains detected and failed captures stay unknown")
func probeUnknownNameAndCaptureFailure() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    try fixture.write(#"{"id":"stale","thread_name":"Old thread"}"#, to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"native_session_id":"stale","pid":999,"tmux_pane_id":"%228"}"#, to: fixture.root.appending(path: "repo/.omx/state/session.json"))
    let runner = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", failCapture: true)
    let result = await fixture.probe(runner).inspect(for: [fixture.room], capturePaneState: true)
    #expect(result.presence["$0"] == .detected(.codex))
    #expect(result.panes["%228"]?.name == nil && result.panes["%228"]?.sessionID == nil)
    #expect(result.panes["%228"]?.state == .unknown)
}

@Test("Codex home and registry location respect environment overrides")
func codexEnvironmentLocations() {
    let home = URL(fileURLWithPath: "/fixture/home")
    #expect(CodexSessionIndex.defaultHome(environment: [:], homeDirectory: home).path == "/fixture/home/.codex")
    #expect(CodexSessionIndex.defaultHome(environment: ["CODEX_HOME":"/fixture/custom"], homeDirectory: home).path == "/fixture/custom")
    #expect(CodexSessionRegistry.defaultDirectory(environment: [:], homeDirectory: home).path == "/fixture/home/.local/state/triflux/codex-sessions")
    #expect(CodexSessionRegistry.defaultDirectory(environment: ["XDG_STATE_HOME":"/fixture/state"], homeDirectory: home).path == "/fixture/state/triflux/codex-sessions")
}

@Test("a symlinked Codex home still matches the resolved paths lsof reports")
func probeLsofResolvesSymlinkedCodexHome() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    let real = fixture.root.appending(path: "real-codex")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.codexHome, withDestinationURL: real)
    let rollout = real.appending(path: "sessions/2026/10/02/rollout-a.jsonl")
    try fixture.write(#"{"id":"a","thread_name":"Linked"}"#, to: real.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"type":"session_meta","payload":{"id":"a","thread_source":"user"}}"#, to: rollout)
    let resolved = try #require(realpath(rollout.path, nil))
    defer { free(resolved) }
    let runner = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + String(cString: resolved))
    let result = await fixture.probe(runner, lsof: true).inspect(for: [fixture.room])
    #expect(result.presence["$0"] == .named(.codex, "Linked"))
}

@Test("with lsof the open rollout outranks an OMX file left by /new or /resume")
func probeRolloutOutranksOMX() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    let rollout = fixture.codexHome.appending(path: "sessions/2026/10/03/rollout-current.jsonl")
    try fixture.write("{\"id\":\"old\",\"thread_name\":\"Old\"}\n{\"id\":\"current\",\"thread_name\":\"Current\"}", to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"native_session_id":"old","pid":100,"tmux_pane_id":"%228"}"#, to: fixture.root.appending(path: "repo/.omx/state/session.json"))
    try fixture.write(#"{"type":"session_meta","payload":{"id":"current","thread_source":"user"}}"#, to: rollout)
    let runner = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + rollout.path)
    #expect(await fixture.probe(runner, lsof: true).inspect(for: [fixture.room]).presence["$0"] == .named(.codex, "Current"))
    let app = AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + rollout.path)
    #expect(await fixture.probe(app).inspect(for: [fixture.room]).presence["$0"] == .named(.codex, "Old"))
    #expect(await app.invocations.map { $0.executableURL.lastPathComponent } == ["ps"])
}

@Test("lsof exiting 1, an unnamed rollout, and capture exiting 1 leave Codex detected and unknown")
func probeCommandFailuresStayUnknown() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    let rollout = fixture.codexHome.appending(path: "sessions/2026/10/03/rollout-unnamed.jsonl")
    try fixture.write(#"{"id":"other","thread_name":"Other"}"#, to: fixture.codexHome.appending(path: "session_index.jsonl"))
    try fixture.write(#"{"type":"session_meta","payload":{"id":"unnamed","thread_source":"user"}}"#, to: rollout)
    let runners = [
        AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + rollout.path, screen: "» Ask Codex to do anything", lsofExit: 1, captureExit: 1),
        AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + rollout.path, screen: "Ready"),
        AgentFixtureRunner(ps: "100 1 node\n102 100 codex", lsof: "n" + rollout.path, screen: "» Ask Codex to do anything", captureExit: 1),
    ]
    for runner in runners {
        let result = await fixture.probe(runner, lsof: true).inspect(for: [fixture.room], capturePaneState: true)
        #expect(result.presence["$0"] == .detected(.codex))
        #expect(result.panes["%228"]?.state == .unknown && result.panes["%228"]?.name == nil)
    }
}

@Test("a Claude pane keeps its registry state and is never captured")
func probeClaudeStateSkipsCapture() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    try fixture.write(#"{"pid":102,"name":"Claude work","tmux":"room:@0.%228","status":"busy"}"#, to: fixture.root.appending(path: "claude/102.json"))
    let runner = AgentFixtureRunner(ps: "100 1 zsh\n102 100 claude", screen: "» idle-looking prompt")
    let result = await fixture.probe(runner, lsof: true).inspect(for: [fixture.room], capturePaneState: true)
    #expect(result.presence["$0"] == .named(.claude, "Claude work"))
    #expect(result.panes["%228"]?.state == .busy && result.panes["%228"]?.pid == 102)
    #expect(await runner.invocations.map { $0.executableURL.lastPathComponent } == ["ps"])
}

@Test("pane captures run at most four at a time and every pane is answered")
func probeBoundsPaneConcurrency() async throws {
    let fixture = try AgentFixture(); defer { fixture.remove() }
    let panes = (0..<7).map { (paneID: "%\(300 + $0)", panePID: Int32(300 + $0 * 10)) }
    let ps = panes.map { "\($0.panePID) 1 zsh\n\($0.panePID + 1) \($0.panePID) codex" }.joined(separator: "\n")
    let runner = AgentFixtureRunner(ps: ps, screen: "Working (esc to interrupt)", captureDelay: .milliseconds(50))
    let result = await fixture.probe(runner).inspect(for: [fixture.room(panes: panes)], capturePaneState: true)
    #expect(result.panes.count == panes.count)
    #expect(panes.allSatisfy { result.panes[$0.paneID]?.state == .busy && result.panes[$0.paneID]?.pid == $0.panePID + 1 })
    let most = await runner.mostCapturesInFlight
    #expect(most > 1 && most <= AgentPresenceProbe.paneConcurrency)
}
