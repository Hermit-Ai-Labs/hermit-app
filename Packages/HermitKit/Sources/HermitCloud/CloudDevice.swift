import Foundation

/// Words that depend on the device, for copy in this module (HermitUI has its own `Device`): "this Mac" on a Mac,
/// "this phone" on an iPhone.
enum CloudDevice {
    #if os(macOS)
    static let here = "this Mac"
    static let noun = "Mac"
    #else
    static let here = "this phone"
    static let noun = "phone"
    #endif
    /// "This Mac" or "This phone", to start a sentence.
    static var capitalHere: String { "T" + here.dropFirst() }
}
