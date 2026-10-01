import Foundation
import Testing

private func room(_ name: String, paths: [String] = ["/p/app"], attached: Int = 0, activity: Int64 = 1_700_000_000, title: String? = nil) -> CLIRoom {
    CLIRoom(
        sessionID: "$\(name.count)", tmuxName: name, title: title ?? name, agent: nil,
        paths: paths, interactiveClients: attached, readOnlyClients: 0, lastActivityAtUnixSeconds: activity
    )
}

@Suite("Chooser input")
struct ChooserInputTests {
    private func keys(_ text: String) -> [ChooserKey] { ChooserInput.decode(Array(text.utf8)) }

    @Test func arrowsInBothTerminalEncodings() {
        #expect(keys("\u{1B}[A") == [.up])
        #expect(keys("\u{1B}[B") == [.down])
        #expect(keys("\u{1B}OA") == [.up])
        #expect(keys("\u{1B}OB") == [.down])
        #expect(keys("\u{1B}[1;5B") == [.down])
    }

    @Test func homeAndEndVariants() {
        #expect(keys("\u{1B}[H") == [.home])
        #expect(keys("\u{1B}[F") == [.end])
        #expect(keys("\u{1B}[1~") == [.home])
        #expect(keys("\u{1B}[4~") == [.end])
    }

    @Test func loneEscapeCancelsButAltKeyDoesNot() {
        #expect(keys("\u{1B}") == [.cancel])
        #expect(keys("\u{1B}x").isEmpty)
    }

    @Test func plainKeys() {
        #expect(keys("\r") == [.enter])
        #expect(keys("\n") == [.enter])
        #expect(keys("q") == [.cancel])
        #expect(keys("\u{03}") == [.cancel])
        #expect(keys("j") == [.down])
        #expect(keys("k") == [.up])
        #expect(keys("\u{0E}") == [.down])
        #expect(keys("\u{10}") == [.up])
        #expect(keys("7") == [.digit(7)])
    }

    @Test func aBurstDecodesEveryKeyAndDropsNoise() {
        #expect(keys("\u{1B}[B\u{1B}[B\r") == [.down, .down, .enter])
        #expect(keys("z1?") == [.digit(1)])
        #expect(keys("\u{1B}[99Z").isEmpty)
    }
}

@Suite("Chooser state")
struct ChooserStateTests {
    @Test func cursorStartsWhereAskedAndIsClamped() {
        #expect(ChooserState(count: 5, cursor: 3).cursor == 3)
        #expect(ChooserState(count: 5, cursor: 99).cursor == 4)
        #expect(ChooserState(count: 5, cursor: -2).cursor == 0)
    }

    @Test func arrowsWrapAroundTheList() {
        var state = ChooserState(count: 3)
        #expect(state.apply(.up) == .none)
        #expect(state.cursor == 2)
        #expect(state.apply(.down) == .none)
        #expect(state.cursor == 0)
        _ = state.apply(.end)
        #expect(state.cursor == 2)
        _ = state.apply(.home)
        #expect(state.cursor == 0)
    }

    @Test func enterSelectsTheHighlightedRoomAndCancelCancels() {
        var state = ChooserState(count: 4, cursor: 2)
        #expect(state.apply(.enter) == .select(2))
        #expect(state.apply(.cancel) == .cancel)
    }

    @Test func aDigitSelectsAtOnceWhenNoLargerNumberFits() {
        var state = ChooserState(count: 9)
        #expect(state.apply(.digit(4)) == .select(3))
        #expect(state.cursor == 3)
        var five = ChooserState(count: 5)
        #expect(five.apply(.digit(3)) == .select(2))
    }

    @Test func aDigitOutOfRangeChangesNothing() {
        var state = ChooserState(count: 3, cursor: 1)
        #expect(state.apply(.digit(7)) == .none)
        #expect(state.apply(.digit(0)) == .none)
        #expect(state.cursor == 1)
    }

    @Test func withTwelveRoomsOneWaitsAndTwelveSelects() {
        var state = ChooserState(count: 12)
        #expect(state.apply(.digit(1)) == .none)
        #expect(state.cursor == 0)
        #expect(state.apply(.digit(2)) == .select(11))

        var enter = ChooserState(count: 12)
        _ = enter.apply(.digit(1))
        #expect(enter.apply(.enter) == .select(0))

        var ten = ChooserState(count: 12)
        _ = ten.apply(.digit(1))
        #expect(ten.apply(.digit(0)) == .select(9))
    }

