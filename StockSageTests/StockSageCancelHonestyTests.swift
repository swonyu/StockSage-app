import Testing
import Foundation
@testable import StockSage

// MARK: - cancelledScanCommit — the reduced, honest commit a cancelled scan runs when at least
// one chunk already published (post-ship critique fleet, orchestrator-confirmed cluster).
// Mirrors StockSageIdeasMissingTests' hand-derived-fixture idiom; this helper wraps
// missingAfterScan (already covered there) plus the nil-when-nothing-published / always-empty-
// deltas rules that are NEW behavior for this fix.

struct StockSageCancelHonestyTests {

    @Test func nothingPublishedIsATrueNoOp() {
        // Cancel landed before chunk 0 ever merged into the board (e.g. the pre-loop
        // `guard !Task.isCancelled` at the benchmark-fetch await) — publishedBoardSymbols is
        // empty. The caller must leave ideasMissing/scanDeltas exactly as they were; this helper
        // signals that with nil rather than returning an "everything is missing" commit that
        // would overwrite a perfectly good PRIOR board's honest state with a worse one.
        let commit = StockSageStore.cancelledScanCommit(
            universe: ["AAPL", "MSFT"],
            publishedBoardSymbols: [],
            stillTracked: ["AAPL", "MSFT"])
        #expect(commit == nil)
    }

    @Test func onePublishedChunkNamesTheUnscannedRemainder() {
        // By hand: universe has 4 attempted-this-scan symbols. Only AAPL made it onto the board
        // (chunk 0 published, chunk 1 never ran before cancel). MSFT and nvda (case-insensitive)
        // are tracked but unscanned → MISSING. ^GSPC is an index → never missing (mirrors
        // missingAfterScan's asset-class exclusion, StockSageIdeasMissingTests).
        let commit = StockSageStore.cancelledScanCommit(
            universe: ["AAPL", "MSFT", "^GSPC", "nvda"],
            publishedBoardSymbols: ["AAPL"],
            stillTracked: ["AAPL", "MSFT", "^GSPC", "NVDA"])
        #expect(commit != nil)
        #expect(commit?.ideasMissing == ["MSFT", "nvda"])
        // Deltas describe the OLD baseline against a board that just changed shape mid-scan —
        // an empty dict is the honest "nothing to compare" state, never a stale claim.
        #expect(commit?.scanDeltas.isEmpty == true)
    }

    @Test func symbolRemovedMidScanIsDroppedNotBannered() {
        // GONE was removed (removeSymbol) during the cancelled scan's own await — it is absent
        // from stillTracked, so it must NOT show up as "couldn't be fetched" (same stillTracked
        // reconcile rule the normal scan-end commit and missingAfterScan already apply).
        let commit = StockSageStore.cancelledScanCommit(
            universe: ["AAPL", "GONE"],
            publishedBoardSymbols: [],   // still triggers the has-published check via a second call below
            stillTracked: ["AAPL"])
        // publishedBoardSymbols empty here only to prove the nil-path is independent of stillTracked
        // filtering; the real "GONE dropped" assertion is the non-empty-publish variant below.
        #expect(commit == nil)

        let published = StockSageStore.cancelledScanCommit(
            universe: ["AAPL", "GONE"],
            publishedBoardSymbols: ["AAPL"],
            stillTracked: ["AAPL"])
        #expect(published?.ideasMissing == [])
        #expect(!(published?.ideasMissing.contains("GONE") ?? true))
    }

    @Test func everyAttemptedSymbolPublishedLeavesNothingMissing() {
        // Cancel landed exactly at chunk-boundary AFTER the last chunk merged (e.g. the watchdog
        // fired on trailing cleanup work) — every universe symbol is already on the board.
        // ideasMissing must come back empty, not a stale non-empty list.
        let commit = StockSageStore.cancelledScanCommit(
            universe: ["AAPL", "MSFT"],
            publishedBoardSymbols: ["AAPL", "MSFT"],
            stillTracked: ["AAPL", "MSFT"])
        #expect(commit?.ideasMissing == [])
        #expect(commit?.scanDeltas.isEmpty == true)
    }
}

// MARK: - cancelSaveDecision — the non-destructive CANCEL-01 fix (round-2, 2026-07-08). Pins the
// invariant a naive "always save scan.accumulatedHistories" hoist violated: `HistoryCache.save()`
// atomically REPLACES the whole on-disk file, so a cancel after chunk 0 of a midday re-scan must
// never overwrite a same-day-fresh ~2,420-entry cache with a ~250-entry partial. Fixtures are
// hand-derived symbol SETS (contents of the histories are irrelevant to the decision — only
// which symbols are present and which day the prior cache was saved on).

struct StockSageCancelSaveDecisionTests {

