import Foundation
import Testing
@testable import TmuxRoomsCore

private let trackerServer = ServerIdentity(canonicalSocketPath: "/tmp/t.sock", socketDevice: 1, socketInode: 2, serverPID: 10, startedAtUnixSeconds: 1_700_000_000)

private func trackerRoom(_ sessionID: String = "$0", panePID: Int32 = 86980, paneID: String = "%184") -> SessionRoom {
    SessionRoom(
        token: SessionToken(server: trackerServer, sessionID: sessionID, createdAtUnixSeconds: 1_700_000_001),
        name: "agent-room",
        lastActivityAtUnixSeconds: 1_700_000_002,
        panes: [SessionRoom.Pane(
            windowID: "@1",
            paneID: paneID,
            panePID: panePID,
            currentPath: "/Users/fixture",
            title: "pane",
            currentCommand: "2.1.247",
            isActive: true,
            isDead: false,
            windowIndex: 0,
            paneIndex: 0
        )],
        clients: []
    )
}

private final class CountingProbe: AgentPresenceProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _answer: [String: AgentPresence]

    var calls: Int { lock.withLock { _calls } }

    init(answer: [String: AgentPresence] = ["$0": .named(.claude, "9.1 배포 경계")]) {
        _answer = answer
    }

    func setAnswer(_ answer: [String: AgentPresence]) { lock.withLock { _answer = answer } }

    func presence(for rooms: [SessionRoom]) async -> [String: AgentPresence] {
        lock.withLock {
            _calls += 1
            return _answer
        }
    }
}

@MainActor
@Test("the first refresh probes and publishes what it found")
func trackerProbesOnFirstRefresh() async {
    let probe = CountingProbe()
    let tracker = AgentPresenceTracker(probe: probe)

    #expect(await tracker.refresh(rooms: [trackerRoom()]))
    #expect(probe.calls == 1)
    #expect(tracker.presence(for: trackerRoom()) == .named(.claude, "9.1 배포 경계"))
}

@MainActor
@Test("unchanged panes are not re-probed on every refresh")
func trackerThrottlesUnchangedPanes() async {
    let probe = CountingProbe()
    let tracker = AgentPresenceTracker(probe: probe)
    let rooms = [trackerRoom()]

    await tracker.refresh(rooms: rooms)
    for _ in 1..<AgentPresenceTracker.refreshesBetweenProbes {
        #expect(await tracker.refresh(rooms: rooms) == false)
    }
    #expect(probe.calls == 1)

    #expect(await tracker.refresh(rooms: rooms))
    #expect(probe.calls == 2)
}

@MainActor
@Test("a pane handed to a different process is re-probed at once")
func trackerProbesWhenPanesChange() async {
    let probe = CountingProbe()
    let tracker = AgentPresenceTracker(probe: probe)

    await tracker.refresh(rooms: [trackerRoom()])
    #expect(await tracker.refresh(rooms: [trackerRoom(panePID: 99999)]))
    #expect(probe.calls == 2)
}

@MainActor
@Test("a new room is re-probed even when the existing panes are unchanged")
func trackerProbesWhenARoomAppears() async {
    let probe = CountingProbe()
    let tracker = AgentPresenceTracker(probe: probe)

    await tracker.refresh(rooms: [trackerRoom()])
    #expect(await tracker.refresh(rooms: [trackerRoom(), trackerRoom("$1", panePID: 5, paneID: "%5")]))
    #expect(probe.calls == 2)
}

@MainActor
@Test("an empty room list clears the labels without probing")
func trackerClearsOnEmptyRoomList() async {
    let probe = CountingProbe()
    let tracker = AgentPresenceTracker(probe: probe)

    await tracker.refresh(rooms: [trackerRoom()])
    #expect(await tracker.refresh(rooms: []) == false)
    #expect(tracker.presence.isEmpty)
    #expect(probe.calls == 1)

    // The next room list is a fresh start rather than a throttled continuation.
    #expect(await tracker.refresh(rooms: [trackerRoom()]))
    #expect(probe.calls == 2)
}

@MainActor
@Test("a room the probe says nothing about reports no agent")
func trackerReportsAbsentForUnknownRoom() async {
    let tracker = AgentPresenceTracker(probe: CountingProbe(answer: [:]))
    await tracker.refresh(rooms: [trackerRoom()])
    #expect(tracker.presence(for: trackerRoom()) == .absent)
}
