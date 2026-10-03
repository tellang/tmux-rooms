import Darwin
import Foundation
import Testing
@testable import TmuxRoomsCore

private func scratchDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tmr-read-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("a regular file under the cap is read whole")
func boundedReadAcceptsRegularFile() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "state.json")
    try Data("{}".utf8).write(to: file)
    #expect(BoundedFileReader.read(file, limit: 2) == Data("{}".utf8))
    try Data().write(to: file)
    #expect(BoundedFileReader.read(file, limit: 2) == Data())
}

@Test("a FIFO with no writer returns nil at once instead of blocking")
func boundedReadRejectsFIFO() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appending(path: "session.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let start = ContinuousClock.now
    #expect(BoundedFileReader.read(fifo, limit: BoundedFileReader.jsonStateLimit) == nil)
    #expect(ContinuousClock.now - start < .seconds(1))
}

@Test("a file over the cap returns nil")
func boundedReadRejectsOversizeFile() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "session_index.jsonl")
    try Data(repeating: 0x61, count: 1025).write(to: file)
    #expect(BoundedFileReader.read(file, limit: 1024) == nil)
    #expect(BoundedFileReader.read(file, limit: 1025)?.count == 1025)
}

@Test("a symlink as the final path component is refused")
func boundedReadRejectsFinalSymlink() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.json")
    let link = root.appending(path: "link.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(BoundedFileReader.read(link, limit: 1024) == nil)
    try FileManager.default.createSymbolicLink(at: root.appending(path: "zero.json"), withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
    #expect(BoundedFileReader.read(root.appending(path: "zero.json"), limit: 1024) == nil)
}

@Test("a directory is not a readable state file")
func boundedReadRejectsDirectory() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(BoundedFileReader.read(root, limit: 1024) == nil)
}

@Test("a relative pane path yields no ancestors to search")
func relativePanePathHasNoAncestors() {
    let home = URL(fileURLWithPath: "/fixture/home")
    #expect(CodexOMXSession.ancestorDirectories(currentPath: "repo/sub", homeDirectory: home).isEmpty)
    #expect(CodexOMXSession.ancestorDirectories(currentPath: "", homeDirectory: home).isEmpty)
    #expect(CodexOMXSession.ancestorDirectories(currentPath: "/fixture/home/repo", homeDirectory: home).count == 2)
}

@Test("a FIFO in place of a registry file is skipped without blocking the scan")
func registryScanSkipsFIFO() throws {
    let root = try scratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(mkfifo(root.appending(path: "1.json").path, 0o600) == 0)
    let start = ContinuousClock.now
    #expect(ClaudeSessionRegistry.records(in: root, projectsDirectory: nil).isEmpty)
    #expect(CodexSessionRegistry.records(in: root, names: [:]).isEmpty)
    #expect(ContinuousClock.now - start < .seconds(1))
}
