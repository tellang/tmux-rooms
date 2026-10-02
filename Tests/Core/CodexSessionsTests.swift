import Foundation
import Testing
@testable import TmuxRoomsCore

@Test("session index keeps the last rename and ignores malformed lines")
func codexIndexLastWins() {
    let data = Data("""
    {"id":"t","thread_name":"old","updated_at":"later"}
    junk
    {"id":"t","thread_name":"새 이름","updated_at":"earlier"}
    {"id":"empty","thread_name":" "}
    """.utf8)
    #expect(CodexSessionIndex.names(fromJSONL: data) == ["t": "새 이름"])
}

@Test("triflux registry requires version one and a known thread name")
func codexRegistryParsing() throws {
    let json = Data(#"{"version":1,"writer":"triflux","pid":102,"sessionId":"t","cwd":"/fixture","tmux":"room:@3.%228","tmuxPane":"%999","source":"hook","updatedAt":1}"#.utf8)
    let record = try #require(CodexSessionRegistry.record(fromJSON: json, names: ["t": "제목"]))
    #expect(record.pid == 102 && record.kind == .codex && record.sessionID == "t")
    #expect(record.paneID == "%228" && record.tmuxSessionName == "room")
    #expect(record.name == "제목" && !record.nameIsDerived && record.currentPath == "/fixture")
    #expect(CodexSessionRegistry.record(fromJSON: json, names: [:]) == nil)
    #expect(CodexSessionRegistry.record(fromJSON: Data(#"{"version":2,"writer":"triflux","pid":102,"sessionId":"t","tmuxPane":"%228"}"#.utf8), names: ["t":"제목"]) == nil)
    let fallback = CodexSessionRegistry.record(fromJSON: Data(#"{"version":1,"writer":"triflux","pid":102,"sessionId":"t","tmux":null,"tmuxPane":"%228"}"#.utf8), names: ["t":"제목"])
    #expect(fallback?.paneID == "%228" && fallback?.tmuxSessionName == nil)
}

@Test("OMX only supplies a name for its exact pane and uses the native agent pid")
func codexOMXParsing() {
    let json = Data(#"{"native_session_id":"t","pid":100,"tmux_pane_id":"%228","tmux_session_name":"room"}"#.utf8)
    let table = ProcessTable(psOutput: "100 1 node\n102 100 codex")
    let record = CodexOMXSession.record(fromJSON: json, paneID: "%228", nativePID: 102, currentPath: "/fixture", names: ["t":"제목"], panePID: 100, table: table)
    #expect(record?.pid == 102 && record?.sessionID == "t" && record?.name == "제목")
    #expect(CodexOMXSession.record(fromJSON: json, paneID: "%229", nativePID: 102, currentPath: "/fixture", names: ["t":"제목"]) == nil)
    #expect(CodexOMXSession.record(fromJSON: json, paneID: "%228", nativePID: 102, currentPath: "/fixture", names: [:]) == nil)
    #expect(CodexOMXSession.ancestorDirectories(currentPath: "/fixture/home/repo/sub", homeDirectory: URL(fileURLWithPath: "/fixture/home")).map(\.path) == ["/fixture/home/repo/sub", "/fixture/home/repo", "/fixture/home"])
    #expect(CodexOMXSession.ancestorDirectories(currentPath: "/fixture/home-other/repo", homeDirectory: URL(fileURLWithPath: "/fixture/home")).isEmpty)
}

@Test("rollout metadata selects user threads without parents")
func codexRolloutMetadata() {
    #expect(CodexRolloutSession.sessionID(fromFirstLine: Data(#"{"type":"session_meta","payload":{"id":"user","thread_source":"user"}}"#.utf8)) == "user")
    #expect(CodexRolloutSession.sessionID(fromFirstLine: Data(#"{"type":"session_meta","payload":{"id":"child","thread_source":"user","parent_thread_id":"parent"}}"#.utf8)) == nil)
    #expect(CodexRolloutSession.sessionID(fromFirstLine: Data(#"{"type":"session_meta","payload":{"id":"child","thread_source":"subagent"}}"#.utf8)) == nil)
    #expect(CodexRolloutSession.sessionID(fromFirstLine: Data(#"{"type":"message","payload":{"id":"user","thread_source":"user"}}"#.utf8)) == nil)
}

@Test("Claude status comes from its registry while screen state uses interrupt text")
func agentActivitySources() {
    for (status, expected) in [("busy", AgentActivityState.busy), ("idle", .idle), ("waiting", .idle)] {
        let json = Data("{\"pid\":1,\"name\":\"test\",\"tmux\":\"room:@0.%0\",\"status\":\"\(status)\"}".utf8)
        #expect(ClaudeSessionRegistry.record(fromJSON: json)?.state == expected)
    }
    #expect(AgentActivityState.claudeStatus(nil) == .unknown)
    #expect(AgentActivityState.visibleScreen("Working (esc to interrupt)") == .busy)
    #expect(AgentActivityState.visibleScreen("Ready\n> ") == .idle)
}

@Test("OMX cannot replace a stale source pid with the current Codex pid")
func codexOMXRejectsStalePID() {
    let json = Data(#"{"native_session_id":"stale","pid":999,"tmux_pane_id":"%228","tmux_session_name":"room"}"#.utf8)
    #expect(CodexOMXSession.record(fromJSON: json, paneID: "%228", nativePID: 102, currentPath: "/fixture", names: ["stale":"Old thread"]) == nil)
    let table = ProcessTable(psOutput: "100 1 node\n102 100 codex\n999 100 zsh")
    #expect(CodexOMXSession.record(fromJSON: json, paneID: "%228", nativePID: 102, currentPath: "/fixture", names: ["stale":"Old thread"], panePID: 100, table: table) == nil)
}
