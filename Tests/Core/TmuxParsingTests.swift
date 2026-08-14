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
private let session = ["$0", "1700000001", "room\n:🧪B0:", "1700000002", "1"]
private let client = ["client:one", "/dev/ttys001", "456", "1700000003", "$0", "1700000004", "attached,readonly,x-z", "1", "xterm-256color", "0"]
private let pane = ["$0", "@0", "%0", "789", "/tmp/a\nb", "title:E1:", "zsh", "1", "0"]
private func validData(clientFields: [String] = client, sessionFields: [String] = session, paneFields: [String] = pane) -> Data {
    record("B", boundary) + record("S", sessionFields) + record("C", clientFields) + record("P", paneFields) + record("E", boundary)
}

@Test("byte framing preserves unicode, LF, colon, and marker-looking content")
func framingRoundTrip() throws {
    let snapshot = try TmuxParser.parse(validData())
    #expect(snapshot.rooms.first?.name == "room\n:🧪B0:")
    #expect(snapshot.rooms.first?.panes.first?.title == "title:E1:")
    #expect(snapshot.rooms.first?.clients.first?.flags == ["attached", "readonly", "x-z"])
}

@Test("connected empty server is a valid snapshot")
func emptyServer() throws { #expect(try TmuxParser.parse(record("B", boundary) + record("E", boundary)).rooms.isEmpty) }

@Test(arguments: [
    Data(), Data("B:bad\n".utf8), Data("B01:x\n".utf8), Data("B-1:x\n".utf8), Data("B١:x\n".utf8),
    Data("B2:x\n".utf8), Data("B1:x".utf8), record("S", session), record("B", boundary) + record("E", boundary) + Data([0]),
    record("B", boundary) + record("B", boundary) + record("E", boundary),
    record("B", boundary) + record("X", []) + record("E", boundary)
])
func malformedFramingIsRejected(data: Data) { #expect(throws: TmuxFailure.self) { try TmuxParser.parse(data) } }

@Test("NUL and configured limits are rejected")
func limits() {
    var nul = validData(); nul.insert(0, at: 4)
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(nul) }
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(Data(repeating: 65, count: TmuxParser.stdoutLimit + 1)) }
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(record("B", [String(repeating: "x", count: TmuxParser.fieldLimit + 1), "a", "1", "1", "3.6b"])) }
}

@Test("boundary records must match and version is allowlisted")
func boundaryValidation() {
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(record("B", boundary) + record("E", ["1", "/tmp/t.sock", "124", "1700000000", "3.6b"])) }
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(record("B", ["1", "/tmp/t.sock", "123", "1700000000", "3.5a"]) + record("E", ["1", "/tmp/t.sock", "123", "1700000000", "3.5a"])) }
}

@Test(arguments: ["$00", "$-1", "0", "$", "$a"])
func invalidSessionIDs(id: String) { var s = session; s[0] = id; #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(sessionFields: s)) } }

@Test("booleans, tty, control mode, and flags agree")
func clientValidation() {
    var c = client; c[7] = "0"; #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(clientFields: c)) }
    c = client; c[1] = ""; #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(clientFields: c)) }
    c = client; c[1] = "/dev/a/b"; #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(clientFields: c)) }
    c = client; c[9] = "1"; c[1] = ""; c[6] = "control-mode,readonly"; c[7] = "1"
    let control = try? TmuxParser.parse(validData(clientFields: c)).rooms[0].clients[0]
    #expect(control?.tty == nil); #expect(control?.isControlMode == true)
    c[1] = "/dev/ttys009"
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(clientFields: c)) }
}

@Test("record sections are strictly B S-star C-star P-star E")
func strictSectionOrder() {
    let valid = record("B", boundary) + record("S", session) + record("C", client) + record("P", pane) + record("E", boundary)
    #expect((try? TmuxParser.parse(valid)) != nil)
    let cBeforeS = record("B", boundary) + record("C", client) + record("S", session) + record("P", pane) + record("E", boundary)
    let sAfterP = record("B", boundary) + record("P", pane) + record("S", session) + record("C", client) + record("E", boundary)
    let freshRegression = record("B", boundary) + record("C", client) + record("P", pane) + record("S", session) + record("E", boundary)
    let cAfterP = record("B", boundary) + record("S", session) + record("P", pane) + record("C", client) + record("E", boundary)
    let interleaved = record("B", boundary) + record("S", session) + record("C", client) + record("P", pane) + record("C", client) + record("E", boundary)
    for data in [cBeforeS, sAfterP, freshRegression, cAfterP, interleaved] {
        #expect(throws: TmuxFailure.self) { try TmuxParser.parse(data) }
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
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(duplicate) }
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(record("B", boundary) + record("C", client) + record("E", boundary)) }
    #expect(throws: TmuxFailure.self) { try TmuxParser.parse(record("B", boundary) + record("S", session) + record("C", client) + record("E", boundary)) }
    var s = session; s[4] = "0"; #expect(throws: TmuxFailure.self) { try TmuxParser.parse(validData(sessionFields: s)) }
}

@Test("same pane id may be linked into distinct sessions")
func linkedPane() throws {
    let s1 = ["$1", "1700000011", "linked", "1700000012", "0"]
    var p1 = pane; p1[0] = "$1"
    let data = record("B", boundary) + record("S", session) + record("S", s1) + record("C", client) + record("P", pane) + record("P", p1) + record("E", boundary)
    #expect(try TmuxParser.parse(data).rooms.count == 2)
}

@Test("client classifications exclude control and readonly as specified")
func clientClassifications() throws {
    var interactive = client; interactive[0] = "i"; interactive[6] = "attached"; interactive[7] = "0"
    var control = client; control[0] = "c"; control[1] = ""; control[6] = "control-mode"; control[7] = "0"; control[9] = "1"
    var s = session; s[4] = "3"
    let data = record("B", boundary) + record("S", s) + record("C", interactive) + record("C", client) + record("C", control) + record("P", pane) + record("E", boundary)
    let room = try TmuxParser.parse(data).rooms[0]
    #expect(room.interactiveClients.map(\.clientName) == ["i"])
    #expect(room.readOnlyClients.map(\.clientName) == ["client:one"])
}
