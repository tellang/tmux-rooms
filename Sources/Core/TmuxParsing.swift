import Foundation

/// A tmux release as reported by `#{version}`.
///
/// tmux spells releases `<major>.<minor>` with an optional lowercase revision
/// letter, as in `3.6`, `3.6b`, and `3.7c`, and prefixes development builds `next-`.
/// Ordering a release against a floor lets a routine tmux upgrade keep working
/// instead of blinding the app until someone edits an exact-match constant.
struct TmuxVersion: Comparable {
    let major: Int, minor: Int, revision: UInt8

    init(major: Int, minor: Int, revision: UInt8) { self.major=major; self.minor=minor; self.revision=revision }

    init?(_ text: String) {
        var body = Substring(text)
        if body.hasPrefix("next-") { body = body.dropFirst(5) }
        var revision: UInt8 = 0
        if let last = body.last, last.isLetter, last.isLowercase, let ascii = last.asciiValue, ascii >= 97 {
            revision = ascii - 96
            body = body.dropLast()
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0 else { return nil }
        self.init(major: major, minor: minor, revision: revision)
    }

    static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.revision) < (b.major, b.minor, b.revision) }
}

enum TmuxParser {
    static let fieldLimit = 1_048_576
    static let stdoutLimit = 16_777_216
    static let recordLimit = 100_000
    /// The oldest release whose format surface this parser has been verified
    /// against. See `docs/design/managed-clients.md`.
    static let minimumSupportedVersion = TmuxVersion(major: 3, minor: 6, revision: 2)

