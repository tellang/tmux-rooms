import Foundation
import Testing
import TmuxRoomsCore

private let esc = "\u{1B}"

private func room(_ name: String, agent: AgentKind?, title: String? = nil) -> CLIRoom {
    CLIRoom(
        sessionID: "$\(name.count)", tmuxName: name, title: title ?? name, agent: agent,
        paths: ["/p/app"], interactiveClients: 0, readOnlyClients: 0, lastActivityAtUnixSeconds: 1_700_000_000
    )
}

@Suite("Agent style")
struct AgentStyleTests {
    @Test func everyAgentHasItsOwnColorAndTag() {
        let colors = AgentKind.allCases.compactMap { AgentStyle.color(for: $0) }
        #expect(colors.count == AgentKind.allCases.count)
        #expect(Set(colors.map(\.trueColor)).count == colors.count)
        #expect(AgentStyle.color(for: nil) == nil)
        #expect(AgentKind.allCases.map { AgentStyle.tag(for: $0) } == ["claude", "codex", "agy"])
        #expect(AgentStyle.tag(for: nil) == "-")
    }

    @Test func eachAgentKeepsItsColor() {
        #expect(AgentStyle.color(for: .claude)?.trueColor == "38;2;232;112;64")
        #expect(AgentStyle.color(for: .codex)?.trueColor == "97")
        #expect(AgentStyle.color(for: .agy)?.trueColor == "38;5;39")
    }

    @Test func codexIsWhiteAndNotAColoredHue() {
        // SGR 97 is bright white; anything else would tint Codex.
        #expect(AgentStyle.foreground(for: .codex, depth: .trueColor) == "97")
        #expect(AgentStyle.foreground(for: .codex, depth: .ansi256) == "97")
    }

    @Test func claudeFallsBackToThePalettesOrangeNotARoundedRed() {
        // 208 is #ff8700. Rounding #E87040 to the nearest color-cube cell gives 167,
        // #d75f5f, a pinkish red.
        #expect(AgentStyle.foreground(for: .claude, depth: .ansi256) == "38;5;208")
    }

    @Test func colorDepthFollowsTheEnvironment() {
        #expect(ColorDepth.detect(environment: ["COLORTERM": "truecolor", "TERM": "tmux-256color"]) == .trueColor)
        #expect(ColorDepth.detect(environment: ["COLORTERM": "24bit"]) == .trueColor)
        #expect(ColorDepth.detect(environment: ["TERM": "xterm-256color"]) == .ansi256)
        #expect(ColorDepth.detect(environment: ["TERM": "screen"]) == .none)
        #expect(ColorDepth.detect(environment: [:]) == .none)
    }

    @Test func noColorBeatsEveryCapabilityButAnEmptyValueDoesNot() {
        #expect(ColorDepth.detect(environment: ["NO_COLOR": "1", "COLORTERM": "truecolor"]) == .none)
        #expect(ColorDepth.detect(environment: ["NO_COLOR": "", "COLORTERM": "truecolor"]) == .trueColor)
    }

    @Test func noForegroundWithoutAnAgentOrWithoutColor() {
        #expect(AgentStyle.foreground(for: nil, depth: .trueColor) == nil)
        #expect(AgentStyle.foreground(for: .claude, depth: .none) == nil)
    }

    @Test func anUnselectedAgentRowIsTextInTheAgentColor() {
        #expect(AgentStyle.paint("row", kind: .claude, selected: false, depth: .trueColor) == "\(esc)[38;2;232;112;64mrow\(esc)[0m")
        #expect(AgentStyle.paint("row", kind: .codex, selected: false, depth: .trueColor) == "\(esc)[97mrow\(esc)[0m")
        #expect(AgentStyle.paint("row", kind: .agy, selected: false, depth: .trueColor) == "\(esc)[38;5;39mrow\(esc)[0m")
    }

