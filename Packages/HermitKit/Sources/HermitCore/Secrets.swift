import Foundation
import Security

/// Small secrets for connectors (exchange API keys, MCP tokens) in the Keychain, this device only, never synced.
public enum Secrets {
    static let service = "my.hermit.connectors"

    /// Saves (or, with nil or "", removes) the secret. False when the Keychain refused: the old value is then still
    /// there (an existing item is updated in place, never deleted first), and the caller says it couldn't save.
    @discardableResult
    public static func set(_ value: String?, for key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let fields: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(base as CFDictionary, fields as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        let add = base.merging(fields) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