    static func parse(_ data: Data) throws -> RawTmuxSnapshot {
        guard data.count <= stdoutLimit else { throw TmuxFailure.outputLimitExceeded }
        var cursor=Cursor(data), records:[(UInt8,[String])]=[]
        while !cursor.isAtEnd { guard records.count < recordLimit else { throw bad("record limit") }; records.append(try cursor.record()) }
        guard records.count >= 2, records.first?.0 == 66, records.last?.0 == 69 else { throw bad("missing boundary") }
        guard records.dropFirst().dropLast().allSatisfy({[83,67,80].contains($0.0)}) else { throw bad("unknown or misplaced record") }
        let begin=records[0].1,end=records[records.count-1].1
        guard begin.count == 5, begin == end else { throw bad("boundary mismatch") }
        guard begin[0] == "1" else { throw bad("schema") }
        guard let version = TmuxVersion(begin[4]), version >= minimumSupportedVersion else { throw TmuxFailure.unsupportedVersion(begin[4]) }
        guard !begin[1].isEmpty,let pid=int32(begin[2]),let started=int64(begin[3]) else { throw bad("boundary values") }
        let boundary=RawTmuxBoundary(socketPath:begin[1],serverPID:pid,startedAtUnixSeconds:started)
        var sessions:[String:RawTmuxSession]=[:],clients:[RawTmuxClient]=[],panes:[RawTmuxPane]=[]
        var clientKeys=Set<String>(),paneKeys=Set<String>(),phase=0
        for(type,f) in records.dropFirst().dropLast(){
            switch type {
            case 83:
                guard phase == 0,f.count == 5,validID(f[0],prefix:"$"),sessions[f[0]] == nil,let created=int64(f[1]),let activity=int64(f[3]),let attached=nonnegativeInt(f[4]) else { throw bad("session") }
                sessions[f[0]]=RawTmuxSession(id:f[0],created:created,name:f[2],activity:activity,attached:attached)
            case 67:
                guard phase <= 1 else { throw bad("section order") };phase=1
                guard f.count == 10,!f[0].isEmpty,let pid=int32(f[2]),let created=int64(f[3]),validID(f[4],prefix:"$"),let activity=int64(f[5]),let readOnly=bool(f[7]),let control=bool(f[9]) else { throw bad("client") }
                let flags=Array(Set(f[6].split(separator:",",omittingEmptySubsequences:true).map(String.init))).sorted()
                guard flags.contains("read-only") == readOnly,flags.contains("control-mode") == control else { throw bad("client flags") }
                let tty:String?
                if control { guard f[1].isEmpty else { throw bad("control tty") };tty=nil } else { tty=try validTTY(f[1]) }
                guard clientKeys.insert(f[0]).inserted else { throw bad("duplicate client") }
                clients.append(.init(name:f[0],tty:tty,pid:pid,created:created,sessionID:f[4],activity:activity,flags:flags,readOnly:readOnly,termName:f[8],control:control))
            case 80:
                phase=2
                guard f.count == 12,validID(f[0],prefix:"$"),validID(f[1],prefix:"@"),validID(f[2],prefix:"%"),let pid=int32(f[3]),let active=bool(f[7]),let dead=bool(f[8]),let windowIndex=nonnegativeInt(f[9]),let paneIndex=nonnegativeInt(f[10]) else { throw bad("pane") }
                guard paneKeys.insert("\(f[0])\u{0}\(f[2])").inserted else { throw bad("duplicate pane") }
                panes.append(.init(sessionID:f[0],windowID:f[1],paneID:f[2],pid:pid,path:f[4],title:f[5],command:f[6],active:active,dead:dead,windowIndex:windowIndex,paneIndex:paneIndex,codexThreadID:f[11]))
            default:throw bad("record")
            }
        }
        var clientCounts:[String:Int]=[:],paneCounts:[String:Int]=[:]
        for client in clients { guard sessions[client.sessionID] != nil else { throw bad("orphan") };clientCounts[client.sessionID,default:0]+=1 }
        for pane in panes { guard sessions[pane.sessionID] != nil else { throw bad("orphan") };paneCounts[pane.sessionID,default:0]+=1 }
        for session in sessions.values { guard paneCounts[session.id,default:0] > 0,clientCounts[session.id,default:0] == session.attached else { throw bad("relations") } }
        return .init(boundary:boundary,sessions:Array(sessions.values),clients:clients,panes:panes)
    }
    private static func bad(_ text:String)->TmuxFailure{.malformedOutput(text)}
    private static func validID(_ value:String,prefix:Character)->Bool{guard value.first==prefix else{return false};let tail=value.dropFirst();return !tail.isEmpty&&tail.allSatisfy(\.isASCIIWholeNumber)&&(tail=="0"||tail.first! != "0")&&UInt64(tail) != nil}
    private static func bool(_ value:String)->Bool?{value=="1" ? true:value=="0" ? false:nil}
    private static func int64(_ value:String)->Int64?{unsigned(value).flatMap(Int64.init(exactly:))}
    private static func int32(_ value:String)->Int32?{unsigned(value).flatMap(Int32.init(exactly:))}
    private static func nonnegativeInt(_ value:String)->Int?{unsigned(value).flatMap(Int.init(exactly:))}
    private static func unsigned(_ value:String)->UInt64?{guard !value.isEmpty,value.allSatisfy(\.isASCIIWholeNumber),value=="0"||value.first! != "0" else{return nil};return UInt64(value)}
    private static func validTTY(_ value:String)throws->String{let component=value.dropFirst(5);guard value.hasPrefix("/dev/"),!component.isEmpty,component != ".",component != "..",!component.contains("/") else{throw bad("tty")};return value}
}

