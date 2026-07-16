import Testing
import Foundation
@testable import StockSage

// MARK: - ToolPolicy gate (SECURITY-CRITICAL)
//
// `ToolPolicy` decides whether the assistant gets EXTERNAL/network tools
// (web_search, fetch_url) on top of the always-on local core. It's the gate
// that keeps a local-first session from silently reaching the network, so it
// must behave exactly. These tests pin: (1) the `override` pin wins; (2) with
// no override, the policy follows the user's web-access setting. (The
// model-facing "web tools never offered when off" property is pinned against
// the live tool list in OllamaToolGateTests via `ollamaToolNames`.)
//
// The suite is `.serialized`: it mutates the process-globals `ToolPolicy.override`
// and the `webAccess` UserDefaults key, and Swift Testing runs tests in parallel —
// two of these racing one global would flake. No other suite touches these
// globals, so cross-suite parallelism stays safe. We avoid `==` on the
// `ToolPolicy` enum itself (its Equatable conformance is main-actor-isolated under
// `-default-isolation=MainActor`) and assert through the `nonisolated` surface
// (`isExternalAllowed`).

@Suite(.serialized)
struct ToolPolicyTests {

    /// Run `body` with `ToolPolicy.override` + every UserDefaults key the gate
    /// consults saved & restored. The gate currently reads two keys:
    /// `Keys.webAccess` (the original input) AND `Keys.offlineOnly` (added by
    /// the Offline-mode feature — forces `isExternalAllowed` to false
    /// regardless of override). A persisted `offlineOnly = true` from a prior
    /// run / Settings interaction would otherwise silently sink any
    /// "expected true" assertion. We explicitly set `offlineOnly = false` for
    /// the duration of the test so the override and webAccess paths can be
    /// asserted in isolation.
    private func withCleanPolicy(_ body: () -> Void) {
        // Cross-suite lock: WebToolsOfflineGateTests mutates these same globals in parallel.
        ToolPolicyTestLock.lock.lock()
        defer { ToolPolicyTestLock.lock.unlock() }   // LIFO: unlocks AFTER the restore defer
        let priorOverride = ToolPolicy.override
        let webKey = AppSettings.Keys.webAccess
        let offlineKey = AppSettings.Keys.offlineOnly
        let priorWeb     = UserDefaults.standard.object(forKey: webKey)
        let priorOffline = UserDefaults.standard.object(forKey: offlineKey)
        UserDefaults.standard.set(false, forKey: offlineKey)
        defer {
            ToolPolicy.override = priorOverride
            if let priorWeb     { UserDefaults.standard.set(priorWeb,     forKey: webKey) }
            else                { UserDefaults.standard.removeObject(forKey: webKey) }
            if let priorOffline { UserDefaults.standard.set(priorOffline, forKey: offlineKey) }
            else                { UserDefaults.standard.removeObject(forKey: offlineKey) }
        }
        body()
    }

    @Test func overridePinsTheGate() {
        withCleanPolicy {
            ToolPolicy.override = .localOnly
            #expect(ToolPolicy.isExternalAllowed == false)

            ToolPolicy.override = .allowExternalTools
            #expect(ToolPolicy.isExternalAllowed == true)
        }
    }

    @Test func withoutOverrideTheGateFollowsTheWebAccessSetting() {
        withCleanPolicy {
            ToolPolicy.override = nil
            UserDefaults.standard.set(false, forKey: AppSettings.Keys.webAccess)
            #expect(ToolPolicy.isExternalAllowed == false)

            UserDefaults.standard.set(true, forKey: AppSettings.Keys.webAccess)
            #expect(ToolPolicy.isExternalAllowed == true)
        }
    }

}

// MARK: - ToolPolicy.webToolsDisabledReason — three-branch diagnostic string
//
// Drives the Offline-Mode banner and the "Web access is off" hint in the
// agent tool-loop. Three distinct paths: nil when external is allowed; the
// Offline-Mode-specific message when `isOfflineOnly == true`; the generic
// "web access is off in Settings" message otherwise. Pins both negative
// strings verbatim so a future refactor can't silently swap them.

@Suite(.serialized)
struct WebToolsDisabledReasonTests {

    private func withGateState(offlineOnly: Bool, webAccess: Bool,
                                _ body: () -> Void) {
        ToolPolicyTestLock.lock.lock()
        defer { ToolPolicyTestLock.lock.unlock() }
        let priorOverride = ToolPolicy.override
        let webKey     = AppSettings.Keys.webAccess
        let offlineKey = AppSettings.Keys.offlineOnly
        let priorWeb     = UserDefaults.standard.object(forKey: webKey)
        let priorOffline = UserDefaults.standard.object(forKey: offlineKey)
        defer {
            ToolPolicy.override = priorOverride
            if let priorWeb     { UserDefaults.standard.set(priorWeb,     forKey: webKey) }
            else                { UserDefaults.standard.removeObject(forKey: webKey) }
            if let priorOffline { UserDefaults.standard.set(priorOffline, forKey: offlineKey) }
            else                { UserDefaults.standard.removeObject(forKey: offlineKey) }
        }
        ToolPolicy.override = nil
        UserDefaults.standard.set(webAccess,   forKey: webKey)
        UserDefaults.standard.set(offlineOnly, forKey: offlineKey)
        body()
    }

    @Test func returnsNilWhenExternalIsAllowed() {
        // With web access on and not offline, isExternalAllowed == true → nil.
        withGateState(offlineOnly: false, webAccess: true) {
            #expect(ToolPolicy.webToolsDisabledReason() == nil)
        }
    }

    @Test func returnsOfflineMessageWhenOfflineModeIsOn() {
        // Offline Mode takes priority over the generic "web access off" path.
        withGateState(offlineOnly: true, webAccess: false) {
            let reason = ToolPolicy.webToolsDisabledReason()
            #expect(reason != nil)
            #expect(reason?.contains("Offline Mode") == true,
                    "expected Offline-Mode-specific message, got: \(reason ?? "nil")")
        }
    }

    @Test func returnsWebAccessMessageWhenWebAccessIsOffButNotOffline() {
        // Web access toggled off in Settings (Offline Mode not engaged).
        withGateState(offlineOnly: false, webAccess: false) {
            let reason = ToolPolicy.webToolsDisabledReason()
            #expect(reason != nil)
            #expect(reason?.contains("Web access") == true,
                    "expected generic web-access message, got: \(reason ?? "nil")")
            #expect(reason?.contains("Offline Mode") == false,
                    "offline-mode message must not appear when Offline Mode is off")
        }
    }

    @Test func offlineAndWebOnStillReturnsOfflineMessage() {
        // Edge case: Offline Mode on, webAccess flag also on.
        // isOfflineOnly dominates — isExternalAllowed = false, path = offline.
        withGateState(offlineOnly: true, webAccess: true) {
            let reason = ToolPolicy.webToolsDisabledReason()
            #expect(reason != nil)
            #expect(reason?.contains("Offline Mode") == true)
        }
    }
}
