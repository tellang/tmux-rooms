import Darwin
import Foundation
import SQLite3

public enum AgySummaryStore {
    public static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        if let raw = environment["AGY_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return homeDirectory
            .appending(path: ".gemini", directoryHint: .isDirectory)
            .appending(path: "antigravity-cli", directoryHint: .isDirectory)
    }

    public static func titles(in agyHome: URL) -> [String: String] {
        let dbURL = agyHome.appending(path: "conversation_summaries.db", directoryHint: .notDirectory)
        guard let file = BoundedFileReader.open(dbURL),
              file.size > 0,
              file.size <= UInt64(BoundedFileReader.sessionIndexLimit) else { return [:] }
        try? file.handle.close()

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        let sql = "SELECT conversation_id, title FROM conversation_summaries WHERE title != ''"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var titles: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0),
                  let rawTitle = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: rawID).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let title = TerminalText.sanitized(String(cString: rawTitle)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty else { continue }
            titles[id] = title
        }
        return titles
    }

    public static func optionName(_ value: String) -> String? {
        let trimmed = TerminalText.sanitized(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum AgyPresenceSession {
    static func conversationID(lsofOutput: String, agyHome: URL) -> String? {
        let home = realPath(agyHome.path)
        let presenceRoot = home.hasSuffix("/") ? home + "presence/" : home + "/presence/"
        let presenceDirectory = String(presenceRoot.dropLast())
        var candidates: [(id: String, modified: Date, path: String)] = []

        for line in lsofOutput.split(separator: "\n") where line.first == "n" {
            let path = realPath(String(line.dropFirst()))
            let url = URL(fileURLWithPath: path)
            guard url.path.hasPrefix(presenceRoot),
                  url.deletingLastPathComponent().path == presenceDirectory,
                  url.pathExtension == "lock" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((stem.lowercased(), modified, url.path))
        }

        return candidates.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.path < $1.path
        }.first?.id
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
