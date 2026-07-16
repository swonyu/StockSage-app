import Foundation

/// Shared lock for any test that mutates the process-globals `ToolPolicy.override`,
/// `AppSettings.Keys.webAccess`, or `AppSettings.Keys.offlineOnly`.
///
/// **Why:** Swift Testing parallelizes tests ACROSS suites by default;
/// `@Suite(.serialized)` only serializes within one suite. `WebToolsOfflineGateTests`
/// and `ToolPolicyTests` both mutate these web-gate globals (which have no injection
/// seam), so they raced each other and `isExternalAllowed` intermittently saw the
/// other suite's pinned `override`/`webAccess`. The `withCleanWebGate` /
/// `withCleanPolicy` helpers acquire this before touching the globals and release it
/// after restoring them. Mirrors `BrainPreferenceTestLock`.
enum ToolPolicyTestLock {
    // NSLock is already Sendable, so a plain `static let` suffices.
    static let lock = NSLock()
}
