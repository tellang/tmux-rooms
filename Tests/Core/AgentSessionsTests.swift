import Foundation
import Testing
@testable import TmuxRoomsCore

private let server = ServerIdentity(canonicalSocketPath: "/tmp/t.sock", socketDevice: 1, socketInode: 2, serverPID: 10, startedAtUnixSeconds: 1_700_000_000)

private func pane(_ paneID: String, pid: Int32, active: Bool = true, dead: Bool = false, command: String = "2.1.247") -> SessionRoom.Pane {
    SessionRoom.Pane(
        windowID: "@1",
        paneID: paneID,
        panePID: pid,
        currentPath: "/Users/fixture/Projects",
        title: "pane",
        currentCommand: command,
        isActive: active,
        isDead: dead,
        windowIndex: 0,
        paneIndex: 0
    )
}

private func room(_ sessionID: String = "$0", name: String = "agent-20260901023710", panes: [SessionRoom.Pane]) -> SessionRoom {
    SessionRoom(
        token: SessionToken(server: server, sessionID: sessionID, createdAtUnixSeconds: 1_700_000_001),
        name: name,
        lastActivityAtUnixSeconds: 1_700_000_002,
        panes: panes,
        clients: []
    )
}

private func registryJSON(
    pid: Int32 = 86980,
    name: String? = "9.1 배포 경계",
    nameSource: String? = nil,
    tmux: String? = "agent-20260901023710:@98.%184"
) -> Data {
    var payload: [String: Any] = ["pid": pid, "cwd": "/Users/fixture/Projects"]
    if let name { payload["name"] = name }
    if let nameSource { payload["nameSource"] = nameSource }
    if let tmux { payload["tmux"] = tmux }
    return try! JSONSerialization.data(withJSONObject: payload)
}

// MARK: - Coordinate parsing

@Test("a pane coordinate splits from the right so session names may hold : and .")
func coordinateSplitsFromTheRight() throws {
    let plain = try #require(TmuxPaneCoordinate("agent-20260901023710:@98.%184"))
    #expect(plain.sessionName == "agent-20260901023710")
    #expect(plain.windowID == "@98")
    #expect(plain.paneID == "%184")

    let awkward = try #require(TmuxPaneCoordinate("weird:@name.%thing:@7.%12"))
    #expect(awkward.sessionName == "weird:@name.%thing")
    #expect(awkward.windowID == "@7")
    #expect(awkward.paneID == "%12")
}

@Test("a coordinate without both ids is rejected")
func coordinateRejectsIncomplete() {
    #expect(TmuxPaneCoordinate("") == nil)
    #expect(TmuxPaneCoordinate("session-only") == nil)
    #expect(TmuxPaneCoordinate("session:@98") == nil)
    #expect(TmuxPaneCoordinate(":@98.%184") == nil)
    #expect(TmuxPaneCoordinate("session:@.%") == nil)
}

// MARK: - Registry decoding

@Test("a registry record carries the rename value and its pane")
func registryDecodesRenamedSession() throws {
    let record = try #require(ClaudeSessionRegistry.record(fromJSON: registryJSON()))
    #expect(record.kind == .claude)
    #expect(record.pid == 86980)
    #expect(record.name == "9.1 배포 경계")
    #expect(record.nameIsDerived == false)
    #expect(record.paneID == "%184")
    #expect(record.tmuxSessionName == "agent-20260901023710")
}

@Test("a derived name is decoded but flagged")
func registryFlagsDerivedName() throws {
    let record = try #require(ClaudeSessionRegistry.record(fromJSON: registryJSON(name: "tmux-rooms-4a", nameSource: "derived")))
    #expect(record.nameIsDerived)
}

@Test("records without a usable name or pane are skipped")
func registrySkipsUnusableRecords() {
    #expect(ClaudeSessionRegistry.record(fromJSON: registryJSON(tmux: nil)) == nil)
    #expect(ClaudeSessionRegistry.record(fromJSON: registryJSON(name: nil)) == nil)
    #expect(ClaudeSessionRegistry.record(fromJSON: registryJSON(name: "   ")) == nil)
    #expect(ClaudeSessionRegistry.record(fromJSON: registryJSON(pid: 0)) == nil)
    #expect(ClaudeSessionRegistry.record(fromJSON: Data("not json".utf8)) == nil)
}

