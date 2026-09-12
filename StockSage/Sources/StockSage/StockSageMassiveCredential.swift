import Foundation
import Security

/// One local, non-synchronizing credential. Injectable operations keep regression tests out of the
/// owner's Keychain; no synchronized item, URL, log, or plaintext preference write.
nonisolated enum StockSageMassiveCredential {
    static func denialUntil(_ gate: String, defaults: UserDefaults) -> Date? {
        guard let record = defaults.dictionary(forKey: gate),
              record["revision"] as? String == (StockSageMassive.credentialRevision(defaults) ?? ""),
              let until = record["until"] as? Date, until.timeIntervalSince1970.isFinite else { return nil }
        return until
    }

    static func recordDenial(_ until: Date, gate: String, revision: String?, defaults: UserDefaults) {
        guard revision == StockSageMassive.credentialRevision(defaults),
              until.timeIntervalSince1970.isFinite else { return }
        defaults.set(["revision": revision ?? "", "until": until], forKey: gate)
    }

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

    /// Called by app startup, not request dispatch. Environment values are never persisted or
    /// fingerprinted; revalidate that fallback on each launch rather than inheriting a denial.
    static func beginLaunch(defaults: UserDefaults, storage: Storage, environment: String?) throws {
        let hasEnvironment = !StockSageMassive.resolvedKey(saved: nil, environment: environment).isEmpty
        do {
            try migrate(defaults: defaults, storage: storage)
            if try saved(defaults: defaults, storage: storage) == nil, hasEnvironment {
                defaults.set(UUID().uuidString, forKey: "stocksage.massive.credentialRevision")
            }
        } catch {
            // A later unlock can expose a different environment fallback. Invalidate ownership
            // now, but never bypass inaccessible secure storage to resolve that fallback.
            if hasEnvironment { defaults.set(UUID().uuidString, forKey: "stocksage.massive.credentialRevision") }
            throw error
        }
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
