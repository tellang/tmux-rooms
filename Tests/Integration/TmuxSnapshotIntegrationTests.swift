import Darwin
import Foundation
import Testing
@testable import TmuxRoomsCore

private actor EndpointChangingRunner: TmuxCommandRunning {
    let socket:URL,tmux:URL
    init(socket:URL,tmux:URL){self.socket=socket;self.tmux=tmux}
    func run(_ invocation:TmuxCommandInvocation) async throws->TmuxCommandOutput {
        let output=try await ProcessTmuxCommandRunner().run(invocation)
        func invoke(_ args:[String]) { let p=Process();p.executableURL=tmux;p.arguments=["-S",socket.path,"-f","/dev/null"]+args;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try? p.run();p.waitUntilExit() }
        invoke(["kill-server"]); try? await Task.sleep(for:.milliseconds(30)); invoke(["start-server",";","set-option","-g","exit-empty","off"])
        return output
    }
}

@Suite("isolated real tmux snapshots", .serialized)
struct TmuxSnapshotIntegrationTests {
    private let tmux=URL(fileURLWithPath:"/opt/homebrew/bin/tmux")
    private func socket(_ label:String)->URL { URL(fileURLWithPath:"/tmp/tr-\(label)-\(UUID().uuidString.prefix(6))") }
    @discardableResult private func command(_ socket:URL,_ args:[String])->(Int32,Data,Data) {
        let p=Process(),o=Pipe(),e=Pipe(); p.executableURL=tmux; p.arguments=["-S",socket.path,"-f","/dev/null"]+args; p.standardOutput=o;p.standardError=e
        try! p.run(); p.waitUntilExit(); return (p.terminationStatus,o.fileHandleForReading.readDataToEndOfFile(),e.fileHandleForReading.readDataToEndOfFile())
    }
    private func teardown(_ socket:URL,pid:Int32?) {
        _=command(socket,["kill-server"])
        for _ in 0..<100 { if pid == nil || kill(pid!,0) != 0 { break }; usleep(10_000) }
        if pid == nil || kill(pid!,0) != 0 { try? FileManager.default.removeItem(at:socket) }
        #expect(!FileManager.default.fileExists(atPath:socket.path)); if let pid { #expect(kill(pid,0) != 0) }
    }

    @Test("-N no-server snapshot does not create an endpoint")
    func noServer() async throws {
        let s=socket("none"); let snapshot=try await TmuxSnapshotLoader(executableURL:tmux).load(socketURL:s)
        #expect(snapshot == .noServer); #expect(!FileManager.default.fileExists(atPath:s.path))
    }

    @Test("live server with exit-empty off has identity and zero rooms")
    func zeroSessions() async throws {
        let s=socket("zero"); #expect(command(s,["start-server",";","set-option","-g","exit-empty","off"]).0 == 0)
        var pid:Int32?; defer { teardown(s,pid:pid) }
        let snapshot=try await TmuxSnapshotLoader(executableURL:tmux).load(socketURL:s); pid=snapshot.server?.serverPID
        #expect(snapshot.server != nil); #expect(snapshot.rooms.isEmpty)
    }

    @Test("one and two detached sessions inventory panes and unicode names")
    func populated() async throws {
        let s=socket("rooms")
        #expect(command(s,["new-session","-d","-s","한글-room","-c","/tmp","/bin/sleep","60"]).0 == 0)
        var pid:Int32?; defer { teardown(s,pid:pid) }
        var snapshot=try await TmuxSnapshotLoader(executableURL:tmux).load(socketURL:s); pid=snapshot.server?.serverPID
        #expect(snapshot.rooms.count == 1); #expect(snapshot.rooms[0].name.precomposedStringWithCanonicalMapping == "한글-room"); #expect(snapshot.rooms[0].panes.count == 1)
        #expect(command(s,["new-session","-d","-s","second"]).0 == 0)
        snapshot=try await TmuxSnapshotLoader(executableURL:tmux).load(socketURL:s)
        #expect(snapshot.rooms.map { $0.name.precomposedStringWithCanonicalMapping }.sorted() == ["second","한글-room"])
        #expect(snapshot.rooms.allSatisfy { $0.panes.count == 1 && $0.clients.isEmpty })
    }

    @Test("socket identity change during the single snapshot call fails closed")
    func identityChange() async throws {
        let s=socket("change"); #expect(command(s,["start-server",";","set-option","-g","exit-empty","off"]).0 == 0)
        defer { teardown(s,pid:nil) }
        await #expect(throws: TmuxFailure.endpointChanged) { try await TmuxSnapshotLoader(runner:EndpointChangingRunner(socket:s,tmux:tmux),executableURL:tmux).load(socketURL:s) }
    }
}
