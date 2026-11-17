import Foundation

// MARK: - Scan deltas ("New" / "was <Action>" chips)
//
// The board is amnesiac between scans by default — nothing marks an idea as new or
// flipped. This module answers "what changed since the last FULL scan" from a tiny
// persisted baseline: symbol → its previous action label. v1 is deliberately narrow —
// see PLAN_2026-07-07_scan_deltas.md — rank-move chips are EXCLUDED (the stored ranking
// order is not necessarily what the user sees under IdeaSort's 6 modes; a movement claim
// that silently references a different order than the visible one fails the honesty
// floor). Pure engine (`deltas`) + a persisted @MainActor store, same shape as
// StockSageVelocityHistory.swift.

/// What changed for one symbol vs the previous full scan.
enum ScanDelta: Sendable, Equatable {
    case new                                  // absent from the previous scan
    case actionChanged(previous: String)      // present, but the action label differs
}

enum StockSageScanDelta {
    /// Pure delta computation: current ideas vs the previous scan's symbol→action map.
    /// Case-insensitive symbol match (StockSageIdea.symbol casing is not guaranteed
    /// consistent with a persisted baseline written from a different session).
    /// `previous` empty ⇒ empty result — the first-run honesty rule: absence of a
    /// baseline renders nothing, never "everything is new".
    nonisolated static func deltas(current: [StockSageIdea], previous: [String: String]) -> [String: ScanDelta] {
        guard !previous.isEmpty else { return [:] }
        let prevByUpper = Dictionary(uniqueKeysWithValues: previous.map { ($0.key.uppercased(), $0.value) })
        var out: [String: ScanDelta] = [:]
        for idea in current {
            let sym = idea.symbol.uppercased()
            guard let prevAction = prevByUpper[sym] else { out[idea.symbol] = .new; continue }
            let curAction = idea.advice.action.rawValue
            if prevAction != curAction { out[idea.symbol] = .actionChanged(previous: prevAction) }
        }
        return out
    }

    /// DEG-01: build the NEXT baseline to persist after a full scan. Starts from `ranked`
    /// (this scan's freshly-priced results), then CARRIES FORWARD the `previous` baseline's
    /// entry for any symbol in `missingButTracked` (still on the board, just not priced this
    /// scan — feed miss/429). Without this, a merely-throttled symbol drops out of the
    /// baseline and the NEXT healthy scan renders a false "New" chip for a name that was
    /// never actually new. Case-insensitive lookup into `previous`, same convention as
    /// `deltas` above; keys written back to the baseline use `ranked`'s original casing
    /// (unaffected — carried-forward symbols come from `missingButTracked`, original casing
    /// from the universe list).
    nonisolated static func nextBaseline(ranked: [StockSageIdea], missingButTracked: [String],
                                         previous: [String: String]) -> [String: String] {
        var out = Dictionary(uniqueKeysWithValues: ranked.map { ($0.symbol, $0.advice.action.rawValue) })
        let prevByUpper = Dictionary(uniqueKeysWithValues: previous.map { ($0.key.uppercased(), $0.value) })
        for sym in missingButTracked {
            if let prevAction = prevByUpper[sym.uppercased()] { out[sym] = prevAction }
        }
        return out
    }
}

/// Persisted "previous full scan" baseline (UserDefaults JSON) — symbol → action label.
/// Schema-versioned so a future incompatible shape degrades to "no baseline" (nothing
/// renders) rather than misreading old data as something it isn't.
struct ScanSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let scanDate: Date
    let entries: [String: String]   // symbol → TradeAdvice.Action.rawValue
}

/// Persisted previous-scan baseline. WRITTEN ONLY by StockSageStore.performRefreshIdeas,
/// at the end of a successful FULL commit, with the PRE-refresh map (so the just-computed
/// deltas describe "vs what was on screen a moment ago", then the new scan becomes the
/// next baseline). retryFailedIdeas (partial merge) and seedQAIdeas (QA fixture seed) must
/// NEVER call `save` — see their doc comments in StockSageStore.swift.
// ponytail: plain @MainActor class, not ObservableObject — nothing observes this store
// directly (StockSageStore.scanDeltas is the @Published surface Views read).
@MainActor
final class StockSageScanSnapshotStore {
    static let shared = StockSageScanSnapshotStore()
    private let key = "stocksage.prevscan.v1"
    private let defaults: UserDefaults

    /// Injectable for test isolation (mirrors StockSagePaperTradeStore's pattern) — never
    /// share a UserDefaults key across parallel tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The current baseline map (symbol → previous action label). Empty when no scan has
    /// ever completed, or the persisted schema doesn't match — both read as "no deltas".
    private(set) var entries: [String: String] = [:]

    /// Persist `entries` as the next baseline. Called by performRefreshIdeas only.
    func save(entries: [String: String], scanDate: Date = Date()) {
        self.entries = entries
        let snapshot = ScanSnapshot(schemaVersion: Self.schemaVersionForSave, scanDate: scanDate, entries: entries)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }
    private static let schemaVersionForSave = ScanSnapshot.currentSchemaVersion

    /// QA-only in-memory seed: assigns `entries` directly, bypassing `save()` so the real
    /// `stocksage.prevscan.v1` key is never touched (same seam shape as
    /// StockSagePortfolio.qaSeed / StockSageJournalStore.qaSeed). Reachable ONLY from the
    /// --qa capture path — never a normal launch.
    func qaSeed(_ seeded: [String: String]) {
        entries = seeded
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ScanSnapshot.self, from: data),
              decoded.schemaVersion == Self.schemaVersionForSave else { return }   // absent/mismatched ⇒ no baseline
        entries = decoded.entries
    }
}