@Test("a directory scan reads json files and tolerates junk beside them")
func registryScansDirectory() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "agent-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try registryJSON().write(to: directory.appending(path: "86980.json"))
    try Data("truncated".utf8).write(to: directory.appending(path: "12345.json"))
    try Data("secret".utf8).write(to: directory.appending(path: "86980.abc.key"))

    let records = ClaudeSessionRegistry.records(in: directory, projectsDirectory: nil)
    #expect(records.count == 1)
    #expect(records.first?.name == "9.1 배포 경계")
}

@Test("a missing directory yields no records rather than failing")
func registryToleratesMissingDirectory() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "absent-\(UUID().uuidString)")
    #expect(ClaudeSessionRegistry.records(in: missing, projectsDirectory: nil).isEmpty)
}

// MARK: - Process table

@Test("the process table finds an agent below a pane's own shell")
func processTableWalksDown() {
    let table = ProcessTable(psOutput: """
      4382     1 tmux
     86980  4382 zsh
     86990 86980 claude
     91000 86990 rg
    """)
    #expect(table.agentKind(inTreeOf: 86980) == .claude)
    #expect(table.agentKind(inTreeOf: 86990) == .claude)
    #expect(table.agentKind(inTreeOf: 91000) == nil)
    #expect(table.command(of: 86990) == "claude")
    #expect(table.isRunning(86980))
    #expect(!table.isRunning(11111))
}

@Test("the process table recognises codex and full executable paths")
func processTableRecognisesCodex() {
    let table = ProcessTable(psOutput: """
     500 1 zsh
     501 500 /Users/fixture/.local/bin/codex
     600 1 ripgrep
    """)
    #expect(table.agentKind(inTreeOf: 500) == .codex)
    #expect(table.agentKind(inTreeOf: 600) == nil)
}

@Test("the process table recognises agy and does not mistake similar names for it")
func processTableRecognisesAgy() {
    let table = ProcessTable(psOutput: """
     700 1 zsh
     701 700 agy
     800 1 zsh
     801 800 /Users/fixture/.local/bin/agy
     900 1 zsh
     901 900 agy-helper
    """)
    #expect(table.agentKind(inTreeOf: 700) == .agy)
    #expect(table.agentKind(inTreeOf: 800) == .agy)
    #expect(table.agentKind(inTreeOf: 900) == nil)
}

@Test("agy is detected by process alone and labelled Antigravity")
func resolverDetectsAgy() {
    let subject = room(panes: [pane("%8", pid: 700, command: "agy")])
    let presence = AgentPresenceResolver.presence(for: subject, records: [], table: ProcessTable(psOutput: "700 4382 agy"))
    #expect(presence == .detected(.agy))
    #expect(presence.title == "Antigravity")
}

@Test("the process table stops before an agent's own deep children")
func processTableBoundsDepth() {
    var rows = ["100 1 zsh"]
    var parent = 100
    for step in 1...(ProcessTable.searchDepth + 2) {
        rows.append("\(100 + step) \(parent) shim")
        parent = 100 + step
    }
    rows.append("\(parent + 1) \(parent) claude")
    #expect(ProcessTable(psOutput: rows.joined(separator: "\n")).agentKind(inTreeOf: 100) == nil)
}

@Test("malformed ps rows are dropped without losing the rest")
func processTableSkipsMalformedRows() {
    let table = ProcessTable(psOutput: "\nbroken\n7 x claude\n8 1 claude\n   \n")
    #expect(table.agentKind(inTreeOf: 8) == .claude)
    #expect(!table.isRunning(7))
}

// MARK: - Resolution

@Test("a live pane matching a named record takes the agent's name")
func resolverNamesMatchingPane() {
    let subject = room(panes: [pane("%184", pid: 86980)])
    let table = ProcessTable(psOutput: "86980 4382 claude")
    let presence = AgentPresenceResolver.presence(for: subject, records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!], table: table)
    #expect(presence == .named(.claude, "9.1 배포 경계"))
    #expect(presence.title == "9.1 배포 경계")
}

