import Foundation

enum ChooserKey: Equatable {
    case up, down, home, end, enter, cancel
    case digit(Int)
}

enum ChooserInput {
    /// Turns one read of raw terminal bytes into keys. Bytes that mean nothing to
    /// the chooser are dropped.
    ///
    /// An arrow key arrives as one `ESC [ A` burst, so an `ESC` with nothing after
    /// it in the same read is the Esc key itself.
    static func decode(_ bytes: [UInt8]) -> [ChooserKey] {
        var keys: [ChooserKey] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x1B:
                if index >= bytes.count {
                    keys.append(.cancel)
                    break
                }
                let introducer = bytes[index]
                index += 1
                // Only CSI (`[`) and SS3 (`O`) sequences carry keys. Alt+key is dropped.
                guard introducer == 0x5B || introducer == 0x4F else { break }
                var parameters: [UInt8] = []
                while index < bytes.count {
                    let next = bytes[index]
                    index += 1
                    if (0x40...0x7E).contains(next) {
                        if let key = escapeKey(final: next, parameters: parameters) { keys.append(key) }
                        break
                    }
                    parameters.append(next)
                }
            case 0x0D, 0x0A:
                keys.append(.enter)
            case 0x03, 0x04, 0x71, 0x51:  // Ctrl-C, Ctrl-D, q, Q
                keys.append(.cancel)
            case 0x10, 0x6B:  // Ctrl-P, k
                keys.append(.up)
            case 0x0E, 0x6A:  // Ctrl-N, j
                keys.append(.down)
            case 0x30...0x39:
                keys.append(.digit(Int(byte) - 0x30))
            default:
                break
            }
        }
        return keys
    }

    private static func escapeKey(final: UInt8, parameters: [UInt8]) -> ChooserKey? {
        let text = String(decoding: parameters, as: UTF8.self)
        switch (Character(UnicodeScalar(final)), text) {
        case ("A", _): return .up
        case ("B", _): return .down
        case ("H", _), ("~", "1"), ("~", "7"): return .home
        case ("F", _), ("~", "4"), ("~", "8"): return .end
        default: return nil
        }
    }
}

/// The chooser's cursor and typed-number state, free of any terminal I/O.
struct ChooserState: Equatable {
    enum Outcome: Equatable {
        case none
        case select(Int)
        case cancel
    }

    let count: Int
    private(set) var cursor: Int
    /// Digits typed so far when they could still grow into a larger room number.
    private(set) var digits = ""

    init(count: Int, cursor: Int = 0) {
        self.count = count
        self.cursor = count > 0 ? min(max(cursor, 0), count - 1) : 0
    }

    mutating func apply(_ key: ChooserKey) -> Outcome {
        guard count > 0 else { return key == .cancel ? .cancel : .none }
        switch key {
        case .digit(let digit):
            return typeDigit(digit)
        case .up:
            digits = ""
            cursor = (cursor - 1 + count) % count
        case .down:
            digits = ""
            cursor = (cursor + 1) % count
        case .home:
            digits = ""
            cursor = 0
        case .end:
            digits = ""
            cursor = count - 1
        case .enter:
            digits = ""
            return .select(cursor)
        case .cancel:
            return .cancel
        }
        return .none
    }

    /// A number selects its room at once when no larger number could start with
    /// the same digits. Otherwise the cursor moves there and waits for another
    /// digit or Enter, so with twelve rooms `1` waits and `12` selects.
    private mutating func typeDigit(_ digit: Int) -> Outcome {
        var number = Int(digits + String(digit)) ?? 0
        if number < 1 || number > count {
            // The longer number names no room, so this digit starts a new one.
            number = digit
            digits = ""
        }
        guard number >= 1, number <= count else { return .none }
        cursor = number - 1
        if number * 10 > count {
            digits = ""
            return .select(cursor)
        }
        digits = String(number)
        return .none
    }

    /// The slice of `rows` visible lines that keeps the cursor on screen.
    func window(rows: Int) -> Range<Int> {
        guard rows > 0, count > rows else { return 0..<count }
        let start = min(max(cursor - rows / 2, 0), count - rows)
        return start..<(start + rows)
    }
}
