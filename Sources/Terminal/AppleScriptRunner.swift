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

public protocol AppleScriptRunning: Sendable {
    func execute(source: String) async -> AppleScriptExecution
}

public final class FoundationAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tellang.tmuxrooms.applescript-smoke")

    public init() {}

    public func execute(source: String) async -> AppleScriptExecution {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(number: nil, message: "Unable to compile AppleScript"))
                    return
                }
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                    let message = error[NSAppleScript.errorMessage] as? String
                    continuation.resume(returning: .failure(number: number, message: message))
                    return
                }
                guard let value = Self.decode(descriptor) else {
                    continuation.resume(returning: .failure(number: nil, message: "Unsupported AppleScript descriptor"))
                    return
                }
                continuation.resume(returning: .success(value))
            }
        }
    }

    private static func decode(_ descriptor: NSAppleEventDescriptor) -> AppleScriptValue? {
        switch descriptor.descriptorType {
        case typeNull:
            return .null
        case typeUnicodeText, typeUTF8Text, typeCString, typeChar:
            return descriptor.stringValue.map(AppleScriptValue.string)
        case typeSInt16, typeSInt32, typeUInt32, typeSInt64, typeUInt64:
            return .integer(Int(descriptor.int32Value))
        case typeBoolean, typeTrue, typeFalse:
            return .boolean(descriptor.booleanValue)
        case typeAEList:
            var values: [AppleScriptValue] = []
            for index in 1...descriptor.numberOfItems {
                guard let item = descriptor.atIndex(index), let value = decode(item) else { return nil }
                values.append(value)
            }
            return .list(values)
        default:
            return nil
        }
    }
}
