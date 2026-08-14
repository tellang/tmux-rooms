import Darwin
import Foundation

public enum DefaultTmuxEndpointResolver {
    public static func resolve(environment: [String:String] = ProcessInfo.processInfo.environment, userID: UInt32 = getuid()) throws -> URL {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        let root=URL(fileURLWithPath:canonicalExistingPath(base),isDirectory:true)
        return root.appending(path:"tmux-\(userID)",directoryHint:.isDirectory).appending(path:"default")
    }
}

public struct TmuxSnapshotLoader: Sendable {
    private let runner:any TmuxCommandRunning; private let executableURL:URL
    public init(runner:any TmuxCommandRunning=ProcessTmuxCommandRunner(), executableURL:URL=URL(fileURLWithPath:"/opt/homebrew/bin/tmux")) { self.runner=runner; self.executableURL=executableURL }
    public func load(socketURL:URL) async throws -> RoomSnapshot {
        let canonical=canonicalSocket(socketURL), before=try endpoint(canonical)
        let invocation=TmuxCommandInvocation(executableURL:executableURL, arguments:TmuxSnapshotCommand.arguments(socketPath:canonical.path))
        let output=try await runner.run(invocation)
        let after=try endpoint(canonical)
        if before != after { throw TmuxFailure.endpointChanged }
        if output.exitCode != 0 {
            if output.exitCode == 1, output.termination == .exit, output.stdout.isEmpty, expectedNoServer(output.stderr) { return .noServer }
            throw TmuxFailure.commandFailed(exitCode:output.exitCode, stderr:String(decoding:output.stderr,as:UTF8.self))
        }
        guard case .exit=output.termination else { throw TmuxFailure.commandFailed(exitCode:output.exitCode,stderr:String(decoding:output.stderr,as:UTF8.self)) }
        guard let before, let after, before == after else { throw TmuxFailure.endpointChanged }
        let parsed=try TmuxParser.parse(output.stdout)
        guard let raw=parsed.server, raw.canonicalSocketPath == canonical.path else { throw TmuxFailure.endpointChanged }
        let identity=ServerIdentity(canonicalSocketPath:canonical.path,socketDevice:before.device,socketInode:before.inode,serverPID:raw.serverPID,startedAtUnixSeconds:raw.startedAtUnixSeconds)
        return rebuild(parsed, identity)
    }
    private func rebuild(_ snapshot:RoomSnapshot,_ server:ServerIdentity)->RoomSnapshot {
        RoomSnapshot(server:server,rooms:snapshot.rooms.map { room in
            let clients=room.clients.map { c in SessionRoom.Client(key:.init(server:server,clientName:c.key.clientName,tty:c.key.tty,clientPID:c.key.clientPID,createdAtUnixSeconds:c.key.createdAtUnixSeconds),lastActivityAtUnixSeconds:c.lastActivityAtUnixSeconds,flags:c.flags,isReadOnly:c.isReadOnly,terminalName:c.terminalName,isControlMode:c.isControlMode) }
            return SessionRoom(token:.init(server:server,sessionID:room.token.sessionID,createdAtUnixSeconds:room.token.createdAtUnixSeconds),name:room.name,lastActivityAtUnixSeconds:room.lastActivityAtUnixSeconds,panes:room.panes,clients:clients)
        })
    }
    private func canonicalSocket(_ url:URL)->URL { let parent=URL(fileURLWithPath:canonicalExistingPath(url.deletingLastPathComponent().path),isDirectory:true); return parent.appending(path:url.lastPathComponent).standardizedFileURL }
    private struct Endpoint:Equatable { let device:UInt64; let inode:UInt64 }
    private func endpoint(_ url:URL)throws->Endpoint? { var s=stat(); if lstat(url.path,&s)==0 { guard (s.st_mode & S_IFMT) == S_IFSOCK else { throw TmuxFailure.endpointChanged }; return Endpoint(device:UInt64(s.st_dev),inode:UInt64(s.st_ino)) }; if errno==ENOENT || errno==ENOTDIR{return nil}; if errno==EACCES{throw TmuxFailure.endpointPermissionDenied}; throw TmuxFailure.launchFailed(String(cString:strerror(errno))) }
    private func expectedNoServer(_ data:Data)->Bool { let s=String(decoding:data,as:UTF8.self).lowercased(); return s.contains("no server running on") || s.contains("connection refused") || s.contains("no such file or directory") }
}

private func canonicalExistingPath(_ path:String)->String { guard let pointer=realpath(path,nil) else { return URL(fileURLWithPath:path).standardizedFileURL.path }; defer{free(pointer)}; return String(cString:pointer) }
