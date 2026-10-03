import Darwin
import Foundation
import Testing
@testable import TmuxRoomsCore

private let token = SessionToken(
    server: ServerIdentity(canonicalSocketPath: "/tmp/journal-security", socketDevice: 1, socketInode: 2, serverPID: 3, startedAtUnixSeconds: 4),
    sessionID: "$1",
    createdAtUnixSeconds: 5
)

private func privateJournal() throws -> (ManagedClientJournal, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "tmux-rooms-journal-\(UUID().uuidString)")
    return (ManagedClientJournal(root: root), root)
}

private func mode(of url: URL) -> mode_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_mode & 0o777
}

@Test("the journal writes configuration files 0600 inside 0700 directories")
func journalWritesPrivateFiles() throws {
    let (journal, root) = try privateJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    try journal.writeConfiguration(.init(nonce: nonce, destination: token, readOnly: false))
    let configuration = root.appending(path: "config/\(nonce).json")
    #expect(mode(of: configuration) == 0o600)
    #expect(mode(of: root.appending(path: "config")) == 0o700)
    #expect(mode(of: root) == 0o700)
    #expect(try journal.readConfiguration(nonce: nonce).destination == token)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "config").path)
    #expect(leftovers == ["\(nonce).json"])
}

@Test("an existing journal directory with a wider mode is narrowed on write")
func journalNarrowsExistingDirectory() throws {
    let (journal, root) = try privateJournal(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try journal.writeConfiguration(.init(nonce: ManagedNonce.generate(), destination: token, readOnly: false))
    #expect(mode(of: root.appending(path: "config")) == 0o700)
}

@Test("a configuration readable by group or others is refused")
func journalRefusesSharedConfiguration() throws {
    let (journal, root) = try privateJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let nonce = ManagedNonce.generate()
    try journal.writeConfiguration(.init(nonce: nonce, destination: token, readOnly: false))
    let configuration = root.appending(path: "config/\(nonce).json")
    for permissions: mode_t in [0o640, 0o604, 0o620, 0o602] {
        #expect(chmod(configuration.path, permissions) == 0)
        #expect(throws: ManagedTerminalError.self) { try journal.readConfiguration(nonce: nonce) }
    }
}

@Test("a configuration that is a symlink or a FIFO is refused")
func journalRefusesSymlinkAndFIFOConfiguration() throws {
    let (journal, root) = try privateJournal(); defer { try? FileManager.default.removeItem(at: root) }
    let real = ManagedNonce.generate()
    try journal.writeConfiguration(.init(nonce: real, destination: token, readOnly: false))
    let linked = ManagedNonce.generate()
    try FileManager.default.createSymbolicLink(at: root.appending(path: "config/\(linked).json"), withDestinationURL: root.appending(path: "config/\(real).json"))
    #expect(throws: ManagedTerminalError.self) { try journal.readConfiguration(nonce: linked) }
    let fifo = ManagedNonce.generate()
    #expect(mkfifo(root.appending(path: "config/\(fifo).json").path, 0o600) == 0)
    #expect(throws: ManagedTerminalError.self) { try journal.readConfiguration(nonce: fifo) }
}

@Test("the helper refuses a tmux executable outside its allow list")
func supervisorRefusesUntrustedExecutable() async throws {
    let (journal, root) = try privateJournal(); defer { try? FileManager.default.removeItem(at: root) }
    for path in ["/bin/sh", "/tmp/tmux", "/opt/homebrew/bin/../bin/tmux", ""] {
        let configuration = ManagedSupervisorConfiguration(nonce: ManagedNonce.generate(), tmuxExecutablePath: path, destination: token, readOnly: false)
        let supervisor = ManagedTmuxSupervisor(configuration: configuration, journal: journal)
        await #expect(throws: ManagedSupervisorFailure.untrustedExecutable) { try await supervisor.run() }
    }
    #expect(ManagedTmuxSupervisor.allowedTmuxExecutables == ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"])
}
