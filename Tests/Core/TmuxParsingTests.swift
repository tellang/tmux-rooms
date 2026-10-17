import Foundation
import Testing
@testable import TmuxRoomsCore

private func field(_ value: String) -> Data { Data("\(value.utf8.count):".utf8) + Data(value.utf8) }
private func record(_ type: Character, _ fields: [String]) -> Data {
    var data = Data(String(type).utf8)
    fields.forEach { data += field($0) }
    data.append(0x0a)
    return data
}
private let boundary = ["1", "/tmp/t.sock", "123", "1700000000", "3.6b"]
private func parseVerified(_ data: Data) throws -> RoomSnapshot {
    let raw = try TmuxParser.parse(data)
    let identity = ServerIdentity(canonicalSocketPath: raw.boundary.socketPath, socketDevice: 1, socketInode: 2, serverPID: raw.boundary.serverPID, startedAtUnixSeconds: raw.boundary.startedAtUnixSeconds)
    return try raw.bind(server: identity)
}
private let session = ["$0", "1700000001", "room\n:🧪B0:", "1700000002", "1"]
private let client = ["client:one", "/dev/ttys001", "456", "1700000003", "$0", "1700000004", "attached,read-only,x-z", "1", "xterm-256color", "0"]
private let pane = ["$0", "@0", "%0", "789", "/tmp/a\nb", "title:E1:", "zsh", "1", "0", "12", "3", "01a147e6-7b45-76f0-9aed-71e6a3fa8be0"]
private func validData(clientFields: [String] = client, sessionFields: [String] = session, paneFields: [String] = pane) -> Data {
    record("B", boundary) + record("S", sessionFields) + record("C", clientFields) + record("P", paneFields) + record("E", boundary)
}

@Test("byte framing preserves unicode, LF, colon, and marker-looking content")
func framingRoundTrip() throws {
    let snapshot = try parseVerified(validData())
    #expect(snapshot.rooms.first?.name == "room\n:🧪B0:")
    #expect(snapshot.rooms.first?.panes.first?.title == "title:E1:")
    #expect(snapshot.rooms.first?.panes.first?.windowIndex == 12)
    #expect(snapshot.rooms.first?.panes.first?.paneIndex == 3)
    #expect(snapshot.rooms.first?.panes.first?.codexThreadID == "01a147e6-7b45-76f0-9aed-71e6a3fa8be0")
    #expect(snapshot.rooms.first?.clients.first?.flags == ["attached", "read-only", "x-z"])
}

@Test("pane indices must be nonnegative canonical integers")
func paneIndexValidation() {
    for invalid in ["", "-1", "01", "1.0", "９", String(repeating: "9", count: 100)] {
        var fields = pane; fields[9] = invalid
        #expect(throws: TmuxFailure.self) { try parseVerified(validData(paneFields: fields)) }
        fields = pane; fields[10] = invalid
        #expect(throws: TmuxFailure.self) { try parseVerified(validData(paneFields: fields)) }
    }
    #expect(throws: TmuxFailure.self) { try parseVerified(validData(paneFields: Array(pane.dropLast()))) }
}

