import Darwin
import Foundation

public enum DefaultTmuxEndpointResolver {
    public static func resolve(environment: [String:String] = ProcessInfo.processInfo.environment, userID: UInt32 = getuid()) throws -> URL {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        let root=URL(fileURLWithPath:canonicalExistingPath(base),isDirectory:true)
        return root.appending(path:"tmux-\(userID)",directoryHint:.isDirectory).appending(path:"default")
    }
}

public protocol TmuxSnapshotLoading: Sendable {
    func load(socketURL: URL) async throws -> RoomSnapshot
}

public struct TmuxSnapshotLoader: TmuxSnapshotLoading, Sendable {
    private let runner:any TmuxCommandRunning; private let executableURL:URL
    public init(runner:any TmuxCommandRunning=ProcessTmuxCommandRunner(), executableURL:URL=URL(fileURLWithPath:"/opt/homebrew/bin/tmux")) { self.runner=runner; self.executableURL=executableURL }
    public func load(socketURL:URL) async throws -> RoomSnapshot {
        let canonical=canonicalSocket(socketURL), before=try endpoint(canonical)
        let invocation=TmuxCommandInvocation(executableURL:executableURL, arguments:TmuxSnapshotCommand.arguments(socketPath:canonical.path))
        let output=try await runner.run(invocation)
        let after=try endpoint(canonical)
        if before != after { throw TmuxFailure.endpointChanged }
        if output.exitCode != 0 {
            if output.exitCode == 1, output.termination == .exit, output.stdout.isEmpty, expectedNoServer(output.stderr,path:canonical.path) { return .noServer }
            throw TmuxFailure.commandFailed(exitCode:output.exitCode, stderr:String(decoding:output.stderr,as:UTF8.self))
        }
        guard case .exit=output.termination else { throw TmuxFailure.commandFailed(exitCode:output.exitCode,stderr:String(decoding:output.stderr,as:UTF8.self)) }
        guard let before, let after, before == after else { throw TmuxFailure.endpointChanged }
        let raw=try TmuxParser.parse(output.stdout)
        let identity=ServerIdentity(canonicalSocketPath:canonical.path,socketDevice:before.device,socketInode:before.inode,serverPID:raw.boundary.serverPID,startedAtUnixSeconds:raw.boundary.startedAtUnixSeconds)
        return try raw.bind(server:identity)
    }
    private func canonicalSocket(_ url:URL)->URL { let parent=URL(fileURLWithPath:canonicalExistingPath(url.deletingLastPathComponent().path),isDirectory:true); return parent.appending(path:url.lastPathComponent).standardizedFileURL }
    private struct Endpoint:Equatable { let device:UInt64; let inode:UInt64 }
    private func endpoint(_ url:URL)throws->Endpoint? { var s=stat(); if lstat(url.path,&s)==0 { guard (s.st_mode & S_IFMT) == S_IFSOCK else { throw TmuxFailure.endpointChanged }; return Endpoint(device:UInt64(s.st_dev),inode:UInt64(s.st_ino)) }; if errno==ENOENT || errno==ENOTDIR{return nil}; if errno==EACCES{throw TmuxFailure.endpointPermissionDenied}; throw TmuxFailure.launchFailed(String(cString:strerror(errno))) }
    private func expectedNoServer(_ data:Data,path:String)->Bool {
        var diagnostic=String(decoding:data,as:UTF8.self)
        if diagnostic.hasSuffix("\n") { diagnostic.removeLast() }
        return diagnostic == "no server running on \(path)" || diagnostic == "error connecting to \(path) (No such file or directory)" || diagnostic == "error connecting to \(path) (Connection refused)"
    }
}

private func canonicalExistingPath(_ path:String)->String { guard let pointer=realpath(path,nil) else { return URL(fileURLWithPath:path).standardizedFileURL.path }; defer{free(pointer)}; return String(cString:pointer) }
