import Foundation
import Security

/// One local, non-synchronizing credential. Injectable operations keep regression tests out of the
/// owner's Keychain; no synchronized item, URL, log, or plaintext preference write.
nonisolated enum StockSageMassiveCredential {
    enum Failure: Error { case unavailable, verification }
    struct Storage {
        let read: () throws -> String?
        let write: (String?) throws -> Void
    }

    private static var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "SA.StockSage.Massive",
         kSecAttrAccount as String: "api-key"]
        #if !os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        result[kSecAttrSynchronizable as String] = false
        #endif
        // macOS uses the user's default file-based Keychain and system-created app ACL.
        // Its SecItem API needs no new provisioning; preserve that ACL on updates.
        return result
    }

    static var keychain: Storage {
        Storage(read: {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
            return value
        }, write: { value in
            guard let value else {
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
                return
            }
            var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            #if !os(macOS)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                let item = query.merging(attributes) { _, new in new }
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
            } else if status != errSecSuccess { throw Failure.unavailable }
        })
    }

    static func saved(defaults: UserDefaults, storage: Storage) throws -> String? {
        // A configured Keychain value wins. Read errors fail closed; legacy bytes remain
        // available for migration retry, not as permission to bypass a locked Keychain.
        if let value = try storage.read(), !value.isEmpty { return value }
        let legacy = defaults.string(forKey: StockSageMassive.keyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy.isEmpty ? nil : legacy
    }

    static func resolve(defaults: UserDefaults, storage: Storage, environment: String?) throws -> String {
        StockSageMassive.resolvedKey(saved: try saved(defaults: defaults, storage: storage), environment: environment)
    }

    static func migrate(defaults: UserDefaults, storage: Storage) throws {
        guard let legacy = defaults.string(forKey: StockSageMassive.keyDefaultsKey) else { return }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try storage.read(), !existing.isEmpty {
            // Never overwrite an already configured secure value with an obsolete preference.
        } else if !trimmed.isEmpty {
            try storage.write(trimmed)
            guard try storage.read() == trimmed else { throw Failure.verification }
        }
        defaults.removeObject(forKey: StockSageMassive.keyDefaultsKey)
    }

    @discardableResult static func set(_ value: String, defaults: UserDefaults, storage: Storage) throws -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let desired = trimmed.isEmpty ? nil : trimmed
        let previous = try saved(defaults: defaults, storage: storage)
        let changed = previous != desired
        // A write may take effect even if its verification read fails. Invalidate before
        // attempting it so failed A→B→A saves cannot resurrect old evidence.
        if changed { defaults.set(UUID().uuidString, forKey: "stocksage.massive.credentialRevision") }
        try storage.write(desired)
        guard try storage.read() == desired else { throw Failure.verification }
        defaults.removeObject(forKey: StockSageMassive.keyDefaultsKey)
        return changed
    }
}
