import Foundation

public struct InvalidJSONValue: LocalizedError {
    public var errorDescription: String? { "Couldn't encode the request." }
}

public extension JSONSerialization {
    /// `data(withJSONObject:)` raises an Objective-C exception on a value it can't write (a nil inside `Any`, a Swift
    /// struct, NaN), which `try` and `try?` don't catch: the app just dies. This checks first and throws instead.
    static func safeData(withJSONObject obj: Any, options: WritingOptions = []) throws -> Data {
        guard isValidJSONObject(obj) else { throw InvalidJSONValue() }
        return try data(withJSONObject: obj, options: options)
    }
}
