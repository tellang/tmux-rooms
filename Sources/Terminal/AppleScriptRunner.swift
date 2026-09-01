import Foundation

public indirect enum AppleScriptValue: Sendable, Equatable, Codable {
    case null
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case list([AppleScriptValue])
}

public enum AppleScriptExecution: Sendable, Equatable {
    case success(AppleScriptValue)
    case failure(number: Int?, message: String?)
}

@MainActor
public protocol AppleScriptRunning: Sendable {
    func execute(source: String) async -> AppleScriptExecution
}

@MainActor
public final class FoundationAppleScriptRunner: AppleScriptRunning {
    public init() {}

    /// Apple Events run on the main thread by contract, so every one of them is
    /// a frozen window for its duration. The slow ones are recorded because a
    /// user who reports "it hangs for a second" has no other way to point at
    /// which round trip did it.
    public func execute(source: String) async -> AppleScriptExecution {
        let started = ContinuousClock.now
        let result = perform(source: source)
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        if milliseconds >= 100 {
            RoomsLog.terminal.notice(
                "applescript.slow trace=\(ActionTrace.currentID, privacy: .public) ms=\(milliseconds, privacy: .public) script=\(Self.label(for: source), privacy: .public)"
            )
        }
        return result
    }

    /// Names the round trip without logging the script or anything it carries.
    private static func label(for source: String) -> String {
        if source.contains("create window") { return "create" }
        if source.contains("launch API script") { return "title-launch" }
        if source.contains("user.tmuxRoomsTitleApplied") { return "title-status" }
        if source.contains("exactMatches") { return "focus" }
        if source.contains("user.tmuxRoomsNonce") { return "enumerate-managed" }
        if source.contains("return {version") { return "enumerate" }
        return "other"
    }

    private func perform(source: String) -> AppleScriptExecution {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(number: nil, message: "Unable to compile AppleScript")
        }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let message = error[NSAppleScript.errorMessage] as? String
            return .failure(number: number, message: message)
        }
        guard let value = Self.decode(descriptor) else {
            return .failure(number: nil, message: "Unsupported AppleScript descriptor")
        }
        return .success(value)
    }

    static func decode(_ descriptor: NSAppleEventDescriptor) -> AppleScriptValue? {
        switch descriptor.descriptorType {
        case typeNull:
            return .null
        case typeUnicodeText, typeUTF8Text, typeCString, typeChar:
            return descriptor.stringValue.map(AppleScriptValue.string)
        case typeSInt16:
            return decodeInteger(descriptor, as: Int16.self).map { .integer(Int($0)) }
        case typeSInt32:
            return decodeInteger(descriptor, as: Int32.self).map { .integer(Int($0)) }
        case typeUInt32:
            return decodeInteger(descriptor, as: UInt32.self).map { .integer(Int($0)) }
        case typeSInt64:
            return decodeInteger(descriptor, as: Int64.self).flatMap { Int(exactly: $0).map(AppleScriptValue.integer) }
        case typeUInt64:
            return decodeInteger(descriptor, as: UInt64.self).flatMap { Int(exactly: $0).map(AppleScriptValue.integer) }
        case typeBoolean, typeTrue, typeFalse:
            return .boolean(descriptor.booleanValue)
        case typeAEList:
            var values: [AppleScriptValue] = []
            if descriptor.numberOfItems > 0 {
                for index in 1...descriptor.numberOfItems {
                    guard let item = descriptor.atIndex(index), let value = decode(item) else { return nil }
                    values.append(value)
                }
            }
            return .list(values)
        default:
            return nil
        }
    }

    private static func decodeInteger<T>(_ descriptor: NSAppleEventDescriptor, as type: T.Type) -> T? {
        let data = descriptor.data
        guard data.count == MemoryLayout<T>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
