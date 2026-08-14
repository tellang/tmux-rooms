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
        try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
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
        return try FileManager.default.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ManagedClientRecord.self, from: Data(contentsOf: $0)) }
    }

    public func reusable(role: ManagedRole) throws -> ManagedClientRecord? {
        try allRecords().filter { $0.launchKind == .reusableRole && $0.role == role }
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func writeConfiguration(_ configuration: ManagedSupervisorConfiguration) throws {
        guard ManagedNonce.isValid(configuration.nonce) else { throw ManagedTerminalError.invalidNonce }
        try FileManager.default.createDirectory(at: configurationsDirectory, withIntermediateDirectories: true)
        try atomicWrite(try encoder.encode(configuration), to: configurationURL(configuration.nonce))
    }

    public func readConfiguration(nonce: String) throws -> ManagedSupervisorConfiguration {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        return try decoder.decode(ManagedSupervisorConfiguration.self, from: Data(contentsOf: configurationURL(nonce)))
    }

    public func readHandshake(nonce: String) throws -> ManagedSupervisorHandshake? {
        guard ManagedNonce.isValid(nonce) else { throw ManagedTerminalError.invalidNonce }
        let url = handshakeURL(nonce)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ManagedSupervisorHandshake.self, from: Data(contentsOf: url))
    }

    public var requestsDirectory: URL { root.appending(path: "requests", directoryHint: .isDirectory) }
    public var responsesDirectory: URL { root.appending(path: "responses", directoryHint: .isDirectory) }
    private var recordsDirectory: URL { root.appending(path: "records", directoryHint: .isDirectory) }
    private var configurationsDirectory: URL { root.appending(path: "config", directoryHint: .isDirectory) }
    private func recordURL(_ nonce: String) -> URL { recordsDirectory.appending(path: "\(nonce).json") }
    private func configurationURL(_ nonce: String) -> URL { configurationsDirectory.appending(path: "\(nonce).json") }
    public func handshakeURL(_ nonce: String) -> URL { root.appending(path: "handshake-\(nonce).json") }

    public func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try atomicWrite(try encoder.encode(value), to: url) }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
