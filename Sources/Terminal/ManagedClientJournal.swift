import Darwin
import Foundation

public struct ManagedClientJournal: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Tmux Rooms/ManagedClients", directoryHint: .isDirectory)
    }

    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = ManagedClientJournal.defaultRoot) {
        self.root = root
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder; self.decoder = decoder
    }

    public func write(_ record: ManagedClientRecord) throws {
        guard ManagedNonce.isValid(record.nonce) else { throw ManagedTerminalError.invalidNonce }
        try createPrivateDirectory(recordsDirectory)
        let data = try encoder.encode(record)
        try atomicWrite(data, to: recordURL(record.nonce))
    }

    public func read(nonce: String) throws -> ManagedClientRecord? {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        let url = recordURL(nonce)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ManagedClientRecord.self, from: Data(contentsOf: url))
    }

    public func allRecords() throws -> [ManagedClientRecord] {
        guard FileManager.default.fileExists(atPath: recordsDirectory.path) else { return [] }
        var records: [ManagedClientRecord] = []
        for url in try FileManager.default.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            do { records.append(try decoder.decode(ManagedClientRecord.self, from: Data(contentsOf: url))) }
            catch { throw ManagedTerminalError.corruptRecord(path: url.path) }
        }
        return records
    }

    public func reusableRecords(role: ManagedRole) throws -> [ManagedClientRecord] {
        try allRecords().filter { $0.launchKind == .reusableRole && $0.role == role }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.nonce < rhs.nonce
            }
    }

    public func writeConfiguration(_ configuration: ManagedSupervisorConfiguration) throws {
        guard ManagedNonce.isValid(configuration.nonce) else { throw ManagedTerminalError.invalidNonce }
        try createPrivateDirectory(configurationsDirectory)
        try atomicWrite(try encoder.encode(configuration), to: configurationURL(configuration.nonce))
    }

    /// The helper runs what this file names, so it must be a regular file this
    /// user owns that nobody else can read or write, and never a symlink.
    public func readConfiguration(nonce: String) throws -> ManagedSupervisorConfiguration {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        guard let data = BoundedFileReader.read(configurationURL(nonce), limit: BoundedFileReader.jsonStateLimit, ownerOnly: true) else {
            throw ManagedTerminalError.journal("supervisor configuration is not a private regular file")
        }
        return try decoder.decode(ManagedSupervisorConfiguration.self, from: data)
    }

    public func readHandshake(nonce: String) throws -> ManagedSupervisorHandshake? {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        let url = handshakeURL(nonce)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ManagedSupervisorHandshake.self, from: Data(contentsOf: url))
    }

    public func readResponse(requestID: UUID) throws -> ManagedSupervisorResponse? {
        let url = responsesDirectory.appending(path: "\(requestID.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ManagedSupervisorResponse.self, from: Data(contentsOf: url))
    }

    public func retire(_ record: ManagedClientRecord, finalRequestID: UUID? = nil) throws {
        var urls = [configurationURL(record.nonce), handshakeURL(record.nonce)]
        let requestIDs = [record.requestID, record.pendingSwitch?.requestID, finalRequestID].compactMap { $0 }
        for id in Set(requestIDs) {
            urls.append(requestsDirectory.appending(path: "\(id.uuidString).json"))
            urls.append(responsesDirectory.appending(path: "\(id.uuidString).json"))
        }
        urls.append(recordURL(record.nonce))
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public var requestsDirectory: URL { root.appending(path: "requests", directoryHint: .isDirectory) }
    public var responsesDirectory: URL { root.appending(path: "responses", directoryHint: .isDirectory) }
    private var recordsDirectory: URL { root.appending(path: "records", directoryHint: .isDirectory) }
    private var configurationsDirectory: URL { root.appending(path: "config", directoryHint: .isDirectory) }
    private func recordURL(_ nonce: String) -> URL { recordsDirectory.appending(path: "\(nonce).json") }
    private func configurationURL(_ nonce: String) -> URL { configurationsDirectory.appending(path: "\(nonce).json") }
    public func handshakeURL(_ nonce: String) -> URL { root.appending(path: "handshake-\(nonce).json") }

    public func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try atomicWrite(try encoder.encode(value), to: url) }

    /// The temporary file is created 0600, so the renamed file is never
    /// readable by anyone else, not even for an instant.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try createPrivateDirectory(directory)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedTerminalError.journal("cannot create \(temporary.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw ManagedTerminalError.journal("cannot replace \(url.path): \(reason)")
        }
    }

    /// Journal directories are 0700, including ones an older build created
    /// with the default mode.
    public func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw ManagedTerminalError.journal("cannot restrict \(url.path): \(String(cString: strerror(errno)))") }
    }
}

public enum ManagedNonce {
    public static func generate() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    public static func isValid(_ value: String) -> Bool {
        (20...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains(Character(String($0))) || ("A"..."Z").contains(Character(String($0))) || ("0"..."9").contains(Character(String($0)))
        }
    }
}