@Test("connected empty server is a valid snapshot")
func emptyServer() throws { #expect(try parseVerified(record("B", boundary) + record("E", boundary)).rooms.isEmpty) }

@Test(arguments: [
    Data(), Data("B:bad\n".utf8), Data("B01:x\n".utf8), Data("B-1:x\n".utf8), Data("B١:x\n".utf8),
    Data("B2:x\n".utf8), Data("B1:x".utf8), record("S", session), record("B", boundary) + record("E", boundary) + Data([0]),
    record("B", boundary) + record("B", boundary) + record("E", boundary),
    record("B", boundary) + record("X", []) + record("E", boundary)
] as [Data])
func malformedFramingIsRejected(data: Data) { #expect(throws: TmuxFailure.self) { try parseVerified(data) } }

@Test("NUL and configured limits are rejected")
func limits() {
    var nul = validData(); nul.insert(0, at: 4)
    #expect(throws: TmuxFailure.self) { try parseVerified(nul) }
    #expect(throws: TmuxFailure.self) { try parseVerified(Data(repeating: 65, count: TmuxParser.stdoutLimit + 1)) }
    #expect(throws: TmuxFailure.self) { try parseVerified(record("B", [String(repeating: "x", count: TmuxParser.fieldLimit + 1), "a", "1", "1", "3.6b"])) }
}

@Test("boundary records must match and the version floor is enforced")
func boundaryValidation() {
    #expect(throws: TmuxFailure.self) { try parseVerified(record("B", boundary) + record("E", ["1", "/tmp/t.sock", "124", "1700000000", "3.6b"])) }
    #expect(throws: TmuxFailure.self) { try parseVerified(record("B", ["1", "/tmp/t.sock", "123", "1700000000", "3.5a"]) + record("E", ["1", "/tmp/t.sock", "123", "1700000000", "3.5a"])) }
}

private func versionedData(_ version: String) -> Data {
    let bounds = ["1", "/tmp/t.sock", "123", "1700000000", version]
    return record("B", bounds) + record("S", session) + record("C", client) + record("P", pane) + record("E", bounds)
}

@Test("a release at or above the verified floor parses; older or unreadable ones stay rejected", arguments: [
    ("3.6b", true), ("3.7c", true), ("3.10", true), ("4.0", true), ("next-3.8", true),
    ("3.6", false), ("3.5a", false), ("2.9", false), ("3", false), ("", false), ("3.x", false), ("3.6B", false),
])
func versionFloor(version: String, supported: Bool) {
    if supported {
        #expect(throws: Never.self) { try parseVerified(versionedData(version)) }
    } else {
        #expect(throws: TmuxFailure.self) { try parseVerified(versionedData(version)) }
    }
}

@Test(arguments: ["$00", "$-1", "0", "$", "$a"])
func invalidSessionIDs(id: String) { var s = session; s[0] = id; #expect(throws: TmuxFailure.self) { try parseVerified(validData(sessionFields: s)) } }

@Test("booleans, tty, control mode, and flags agree")
func clientValidation() {
    var c = client; c[7] = "0"; #expect(throws: TmuxFailure.self) { try parseVerified(validData(clientFields: c)) }
    c = client; c[1] = ""; #expect(throws: TmuxFailure.self) { try parseVerified(validData(clientFields: c)) }
    c = client; c[1] = "/dev/a/b"; #expect(throws: TmuxFailure.self) { try parseVerified(validData(clientFields: c)) }
    c = client; c[9] = "1"; c[1] = ""; c[6] = "control-mode,read-only"; c[7] = "1"
    let control = try? parseVerified(validData(clientFields: c)).rooms[0].clients[0]
    #expect(control?.tty == nil); #expect(control?.isControlMode == true)
    c[1] = "/dev/ttys009"
    #expect(throws: TmuxFailure.self) { try parseVerified(validData(clientFields: c)) }
}

@Test("record sections are strictly B S-star C-star P-star E")
func strictSectionOrder() {
    let valid = record("B", boundary) + record("S", session) + record("C", client) + record("P", pane) + record("E", boundary)
    #expect((try? parseVerified(valid)) != nil)
    let cBeforeS = record("B", boundary) + record("C", client) + record("S", session) + record("P", pane) + record("E", boundary)
    let sAfterP = record("B", boundary) + record("P", pane) + record("S", session) + record("C", client) + record("E", boundary)
    let freshRegression = record("B", boundary) + record("C", client) + record("P", pane) + record("S", session) + record("E", boundary)
    let cAfterP = record("B", boundary) + record("S", session) + record("P", pane) + record("C", client) + record("E", boundary)
    let interleaved = record("B", boundary) + record("S", session) + record("C", client) + record("P", pane) + record("C", client) + record("E", boundary)
    for data in [cBeforeS, sAfterP, freshRegression, cAfterP, interleaved] {
        #expect(throws: TmuxFailure.self) { try parseVerified(data) }
    }
}

@Test("RoomActionResult exposes the frozen UI-facing cases")
func actionResultCases() {
    let values: [RoomActionResult] = [
        .succeeded, .alreadyGone, .staleTarget, .cancelled,
        .tmuxFailure(.timedOut), .terminalFailure(.timeout)
    ]
    #expect(values.count == 6)
}

@Test("duplicates, orphans, missing panes, and attached mismatch are rejected")
func relationValidation() {
    let duplicate = record("B", boundary) + record("S", session) + record("S", session) + record("P", pane) + record("E", boundary)
    #expect(throws: TmuxFailure.self) { try parseVerified(duplicate) }
    #expect(throws: TmuxFailure.self) { try parseVerified(record("B", boundary) + record("C", client) + record("E", boundary)) }
    #expect(throws: TmuxFailure.self) { try parseVerified(record("B", boundary) + record("S", session) + record("C", client) + record("E", boundary)) }
    var s = session; s[4] = "0"; #expect(throws: TmuxFailure.self) { try parseVerified(validData(sessionFields: s)) }
}

@Test("same pane id may be linked into distinct sessions")
func linkedPane() throws {
    let s1 = ["$1", "1700000011", "linked", "1700000012", "0"]
    var p1 = pane; p1[0] = "$1"
    let data = record("B", boundary) + record("S", session) + record("S", s1) + record("C", client) + record("P", pane) + record("P", p1) + record("E", boundary)
    #expect(try parseVerified(data).rooms.count == 2)
}

@Test("client classifications exclude control and readonly as specified")
func clientClassifications() throws {
    var interactive = client; interactive[0] = "i"; interactive[6] = "attached"; interactive[7] = "0"
    var control = client; control[0] = "c"; control[1] = ""; control[6] = "control-mode"; control[7] = "0"; control[9] = "1"
    var s = session; s[4] = "3"
    let data = record("B", boundary) + record("S", s) + record("C", interactive) + record("C", client) + record("C", control) + record("P", pane) + record("E", boundary)
    let room = try parseVerified(data).rooms[0]
    #expect(room.interactiveClients.map(\.clientName) == ["i"])
    #expect(room.readOnlyClients.map(\.clientName) == ["client:one"])
}

@Test("10k session inventory assembles linearly within a loose bound")
func largeInventoryIsBounded() throws {
    let count = 10_001
    var data = record("B", boundary)
    for index in 0..<count { data += record("S", ["$\(index)", "1700000001", "r\(index)", "1700000002", "0"]) }
    for index in 0..<count { data += record("P", ["$\(index)", "@\(index)", "%\(index)", "789", "/tmp", "t", "zsh", "1", "0", "\(index)", "0", ""]) }
    data += record("E", boundary)
    let start = ContinuousClock.now
    let snapshot = try parseVerified(data)
    let elapsed = start.duration(to: .now)
    #expect(snapshot.rooms.count == count)
    #expect(elapsed < .seconds(3))
}
