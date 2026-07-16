import Foundation

/// Shared lock for any test that reads-under-assertion or mutates the process-global
/// `StockSageAdvisor.turnOfMonthEnabled` (a `nonisolated(unsafe) static var` with no
/// injection seam).
///
/// **Why:** Swift Testing parallelizes tests ACROSS suites by default;
/// `@Suite(.serialized)` only serializes within one suite. `StockSageTomGateTests`
/// briefly flips the flag off (inertness test) while `StockSageExpectedValueTests`'
/// activation-rank test and the TomGate state-pin test assert against it — unguarded,
/// one suite's flag-off window can race the other's assertion (2026-07-09 review
/// finding; the exact failure `ToolPolicyTestLock` documents for the web-gate
/// globals). Acquire before save/mutate, release after restore. Mirrors
/// `ToolPolicyTestLock` / `BrainPreferenceTestLock`.
enum TomFlagTestLock {
    // NSLock is already Sendable, so a plain `static let` suffices.
    static let lock = NSLock()
}