@Test("a stale registry file left by a dead session does not name a room")
func resolverIgnoresStaleRecord() {
    // The pane is now a plain shell; the record still claims %184.
    let subject = room(panes: [pane("%184", pid: 12345, command: "zsh")])
    let presence = AgentPresenceResolver.presence(
        for: subject,
        records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!],
        table: ProcessTable(psOutput: "12345 4382 zsh")
    )
    #expect(presence == .absent)
    #expect(presence.title == nil)
}

@Test("a recycled pid whose process is not the agent is refused")
func resolverRefusesRecycledPID() {
    let subject = room(panes: [pane("%184", pid: 86980)])
    let presence = AgentPresenceResolver.presence(
        for: subject,
        records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!],
        table: ProcessTable(psOutput: "86980 4382 vim")
    )
    #expect(presence == .absent)
}

@Test("a derived name falls back to the agent label")
func resolverDemotesDerivedName() {
    let subject = room(panes: [pane("%184", pid: 86980)])
    let record = ClaudeSessionRegistry.record(fromJSON: registryJSON(name: "tmux-rooms-4a", nameSource: "derived"))!
    let presence = AgentPresenceResolver.presence(for: subject, records: [record], table: ProcessTable(psOutput: "86980 4382 claude"))
    #expect(presence == .detected(.claude))
    #expect(presence.title == "Claude")
}

@Test("an agent with no registry entry is still detected")
func resolverDetectsUnregisteredAgent() {
    let subject = room(panes: [pane("%101", pid: 25124, command: "2.1.229")])
    let presence = AgentPresenceResolver.presence(for: subject, records: [], table: ProcessTable(psOutput: "25124 4382 claude"))
    #expect(presence == .detected(.claude))
}

@Test("codex is detected by process alone since it publishes no pane")
func resolverDetectsCodex() {
    let subject = room(panes: [pane("%7", pid: 500, command: "codex")])
    let presence = AgentPresenceResolver.presence(for: subject, records: [], table: ProcessTable(psOutput: "500 4382 codex"))
    #expect(presence == .detected(.codex))
    #expect(presence.title == "Codex")
}

@Test("a room with no agent keeps its tmux name")
func resolverLeavesPlainRoomAlone() {
    let subject = room(panes: [pane("%3", pid: 700, command: "zsh")])
    #expect(AgentPresenceResolver.presence(for: subject, records: [], table: ProcessTable(psOutput: "700 4382 zsh")) == .absent)
}

@Test("a named pane wins over a detected one regardless of pane order")
func resolverPrefersNamedPane() {
    let panes = [pane("%9", pid: 700, active: true, command: "zsh"), pane("%184", pid: 86980, active: false)]
    let table = ProcessTable(psOutput: "700 4382 zsh\n86980 4382 claude")
    let presence = AgentPresenceResolver.presence(for: room(panes: panes), records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!], table: table)
    #expect(presence == .named(.claude, "9.1 배포 경계"))
}

@Test("a dead pane is never read")
func resolverSkipsDeadPanes() {
    let subject = room(panes: [pane("%184", pid: 86980, dead: true)])
    let presence = AgentPresenceResolver.presence(
        for: subject,
        records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!],
        table: ProcessTable(psOutput: "86980 4382 claude")
    )
    #expect(presence == .absent)
}

@Test("without a process table a matching record is still trusted")
func resolverWorksWithoutProcessTable() {
    let subject = room(panes: [pane("%184", pid: 86980)])
    let presence = AgentPresenceResolver.presence(for: subject, records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!], table: nil)
    #expect(presence == .named(.claude, "9.1 배포 경계"))
}