    /// One-bar placeholder history — `cancelSaveDecision` never reads bar contents, only keys.
    private func h(_ symbol: String) -> StockSagePriceHistory {
        StockSagePriceHistory(symbol: symbol, dates: [Date(timeIntervalSince1970: 0)],
                              opens: [1], highs: [1], lows: [1], closes: [1], volumes: [1])
    }

    private let today = 20_000       // utcDayKey(now) for every case below
    private let yesterday = 19_999

    @Test func sameDayCancelMergesOverThePriorCacheNeverShrinkingIt() {
        // Prior cache saved TODAY has 3 symbols; cancel only re-fetched 1 (chunk 0 of a bigger
        // re-scan). By hand: same-day ⇒ merge branch fires ⇒ result is prior ∪ accumulated,
        // accumulated's value winning on overlap (AAPL is in both — `new` must survive).
        let prior = ["AAPL": h("stale-AAPL"), "MSFT": h("MSFT"), "GOOGL": h("GOOGL")]
        let accumulated = ["AAPL": h("fresh-AAPL")]
        let result = StockSageStore.cancelSaveDecision(
            priorCacheSymbols: Set(prior.keys), priorCacheSavedAtDayKey: today,
            accumulated: accumulated, priorCacheHistories: prior, nowDayKey: today)
        #expect(result != nil)
        #expect(Set((result ?? [:]).keys) == ["AAPL", "MSFT", "GOOGL"])   // MSFT/GOOGL NOT shrunk away
        #expect(result?["AAPL"]?.symbol == "fresh-AAPL")                // accumulated wins on overlap
    }

    @Test func crossDaySupersetSavesTheAccumulatedSetAlone() {
        // Prior cache is from YESTERDAY (2 symbols); accumulated this cancelled scan is a
        // superset (all of yesterday's symbols plus a new one) — safe to save alone under an
        // honest `savedAt: now` stamp, since nothing carried-forward-but-unfetched is lost.
        let prior = ["AAPL": h("AAPL"), "MSFT": h("MSFT")]
        let accumulated = ["AAPL": h("AAPL"), "MSFT": h("MSFT"), "GOOGL": h("GOOGL")]
        let result = StockSageStore.cancelSaveDecision(
            priorCacheSymbols: Set(prior.keys), priorCacheSavedAtDayKey: yesterday,
            accumulated: accumulated, priorCacheHistories: prior, nowDayKey: today)
        #expect(result != nil)
        #expect(Set((result ?? [:]).keys) == ["AAPL", "MSFT", "GOOGL"])
    }

    @Test func crossDayNonSupersetSkipsTheSaveEntirely() {
        // Prior cache is from YESTERDAY (3 symbols); accumulated this cancelled scan covers only
        // 1 of them (chunk 0 of a bigger re-scan, cancelled early) — NOT a superset, and none of
        // yesterday's entries can be honestly re-stamped `savedAt: now` (they weren't re-fetched
        // today). Saving accumulated alone would shrink 3→1; saving a merge would lie about
        // freshness. The only non-destructive, non-dishonest move is: skip (pre-fix behavior).
        let prior = ["AAPL": h("AAPL"), "MSFT": h("MSFT"), "GOOGL": h("GOOGL")]
        let accumulated = ["AAPL": h("AAPL")]
        let result = StockSageStore.cancelSaveDecision(
            priorCacheSymbols: Set(prior.keys), priorCacheSavedAtDayKey: yesterday,
            accumulated: accumulated, priorCacheHistories: prior, nowDayKey: today)
        #expect(result == nil)
    }

    @Test func nilPriorCacheAlwaysSavesTheAccumulatedSet() {
        // No cache on disk yet (first scan of the day / fresh install) — nothing to shrink, so
        // the accumulated set (however partial) is always safe to save. `priorCacheSavedAtDayKey`
        // nil mirrors `cache.map { ... }` on a nil `cache` at the real call site.
        let accumulated = ["AAPL": h("AAPL")]
        let result = StockSageStore.cancelSaveDecision(
            priorCacheSymbols: [], priorCacheSavedAtDayKey: nil,
            accumulated: accumulated, priorCacheHistories: [:], nowDayKey: today)
        #expect(result != nil)
        #expect(Set((result ?? [:]).keys) == ["AAPL"])
    }

    @Test func emptyAccumulatedNeverTriggersASave() {
        // A cancel before chunk 0 ever merged (accumulatedHistories empty) must not trigger the
        // detached save Task at all — nil signals "nothing to save", not "save an empty file".
        let result = StockSageStore.cancelSaveDecision(
            priorCacheSymbols: ["AAPL"], priorCacheSavedAtDayKey: today,
            accumulated: [:], priorCacheHistories: ["AAPL": h("AAPL")], nowDayKey: today)
        #expect(result == nil)
    }
}
