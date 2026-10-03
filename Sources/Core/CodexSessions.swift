import Foundation

/// Thread names are append-only renames; timestamps do not decide which name
/// the user last chose.
public enum CodexSessionIndex {
    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private struct Entry: Decodable {
        let id: String
        let thread_name: String
    }

    public static func names(fromJSONL data: Data) -> [String: String] {
        var names: [String: String] = [:]
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0a) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)), !entry.id.isEmpty else { continue }
            let name = TerminalText.sanitized(entry.thread_name).trimmingCharacters(in: .whitespacesAndNewlines)
            names[entry.id] = name.isEmpty ? nil : name
        }
        return names
    }

    public static func names(in codexHome: URL) -> [String: String] {
        guard let data = BoundedFileReader.read(codexHome.appending(path: "session_index.jsonl"), limit: BoundedFileReader.sessionIndexLimit) else { return [:] }
        return names(fromJSONL: data)
    }
}

/// Triflux binds a native Codex process to its thread without inspecting its
/// terminal or opening its transcript.
public enum CodexSessionRegistry {
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        let root = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appending(path: ".local/state", directoryHint: .isDirectory)
        return root.appending(path: "triflux/codex-sessions", directoryHint: .isDirectory)
    }

    private struct Payload: Decodable {
        let version: Int
        let writer: String
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let tmux: String?
        let tmuxPane: String?
    }

    public static func record(fromJSON data: Data, names: [String: String]) -> AgentSessionRecord? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1, payload.writer == "triflux", payload.pid > 0,
              let name = names[payload.sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let coordinate = payload.tmux.flatMap(TmuxPaneCoordinate.init)
        guard let paneID = coordinate?.paneID ?? payload.tmuxPane,
              paneID.first == "%", Int(paneID.dropFirst()).map({ $0 >= 0 }) == true else { return nil }
        return AgentSessionRecord(kind: .codex, pid: payload.pid, sessionID: payload.sessionId, name: name, nameIsDerived: false, paneID: paneID, tmuxSessionName: coordinate?.sessionName, currentPath: payload.cwd ?? "")
    }

    public static func records(in directory: URL, names: [String: String]) -> [AgentSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.sorted().compactMap { file in
            guard file.hasSuffix(".json"), let data = BoundedFileReader.read(directory.appending(path: file), limit: BoundedFileReader.jsonStateLimit) else { return nil }
            return record(fromJSON: data, names: names)
        }
    }
}

/// An OMX file can be shared by several panes in one checkout, so only its
/// exact pane is eligible. The process table supplies the native Codex pid
/// because OMX's own pid may identify its leader wrapper.
public enum CodexOMXSession {
    private struct Payload: Decodable {
        let native_session_id: String
        let pid: Int32
        let tmux_pane_id: String
        let tmux_session_name: String?
    }

    public static func record(fromJSON data: Data, paneID: String, nativePID: Int32, currentPath: String, names: [String: String], panePID: Int32? = nil, table: ProcessTable? = nil) -> AgentSessionRecord? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.pid > 0, nativePID > 0,
              payload.tmux_pane_id == paneID, let name = names[payload.native_session_id], !name.isEmpty else { return nil }
        if let table, let panePID {
            guard table.contains(payload.pid, inTreeOf: panePID),
                  table.contains(nativePID, inTreeOf: payload.pid) else { return nil }
        } else {
            guard payload.pid == nativePID else { return nil }
        }
        return AgentSessionRecord(kind: .codex, pid: nativePID, sessionID: payload.native_session_id, name: name, nameIsDerived: false, paneID: paneID, tmuxSessionName: payload.tmux_session_name, currentPath: currentPath)
    }

    /// tmux reports an absolute path; anything else would resolve against this
    /// process's own working directory.
    static func ancestorDirectories(currentPath: String, homeDirectory: URL) -> [URL] {
        guard currentPath.hasPrefix("/") else { return [] }
        let home = homeDirectory.standardizedFileURL.path
        var directory = URL(fileURLWithPath: currentPath, isDirectory: true).standardizedFileURL
        guard directory.path == home || directory.path.hasPrefix(home + "/") else { return [] }
        var result: [URL] = []
        while true {
            result.append(directory)
            if directory.path == home { return result }
            directory.deleteLastPathComponent()
        }
    }

    public static func record(for pane: SessionRoom.Pane, nativePID: Int32, names: [String: String], homeDirectory: URL, table: ProcessTable) -> AgentSessionRecord? {
        for directory in ancestorDirectories(currentPath: pane.currentPath, homeDirectory: homeDirectory) {
            let file = directory.appending(path: ".omx/state/session.json")
            guard let data = BoundedFileReader.read(file, limit: BoundedFileReader.jsonStateLimit) else { continue }
            if let record = record(fromJSON: data, paneID: pane.paneID, nativePID: nativePID, currentPath: pane.currentPath, names: names, panePID: pane.panePID, table: table) { return record }
        }
        return nil
    }
}

/// Open rollouts include subagent transcripts. Only a user thread with no
/// parent can supply the pane's name, even if a child file was modified later.
public enum CodexRolloutSession {
    private struct Metadata: Decodable {
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let id: String
            let thread_source: String?
            let parent_thread_id: String?
        }
    }

    static func sessionID(fromFirstLine data: Data) -> String? {
        guard let record = try? JSONDecoder().decode(Metadata.self, from: data), record.type == "session_meta",
              record.payload.thread_source == "user", record.payload.parent_thread_id == nil,
              !record.payload.id.isEmpty else { return nil }
        return record.payload.id
    }

    /// Read only the header, never a growing conversation body.
    private static func firstLine(of url: URL) -> Data? {
        guard let handle = BoundedFileReader.open(url)?.handle else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < 65_536 {
            guard let chunk = try? handle.read(upToCount: 1024), !chunk.isEmpty else { return line }
            if let newline = chunk.firstIndex(of: 0x0a) { line.append(chunk[..<newline]); return line }
            line.append(chunk)
        }
        return nil
    }

    /// Both sides are resolved before the prefix test, so a symlinked Codex home
    /// still matches and a symlink inside it cannot point outside.
    static func sessionID(lsofOutput: String, codexHome: URL) -> String? {
        guard let home = realPath(codexHome.path) else { return nil }
        let root = home + "/sessions/"
        var candidates: [(id: String, modified: Date, path: String)] = []
        for line in lsofOutput.split(separator: "\n") where line.first == "n" {
            guard let path = realPath(String(line.dropFirst())) else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.path.hasPrefix(root), url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let first = firstLine(of: url), let id = sessionID(fromFirstLine: first) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((id, modified, url.path))
        }
        return candidates.sorted { a, b in a.modified != b.modified ? a.modified > b.modified : a.path < b.path }.first?.id
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
