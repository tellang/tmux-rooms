import Darwin
import Foundation

/// Reads state files that another program, or a cloned repository, controls.
///
/// A FIFO would block the refresh, a symlink to `/dev/zero` would never end, and
/// a runaway file would fill memory. So the final path component is never
/// followed, opening never waits for a writer, and only a regular file is read.
public enum BoundedFileReader {
    /// The cap for one JSON state file, such as a registry entry.
    public static let jsonStateLimit = 1_048_576
    /// The cap for Codex's append-only `session_index.jsonl`.
    public static let sessionIndexLimit = 8_388_608

    /// An open regular file and the size `fstat` reported for it.
    struct OpenFile {
        let handle: FileHandle
        let size: UInt64
    }

    /// Opens `url` for reading, or returns `nil` for anything but a regular file.
    static func open(_ url: URL) -> OpenFile? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            close(descriptor)
            return nil
        }
        return OpenFile(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), size: UInt64(info.st_size))
    }

    /// The whole file, or `nil` when it is not a regular file or exceeds `limit`.
    public static func read(_ url: URL, limit: Int) -> Data? {
        guard let file = open(url), file.size <= UInt64(limit) else { return nil }
        defer { try? file.handle.close() }
        // The size can grow between fstat and read, so the cap is enforced again.
        guard let data = try? file.handle.read(upToCount: limit + 1) else { return file.size == 0 ? Data() : nil }
        return data.count <= limit ? data : nil
    }
}
