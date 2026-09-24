// Mirrors crypto/SecureKeyStore.kt: the secrets (the encryption key, the MQTT and Hub
// passwords, the certificate pins, the signing and routing identities) in the Keychain, as
// Android keeps them in the Keystore. Generic-password items under one service, readable after
// the first unlock and on this device only, so the gateway can use them from the background
// and a backup cannot carry them to another phone.
import Foundation
import MeshSatEngine
import Security

public final class SecureKeyStore: KeyValueStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = MeshSatStore.keychainService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func remove(_ key: String) {
        _ = SecItemDelete(query(key) as CFDictionary)
    }

    public func contains(_ key: String) -> Bool {
        var q = query(key)
        q[kSecReturnData as String] = false
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Every item of this service, for a reset.
    public func removeAll() {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        _ = SecItemDelete(q as CFDictionary)
    }
}
