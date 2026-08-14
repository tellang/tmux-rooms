import Foundation
import OSLog
import Security

public enum SmokeStepOutcome: Sendable, Codable, Equatable {
    case success
    case failure(SmokeAutomationError)
}

public struct SmokeStepEvidence: Sendable, Codable, Equatable {
    public let name: String
    public let durationMilliseconds: Int
    public let outcome: SmokeStepOutcome
    public let appleScriptErrorNumber: Int?

    public init(name: String, durationMilliseconds: Int, outcome: SmokeStepOutcome, appleScriptErrorNumber: Int?) {
        self.name = name
        self.durationMilliseconds = durationMilliseconds
        self.outcome = outcome
        self.appleScriptErrorNumber = appleScriptErrorNumber
    }

    func replacingOutcome(_ newOutcome: SmokeStepOutcome) -> Self {
        .init(name: name, durationMilliseconds: durationMilliseconds, outcome: newOutcome, appleScriptErrorNumber: appleScriptErrorNumber)
    }
}

public struct SmokeBundleEvidence: Sendable, Codable, Equatable {
    public let path: String
    public let bundleIdentifier: String?
    public let version: String?
    public let build: String?
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let cdHash: String?

    public init(path: String, bundleIdentifier: String?, version: String?, build: String?, signingIdentifier: String?, teamIdentifier: String?, cdHash: String?) {
        self.path = path; self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
        self.signingIdentifier = signingIdentifier; self.teamIdentifier = teamIdentifier; self.cdHash = cdHash
    }

    public static func current(bundle: Bundle = .main) -> Self {
        var signingIdentifier: String?
        var teamIdentifier: String?
        var cdHash: String?
        var code: SecCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
               let values = information as? [CFString: Any] {
                signingIdentifier = values[kSecCodeInfoIdentifier] as? String
                teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
                if let data = values[kSecCodeInfoUnique] as? Data { cdHash = data.map { String(format: "%02x", $0) }.joined() }
            }
        }
        return .init(path: bundle.bundleURL.resolvingSymlinksInPath().path,
                     bundleIdentifier: bundle.bundleIdentifier,
                     version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                     build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                     signingIdentifier: signingIdentifier, teamIdentifier: teamIdentifier, cdHash: cdHash)
    }
}

public struct SmokeEvidence: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let runID: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let durationMilliseconds: Int
    public let bundle: SmokeBundleEvidence
    public let iTermVersion: String?
    public let before: [ITermSessionReference]
    public let created: ITermSessionReference?
    public let actual: ITermSessionReference?
    public let steps: [SmokeStepEvidence]
    public let finalResult: SmokeFinalResult

    public init(schemaVersion: Int, runID: UUID, startedAt: Date, finishedAt: Date, durationMilliseconds: Int, bundle: SmokeBundleEvidence, iTermVersion: String?, before: [ITermSessionReference], created: ITermSessionReference?, actual: ITermSessionReference?, steps: [SmokeStepEvidence], finalResult: SmokeFinalResult) {
        self.schemaVersion = schemaVersion; self.runID = runID; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds; self.bundle = bundle; self.iTermVersion = iTermVersion
        self.before = before; self.created = created; self.actual = actual; self.steps = steps; self.finalResult = finalResult
    }
}

public extension JSONEncoder {
    static var smoke: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
public extension JSONDecoder {
    static var smoke: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

public protocol SmokeEvidenceWriting: Sendable {
    func write(_ evidence: SmokeEvidence) throws -> URL
}

public struct SmokeEvidenceWriter: SmokeEvidenceWriting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Tmux Rooms/iTerm-automation-smoke", directoryHint: .isDirectory)) {
        self.rootDirectory = rootDirectory
    }

    @discardableResult public func write(_ evidence: SmokeEvidence) throws -> URL {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = rootDirectory.appending(path: "\(evidence.runID.uuidString).json")
        try JSONEncoder.smoke.encode(evidence).write(to: destination, options: [.atomic])
        return destination
    }
}

public enum SmokeCoordinatorResult: Sendable, Equatable {
    case evidenceWritten(URL)
    case evidenceWriteFailed(String)
}

@MainActor
public struct SmokeCoordinator: Sendable {
    private let runner: any AppleScriptRunning
    private let writer: any SmokeEvidenceWriting
    private let bundle: SmokeBundleEvidence
    private let terminate: @Sendable () async -> Void

    public init(runner: any AppleScriptRunning, writer: any SmokeEvidenceWriting = SmokeEvidenceWriter(), bundle: SmokeBundleEvidence = .current(), terminate: @escaping @Sendable () async -> Void) {
        self.runner = runner; self.writer = writer; self.bundle = bundle; self.terminate = terminate
    }

    public func run(runID: UUID) async -> SmokeCoordinatorResult {
        let report = await ITermAutomationSmoke(runner: runner).run()
        let duration = max(0, Int(report.finishedAt.timeIntervalSince(report.startedAt) * 1_000))
        let evidence = SmokeEvidence(schemaVersion: 1, runID: runID, startedAt: report.startedAt, finishedAt: report.finishedAt, durationMilliseconds: duration, bundle: bundle, iTermVersion: report.iTermVersion, before: report.before, created: report.created, actual: report.actual, steps: report.steps, finalResult: report.finalResult)
        let result: SmokeCoordinatorResult
        do {
            result = .evidenceWritten(try writer.write(evidence))
        } catch {
            let message = String(describing: error)
            Logger(subsystem: "com.tellang.tmuxrooms", category: "iTerm-automation-smoke").error("Evidence write failed: \(message, privacy: .public)")
            result = .evidenceWriteFailed(message)
        }
        await terminate()
        return result
    }
}
