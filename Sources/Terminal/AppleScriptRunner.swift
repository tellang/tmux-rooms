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

    public func execute(source: String) async -> AppleScriptExecution {
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
