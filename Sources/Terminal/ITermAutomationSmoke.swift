import Foundation

public struct ITermSessionReference: Sendable, Codable, Equatable {
    public let windowID: Int
    public let tabIndex: Int
    public let sessionGUID: String
    public let tty: String

    public init(windowID: Int, tabIndex: Int, sessionGUID: String, tty: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.sessionGUID = sessionGUID
        self.tty = tty
    }
}

public enum SmokeAutomationError: Error, Sendable, Codable, Equatable {
    case permissionDenied
    case timeout
    case staleTarget
    case notFound
    case ambiguous
    case invalidReply
    case scriptFailure(number: Int?)
}

public enum SmokeFinalResult: Sendable, Codable, Equatable {
    case success
    case failure(SmokeAutomationError)
}

public enum ReferenceProvenance: Sendable { case created, external }

public struct SmokeRunReport: Sendable, Equatable {
    public let startedAt: Date
    public let finishedAt: Date
    public let iTermVersion: String?
    public let before: [ITermSessionReference]
    public let created: ITermSessionReference?
    public let actual: ITermSessionReference?
    public let steps: [SmokeStepEvidence]
    public let finalResult: SmokeFinalResult
}

public struct ITermAutomationSmoke: Sendable {
    private let runner: any AppleScriptRunning

    public init(runner: any AppleScriptRunning) { self.runner = runner }

    public func run() async -> SmokeRunReport {
        let startedAt = Date()
        var steps: [SmokeStepEvidence] = []
        let enumeration = await execute(name: "enumerate", source: ITermSmokeScripts.enumerate)
        steps.append(enumeration.step)
        guard case let .success(enumerationValue) = enumeration.result,
              let decoded = Self.decodeEnumeration(enumerationValue) else {
            let error = Self.error(from: enumeration.result) ?? .invalidReply
            if Self.error(from: enumeration.result) == nil { steps[steps.count - 1] = enumeration.step.replacingOutcome(.failure(.invalidReply)) }
            return report(startedAt, nil, [], nil, nil, steps, .failure(error))
        }

        let creation = await execute(name: "create", source: ITermSmokeScripts.create)
        steps.append(creation.step)
        guard case let .success(createdValue) = creation.result,
              let created = Self.decodeReference(createdValue) else {
            let error = Self.error(from: creation.result) ?? .invalidReply
            if Self.error(from: creation.result) == nil { steps[steps.count - 1] = creation.step.replacingOutcome(.failure(.invalidReply)) }
            return report(startedAt, decoded.version, decoded.references, nil, nil, steps, .failure(error))
        }

        let focusResult = await focusDetail(reference: created, provenance: .created)
        steps.append(focusResult.step)
        switch focusResult.result {
        case let .success(actual):
            return report(startedAt, decoded.version, decoded.references, created, actual, steps, .success)
        case let .failure(error):
            return report(startedAt, decoded.version, decoded.references, created, nil, steps, .failure(error))
        }
    }

    public func focus(reference: ITermSessionReference, provenance: ReferenceProvenance) async -> Result<ITermSessionReference, SmokeAutomationError> {
        await focusDetail(reference: reference, provenance: provenance).result
    }

    private func focusDetail(reference: ITermSessionReference, provenance: ReferenceProvenance) async -> (result: Result<ITermSessionReference, SmokeAutomationError>, step: SmokeStepEvidence) {
        let source: String
        do { source = try ITermSmokeScripts.focus(reference) }
        catch {
            return (.failure(.invalidReply), SmokeStepEvidence(name: "focus", durationMilliseconds: 0, outcome: .failure(.invalidReply), appleScriptErrorNumber: nil))
        }
        let execution = await execute(name: "focus", source: source)
        switch execution.result {
        case let .failure(number, _):
            return (.failure(Self.map(number)), execution.step)
        case let .success(value):
            guard case let .list(items) = value else { return (.failure(.invalidReply), execution.step.replacingOutcome(.failure(.invalidReply))) }
            if items == [.string("not-found")] {
                let error: SmokeAutomationError = provenance == .created ? .staleTarget : .notFound
                return (.failure(error), execution.step.replacingOutcome(.failure(error)))
            }
            if items == [.string("ambiguous")] { return (.failure(.ambiguous), execution.step.replacingOutcome(.failure(.ambiguous))) }
            guard items.count == 2, let actual = Self.decodeReference(items[0]), items[1] == .boolean(true) else {
                let error: SmokeAutomationError = provenance == .created ? .staleTarget : .invalidReply
                return (.failure(error), execution.step.replacingOutcome(.failure(error)))
            }
            guard actual == reference else {
                let error: SmokeAutomationError = provenance == .created ? .staleTarget : .invalidReply
                return (.failure(error), execution.step.replacingOutcome(.failure(error)))
            }
            return (.success(actual), execution.step)
        }
    }

    private func execute(name: String, source: String) async -> (result: AppleScriptExecution, step: SmokeStepEvidence) {
        let start = ContinuousClock.now
        let result = await runner.execute(source: source)
        let duration = start.duration(to: .now).milliseconds
        switch result {
        case .success:
            return (result, SmokeStepEvidence(name: name, durationMilliseconds: duration, outcome: .success, appleScriptErrorNumber: nil))
        case let .failure(number, _):
            let error = Self.map(number)
            return (result, SmokeStepEvidence(name: name, durationMilliseconds: duration, outcome: .failure(error), appleScriptErrorNumber: number))
        }
    }

    private func report(_ started: Date, _ version: String?, _ before: [ITermSessionReference], _ created: ITermSessionReference?, _ actual: ITermSessionReference?, _ steps: [SmokeStepEvidence], _ result: SmokeFinalResult) -> SmokeRunReport {
        SmokeRunReport(startedAt: started, finishedAt: Date(), iTermVersion: version, before: before, created: created, actual: actual, steps: steps, finalResult: result)
    }

    private static func decodeEnumeration(_ value: AppleScriptValue) -> (version: String, references: [ITermSessionReference])? {
        guard case let .list(items) = value, items.count == 2, case let .string(version) = items[0], case let .list(rows) = items[1] else { return nil }
        let references = rows.compactMap(decodeReference)
        guard references.count == rows.count else { return nil }
        return (version, references)
    }

    fileprivate static func decodeReference(_ value: AppleScriptValue) -> ITermSessionReference? {
        guard case let .list(items) = value, items.count == 4,
              case let .integer(windowID) = items[0], case let .integer(tabIndex) = items[1],
              case let .string(guid) = items[2], case let .string(tty) = items[3],
              windowID > 0, tabIndex > 0, !guid.isEmpty, !tty.isEmpty else { return nil }
        return ITermSessionReference(windowID: windowID, tabIndex: tabIndex, sessionGUID: guid, tty: tty)
    }

    private static func error(from execution: AppleScriptExecution) -> SmokeAutomationError? {
        guard case let .failure(number, _) = execution else { return nil }
        return map(number)
    }

    private static func map(_ number: Int?) -> SmokeAutomationError {
        switch number { case -1743: .permissionDenied; case -1712: .timeout; default: .scriptFailure(number: number) }
    }
}

private extension Duration {
    var milliseconds: Int { Int((components.seconds * 1_000) + (components.attoseconds / 1_000_000_000_000_000)) }
}
