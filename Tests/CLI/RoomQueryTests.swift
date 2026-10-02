import Foundation
import Testing
import TmuxRoomsCore

private let server = ServerIdentity(canonicalSocketPath: "/tmp/t.sock", socketDevice: 1, socketInode: 2, serverPID: 10, startedAtUnixSeconds: 1_700_000_000)
private let utc = TimeZone(identifier: "UTC")!

private func client(_ name: String, readOnly: Bool = false) -> SessionRoom.Client {
    SessionRoom.Client(
        key: ClientKey(server: server, clientName: name, tty: "/dev/ttys00\(name.count)", clientPID: 100, createdAtUnixSeconds: 1_700_000_000),
        lastActivityAtUnixSeconds: 1_700_000_000,
        flags: [],
        isReadOnly: readOnly,
        terminalName: "xterm-256color",
        isControlMode: false
    )
}

private func room(
    _ sessionID: String,
    name: String,
    activity: Int64 = 1_700_000_100,
    paths: [String] = ["/Users/fixture/Projects/app"],
    clients: [SessionRoom.Client] = []
) -> SessionRoom {
    SessionRoom(
        token: SessionToken(server: server, sessionID: sessionID, createdAtUnixSeconds: 1_700_000_001),
        name: name,
        lastActivityAtUnixSeconds: activity,
        panes: paths.enumerated().map { offset, path in
            SessionRoom.Pane(windowID: "@\(offset)", paneID: "%\(offset)", panePID: Int32(200 + offset), currentPath: path, title: "pane", currentCommand: "node", isActive: offset == 0, isDead: false, windowIndex: 2, paneIndex: offset + 3)
        },
        clients: clients
    )
}

private func rooms(
    _ list: [SessionRoom],
    presence: [String: AgentPresence] = [:],
    panes: [String: PaneAgentInfo] = [:]
) -> [CLIRoom] {
    RoomQuery.rooms(from: RoomSnapshot(server: server, rooms: list), presence: presence, panes: panes)
}

@Suite("CLI room query")
struct RoomQueryTests {
    @Test func agentLabelReplacesTmuxNameAndKeepsIt() {
        let result = rooms(
            [room("$1", name: "omx-app-1790736413784-94242v")],
            presence: ["$1": .named(.claude, "9.1 배포 경계")]
        )
        #expect(result[0].title == "9.1 배포 경계")
        #expect(result[0].tmuxName == "omx-app-1790736413784-94242v")
        #expect(result[0].agent == .claude)
        #expect(!result[0].titleIsTmuxName)
    }

    @Test func detectedAgentIsLabelledByProductAndRoomWithoutAgentKeepsName() {
        let result = rooms(
            [room("$1", name: "omx-app"), room("$2", name: "plain-shell", activity: 1_700_000_050)],
            presence: ["$1": .detected(.codex)]
        )
        #expect(result.map(\.title) == ["Codex", "plain-shell"])
        #expect(result[1].agent == nil)
        #expect(result[1].titleIsTmuxName)
    }

    @Test func mostRecentlyActiveRoomComesFirstAndTiesSortByName() {
        let result = rooms([
            room("$1", name: "b", activity: 10),
            room("$2", name: "a", activity: 10),
            room("$3", name: "c", activity: 99),
        ])
        #expect(result.map(\.tmuxName) == ["c", "a", "b"])
    }

    @Test func clientsAreCountedByKind() {
        let result = rooms([room("$1", name: "a", clients: [client("x"), client("yy"), client("zzz", readOnly: true)])])
        #expect(result[0].interactiveClients == 2)
        #expect(result[0].readOnlyClients == 1)
    }

    @Test func pathsAreDistinctInPaneOrder() {
        let result = rooms([room("$1", name: "a", paths: ["/p/one", "/p/two", "/p/one"])])
        #expect(result[0].paths == ["/p/one", "/p/two"])
    }

    @Test func hereKeepsOnlyRoomsWithAPaneInThatDirectory() {
        let all = rooms([
            room("$1", name: "in", paths: ["/p/app"]),
            room("$2", name: "out", paths: ["/p/other"]),
            room("$3", name: "split", paths: ["/p/other", "/p/app"]),
        ])
        let found = RoomQuery.filter(all, directory: "/p/app", text: nil)
        #expect(Set(found.map(\.tmuxName)) == ["in", "split"])
        #expect(RoomQuery.filter(all, directory: "/p/app/sub", text: nil).isEmpty)
    }

