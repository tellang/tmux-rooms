import Foundation

/// Recovers the conversation title Claude Code shows for a session that was
/// never renamed.
///
/// The live registry keeps a generated handle such as `tmux-rooms-4a` for those
/// sessions, which repeats what the room already says. The title Claude Code
/// derives from the conversation is written instead into the session transcript
/// at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, as a record that is
/// appended again every time it changes. Reading the last one recovers the name
/// a person actually sees on that session.
public enum ClaudeConversationTitles {
    /// How much of a transcript's tail is read. Transcripts grow into the
    /// megabytes, and the title is re-appended throughout, so the last stretch
    /// is enough without loading the file.
    static let tailByteCount = 262_144

    public static var defaultProjectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "projects", directoryHint: .isDirectory)
    }

    private struct TitleRecord: Decodable {
        let type: String
        let aiTitle: String?
        let customTitle: String?

        var title: String? { customTitle ?? aiTitle }
    }

    /// The title recorded in a transcript tail, or `nil` when none is present.
    ///
    /// A tail can begin mid-line, so the truncated first line is only ever a
    /// discarded candidate rather than a decoding failure.
    static func title(inTail data: Data) -> String? {
        for line in data.split(separator: 0x0a).reversed() {
            guard let record = try? JSONDecoder().decode(TitleRecord.self, from: Data(line)) else { continue }
            guard record.type == "ai-title" || record.type == "custom-title" else { continue }
            guard let title = record.title.map(TerminalText.sanitized)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    /// Finds the transcript for `sessionID` and reads its title.
    ///
    /// The per-project directory name is a lossy encoding of the working
    /// directory, so the transcript is located by looking for the session's own
    /// file rather than by rebuilding that name.
    public static func title(forSessionID sessionID: String, projectsDirectory: URL = defaultProjectsDirectory) -> String? {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        for project in projects.sorted() {
            let transcript = projectsDirectory.appending(path: project).appending(path: "\(sessionID).jsonl")
            guard FileManager.default.fileExists(atPath: transcript.path) else { continue }
            guard let tail = tail(of: transcript) else { continue }
            if let title = title(inTail: tail) { return title }
        }
        return nil
    }

    private static func tail(of url: URL) -> Data? {
        guard let file = BoundedFileReader.open(url) else { return nil }
        defer { try? file.handle.close() }
        let offset = file.size > UInt64(tailByteCount) ? file.size - UInt64(tailByteCount) : 0
        guard (try? file.handle.seek(toOffset: offset)) != nil else { return nil }
        return try? file.handle.read(upToCount: tailByteCount)
    }
}
