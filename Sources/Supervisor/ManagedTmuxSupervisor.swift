import Darwin
import Foundation

@_silgen_name("fork") private func tmuxRoomsFork() -> pid_t

public struct ManagedSupervisorConfiguration: Sendable, Codable, Equatable {
    public let nonce: String
    public let tmuxExecutablePath: String
    public let destination: SessionToken
    public let readOnly: Bool

    public init(nonce: String, tmuxExecutablePath: String = "/opt/homebrew/bin/tmux", destination: SessionToken, readOnly: Bool) {
        self.nonce = nonce; self.tmuxExecutablePath = tmuxExecutablePath; self.destination = destination; self.readOnly = readOnly
    }
}

public enum ManagedSupervisorAction: Sendable, Codable, Equatable {
    case switchSession(SessionToken, readOnly: Bool)
    case detach
}

public struct ManagedSupervisorRequest: Sendable, Codable, Equatable {
    public let id: UUID
    public let nonce: String
    public let action: ManagedSupervisorAction
    public init(id: UUID = UUID(), nonce: String, action: ManagedSupervisorAction) { self.id = id; self.nonce = nonce; self.action = action }
}

public enum ManagedSupervisorResponseStatus: String, Sendable, Codable, Equatable { case completed, rejected }

public struct ManagedSupervisorResponse: Sendable, Codable, Equatable {
    public let requestID: UUID
    public let status: ManagedSupervisorResponseStatus
    public let childPID: Int32?
    public let message: String?
    public init(requestID: UUID, status: ManagedSupervisorResponseStatus, childPID: Int32?, message: String? = nil) {
        self.requestID = requestID; self.status = status; self.childPID = childPID; self.message = message
    }
}

public struct ManagedSupervisorHandshake: Sendable, Codable, Equatable {
    public let nonce: String
    public let supervisorPID: Int32
    public let childPID: Int32
    public let destination: SessionToken
    public let readOnly: Bool
}

public enum ManagedSupervisorFailure: Error, Sendable, Equatable {
    case invalidNonce
    case staleDestination
    case launchFailed(String)
    case childTerminationTimedOut
    case malformedRequest
}

public struct ManagedSupervisorIO: @unchecked Sendable {
    public let input: FileHandle
    public let output: FileHandle
    public let error: FileHandle
    public init(input: FileHandle, output: FileHandle, error: FileHandle) { self.input = input; self.output = output; self.error = error }
}

public enum ManagedSupervisorCLI {
    public static func parse(arguments: [String]) throws -> String {
        guard arguments.count == 2, arguments[0] == "--supervise", ManagedNonce.isValid(arguments[1]) else { throw ManagedSupervisorFailure.invalidNonce }
        return arguments[1]
    }
}

public final class ManagedTmuxSupervisor: @unchecked Sendable {
    private let journal: ManagedClientJournal
    private let pollInterval: Duration
    private let runner: any TmuxCommandRunning
    private let io: ManagedSupervisorIO?
    private let handshakeWriter: @Sendable (ManagedSupervisorHandshake, URL) throws -> Void
    private var child: Process?
    private var rawChildPID: Int32?
    private var testingPTYMasters: [FileHandle] = []
    private var configuration: ManagedSupervisorConfiguration
    private var stopped = false

    public init(configuration: ManagedSupervisorConfiguration, journal: ManagedClientJournal = .init(), pollInterval: Duration = .milliseconds(50), runner: any TmuxCommandRunning = ProcessTmuxCommandRunner(), io: ManagedSupervisorIO? = nil, handshakeWriter: (@Sendable (ManagedSupervisorHandshake, URL) throws -> Void)? = nil) {
        self.configuration = configuration; self.journal = journal; self.pollInterval = pollInterval; self.runner = runner; self.io = io
        self.handshakeWriter = handshakeWriter ?? { handshake, url in try journal.atomicWrite(handshake, to: url) }
    }

    public func run() async throws {
        try await launch(configuration)
        while !stopped {
            try await processRequests()
            try await Task.sleep(for: pollInterval)
        }
    }

