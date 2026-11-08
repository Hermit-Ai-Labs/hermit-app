/// Words that depend on the device, so copy says "this Mac" and "Touch ID" on a Mac and "this phone" and "Face ID" on an iPhone.
enum Device {
    #if os(macOS)
    static let here = "this Mac"
    static let bio = "Touch ID"
    static let unlock = "Touch ID or your password"
    static let symbol = "laptopcomputer"
    static let offlineTip = "Works offline. Turning off Wi-Fi adds peace of mind."
    #else
    static let here = "this phone"
    static let bio = "Face ID"
    static let unlock = "Face ID or your passcode"
    static let symbol = "iphone"
    static let offlineTip = "Works offline. Airplane Mode adds peace of mind."
    #endif
}