    @Test func textMatchesTitleNameAgentAndPathIgnoringCase() {
        let all = rooms(
            [room("$1", name: "omx-app", paths: ["/p/Billing"]), room("$2", name: "misc", paths: ["/p/x"])],
            presence: ["$1": .named(.claude, "배포 경계")]
        )
        #expect(RoomQuery.filter(all, directory: nil, text: "배포").map(\.sessionID) == ["$1"])
        #expect(RoomQuery.filter(all, directory: nil, text: "OMX").map(\.sessionID) == ["$1"])
        #expect(RoomQuery.filter(all, directory: nil, text: "claude").map(\.sessionID) == ["$1"])
        #expect(RoomQuery.filter(all, directory: nil, text: "billing").map(\.sessionID) == ["$1"])
        #expect(RoomQuery.filter(all, directory: nil, text: "nothing").isEmpty)
    }

    @Test func exactTmuxNameOrIDBeatsPartialMatches() {
        let all = rooms([room("$1", name: "cx-app"), room("$2", name: "cx-app-2")])
        #expect(RoomQuery.filter(all, directory: nil, text: "cx-app").map(\.sessionID) == ["$1"])
        #expect(RoomQuery.filter(all, directory: nil, text: "cx-app-2").map(\.sessionID) == ["$2"])
        #expect(RoomQuery.filter(all, directory: nil, text: "$2").map(\.sessionID) == ["$2"])
        #expect(Set(RoomQuery.filter(all, directory: nil, text: "cx").map(\.sessionID)) == ["$1", "$2"])
    }

    @Test func blankTextDoesNotNarrow() {
        let all = rooms([room("$1", name: "a"), room("$2", name: "b")])
        #expect(RoomQuery.filter(all, directory: nil, text: "  ").count == 2)
        #expect(RoomQuery.filter(all, directory: nil, text: nil).count == 2)
    }

    @Test func chooserAnswerMapsToAZeroBasedIndex() {
        #expect(RoomQuery.pickIndex("1", count: 3) == 0)
        #expect(RoomQuery.pickIndex(" 3 ", count: 3) == 2)
        #expect(RoomQuery.pickIndex("4", count: 3) == nil)
        #expect(RoomQuery.pickIndex("0", count: 3) == nil)
        #expect(RoomQuery.pickIndex("", count: 3) == nil)
        #expect(RoomQuery.pickIndex("x", count: 3) == nil)
        #expect(RoomQuery.pickIndex(nil, count: 3) == nil)
        #expect(RoomQuery.pickIndex("1", count: 0) == nil)
    }

    @Test func attachTargetsTheSessionIDOutsideTmux() throws {
        #expect(try AttachCommand.arguments(sessionID: "$7", readOnly: false, insideTmux: false) == ["attach-session", "-t", "$7"])
        #expect(try AttachCommand.arguments(sessionID: "$7", readOnly: true, insideTmux: false) == ["attach-session", "-r", "-t", "$7"])
    }