@Test("the batch resolver keys by session id and omits rooms without agents")
func resolverBatchesRooms() {
    let named = room("$0", panes: [pane("%184", pid: 86980)])
    let plain = room("$1", name: "scratch", panes: [pane("%3", pid: 700, command: "zsh")])
    let resolved = AgentPresenceResolver.presence(
        for: [named, plain],
        records: [ClaudeSessionRegistry.record(fromJSON: registryJSON())!],
        table: ProcessTable(psOutput: "86980 4382 claude\n700 4382 zsh")
    )
    #expect(resolved == ["$0": .named(.claude, "9.1 배포 경계")])
}

// MARK: - Conversation titles

private func transcript(_ records: [String]) -> Data {
    Data(records.joined(separator: "\n").utf8)
}

@Test("the last recorded title in a transcript tail wins")
func conversationTitleTakesTheLastRecord() {
    let tail = transcript([
        #"{"type":"ai-title","aiTitle":"first guess","sessionId":"s"}"#,
        #"{"type":"user","message":"noise"}"#,
        #"{"type":"ai-title","aiTitle":"Claude 세션 이름 외부 접근","sessionId":"s"}"#,
    ])
    #expect(ClaudeConversationTitles.title(inTail: tail) == "Claude 세션 이름 외부 접근")
}

