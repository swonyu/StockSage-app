import Combine
import Foundation
import SwiftUI

// MARK: - AppSettings (standalone StockSage app)
//
// A minimal, self-contained settings object for the standalone StockSage / Markets app.
// In the parent "Salehman AI" app, AppSettings was a ~200-line shared object spanning the
// LLM brain, voice, agents, etc. The StockSage/Markets subsystem depends on exactly THREE
// of its members — all consumed only by `ToolPolicy` (the web-access gate):
//   • `AppSettings.Keys.webAccess`     — the UserDefaults key for the web-access toggle
//   • `AppSettings.boolDefaultTrue(_:)` — read a Bool that defaults to true when unset
//   • `AppSettings.isOfflineOnly`      — the stronger "no network at all" constraint
//
// This shim reproduces those three BYTE-IDENTICALLY (same keys, same default semantics), so
// ToolPolicy behaves exactly as it did in the parent app. Nothing else from the original
// AppSettings is carried over — the standalone app has no brain/voice/agent surface.
//
// Extracted from Salehman AI @ fc8f383 (2026-07-16).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    /// Web access — the money engine's live quote/history fetches (Yahoo) need this ON.
    /// Defaults ON (like the parent app), persisted under the same UserDefaults key.
    @Published var webAccess: Bool {
        didSet {
            defaults.set(webAccess, forKey: Keys.webAccess)
            if webAccess != oldValue {
                defaults.set(UUID().uuidString, forKey: Keys.policyRevision)
            }
        }
    }
    /// Offline Mode — the stronger constraint: with it ON, no network is attempted at all.
    @Published var offlineOnly: Bool {
        didSet {
            defaults.set(offlineOnly, forKey: Keys.offlineOnly)
            if offlineOnly != oldValue {
                defaults.set(UUID().uuidString, forKey: Keys.policyRevision)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        webAccess = AppSettings.boolDefaultTrue(Keys.webAccess, defaults: defaults)
        offlineOnly = defaults.bool(forKey: Keys.offlineOnly)
    }

    // MARK: - Keys (same string values as the parent app, so existing prefs carry over)
    enum Keys {
        nonisolated static let webAccess = "set_webAccess"
        nonisolated static let offlineOnly = "set_offlineOnly"
        nonisolated static let policyRevision = "set_policyRevision"
    }

    // MARK: - Nonisolated, actor-safe accessors (used by ToolPolicy from off-main contexts)

    /// Read a Bool that DEFAULTS TO TRUE when the key has never been written.
    nonisolated static func boolDefaultTrue(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Opaque identity for native policy edits; reading or loading settings does not create one.
    nonisolated static func policyRevision(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: Keys.policyRevision)
    }

    /// True when Offline Mode is on (defaults OFF).
    nonisolated static var isOfflineOnly: Bool { UserDefaults.standard.bool(forKey: Keys.offlineOnly) }
}
