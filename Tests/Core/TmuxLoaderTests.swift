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
    let socket = URL(fileURLWithPath: "/tmp/does-not-exist.sock")
    let fake = FakeRunner(.init(exitCode: 1, termination: .exit, stdout: Data(), stderr: Data("no server running on /private/tmp/does-not-exist.sock\n".utf8)))
    _ = try await TmuxSnapshotLoader(runner: fake, executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")).load(socketURL: socket)
    let calls = await fake.captured()
    let canonicalSocket = "/private/tmp/does-not-exist.sock"
    #expect(calls.count == 1)
    #expect(calls[0].arguments == TmuxSnapshotCommand.arguments(socketPath: canonicalSocket))
    #expect(calls[0].arguments.prefix(4) == ["-S", canonicalSocket, "-N", "-u"])
    #expect(!calls[0].arguments.contains("new-session"))
    #expect(TmuxSnapshotCommand.boundaryFormat == "B1:1#{n:socket_path}:#{socket_path}#{n:pid}:#{pid}#{n:start_time}:#{start_time}#{n:version}:#{version}")
    #expect(TmuxSnapshotCommand.sessionFormat == "S#{n:session_id}:#{session_id}#{n:session_created}:#{session_created}#{n:session_name}:#{session_name}#{n:session_activity}:#{session_activity}#{n:session_attached}:#{session_attached}")
    #expect(TmuxSnapshotCommand.clientFormat == "C#{n:client_name}:#{client_name}#{n:client_tty}:#{client_tty}#{n:client_pid}:#{client_pid}#{n:client_created}:#{client_created}#{n:session_id}:#{session_id}#{n:client_activity}:#{client_activity}#{n:client_flags}:#{client_flags}#{n:client_readonly}:#{client_readonly}#{n:client_termname}:#{client_termname}#{n:client_control_mode}:#{client_control_mode}")
    #expect(TmuxSnapshotCommand.paneFormat == "P#{n:session_id}:#{session_id}#{n:window_id}:#{window_id}#{n:pane_id}:#{pane_id}#{n:pane_pid}:#{pane_pid}#{n:pane_current_path}:#{pane_current_path}#{n:pane_title}:#{pane_title}#{n:pane_current_command}:#{pane_current_command}#{n:pane_active}:#{pane_active}#{n:pane_dead}:#{pane_dead}#{n:window_index}:#{window_index}#{n:pane_index}:#{pane_index}")
}

@Test("unknown nonzero and partial stdout are failures")
func nonzeroClassification() async {
    let socket = URL(fileURLWithPath: "/tmp/missing-x.sock")
    let unknown = FakeRunner(.init(exitCode: 2, termination: .exit, stdout: Data(), stderr: Data("weird".utf8)))
    await #expect(throws: TmuxFailure.self) { try await TmuxSnapshotLoader(runner: unknown).load(socketURL: socket) }
    let partial = FakeRunner(.init(exitCode: 1, termination: .exit, stdout: Data("x".utf8), stderr: Data("no server running".utf8)))
    await #expect(throws: TmuxFailure.self) { try await TmuxSnapshotLoader(runner: partial).load(socketURL: socket) }
}

@Test("no-server diagnostic must exactly name the canonical requested socket")
func exactNoServerDiagnostic() async {
    let socket = URL(fileURLWithPath: "/tmp/missing-exact.sock")
    let nearMisses = [
        "no server running on /private/tmp/other.sock\n",
        "prefix no server running on /private/tmp/missing-exact.sock suffix\n",
        "error connecting to /private/tmp/missing-exact.sock (Permission denied)\n"
    ]
    for message in nearMisses {
        let fake = FakeRunner(.init(exitCode: 1, termination: .exit, stdout: Data(), stderr: Data(message.utf8)))
        do { _ = try await TmuxSnapshotLoader(runner: fake).load(socketURL: socket); Issue.record("near miss mapped to noServer") }
        catch let TmuxFailure.commandFailed(code, stderr) { #expect(code == 1); #expect(stderr == message) }
        catch { Issue.record("unexpected error \(error)") }
    }
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

@Test("runner output limit wins before deadline")
func runnerOutputLimitIsImmediate() async {
    let start=ContinuousClock.now
    await #expect(throws: TmuxFailure.outputLimitExceeded) { try await ProcessTmuxCommandRunner().run(.init(executableURL:URL(fileURLWithPath:"/usr/bin/yes"),arguments:[],deadline:.seconds(5),stdoutLimit:32)) }
    #expect(start.duration(to:.now) < .seconds(1))
}

@Test("parallel cancellation is not queued behind an inherited-pipe timeout")
func parallelRunsDoNotQueue() async {
    let runner=ProcessTmuxCommandRunner()
    let holder=Task { try await runner.run(.init(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","sleep 5 & exit 0"],deadline:.milliseconds(50))) }
    let cancelled=Task { try await runner.run(.init(executableURL:URL(fileURLWithPath:"/bin/sleep"),arguments:["5"],deadline:.seconds(5))) }
    try? await Task.sleep(for:.milliseconds(20)); let start=ContinuousClock.now; cancelled.cancel()
    await #expect(throws: TmuxFailure.cancelled) { try await cancelled.value }
    #expect(start.duration(to:.now) < .seconds(1))
    _ = try? await holder.value
}

@Test("inherited-pipe child cannot hold runner completion open")
func inheritedPipeChildIsBounded() async throws {
    let start=ContinuousClock.now
    _ = try await ProcessTmuxCommandRunner().run(.init(executableURL:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","sleep 5 & exit 0"],deadline:.milliseconds(50)))
    #expect(start.duration(to:.now) < .seconds(1))
}