    @Test func aSecondDigitThatNamesNoRoomStartsOver() {
        var state = ChooserState(count: 12)
        _ = state.apply(.digit(1))
        #expect(state.apply(.digit(5)) == .select(4))
    }

    @Test func movingClearsTheTypedDigits() {
        var state = ChooserState(count: 12)
        _ = state.apply(.digit(1))
        #expect(state.digits == "1")
        _ = state.apply(.down)
        #expect(state.digits.isEmpty)
        // Had the 1 survived the move, this would read as 11 and select room 11.
        #expect(state.apply(.digit(1)) == .none)
        #expect(state.cursor == 0)
    }

    @Test func anEmptyListOnlyCancels() {
        var state = ChooserState(count: 0)
        #expect(state.apply(.enter) == .none)
        #expect(state.apply(.digit(1)) == .none)
        #expect(state.apply(.cancel) == .cancel)
    }

    @Test func windowKeepsTheCursorVisible() {
        #expect(ChooserState(count: 3).window(rows: 10) == 0..<3)
        #expect(ChooserState(count: 20, cursor: 0).window(rows: 5) == 0..<5)
        #expect(ChooserState(count: 20, cursor: 10).window(rows: 5) == 8..<13)
        #expect(ChooserState(count: 20, cursor: 19).window(rows: 5) == 15..<20)
        for cursor in 0..<20 {
            let window = ChooserState(count: 20, cursor: cursor).window(rows: 5)
            #expect(window.contains(cursor) && window.count == 5)
        }
    }
}

@Suite("Chooser display")
struct ChooserDisplayTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func highlightStartsOnTheFirstRoomInTheDirectory() {
        let rooms = [room("a", paths: ["/p/other"]), room("b", paths: ["/p/app"]), room("c", paths: ["/p/app"])]
        #expect(RoomQuery.initialCursor(rooms, directory: "/p/app") == 1)
        #expect(RoomQuery.initialCursor(rooms, directory: "/nowhere") == 0)
        #expect(RoomQuery.initialCursor([], directory: "/p/app") == 0)
    }

    @Test func rowsAreNumberedAlignedAndMarkAttachedRooms() {
        let rooms = [
            room("a", attached: 1, title: "배포 경계"),
            room("bb", paths: ["/Users/fixture/x"]),
        ]
        let rows = RoomFormat.chooserRows(rooms, home: "/Users/fixture", timeZone: utc)
        #expect(rows.count == 2)
        #expect(rows[0].hasPrefix("1  배포 경계"))
        #expect(rows[0].hasSuffix("[attached]"))
        #expect(rows[1].hasPrefix("2  bb"))
        #expect(rows[1].contains("~/x"))
        #expect(!rows[1].contains("[attached]"))
        // The time column starts at the same cell in both rows, wide Hangul included.
        let starts = rows.map { row -> Int in
            let range = row.range(of: "11-14")!
            return TextWidth.of(String(row[row.startIndex..<range.lowerBound]))
        }
        #expect(Set(starts).count == 1)
    }

    @Test func rowNumbersAlignPastNine() {
        let rooms = (1...10).map { room("r\($0)") }
        let rows = RoomFormat.chooserRows(rooms, home: "/h", timeZone: utc)
        #expect(rows[0].hasPrefix(" 1  "))
        #expect(rows[9].hasPrefix("10  "))
    }

    @Test func detailNamesTheTmuxSession() {
        #expect(RoomFormat.chooserDetail(room("omx-app")) == "tmux: omx-app  ($7)")
    }
}

@Suite("Help text")
struct HelpTextTests {
    @Test func everySpellingOfHelpIsRecognised() {
        for flag in ["-h", "-help", "--help"] { #expect(HelpText.isHelpFlag(flag)) }
        #expect(!HelpText.isHelpFlag("help"))
        #expect(!HelpText.isHelpFlag("--here"))
    }

    @Test func fullHelpUsesTheProgramNameAndCoversEveryOptionAndKey() {
        let help = HelpText.full(program: "tmr")
        #expect(help.hasPrefix("tmr: "))
        for needle in ["tmr ls", "--here", "--json", "--read-only", "-help", "Enter", "Home, End", "Esc", "Exit codes", "never creates"] {
            #expect(help.lowercased().contains(needle.lowercased()), "missing \(needle)")
        }
        #expect(!help.contains("tmuxrooms"))
    }

    @Test func shortUsagePointsAtFullHelp() {
        #expect(HelpText.short(program: "tmr").contains("tmr -help"))
    }
}