@Test("a rename recorded in the transcript outranks the derived title on the same line")
func conversationTitlePrefersCustomTitle() {
    let tail = transcript([#"{"type":"custom-title","customTitle":"주간 정리","sessionId":"s"}"#])
    #expect(ClaudeConversationTitles.title(inTail: tail) == "주간 정리")
}

@Test("a tail beginning mid-line drops only the truncated record")
func conversationTitleSurvivesATruncatedFirstLine() {
    var tail = Data(#"aiTitle":"cut in half"}"#.utf8)
    tail.append(0x0a)
    tail.append(contentsOf: Data(#"{"type":"ai-title","aiTitle":"whole record","sessionId":"s"}"#.utf8))
    #expect(ClaudeConversationTitles.title(inTail: tail) == "whole record")
}

@Test("a transcript with no title record yields nothing")
func conversationTitleAbsent() {
    #expect(ClaudeConversationTitles.title(inTail: transcript([#"{"type":"user","message":"hello"}"#])) == nil)
    #expect(ClaudeConversationTitles.title(inTail: transcript([#"{"type":"ai-title","sessionId":"s"}"#])) == nil)
    #expect(ClaudeConversationTitles.title(inTail: transcript([#"{"type":"ai-title","aiTitle":"  ","sessionId":"s"}"#])) == nil)
    #expect(ClaudeConversationTitles.title(inTail: Data()) == nil)
}

@Test("a derived registry name is replaced by the session's conversation title")
func registryUpgradesDerivedNameFromTranscript() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "agent-titles-\(UUID().uuidString)")
    let sessions = root.appending(path: "sessions")
    let projects = root.appending(path: "projects").appending(path: "-Users-fixture-Projects")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var payload = try JSONSerialization.jsonObject(with: registryJSON(name: "tmux-rooms-4a", nameSource: "derived")) as! [String: Any]
    payload["sessionId"] = "ed26a5b4"
    try JSONSerialization.data(withJSONObject: payload).write(to: sessions.appending(path: "86980.json"))
    try transcript([#"{"type":"ai-title","aiTitle":"Claude 세션 이름 외부 접근","sessionId":"ed26a5b4"}"#])
        .write(to: projects.appending(path: "ed26a5b4.jsonl"))

    let record = try #require(ClaudeSessionRegistry.records(in: sessions, projectsDirectory: root.appending(path: "projects")).first)
    #expect(record.name == "Claude 세션 이름 외부 접근")
    #expect(record.nameIsDerived == false)
}

@Test("a derived name with no transcript stays derived")
func registryKeepsDerivedNameWithoutTranscript() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "agent-titles-\(UUID().uuidString)")
    let sessions = root.appending(path: "sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try registryJSON(name: "tmux-rooms-4a", nameSource: "derived").write(to: sessions.appending(path: "86980.json"))
    let record = try #require(ClaudeSessionRegistry.records(in: sessions, projectsDirectory: root.appending(path: "projects")).first)
    #expect(record.name == "tmux-rooms-4a")
    #expect(record.nameIsDerived)
}

@Test("a session id that could escape the projects directory is refused")
func conversationTitleRefusesPathTraversal() {
    #expect(ClaudeConversationTitles.title(forSessionID: "../../etc/passwd", projectsDirectory: URL(fileURLWithPath: NSTemporaryDirectory())) == nil)
    #expect(ClaudeConversationTitles.title(forSessionID: "", projectsDirectory: URL(fileURLWithPath: NSTemporaryDirectory())) == nil)
}

@Test("a Codex descendant record names its pane but a mismatched pane never does")
func resolverNamesCodexDescendant() {
    let subject = room(panes: [pane("%228", pid: 100)])
    let table = ProcessTable(psOutput: "100 1 node\n101 100 node\n102 101 codex")
    let record = AgentSessionRecord(kind: .codex, pid: 102, sessionID: "thread", name: "리메이크", nameIsDerived: false, paneID: "%228", tmuxSessionName: nil, currentPath: "")
    #expect(AgentPresenceResolver.presence(for: subject, records: [record], table: table) == .named(.codex, "리메이크"))
    let other = room(panes: [pane("%229", pid: 100)])
    #expect(AgentPresenceResolver.presence(for: other, records: [record], table: table) == .detected(.codex))
    #expect(AgentPresenceResolver.presence(for: subject, records: [record], table: nil) == .absent)
}

// MARK: - Record proof

private func claudeRecord(pid: Int32, kind: AgentKind = .claude, paneID: String = "%184", name: String = "작업") -> AgentSessionRecord {
    AgentSessionRecord(kind: kind, pid: pid, sessionID: "s\(pid)", name: name, nameIsDerived: false, paneID: paneID, tmuxSessionName: nil, currentPath: "")
}

@Test("a descendant pid now running a different program is refused")
func matchingRefusesDescendantRunningOtherProgram() {
    let table = ProcessTable(psOutput: "86980 4382 zsh\n86990 86980 zsh")
    #expect(AgentPresenceResolver.matchingRecord(for: pane("%184", pid: 86980), records: [claudeRecord(pid: 86990)], table: table) == nil)
}

@Test("a record whose pid lives outside the pane's tree is refused")
func matchingRefusesPIDOutsideTree() {
    let table = ProcessTable(psOutput: "86980 4382 zsh\n99999 1 claude")
    #expect(AgentPresenceResolver.matchingRecord(for: pane("%184", pid: 86980), records: [claudeRecord(pid: 99999)], table: table) == nil)
}

@Test("a record whose kind differs from the running program is refused")
func matchingRefusesKindMismatch() {
    let table = ProcessTable(psOutput: "86980 4382 zsh\n86990 86980 claude")
    #expect(AgentPresenceResolver.matchingRecord(for: pane("%184", pid: 86980), records: [claudeRecord(pid: 86990, kind: .codex)], table: table) == nil)
}

@Test("a record naming the pane process is refused when that process is another program")
func matchingRefusesPanePIDRunningOtherProgram() {
    let subject = pane("%184", pid: 86980)
    let table = ProcessTable(psOutput: "86980 4382 zsh\n86990 86980 claude")
    #expect(AgentPresenceResolver.matchingRecord(for: subject, records: [claudeRecord(pid: 86980)], table: table) == nil)
    let info = AgentPresenceResolver.agent(for: subject, records: [claudeRecord(pid: 86980)], table: table)
    #expect(info.kind == .claude && info.pid == 86990 && info.name == nil)
}

@Test("of several proven records the one naming the shallowest agent wins")
func matchingPrefersShallowestAgent() {
    let table = ProcessTable(psOutput: "100 1 zsh\n101 100 codex\n102 101 codex")
    let child = claudeRecord(pid: 102, kind: .codex, name: "Child")
    let parent = claudeRecord(pid: 101, kind: .codex, name: "Parent")
    #expect(AgentPresenceResolver.matchingRecord(for: pane("%184", pid: 100), records: [child, parent], table: table)?.name == "Parent")
    #expect(AgentPresenceResolver.matchingRecord(for: pane("%184", pid: 100), records: [child], table: table)?.name == "Child")
}
