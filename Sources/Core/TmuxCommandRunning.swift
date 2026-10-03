import Darwin
import Foundation

public struct TmuxCommandInvocation: Sendable, Hashable {
    public let executableURL: URL; public let arguments: [String]; public let deadline: Duration
    public let stdoutLimit: Int; public let stderrLimit: Int
    public init(executableURL: URL, arguments: [String], deadline: Duration = .seconds(5), stdoutLimit: Int = 16_777_216, stderrLimit: Int = 1_048_576) {
        self.executableURL = executableURL; self.arguments = arguments; self.deadline = deadline; self.stdoutLimit = stdoutLimit; self.stderrLimit = stderrLimit
    }
}
public enum TmuxCommandTermination: Sendable, Hashable { case exit, signal(Int32) }
public struct TmuxCommandOutput: Sendable, Hashable {
    public let exitCode: Int32; public let termination: TmuxCommandTermination; public let stdout: Data; public let stderr: Data
    public init(exitCode: Int32, termination: TmuxCommandTermination, stdout: Data, stderr: Data) { self.exitCode=exitCode; self.termination=termination; self.stdout=stdout; self.stderr=stderr }
}
public protocol TmuxCommandRunning: Sendable { func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput }

public struct ProcessTmuxCommandRunner: TmuxCommandRunning, Sendable {
    public init() {}
    public func run(_ invocation: TmuxCommandInvocation) async throws -> TmuxCommandOutput {
        try Task.checkCancellation()
        let state = ProcessInvocationState(invocation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in state.start(continuation) }
        } onCancel: { state.stop(.cancelled) }
    }
}

private final class ProcessInvocationState: @unchecked Sendable {
    private let invocation: TmuxCommandInvocation
    private let lock=NSLock()
    private var continuation: CheckedContinuation<TmuxCommandOutput, Error>?
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdout=Data(), stderr=Data()
    private var timer: DispatchSourceTimer?
    private var terminalError: TmuxFailure?
    private var finished=false
    private var ownsProcessGroup=false

    init(_ invocation:TmuxCommandInvocation){self.invocation=invocation}

    func start(_ continuation:CheckedContinuation<TmuxCommandOutput,Error>){
        lock.withLock { self.continuation=continuation }
        if lock.withLock({ terminalError != nil }) { finish(nil); return }
        let p=Process(), out=Pipe(), err=Pipe()
        p.executableURL=invocation.executableURL; p.arguments=invocation.arguments
        p.standardInput=FileHandle.nullDevice; p.standardOutput=out; p.standardError=err
        let stdoutHandle=out.fileHandleForReading,stderrHandle=err.fileHandleForReading
        makeNonblocking(stdoutHandle); makeNonblocking(stderrHandle)
        stdoutHandle.readabilityHandler={ [weak self] _ in self?.drain(stdout:true) }
        stderrHandle.readabilityHandler={ [weak self] _ in self?.drain(stdout:false) }
        p.terminationHandler={ [weak self] process in self?.terminated(process) }
        lock.lock()
        guard terminalError == nil else { lock.unlock();try? stdoutHandle.close();try? stderrHandle.close();finish(nil);return }
        self.process=p;self.stdoutHandle=stdoutHandle;self.stderrHandle=stderrHandle
        do { try p.run() } catch { lock.unlock();finish(.failure(TmuxFailure.launchFailed(String(describing:error))));return }
        lock.unlock()
        let group=setpgid(p.processIdentifier,p.processIdentifier) == 0
        lock.withLock { ownsProcessGroup=group }
        if lock.withLock({ terminalError != nil }) { terminate(p) }
        let timer=DispatchSource.makeTimerSource(queue:.global(qos:.userInitiated))
        timer.schedule(deadline:.now()+invocation.deadline.timeInterval)
        timer.setEventHandler{ [weak self] in self?.stop(.timedOut) }
        timer.resume();let keep=lock.withLock { if finished{return false};self.timer=timer;return true };if !keep{timer.cancel()}
    }

