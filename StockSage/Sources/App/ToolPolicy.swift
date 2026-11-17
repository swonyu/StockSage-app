import Foundation
import Synchronization

/// Controls whether external/non-local tools are allowed.
/// Reads the existing Web access preference; Offline Mode always takes precedence.
///
/// `current` is derived from the user's web-access Settings toggle on each
/// read. Set the override explicitly only to force a mode for testing.
enum ToolPolicy {
    case localOnly
    case allowExternalTools

    /// Mutable override. `nil` (the default) means "read from user settings".
    /// Set to a concrete case to force-pin the policy regardless of settings.
    nonisolated private static let policyOverride = Mutex<ToolPolicy?>(nil)
    nonisolated static var override: ToolPolicy? {
        get { policyOverride.withLock { $0 } }
        set { policyOverride.withLock { $0 = newValue } }
    }

    /// The policy in effect right now. Computed from `override` if set,
    /// otherwise from the user's web-access toggle in Settings.
    nonisolated static var current: ToolPolicy {
        if let override { return override }
        return isWebAccessEnabled ? .allowExternalTools : .localOnly
    }

    // MARK: - Setting accessors (nonisolated, actor-safe)

    nonisolated static var isWebAccessEnabled: Bool {
        AppSettings.boolDefaultTrue(AppSettings.Keys.webAccess)
    }

    // Pre-computed predicate to avoid `==` on `ToolPolicy` from nonisolated
    // contexts (which would drag the main-actor Equatable conformance across
    // the actor boundary — a Swift-6 error).
    nonisolated static var isExternalAllowed: Bool {
        #if os(iOS)
        return false
        #else
        // Offline Mode is the STRONGER constraint: it short-circuits even if
        // the user has `webAccess` on (or a test override pins `.allowExternalTools`).
        // Every network client uses this shared decision before dispatch.
        if AppSettings.isOfflineOnly { return false }
        switch current {
        case .allowExternalTools: return true
        case .localOnly:          return false
        }
        #endif
    }

    /// Returns the user-facing refusal string when network access
    /// are disabled by policy (webAccess off or Offline Mode), or nil when
    /// allowed. Single source of truth for the two reasons + Offline precedence.
    /// Callers should use:
    ///   guard ToolPolicy.isExternalAllowed else { return ToolPolicy.webToolsDisabledReason() ?? "..." }
    /// This keeps the two settings explanations consistent across clients.
    nonisolated static func webToolsDisabledReason() -> String? {
        guard !isExternalAllowed else { return nil }
        #if os(iOS)
        return "This edition works with your local records. Automatic market-data retrieval is unavailable; record a price in Watchlist to update your portfolio."
        #else
        if AppSettings.isOfflineOnly {
            return "Offline Mode is on — web access is disabled."
        } else {
            return "Web access is turned off in Settings."
        }
        #endif
    }
}