struct RawTmuxBoundary:Sendable,Hashable{let socketPath:String;let serverPID:Int32;let startedAtUnixSeconds:Int64}
struct RawTmuxSession:Sendable,Hashable{let id:String;let created:Int64;let name:String;let activity:Int64;let attached:Int}
struct RawTmuxClient:Sendable,Hashable{let name:String;let tty:String?;let pid:Int32;let created:Int64;let sessionID:String;let activity:Int64;let flags:[String];let readOnly:Bool;let termName:String;let control:Bool}
struct RawTmuxPane:Sendable,Hashable{let sessionID:String;let windowID:String;let paneID:String;let pid:Int32;let path:String;let title:String;let command:String;let active:Bool;let dead:Bool;let windowIndex:Int;let paneIndex:Int;let codexThreadID:String}
struct RawTmuxSnapshot:Sendable,Hashable{
    let boundary:RawTmuxBoundary;let sessions:[RawTmuxSession];let clients:[RawTmuxClient];let panes:[RawTmuxPane]
    func bind(server:ServerIdentity)throws->RoomSnapshot{
        guard server.socketDevice != 0,server.socketInode != 0,canonicalTmuxSocketPath(boundary.socketPath)==canonicalTmuxSocketPath(server.canonicalSocketPath),boundary.serverPID==server.serverPID,boundary.startedAtUnixSeconds==server.startedAtUnixSeconds else{throw TmuxFailure.endpointChanged}
        var clientsBySession:[String:[RawTmuxClient]]=[:],panesBySession:[String:[RawTmuxPane]]=[:]
        for client in clients{clientsBySession[client.sessionID,default:[]].append(client)}
        for pane in panes{panesBySession[pane.sessionID,default:[]].append(pane)}
        let rooms=sessions.sorted{numericID($0.id)<numericID($1.id)}.map{session in
            let publicClients=(clientsBySession[session.id] ?? []).map{client in SessionRoom.Client(key:.init(server:server,clientName:client.name,tty:client.tty,clientPID:client.pid,createdAtUnixSeconds:client.created),lastActivityAtUnixSeconds:client.activity,flags:client.flags,isReadOnly:client.readOnly,terminalName:client.termName,isControlMode:client.control)}
            let publicPanes=(panesBySession[session.id] ?? []).map{pane in SessionRoom.Pane(windowID:pane.windowID,paneID:pane.paneID,panePID:pane.pid,currentPath:pane.path,title:pane.title,currentCommand:pane.command,isActive:pane.active,isDead:pane.dead,windowIndex:pane.windowIndex,paneIndex:pane.paneIndex,codexThreadID:pane.codexThreadID)}
            return SessionRoom(token:.init(server:server,sessionID:session.id,createdAtUnixSeconds:session.created),name:session.name,lastActivityAtUnixSeconds:session.activity,panes:publicPanes,clients:publicClients)
        }
        return RoomSnapshot(server:server,rooms:rooms)
    }
    private func numericID(_ value:String)->UInt64{UInt64(value.dropFirst())!}
}
private extension Character{var isASCIIWholeNumber:Bool{unicodeScalars.count==1&&unicodeScalars.first!.value>=48&&unicodeScalars.first!.value<=57}}
private struct Cursor{
    let bytes:[UInt8];var index=0;var isAtEnd:Bool{index==bytes.count};init(_ data:Data){bytes=Array(data)}
    mutating func record()throws->(UInt8,[String]){guard index<bytes.count else{throw TmuxFailure.malformedOutput("truncated")};let type=bytes[index];index+=1;let count:Int;switch type{case 66,69,83:count=5;case 67:count=10;case 80:count=12;default:throw TmuxFailure.malformedOutput("unknown type")};var fields:[String]=[];for _ in 0..<count{fields.append(try field())};guard index<bytes.count,bytes[index]==10 else{throw TmuxFailure.malformedOutput("missing LF")};index+=1;return(type,fields)}
    mutating func field()throws->String{let start=index;while index<bytes.count,bytes[index]>=48,bytes[index]<=57{index+=1};guard index>start,index<bytes.count,bytes[index]==58 else{throw TmuxFailure.malformedOutput("length")};guard index-start==1||bytes[start] != 48,let length=Int(String(decoding:bytes[start..<index],as:UTF8.self)),length<=TmuxParser.fieldLimit else{throw TmuxFailure.malformedOutput("length")};index+=1;guard index<=bytes.count-length else{throw TmuxFailure.malformedOutput("truncated field")};let raw=bytes[index..<index+length];index+=length;guard !raw.contains(0),let string=String(bytes:raw,encoding:.utf8) else{throw TmuxFailure.malformedOutput("utf8")};return string}
}