    @Test func attachSwitchesClientInsideTmuxAndRefusesReadOnly() throws {
        #expect(try AttachCommand.arguments(sessionID: "$7", readOnly: false, insideTmux: true) == ["switch-client", "-t", "$7"])
        #expect(throws: AttachCommand.Failure.readOnlyInsideTmux) {
            try AttachCommand.arguments(sessionID: "$7", readOnly: true, insideTmux: true)
        }
    }

    @Test func tableAlignsColumnsAcrossWideHangul() {
        let all = rooms(
            [
                room("$1", name: "omx-app-1", activity: 1_700_000_200, paths: ["/Users/fixture/Projects/app"]),
                room("$2", name: "shell", activity: 1_700_000_100, paths: ["/tmp"], clients: [client("x"), client("y", readOnly: true)]),
            ],
            presence: ["$1": .named(.claude, "배포 경계")]
        )
        let lines = RoomFormat.table(all, home: "/Users/fixture", timeZone: utc).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("TITLE"))
        // The PATH column starts at the same cell in every row.
        let starts = lines.map { line -> Int in
            let range = line.range(of: "PATH") ?? line.range(of: "~/Projects/app") ?? line.range(of: "/tmp")!
            return TextWidth.of(String(line[line.startIndex..<range.lowerBound]))
        }
        #expect(Set(starts).count == 1)
        #expect(lines[1].contains("~/Projects/app"))
        #expect(lines[1].hasSuffix("omx-app-1"))
        #expect(lines[2].contains("1 (+1 ro)"))
        #expect(lines[2].hasSuffix("-"))
    }

    @Test func wideScalarsCountTwoCellsAndTruncationRespectsIt() {
        #expect(TextWidth.of("배포") == 4)
        #expect(TextWidth.of("ab") == 2)
        #expect(TextWidth.truncate("배포 경계 검증 완료", to: 8) == "배포 경…")
        #expect(TextWidth.of(TextWidth.truncate("배포 경계 검증 완료", to: 8)) <= 8)
        #expect(TextWidth.truncate("short", to: 10) == "short")
    }

    @Test func homeIsAbbreviatedOnlyAtADirectoryBoundary() {
        #expect(RoomFormat.abbreviate("/Users/fixture", home: "/Users/fixture") == "~")
        #expect(RoomFormat.abbreviate("/Users/fixture/p", home: "/Users/fixture") == "~/p")
        #expect(RoomFormat.abbreviate("/Users/fixtures/p", home: "/Users/fixture") == "/Users/fixtures/p")
    }

    @Test func chooserLineMarksAttachedRoomsAndSkipsARepeatedName() {
        let all = rooms(
            [
                room("$1", name: "plain", clients: [client("x")]),
                room("$2", name: "omx-app", activity: 1_700_000_000),
            ],
            presence: ["$2": .detected(.codex)]
        )
        let plain = RoomFormat.chooserLine(index: 1, room: all[0], home: "/Users/fixture", timeZone: utc)
        let agent = RoomFormat.chooserLine(index: 2, room: all[1], home: "/Users/fixture", timeZone: utc)
        #expect(plain.hasSuffix("[attached]"))
        #expect(plain.components(separatedBy: "plain").count == 2)
        #expect(agent.contains("Codex") && agent.contains("omx-app"))
    }

    @Test func jsonCarriesTheRoomFields() throws {
        let all = rooms([room("$1", name: "omx-app")], presence: ["$1": .named(.codex, "작업")])
        let text = try RoomFormat.json(all)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        #expect(decoded.count == 1)
        #expect(decoded[0]["id"] as? String == "$1")
        #expect(decoded[0]["name"] as? String == "omx-app")
        #expect(decoded[0]["title"] as? String == "작업")
        #expect(decoded[0]["agent"] as? String == "codex")
        #expect(decoded[0]["paths"] as? [String] == ["/Users/fixture/Projects/app"])
    }

    @Test func jsonCarriesLivePaneTargetsAndExplicitUnknownFields() throws {
        let source = room("$1", name: "work", paths: ["/p/one", "/p/two"])
        let named = PaneAgentInfo(
            kind: .codex, pid: 73965, sessionID: "thread-1", name: "작업", state: .busy
        )
        let all = rooms([source], presence: ["$1": .named(.codex, "작업")], panes: ["%0": named])
        let text = try RoomFormat.json(all)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let paneJSON = try #require(decoded[0]["panes"] as? [[String: Any]])
        #expect(paneJSON.count == 2)
        #expect(paneJSON[0]["paneId"] as? String == "%0")
        #expect(paneJSON[0]["target"] as? String == "work:2.3")
        #expect(paneJSON[0]["active"] as? Bool == true)
        #expect(paneJSON[0]["path"] as? String == "/p/one")
        #expect(paneJSON[0]["agent"] as? String == "codex")
        #expect(paneJSON[0]["pid"] as? Int == 73965)
        #expect(paneJSON[0]["sessionId"] as? String == "thread-1")
        #expect(paneJSON[0]["name"] as? String == "작업")
        #expect(paneJSON[0]["state"] as? String == "busy")
        #expect(paneJSON[1]["target"] as? String == "work:2.4")
        #expect(paneJSON[1]["agent"] is NSNull)
        #expect(paneJSON[1]["pid"] as? Int == 201)
        #expect(paneJSON[1]["sessionId"] is NSNull)
        #expect(paneJSON[1]["name"] is NSNull)
        #expect(paneJSON[1]["state"] as? String == "unknown")
    }

    @Test func deadPanesAreNotIncludedInJSON() throws {
        let live = SessionRoom.Pane(windowID: "@1", paneID: "%1", panePID: 101, currentPath: "/live", title: "", currentCommand: "zsh", isActive: true, isDead: false)
        let dead = SessionRoom.Pane(windowID: "@1", paneID: "%2", panePID: 102, currentPath: "/dead", title: "", currentCommand: "zsh", isActive: false, isDead: true)
        let source = SessionRoom(token: SessionToken(server: server, sessionID: "$1", createdAtUnixSeconds: 1), name: "work", lastActivityAtUnixSeconds: 2, panes: [live, dead], clients: [])
        let text = try RoomFormat.json(rooms([source]))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let paneJSON = try #require(decoded[0]["panes"] as? [[String: Any]])
        #expect(paneJSON.map { $0["paneId"] as? String } == ["%1"])
    }
}
