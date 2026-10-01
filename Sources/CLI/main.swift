import Darwin
import Foundation
import TmuxRoomsCore

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    writeError("tmuxrooms: \(message)")
    exit(code)
}

struct Options {
    var here = false
    var json = false
    var readOnly = false
    var text: String?
}

func parseOptions(_ arguments: [String]) -> Options? {
    var options = Options()
    var words: [String] = []
    for argument in arguments {
        switch argument {
        case "--here": options.here = true
        case "--json": options.json = true
        case "-r", "--read-only": options.readOnly = true
        default:
            if argument.hasPrefix("-") { return nil }
            words.append(argument)
        }
    }
    if !words.isEmpty { options.text = words.joined(separator: " ") }
    return options
}

func canonicalCurrentDirectory() -> String {
    let path = FileManager.default.currentDirectoryPath
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func describe(_ failure: TmuxFailure) -> String {
    switch failure {
    case let .commandFailed(exitCode, stderr):
        "tmux exited \(exitCode): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    case .timedOut: "tmux did not answer in time"
    case .launchFailed(let detail): "could not run tmux: \(detail)"
    case .endpointPermissionDenied: "no permission to read the tmux socket"
    case .endpointChanged: "the tmux server changed while it was being read"
    case .unsupportedVersion(let version): "unsupported tmux version \(version)"
    case .malformedOutput, .cancelled, .outputLimitExceeded: "unexpected tmux output (\(failure))"
    }
}

func loadRooms() async -> [CLIRoom] {
    do {
        let socket = try DefaultTmuxEndpointResolver.resolve()
        let snapshot = try await TmuxSnapshotLoader().load(socketURL: socket)
        let presence = await AgentPresenceProbe().presence(for: snapshot.rooms)
        return RoomQuery.rooms(from: snapshot, presence: presence)
    } catch let failure as TmuxFailure {
        fail(describe(failure), code: 3)
    } catch {
        fail("\(error)", code: 3)
    }
}

func emptyMessage(options: Options, directory: String, home: String) -> String {
    var message = "no matching tmux room"
    if options.here { message += " in \(RoomFormat.abbreviate(directory, home: home))" }
    if let text = options.text { message += " for \"\(text)\"" }
    return message
}

func choose(
    from rooms: [CLIRoom], home: String, directory: String, program: String, readOnly: Bool
) -> CLIRoom {
    let initial = RoomQuery.initialCursor(rooms, directory: directory)
    switch RoomChooser.run(rooms: rooms, home: home, initial: initial, program: program, readOnly: readOnly) {
    case .picked(let room):
        return room
    case .cancelled:
        exit(1)
    case .unavailable:
        var lines = ["Rooms:"]
        for (offset, room) in rooms.enumerated() {
            lines.append(RoomFormat.chooserLine(index: offset + 1, room: room, home: home))
        }
        writeError(lines.joined(separator: "\n"))
        fail("several rooms match and there is no terminal to choose in; narrow with <text> or --here", code: 1)
    }
}

func exec(_ path: String, _ arguments: [String]) -> Never {
    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
    argv.append(nil)
    execv(path, argv)
    fail("could not run \(path): \(String(cString: strerror(errno)))", code: 126)
}

let tmuxPath = "/opt/homebrew/bin/tmux"
let home = NSHomeDirectory()
let program = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
var arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "help" || arguments.contains(where: HelpText.isHelpFlag) {
    print(HelpText.full(program: program))
    exit(0)
}

// A bare invocation, or one that starts with an option or search text, is the
// chooser. `ls` and `attach` stay available as explicit words.
var command = "attach"
if let first = arguments.first, ["ls", "list", "attach", "a"].contains(first) {
    command = first
    arguments.removeFirst()
}
guard let options = parseOptions(arguments) else {
    writeError(HelpText.short(program: program))
    exit(2)
}

let directory = canonicalCurrentDirectory()
let scope = options.here ? directory : nil
let rooms = RoomQuery.filter(await loadRooms(), directory: scope, text: options.text)

switch command {
case "ls", "list":
    if options.json {
        print(try RoomFormat.json(rooms))
    } else if rooms.isEmpty {
        fail(emptyMessage(options: options, directory: directory, home: home), code: 1)
    } else {
        let depth = isatty(STDOUT_FILENO) != 0
            ? ColorDepth.detect(environment: ProcessInfo.processInfo.environment)
            : ColorDepth.none
        print(RoomFormat.table(rooms, home: home, depth: depth))
    }

default:
    guard !rooms.isEmpty else {
        fail(emptyMessage(options: options, directory: directory, home: home), code: 1)
    }
    let room = rooms.count == 1
        ? rooms[0]
        : choose(from: rooms, home: home, directory: directory, program: program, readOnly: options.readOnly)
    do {
        let insideTmux = !(ProcessInfo.processInfo.environment["TMUX"] ?? "").isEmpty
        let tmuxArguments = try AttachCommand.arguments(
            sessionID: room.sessionID, readOnly: options.readOnly, insideTmux: insideTmux
        )
        exec(tmuxPath, tmuxArguments)
    } catch {
        fail("read-only attach is not available from inside tmux; detach first or drop -r", code: 2)
    }
}
