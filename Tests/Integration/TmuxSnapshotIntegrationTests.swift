import Foundation
import Testing
@testable import TmuxRoomsCore

@Suite("isolated real tmux snapshots")
struct TmuxSnapshotIntegrationTests {
    @Test("-N no-server snapshot does not create an endpoint")
    func noServer() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let snapshot=try await TmuxSnapshotLoader(executableURL:h.tmux).load(socketURL:h.socket)
            #expect(snapshot == .noServer);#expect(!FileManager.default.fileExists(atPath:h.socket.path))
        }
    }
    @Test("live server with exit-empty off has identity and zero rooms")
    func zeroSessions() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let started=try await h.command(["start-server",";","set-option","-g","exit-empty","off"]);#expect(started.exitCode == 0)
            let snapshot=try await TmuxSnapshotLoader(executableURL:h.tmux).load(socketURL:h.socket)
            #expect(snapshot.server != nil);#expect(snapshot.rooms.isEmpty)
        }
    }
    @Test("one and two detached sessions inventory panes and unicode names")
    func populated() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let first=try await h.command(["new-session","-d","-s","한글-room","-c","/tmp","/bin/sleep","60"]);#expect(first.exitCode == 0)
            var snapshot=try await TmuxSnapshotLoader(executableURL:h.tmux).load(socketURL:h.socket)
            #expect(snapshot.rooms.count==1);#expect(snapshot.rooms[0].name.precomposedStringWithCanonicalMapping=="한글-room");#expect(snapshot.rooms[0].panes.count==1)
            let second=try await h.command(["new-session","-d","-s","second"]);#expect(second.exitCode==0)
            snapshot=try await TmuxSnapshotLoader(executableURL:h.tmux).load(socketURL:h.socket)
            #expect(snapshot.rooms.map{$0.name.precomposedStringWithCanonicalMapping}.sorted()==["second","한글-room"])
        }
    }
    @Test("normal, real read-only PTY, and control clients classify together")
    func realClientClasses() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let started=try await h.command(["new-session","-d","-s","clients","/bin/sleep","60"]);#expect(started.exitCode==0)
            try h.startAttachedClients(session:"clients")
            let room=try await h.waitForClients(3).rooms[0]
            #expect(room.interactiveClients.count==1);#expect(room.readOnlyClients.count==1)
            #expect(room.readOnlyClients[0].flags.contains("read-only"));#expect(room.readOnlyClients[0].tty != nil)
            let control=room.clients.first{$0.isControlMode};#expect(control?.tty==nil);#expect(control?.flags.contains("control-mode")==true)
        }
    }
    @Test("socket identity change during the single snapshot call fails closed")
    func identityChange() async throws {
        try await IsolatedTmuxHarness.withHarness { h in
            let started=try await h.command(["start-server",";","set-option","-g","exit-empty","off"]);#expect(started.exitCode==0)
            await #expect(throws:TmuxFailure.endpointChanged){try await TmuxSnapshotLoader(runner:EndpointChangingRunner(h),executableURL:h.tmux).load(socketURL:h.socket)}
        }
    }
}
