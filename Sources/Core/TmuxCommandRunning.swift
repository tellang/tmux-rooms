import Darwin
import Foundation

public struct TmuxCommandInvocation: Sendable, Hashable {
    public let executableURL: URL; public let arguments: [String]; public let deadline: Duration
    public let stdoutLimit: Int; public let stderrLimit: Int
    public init(executableURL: URL, arguments: [String], deadline: Duration = .seconds(5), stdoutLimit: Int = TmuxParser.stdoutLimit, stderrLimit: Int = 1_048_576) {
        self.executableURL = executableURL; self.arguments = arguments; self.deadline = deadline; self.stdoutLimit = stdoutLimit; self.stderrLimit = stderrLimit
    }
}
public enum TmuxCommandTermination: Sendable, Hashable { case exit, signal(Int32) }
public struct TmuxCommandOutput: Sendable, Hashable {
    public let exitCode: Int32; public let termination: TmuxCommandTermination; public let stdout: Data; public let stderr: Data
    public init(exitCode: Int32, termination: TmuxCommandTermination, stdout: Data, stderr: Data) { self.exitCode=exitCode; self.termination=termination; self.stdout=stdout; self.stderr=stderr }
}
public protocol TmuxCommandRunning: Sendable { func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput }

private actor ProcessInvocationQueue {
    static let shared = ProcessInvocationQueue()
    func execute(_ invocation: TmuxCommandInvocation, cancellation: CancellationBox) throws -> TmuxCommandOutput { try ProcessTmuxCommandRunner.execute(invocation, cancellation: cancellation) }
}

public struct ProcessTmuxCommandRunner: TmuxCommandRunning, Sendable {
    public init() {}
    public func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput {
        try Task.checkCancellation()
        let cancellation=CancellationBox()
        return try await withTaskCancellationHandler {
            try await ProcessInvocationQueue.shared.execute(invocation, cancellation:cancellation)
        } onCancel: { cancellation.cancel() }
    }

    fileprivate static func execute(_ invocation: TmuxCommandInvocation, cancellation:CancellationBox) throws -> TmuxCommandOutput {
        let process=Process(), out=Pipe(), err=Pipe()
        process.executableURL=invocation.executableURL; process.arguments=invocation.arguments
        process.standardInput=FileHandle.nullDevice; process.standardOutput=out; process.standardError=err
        do { try process.run() } catch { throw TmuxFailure.launchFailed(String(describing:error)) }
        cancellation.setPID(process.processIdentifier)
        let capture=Capture(), group=DispatchGroup()
        group.enter(); DispatchQueue.global().async { capture.setOut(readBounded(out.fileHandleForReading, invocation.stdoutLimit)); group.leave() }
        group.enter(); DispatchQueue.global().async { capture.setErr(readBounded(err.fileHandleForReading, invocation.stderrLimit)); group.leave() }
        let deadline=ContinuousClock.now.advanced(by: invocation.deadline)
        while process.isRunning && ContinuousClock.now < deadline && !cancellation.isCancelled { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            let grace=ContinuousClock.now.advanced(by:.milliseconds(200))
            while process.isRunning && ContinuousClock.now < grace { usleep(10_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); group.wait(); throw cancellation.isCancelled ? TmuxFailure.cancelled : TmuxFailure.timedOut
        }
        process.waitUntilExit(); group.wait()
        if cancellation.isCancelled { throw TmuxFailure.cancelled }
        let stdout=capture.out, stderr=capture.err
        guard stdout.count <= invocation.stdoutLimit, stderr.count <= invocation.stderrLimit else { throw TmuxFailure.outputLimitExceeded }
        let termination: TmuxCommandTermination = process.terminationReason == .exit ? .exit : .signal(process.terminationStatus)
        return .init(exitCode:process.terminationStatus, termination:termination, stdout:stdout, stderr:stderr)
    }
}
private func readBounded(_ handle:FileHandle,_ limit:Int)->Data { var result=Data(); while let chunk=try? handle.read(upToCount:64*1024), !chunk.isEmpty { if result.count <= limit { result.append(chunk.prefix(max(0,limit+1-result.count))) } }; return result }
private final class Capture: @unchecked Sendable {
    private let lock=NSLock(); private var _out=Data(), _err=Data()
    func setOut(_ d:Data){ lock.withLock{_out=d} }; func setErr(_ d:Data){lock.withLock{_err=d}}
    var out:Data{lock.withLock{_out}}; var err:Data{lock.withLock{_err}}
}
private final class CancellationBox: @unchecked Sendable {
    private let lock=NSLock(); private var cancelled=false; private var pid:Int32?
    func setPID(_ value:Int32){lock.withLock{pid=value;if cancelled{Darwin.kill(value,SIGTERM)}}}
    func cancel(){lock.withLock{cancelled=true;if let pid{Darwin.kill(pid,SIGTERM)}}}
    var isCancelled:Bool{lock.withLock{cancelled}}
}

public enum TmuxSnapshotCommand {
    private static func f(_ name:String)->String { "#{n:\(name)}:#{\(name)}" }
    public static let boundaryFormat = "B" + ["tmux_rooms_schema", "socket_path", "pid", "start_time", "version"].map(f).joined()
        .replacingOccurrences(of:"#{n:tmux_rooms_schema}:#{tmux_rooms_schema}",with:"1:1")
    public static let endFormat = "E" + String(boundaryFormat.dropFirst())
    public static let sessionFormat = "S" + ["session_id","session_created","session_name","session_activity","session_attached"].map(f).joined()
    public static let clientFormat = "C" + ["client_name","client_tty","client_pid","client_created","session_id","client_activity","client_flags","client_readonly","client_termname","client_control_mode"].map(f).joined()
    public static let paneFormat = "P" + ["session_id","window_id","pane_id","pane_pid","pane_current_path","pane_title","pane_current_command","pane_active","pane_dead"].map(f).joined()
    private static let emptyBranch = "display-message -p '\(endFormat)'"
    private static let populatedBranch = "list-sessions -F '\(sessionFormat)' ; list-clients -F '\(clientFormat)' ; list-panes -a -F '\(paneFormat)' ; display-message -p '\(endFormat)'"
    public static func arguments(socketPath:String)->[String] {
        ["-S",socketPath,"-N","-u","display-message","-p",boundaryFormat,";","if-shell","-F","#{==:#{server_sessions},0}",emptyBranch,populatedBranch]
    }
}
