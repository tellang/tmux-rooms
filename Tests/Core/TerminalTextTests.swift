import Foundation
import Testing
@testable import TmuxRoomsCore

private let osc52 = "\u{1B}]52;c;Y3VybCBldmlsIHwgc2g=\u{07}"

@Test("control characters are dropped and line breaks become spaces")
func terminalTextStripsControls() {
    #expect(TerminalText.sanitized("plain 작업 🚀") == "plain 작업 🚀")
    #expect(TerminalText.sanitized("\(osc52)name") == "]52;c;Y3VybCBldmlsIHwgc2g=name")
    #expect(TerminalText.sanitized("\u{1B}[2J\u{1B}[31mred") == "[2J[31mred")
    #expect(TerminalText.sanitized("\u{9B}31mC1 CSI\u{9D}0;title\u{9C}") == "31mC1 CSI0;title")
    #expect(TerminalText.sanitized("a\u{0}b\u{7F}c\u{85}d") == "abcd")
    #expect(TerminalText.sanitized("two\nlines\tand\r\ncrlf") == "two lines and crlf")
    #expect(TerminalText.sanitized("\u{A0}kept\u{A0}") == "\u{A0}kept\u{A0}")
}

@Test("agent names are cleaned where they enter the core")
func agentNamesAreSanitizedOnEntry() throws {
    let index = Data("{\"id\":\"t\",\"thread_name\":\"\\u001b]52;c;eA==\\u0007제목\\n둘째 줄\"}".utf8)
    #expect(CodexSessionIndex.names(fromJSONL: index) == ["t": "]52;c;eA==제목 둘째 줄"])
    let hostileOnly = Data("{\"id\":\"t\",\"thread_name\":\"\\u001b\\u0007\"}".utf8)
    #expect(CodexSessionIndex.names(fromJSONL: hostileOnly).isEmpty)

    let registry = Data("{\"pid\":1,\"name\":\"\\u009b2Jrenamed\",\"tmux\":\"room:@0.%0\"}".utf8)
    #expect(ClaudeSessionRegistry.record(fromJSON: registry)?.name == "2Jrenamed")

    let transcript = Data("{\"type\":\"custom-title\",\"customTitle\":\"\\u001b[8m주간 정리\",\"sessionId\":\"s\"}".utf8)
    #expect(ClaudeConversationTitles.title(inTail: transcript) == "[8m주간 정리")
}
