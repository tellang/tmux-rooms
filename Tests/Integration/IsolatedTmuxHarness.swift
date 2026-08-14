import Darwin
import Foundation
import Testing
@testable import TmuxRoomsCore

final class IsolatedTmuxHarness: @unchecked Sendable {
    final class PTYClient: @unchecked Sendable {
        fileprivate let process: Process
        fileprivate init(process: Process) { self.process = process }
    }

    let tmux=URL(fileURLWithPath:"/opt/homebrew/bin/tmux")
    let root:URL
    let socket:URL
    private var children:[Process]=[]
    private var retainedPipes:[Pipe]=[]
    private let lock=NSLock()

    init() throws {
        root=URL(fileURLWithPath:"/tmp/tr-\(UUID().uuidString.prefix(8))",isDirectory:true)
        socket=root.appending(path:"s")
        #expect(socket.path.utf8.count < 100)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let defaultPath=try DefaultTmuxEndpointResolver.resolve().path
        #expect(socket.path != defaultPath)
    }

    static func withHarness(_ body:(IsolatedTmuxHarness) async throws -> Void) async throws {
        let harness=try IsolatedTmuxHarness()
        do { try await body(harness); try harness.cleanup() }
        catch { try? harness.cleanup(); throw error }
    }

    func command(_ args:[String],deadline:Duration = .seconds(2)) async throws -> TmuxCommandOutput {
        let argv=["-S",socket.path,"-f","/dev/null"]+args
        #expect(argv.prefix(4) == ["-S",socket.path,"-f","/dev/null"])
        return try await ProcessTmuxCommandRunner().run(.init(executableURL:tmux,arguments:argv,deadline:deadline))
    }

    func localCommand(_ args:[String], deadline:Duration = .seconds(2)) async throws -> TmuxCommandOutput {
        try await ProcessTmuxCommandRunner().run(.init(executableURL:tmux, arguments:args, deadline:deadline))
    }

    func startAttachedClients(session:String) throws {
        _ = try startScriptClient(session:session,readOnly:false)
        _ = try startScriptClient(session:session,readOnly:true)
        let p=Process(), input=Pipe(), output=Pipe(), error=Pipe()
        p.executableURL=tmux;p.arguments=["-S",socket.path,"-f","/dev/null","-C","attach-session","-t",session]
        p.standardInput=input;p.standardOutput=output;p.standardError=error
        try p.run(); lock.withLock{children.append(p);retainedPipes += [input,output,error]}
        drain(output.fileHandleForReading);drain(error.fileHandleForReading)
    }


    func startPTYClient(arguments:[String]) throws -> PTYClient {
        try startScriptClient(arguments:arguments)
    }

    func stopClient(_ client:PTYClient) {
        let process=client.process
        if process.isRunning { process.terminate() }
        wait(process,limit:.seconds(1))
        if process.isRunning { Darwin.kill(process.processIdentifier,SIGKILL);wait(process,limit:.seconds(1)) }
    }

    func waitForExit(_ client:PTYClient) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while client.process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
        guard !client.process.isRunning else { throw TmuxFailure.timedOut }
    }

    func socketIdentity() throws -> (device:UInt64,inode:UInt64) {
        var info=stat()
        guard lstat(socket.path,&info)==0 else { throw POSIXError(.ENOENT) }
        return (UInt64(info.st_dev),UInt64(info.st_ino))
    }

    func waitUntilNextUnixSecond(after value:Int64) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while Int64(Date().timeIntervalSince1970) <= value && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
        guard Int64(Date().timeIntervalSince1970) > value else { throw TmuxFailure.timedOut }
    }

    func waitForClients(_ count:Int) async throws -> RoomSnapshot {
        let deadline=ContinuousClock.now.advanced(by:.seconds(3))
        while ContinuousClock.now < deadline {
            let snapshot=try await TmuxSnapshotLoader(executableURL:tmux).load(socketURL:socket)
            if snapshot.rooms.reduce(0,{ $0 + $1.clients.count }) == count{return snapshot}
            try await Task.sleep(for:.milliseconds(30))
        }
        throw TmuxFailure.timedOut
    }

    func replaceServer() async {
        _=try? await command(["kill-server"])
        try? await Task.sleep(for:.milliseconds(30))
        _=try? await command(["start-server",";","set-option","-g","exit-empty","off"])
    }

    private func startScriptClient(session:String,readOnly:Bool)throws -> PTYClient {
        var arguments=["attach-session"]
        if readOnly { arguments.append("-r") }
        arguments += ["-t",session]
        return try startScriptClient(arguments:arguments)
    }

    private func startScriptClient(arguments:[String])throws -> PTYClient {
        let p=Process(),output=Pipe(),error=Pipe()
        p.executableURL=URL(fileURLWithPath:"/usr/bin/script")
        p.environment=ProcessInfo.processInfo.environment.merging(["TERM":"xterm-256color"]){_,new in new}
        let input=Pipe();p.arguments=["-q","/dev/null",tmux.path,"-S",socket.path,"-f","/dev/null"]+arguments;p.standardInput=input;p.standardOutput=output;p.standardError=error
        try p.run();lock.withLock{children.append(p);retainedPipes += [input,output,error]}
        drain(output.fileHandleForReading);drain(error.fileHandleForReading)
        return PTYClient(process:p)
    }
    private func drain(_ handle:FileHandle){handle.readabilityHandler={ h in _=try? h.read(upToCount:64*1024)}}

    private func cleanup()throws{
        let killer=Process();killer.executableURL=tmux;killer.arguments=["-S",socket.path,"-f","/dev/null","kill-server"]
        killer.standardOutput=FileHandle.nullDevice;killer.standardError=FileHandle.nullDevice;try? killer.run()
        wait(killer,limit:.seconds(1))
        for child in lock.withLock({children}) { if child.isRunning{child.terminate()};wait(child,limit:.seconds(1));if child.isRunning{Darwin.kill(child.processIdentifier,SIGKILL);wait(child,limit:.seconds(1))} }
        for _ in 0..<100 { if !FileManager.default.fileExists(atPath:socket.path){break};usleep(10_000) }
        if FileManager.default.fileExists(atPath:socket.path){try FileManager.default.removeItem(at:socket)}
        try FileManager.default.removeItem(at:root)
        #expect(!FileManager.default.fileExists(atPath:socket.path))
        for child in lock.withLock({children}){#expect(!child.isRunning)}
    }
    private func wait(_ process:Process,limit:Duration){let end=ContinuousClock.now.advanced(by:limit);while process.isRunning&&ContinuousClock.now<end{usleep(10_000)}}
}

actor EndpointChangingRunner:TmuxCommandRunning{
    let harness:IsolatedTmuxHarness
    init(_ harness:IsolatedTmuxHarness){self.harness=harness}
    func run(_ invocation:TmuxCommandInvocation)async throws->TmuxCommandOutput{let output=try await ProcessTmuxCommandRunner().run(invocation);await harness.replaceServer();return output}
}
