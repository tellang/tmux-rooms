import Foundation
import Testing
@testable import TmuxRoomsCore

private actor FakeRunner: TmuxCommandRunning {
    let output: TmuxCommandOutput
    private(set) var invocations: [TmuxCommandInvocation] = []
    init(_ output: TmuxCommandOutput) { self.output = output }
    func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput { invocations.append(invocation); return output }
    func captured() -> [TmuxCommandInvocation] { invocations }
}

@Test("snapshot argv is static, explicit, noncreating, and exactly one runner call")
func goldenInvocation() async throws {
    let socket = URL(fileURLWithPath: "/tmp/does-not-exist-t3.sock")
    let fake = FakeRunner(.init(exitCode: 1, termination: .exit, stdout: Data(), stderr: Data("no server running on /tmp/does-not-exist-t3.sock\n".utf8)))
    _ = try await TmuxSnapshotLoader(runner: fake, executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")).load(socketURL: socket)
    let calls = await fake.captured()
    let canonicalSocket = "/private/tmp/does-not-exist-t3.sock"
    #expect(calls.count == 1)
    #expect(calls[0].arguments == TmuxSnapshotCommand.arguments(socketPath: canonicalSocket))
    #expect(calls[0].arguments.prefix(4) == ["-S", canonicalSocket, "-N", "-u"])
    #expect(!calls[0].arguments.contains("new-session"))
    #expect(TmuxSnapshotCommand.boundaryFormat == "B1:1#{n:socket_path}:#{socket_path}#{n:pid}:#{pid}#{n:start_time}:#{start_time}#{n:version}:#{version}")
    #expect(TmuxSnapshotCommand.sessionFormat == "S#{n:session_id}:#{session_id}#{n:session_created}:#{session_created}#{n:session_name}:#{session_name}#{n:session_activity}:#{session_activity}#{n:session_attached}:#{session_attached}")
    #expect(TmuxSnapshotCommand.clientFormat == "C#{n:client_name}:#{client_name}#{n:client_tty}:#{client_tty}#{n:client_pid}:#{client_pid}#{n:client_created}:#{client_created}#{n:session_id}:#{session_id}#{n:client_activity}:#{client_activity}#{n:client_flags}:#{client_flags}#{n:client_readonly}:#{client_readonly}#{n:client_termname}:#{client_termname}#{n:client_control_mode}:#{client_control_mode}")
    #expect(TmuxSnapshotCommand.paneFormat == "P#{n:session_id}:#{session_id}#{n:window_id}:#{window_id}#{n:pane_id}:#{pane_id}#{n:pane_pid}:#{pane_pid}#{n:pane_current_path}:#{pane_current_path}#{n:pane_title}:#{pane_title}#{n:pane_current_command}:#{pane_current_command}#{n:pane_active}:#{pane_active}#{n:pane_dead}:#{pane_dead}")
}

@Test("unknown nonzero and partial stdout are failures")
func nonzeroClassification() async {
    let socket = URL(fileURLWithPath: "/tmp/missing-t3-x.sock")
    let unknown = FakeRunner(.init(exitCode: 2, termination: .exit, stdout: Data(), stderr: Data("weird".utf8)))
    await #expect(throws: TmuxFailure.self) { try await TmuxSnapshotLoader(runner: unknown).load(socketURL: socket) }
    let partial = FakeRunner(.init(exitCode: 1, termination: .exit, stdout: Data("x".utf8), stderr: Data("no server running".utf8)))
    await #expect(throws: TmuxFailure.self) { try await TmuxSnapshotLoader(runner: partial).load(socketURL: socket) }
}

@Test("default resolver ignores inherited TMUX")
func resolverIgnoresTMUX() throws {
    let a = try DefaultTmuxEndpointResolver.resolve(environment: ["TMUX": "/evil,1,0"], userID: 501)
    let b = try DefaultTmuxEndpointResolver.resolve(environment: [:], userID: 501)
    #expect(a == b); #expect(a.path == "/private/tmp/tmux-501/default")
}

@Test("real runner enforces output limits and deadline")
func runnerLimitsAndDeadline() async {
    let runner=ProcessTmuxCommandRunner()
    await #expect(throws: TmuxFailure.self) { try await runner.run(.init(executableURL:URL(fileURLWithPath:"/usr/bin/yes"),arguments:[],deadline:.seconds(1),stdoutLimit:32)) }
    await #expect(throws: TmuxFailure.timedOut) { try await runner.run(.init(executableURL:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],deadline:.milliseconds(30))) }
}

@Test("real runner cancellation cannot become late success")
func runnerCancellation() async {
    let task=Task { try await ProcessTmuxCommandRunner().run(.init(executableURL:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],deadline:.seconds(5))) }
    try? await Task.sleep(for:.milliseconds(30)); task.cancel()
    await #expect(throws: TmuxFailure.cancelled) { try await task.value }
}