    func stop(_ error:TmuxFailure){
        let p:Process? = lock.withLock {
            guard !finished else{return nil}
            if terminalError == nil { terminalError=error }
            return process
        }
        closeReadEnds()
        guard let p, p.isRunning else { finish(nil); return }
        terminate(p)
        let pid=p.processIdentifier, group=lock.withLock{ownsProcessGroup}
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.2){
            if group { Darwin.kill(-pid,SIGKILL) }
            Darwin.kill(pid,SIGKILL)
        }
    }

    private func terminate(_ p:Process){
        let pid=p.processIdentifier
        if lock.withLock({ownsProcessGroup}) { Darwin.kill(-pid,SIGTERM) }
        Darwin.kill(pid,SIGTERM)
    }

    private func drain(stdout isStdout:Bool){
        var buffer=[UInt8](repeating:0,count:64*1024)
        while true {
            let result:(Int,Bool)=lock.withLock {
                guard !finished,let handle=(isStdout ? stdoutHandle:stderrHandle) else{return(0,false)}
                let count=Darwin.read(handle.fileDescriptor,&buffer,buffer.count)
                guard count>0 else{return(count,false)}
                let chunk=Data(buffer[0..<count])
                if isStdout{stdout.append(chunk);return(count,stdout.count>invocation.stdoutLimit)}
                stderr.append(chunk);return(count,stderr.count>invocation.stderrLimit)
            }
            guard result.0>0 else{return}
            if result.1{stop(.outputLimitExceeded);return}
            if result.0<buffer.count{return}
        }
    }

    private func terminated(_ p:Process){
        drain(stdout:true); drain(stdout:false)
        let termination:TmuxCommandTermination = p.terminationReason == .exit ? .exit : .signal(p.terminationStatus)
        let output=lock.withLock { TmuxCommandOutput(exitCode:p.terminationStatus,termination:termination,stdout:stdout,stderr:stderr) }
        finish(.success(output))
    }

    private func finish(_ result:Result<TmuxCommandOutput,Error>?){
        let payload:(CheckedContinuation<TmuxCommandOutput,Error>,Result<TmuxCommandOutput,Error>)?=lock.withLock {
            guard !finished, let continuation else{return nil}
            finished=true; self.continuation=nil; timer?.cancel(); timer=nil
            let resolved = terminalError.map { Result<TmuxCommandOutput,Error>.failure($0) } ?? result ?? .failure(TmuxFailure.launchFailed("process ended without result"))
            return (continuation,resolved)
        }
        closeReadEnds()
        guard let payload else{return}; payload.0.resume(with:payload.1)
    }

    private func closeReadEnds(){
        let handles:(FileHandle?,FileHandle?)=lock.withLock { let pair=(stdoutHandle,stderrHandle); stdoutHandle=nil;stderrHandle=nil;return pair }
        handles.0?.readabilityHandler=nil; handles.1?.readabilityHandler=nil
        try? handles.0?.close(); try? handles.1?.close()
    }
}
private func makeNonblocking(_ handle:FileHandle){ let fd=handle.fileDescriptor; _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) }
private extension Duration { var timeInterval:TimeInterval { let c=components; return Double(c.seconds)+Double(c.attoseconds)/1e18 } }

public enum TmuxSnapshotCommand {
    private static func f(_ name:String)->String { "#{n:\(name)}:#{\(name)}" }
    public static let boundaryFormat = "B" + ["tmux_rooms_schema", "socket_path", "pid", "start_time", "version"].map(f).joined()
        .replacingOccurrences(of:"#{n:tmux_rooms_schema}:#{tmux_rooms_schema}",with:"1:1")
    public static let endFormat = "E" + String(boundaryFormat.dropFirst())
    public static let sessionFormat = "S" + ["session_id","session_created","session_name","session_activity","session_attached"].map(f).joined()
    public static let clientFormat = "C" + ["client_name","client_tty","client_pid","client_created","session_id","client_activity","client_flags","client_readonly","client_termname","client_control_mode"].map(f).joined()
    public static let paneFormat = "P" + ["session_id","window_id","pane_id","pane_pid","pane_current_path","pane_title","pane_current_command","pane_active","pane_dead","window_index","pane_index"].map(f).joined()
    private static let emptyBranch = "display-message -p '\(endFormat)'"
    private static let populatedBranch = "list-sessions -F '\(sessionFormat)' ; list-clients -F '\(clientFormat)' ; list-panes -a -F '\(paneFormat)' ; display-message -p '\(endFormat)'"
    public static func arguments(socketPath:String)->[String] {
        ["-S",socketPath,"-N","-u","display-message","-p",boundaryFormat,";","if-shell","-F","#{==:#{server_sessions},0}",emptyBranch,populatedBranch]
    }
}