    public func processRequests() async throws {
        try FileManager.default.createDirectory(at: journal.requestsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journal.responsesDirectory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: journal.requestsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in files {
            guard let request = try? decoder.decode(ManagedSupervisorRequest.self, from: Data(contentsOf: file)), request.nonce == configuration.nonce else { continue }
            let responseURL = journal.responsesDirectory.appending(path: "\(request.id.uuidString).json")
            if FileManager.default.fileExists(atPath: responseURL.path) { try? FileManager.default.removeItem(at: file); continue }
            let response = await handle(request)
            try journal.atomicWrite(response, to: responseURL)
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func handle(_ request: ManagedSupervisorRequest) async -> ManagedSupervisorResponse {
        guard request.nonce == configuration.nonce else { return .init(requestID: request.id, status: .rejected, childPID: childPID, message: "nonce mismatch") }
        switch request.action {
        case .detach:
            do { try terminateChild(); stopped = true; return .init(requestID: request.id, status: .completed, childPID: nil) }
            catch { return .init(requestID: request.id, status: .rejected, childPID: childPID, message: String(describing: error)) }
        case let .switchSession(destination, readOnly):
            let next = ManagedSupervisorConfiguration(nonce: configuration.nonce, tmuxExecutablePath: configuration.tmuxExecutablePath, destination: destination, readOnly: readOnly)
            do {
                try await validate(next)
                try terminateChild()
                try await launchValidated(next)
                configuration = next
                return .init(requestID: request.id, status: .completed, childPID: childPID)
            } catch {
                return .init(requestID: request.id, status: .rejected, childPID: childPID, message: String(describing: error))
            }
        }
    }

    public var childPID: Int32? {
        if let child, child.isRunning { return child.processIdentifier }
        if let rawChildPID, rawChildIsRunning(rawChildPID) { return rawChildPID }
        return nil
    }

    private func launch(_ configuration: ManagedSupervisorConfiguration) async throws {
        try await validate(configuration)
        try await launchValidated(configuration)
    }

    private func launchValidated(_ configuration: ManagedSupervisorConfiguration) async throws {
        let launchedPID: Int32
        if let io {
            launchedPID = try spawnWithControllingTTY(executable: configuration.tmuxExecutablePath, arguments: Self.initialAttachArguments(configuration), io: io)
            rawChildPID = launchedPID
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.tmuxExecutablePath)
            process.arguments = Self.initialAttachArguments(configuration)
            process.environment = ProcessInfo.processInfo.environment.merging(["TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"]) { _, new in new }
            do { try process.run() } catch { throw ManagedSupervisorFailure.launchFailed(String(describing: error)) }
            child = process; launchedPID = process.processIdentifier
        }
        let handshake = ManagedSupervisorHandshake(nonce: configuration.nonce, supervisorPID: getpid(), childPID: launchedPID, destination: configuration.destination, readOnly: configuration.readOnly)
        do {
            try handshakeWriter(handshake, journal.handshakeURL(configuration.nonce))
        } catch {
            let handshakeError = error
            try terminateChild()
            throw handshakeError
        }
    }

    private func validate(_ configuration: ManagedSupervisorConfiguration) async throws {
        guard ManagedNonce.isValid(configuration.nonce) else { throw ManagedSupervisorFailure.invalidNonce }
        let token = configuration.destination
        var info = stat()
        guard lstat(token.server.canonicalSocketPath, &info) == 0,
              UInt64(info.st_dev) == token.server.socketDevice,
              UInt64(info.st_ino) == token.server.socketInode else { throw ManagedSupervisorFailure.staleDestination }
        let invocation = TmuxCommandInvocation(executableURL: URL(fileURLWithPath: configuration.tmuxExecutablePath), arguments: ["-S", token.server.canonicalSocketPath, "-f", "/dev/null", "display-message", "-p", "-t", token.sessionID, "#{pid}|#{start_time}|#{session_id}|#{session_created}"], deadline: .seconds(2))
        let output = try await runner.run(invocation)
        guard output.exitCode == 0 else { throw ManagedSupervisorFailure.staleDestination }
        let expected = "\(token.server.serverPID)|\(token.server.startedAtUnixSeconds)|\(token.sessionID)|\(token.createdAtUnixSeconds)"
        guard String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected else { throw ManagedSupervisorFailure.staleDestination }
    }

    private func terminateChild() throws {
        guard let pid = childPID else { self.child = nil; rawChildPID = nil; return }
        if let child, child.isRunning { child.terminate() } else { Darwin.kill(pid, SIGTERM) }
        let soft = ContinuousClock.now.advanced(by: .milliseconds(500))
        while isChildRunning, ContinuousClock.now < soft { usleep(10_000) }
        if isChildRunning { Darwin.kill(pid, SIGKILL) }
        let hard = ContinuousClock.now.advanced(by: .milliseconds(500))
        while isChildRunning, ContinuousClock.now < hard { usleep(10_000) }
        guard !isChildRunning else { throw ManagedSupervisorFailure.childTerminationTimedOut }
        self.child = nil; rawChildPID = nil
        if let master = testingPTYMasters.popLast() { master.readabilityHandler = nil; try? master.close() }
    }

    private var isChildRunning: Bool { childPID != nil }
    private func rawChildIsRunning(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == 0 && Darwin.kill(pid, 0) == 0
    }

    private func spawnWithControllingTTY(executable: String, arguments: [String], io: ManagedSupervisorIO) throws -> Int32 {
        _ = io // Injected I/O selects the isolated test PTY path; production inherits iTerm's TTY.
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw ManagedSupervisorFailure.launchFailed("openpty failed") }
        let pid = tmuxRoomsFork()
        guard pid >= 0 else { throw ManagedSupervisorFailure.launchFailed("fork failed") }
        if pid == 0 {
            close(masterFD)
            _ = setsid()
            _ = ioctl(slaveFD, TIOCSCTTY, 0)
            _ = dup2(slaveFD, STDIN_FILENO)
            _ = dup2(slaveFD, STDOUT_FILENO)
            _ = dup2(slaveFD, STDERR_FILENO)
            if slaveFD > STDERR_FILENO { close(slaveFD) }
            setenv("TERM", "xterm-256color", 1)
            let values = [executable] + arguments
            let pointers = values.map { strdup($0) } + [nil]
            execv(executable, pointers)
            _exit(127)
        }
        close(slaveFD)
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        master.readabilityHandler = { handle in _ = try? handle.read(upToCount: 64 * 1024) }
        testingPTYMasters.append(master)
        return pid
    }

    public static func initialAttachArguments(_ configuration: ManagedSupervisorConfiguration) -> [String] {
        let token = configuration.destination
        let condition = "#{&&:#{==:#{pid},\(token.server.serverPID)},#{==:#{start_time},\(token.server.startedAtUnixSeconds)},#{m:*1*,#{S:#{?#{&&:#{==:#{session_id},\(token.sessionID)},#{==:#{session_created},\(token.createdAtUnixSeconds)}},1,}}}}"
        var attach = "attach-session"
        if configuration.readOnly { attach += " -r" }
        attach += " -t '\(token.sessionID)'"
        return ["-S", token.server.canonicalSocketPath, "-f", "/dev/null", "if-shell", "-F", condition, attach, ""]
    }
}
