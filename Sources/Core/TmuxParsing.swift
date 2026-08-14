import Foundation

public enum TmuxParser {
    public static let fieldLimit = 1_048_576
    public static let stdoutLimit = 16_777_216
    public static let recordLimit = 100_000

    public static func parse(_ data: Data) throws -> RoomSnapshot {
        guard data.count <= stdoutLimit else { throw TmuxFailure.outputLimitExceeded }
        var cursor = Cursor(data); var records: [(UInt8, [String])] = []
        while !cursor.isAtEnd {
            guard records.count < recordLimit else { throw TmuxFailure.malformedOutput("record limit") }
            records.append(try cursor.record())
        }
        guard records.count >= 2, records.first?.0 == 66, records.last?.0 == 69 else { throw bad("missing boundary") }
        guard records.dropFirst().dropLast().allSatisfy({ [83, 67, 80].contains($0.0) }) else { throw bad("unknown or misplaced record") }
        let begin = records[0].1, end = records[records.count - 1].1
        guard begin.count == 5, begin == end else { throw bad("boundary mismatch") }
        guard begin[0] == "1" else { throw bad("schema") }
        guard begin[4] == "3.6b" else { throw TmuxFailure.unsupportedVersion(begin[4]) }
        guard !begin[1].isEmpty, let pid = int32(begin[2]), let started = int64(begin[3]) else { throw bad("boundary values") }
        let server = ServerIdentity(canonicalSocketPath: begin[1], socketDevice: 0, socketInode: 0, serverPID: pid, startedAtUnixSeconds: started)

        struct S { let id: String; let created: Int64; let name: String; let activity: Int64; let attached: Int }
        struct C { let name: String; let tty: String?; let pid: Int32; let created: Int64; let sid: String; let activity: Int64; let flags: [String]; let ro: Bool; let term: String; let control: Bool }
        struct P { let sid: String; let pane: SessionRoom.Pane }
        var sessions: [String:S] = [:], clients: [C] = [], panes: [P] = [], clientKeys = Set<String>(), paneKeys = Set<String>()
        var phase = 0 // S=0, C=1, P=2; phases may be empty but never regress.
        for (type, f) in records.dropFirst().dropLast() {
            switch type {
            case 83:
                guard phase == 0 else { throw bad("section order") }
                guard f.count == 5, validID(f[0], prefix: "$"), sessions[f[0]] == nil, let created = int64(f[1]), let activity = int64(f[3]), let attached = nonnegativeInt(f[4]) else { throw bad("session") }
                sessions[f[0]] = S(id:f[0], created:created, name:f[2], activity:activity, attached:attached)
            case 67:
                guard phase <= 1 else { throw bad("section order") }; phase = 1
                guard f.count == 10, !f[0].isEmpty, let pid = int32(f[2]), let created = int64(f[3]), validID(f[4], prefix:"$"), let activity = int64(f[5]), let ro = bool(f[7]), let control = bool(f[9]) else { throw bad("client") }
                let flags = Array(Set(f[6].split(separator: ",", omittingEmptySubsequences: true).map(String.init))).sorted()
                guard flags.contains("readonly") == ro, flags.contains("control-mode") == control else { throw bad("client flags") }
                let tty: String?
                if control { guard f[1].isEmpty else { throw bad("control tty") }; tty = nil } else { tty = try validTTY(f[1]) }
                guard clientKeys.insert(f[0]).inserted else { throw bad("duplicate client") }
                clients.append(C(name:f[0], tty:tty, pid:pid, created:created, sid:f[4], activity:activity, flags:flags, ro:ro, term:f[8], control:control))
            case 80:
                phase = 2
                guard f.count == 9, validID(f[0], prefix:"$"), validID(f[1], prefix:"@"), validID(f[2], prefix:"%"), let pid = int32(f[3]), let active = bool(f[7]), let dead = bool(f[8]) else { throw bad("pane") }
                let key = "\(f[0])\u{0}\(f[2])"; guard paneKeys.insert(key).inserted else { throw bad("duplicate pane") }
                panes.append(P(sid:f[0], pane:.init(windowID:f[1], paneID:f[2], panePID:pid, currentPath:f[4], title:f[5], currentCommand:f[6], isActive:active, isDead:dead)))
            default: throw bad("record")
            }
        }
        guard clients.allSatisfy({ sessions[$0.sid] != nil }), panes.allSatisfy({ sessions[$0.sid] != nil }) else { throw bad("orphan") }
        var rooms: [SessionRoom] = []
        for s in sessions.values.sorted(by: { numericID($0.id) < numericID($1.id) }) {
            let cs = clients.filter { $0.sid == s.id }
            let ps = panes.filter { $0.sid == s.id }.map(\.pane)
            guard !ps.isEmpty, cs.count == s.attached else { throw bad("relations") }
            let publicClients = cs.map { c in SessionRoom.Client(key:.init(server:server, clientName:c.name, tty:c.tty, clientPID:c.pid, createdAtUnixSeconds:c.created), lastActivityAtUnixSeconds:c.activity, flags:c.flags, isReadOnly:c.ro, terminalName:c.term, isControlMode:c.control) }
            rooms.append(.init(token:.init(server:server, sessionID:s.id, createdAtUnixSeconds:s.created), name:s.name, lastActivityAtUnixSeconds:s.activity, panes:ps, clients:publicClients))
        }
        return RoomSnapshot(server: server, rooms: rooms)
    }