    @Test func aSelectedAgentRowKeepsTheColorAndSwapsForegroundWithBackground() {
        // Bold, the agent color as foreground, then reverse video: the terminal
        // swaps them, so the bar is the agent color and the text is its background.
        #expect(AgentStyle.paint("row", kind: .claude, selected: true, depth: .trueColor) == "\(esc)[1;38;2;232;112;64;7mrow\(esc)[0m")
        #expect(AgentStyle.paint("row", kind: .codex, selected: true, depth: .trueColor) == "\(esc)[1;97;7mrow\(esc)[0m")
        #expect(AgentStyle.paint("row", kind: .agy, selected: true, depth: .trueColor) == "\(esc)[1;38;5;39;7mrow\(esc)[0m")
    }

    @Test func selectionWithoutAnAgentOrWithoutColorIsAPlainReverse() {
        #expect(AgentStyle.paint("row", kind: nil, selected: true, depth: .trueColor) == "\(esc)[7mrow\(esc)[0m")
        #expect(AgentStyle.paint("row", kind: .codex, selected: true, depth: .none) == "\(esc)[7mrow\(esc)[0m")
    }

    @Test func aRowWithNothingToStyleIsLeftAlone() {
        #expect(AgentStyle.paint("row", kind: nil, selected: false, depth: .trueColor) == "row")
        #expect(AgentStyle.paint("row", kind: .claude, selected: false, depth: .none) == "row")
    }

    @Test func the256ColorFallbackUsesItsOwnParameters() {
        #expect(AgentStyle.paint("row", kind: .claude, selected: false, depth: .ansi256) == "\(esc)[38;5;208mrow\(esc)[0m")
    }
}

@Suite("Agent columns")
struct AgentColumnTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func tableShowsTheAgentColumnAndKeepsAlignmentWithoutColor() {
        let rooms = [room("a", agent: .claude, title: "배포 경계"), room("b", agent: nil), room("c", agent: .agy, title: "Antigravity")]
        let lines = RoomFormat.table(rooms, home: "/h", timeZone: utc).split(separator: "\n").map(String.init)
        #expect(lines[0].contains("AGENT"))
        #expect(lines[1].contains("claude"))
        #expect(lines[2].contains(" - "))
        #expect(lines[3].contains("agy"))
        #expect(!lines.contains { $0.contains(esc) })
        let starts = lines.map { line -> Int in
            let range = line.range(of: "LAST") ?? line.range(of: "11-14")!
            return TextWidth.of(String(line[line.startIndex..<range.lowerBound]))
        }
        #expect(Set(starts).count == 1)
    }

    @Test func tablePaintsAgentRowsAndLeavesTheHeaderPlain() {
        let rooms = [room("a", agent: .claude), room("b", agent: nil), room("c", agent: .codex)]
        let lines = RoomFormat.table(rooms, home: "/h", timeZone: utc, depth: .trueColor).split(separator: "\n").map(String.init)
        #expect(!lines[0].contains(esc))
        #expect(lines[1].hasPrefix("\(esc)[38;2;232;112;64m") && lines[1].hasSuffix("\(esc)[0m"))
        #expect(!lines[2].contains(esc))
        #expect(lines[3].hasPrefix("\(esc)[97m"))
    }

    @Test func chooserRowsCarryTheAgentTag() {
        let rooms = [room("a", agent: .claude), room("b", agent: nil), room("c", agent: .agy)]
        let rows = RoomFormat.chooserRows(rooms, home: "/h", timeZone: utc)
        #expect(rows[0].contains("claude"))
        #expect(rows[2].contains("agy"))
        // Tags are padded to one width, so the time column lines up.
        let starts = rows.map { row -> Int in
            let range = row.range(of: "11-14")!
            return TextWidth.of(String(row[row.startIndex..<range.lowerBound]))
        }
        #expect(Set(starts).count == 1)
    }

    @Test func textFilterFindsAnAgentByItsShortName() {
        let rooms = [room("a", agent: .agy, title: "Antigravity"), room("b", agent: .claude, title: "9.1"), room("c", agent: nil)]
        #expect(RoomQuery.filter(rooms, directory: nil, text: "agy").map(\.tmuxName) == ["a"])
        #expect(RoomQuery.filter(rooms, directory: nil, text: "claude").map(\.tmuxName) == ["b"])
        #expect(RoomQuery.filter(rooms, directory: nil, text: "codex").isEmpty)
    }
}