    private static func bad(_ text: String) -> TmuxFailure { .malformedOutput(text) }
    private static func validID(_ value: String, prefix: Character) -> Bool {
        guard value.first == prefix else { return false }; let tail = value.dropFirst()
        return !tail.isEmpty && tail.allSatisfy(\.isASCIIWholeNumber) && (tail == "0" || tail.first != "0") && UInt64(tail) != nil
    }
    private static func numericID(_ value: String) -> UInt64 { UInt64(value.dropFirst())! }
    private static func bool(_ value: String) -> Bool? { value == "1" ? true : value == "0" ? false : nil }
    private static func int64(_ value: String) -> Int64? { unsigned(value).flatMap(Int64.init(exactly:)) }
    private static func int32(_ value: String) -> Int32? { unsigned(value).flatMap(Int32.init(exactly:)) }
    private static func nonnegativeInt(_ value: String) -> Int? { unsigned(value).flatMap(Int.init(exactly:)) }
    private static func unsigned(_ value: String) -> UInt64? { guard !value.isEmpty, value.allSatisfy(\.isASCIIWholeNumber), value == "0" || value.first != "0" else { return nil }; return UInt64(value) }
    private static func validTTY(_ value: String) throws -> String { let component=value.dropFirst(5); guard value.hasPrefix("/dev/"), !component.isEmpty, component != ".", component != "..", !component.contains("/") else { throw bad("tty") }; return value }
}

private extension Character { var isASCIIWholeNumber: Bool { unicodeScalars.count == 1 && unicodeScalars.first!.value >= 48 && unicodeScalars.first!.value <= 57 } }
private struct Cursor {
    let bytes: [UInt8]; var index = 0; var isAtEnd: Bool { index == bytes.count }
    init(_ data: Data) { bytes = Array(data) }
    mutating func record() throws -> (UInt8,[String]) {
        guard index < bytes.count else { throw TmuxFailure.malformedOutput("truncated") }; let type = bytes[index]; index += 1
        let count: Int
        switch type { case 66,69: count=5; case 83: count=5; case 67: count=10; case 80: count=9; default: throw TmuxFailure.malformedOutput("unknown type") }
        var fields:[String]=[]
        for _ in 0..<count { fields.append(try field()) }
        guard index < bytes.count, bytes[index] == 10 else { throw TmuxFailure.malformedOutput("missing LF") }; index += 1
        return (type,fields)
    }
    mutating func field() throws -> String {
        let start=index; while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
        guard index > start, index < bytes.count, bytes[index] == 58 else { throw TmuxFailure.malformedOutput("length") }
        guard index-start == 1 || bytes[start] != 48, let length=Int(String(decoding:bytes[start..<index],as:UTF8.self)), length <= TmuxParser.fieldLimit else { throw TmuxFailure.malformedOutput("length") }
        index += 1; guard index <= bytes.count-length else { throw TmuxFailure.malformedOutput("truncated field") }
        let raw=bytes[index..<index+length]; index += length
        guard !raw.contains(0), let string=String(bytes:raw,encoding:.utf8) else { throw TmuxFailure.malformedOutput("utf8") }; return string
    }
}
