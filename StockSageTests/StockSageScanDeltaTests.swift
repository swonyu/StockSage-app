import Testing
import Foundation
@testable import StockSage

// MARK: - Scan deltas ("New" / "was <Action>") — pure static deltas(), hand-derived
//
// Fixtures hand-derived from PLAN_2026-07-07_scan_deltas.md's prose spec (Delta computation
// section), never from calling the implementation (F40 discipline). See scratchpad
// derive_deltas.md for the derivation notes.

struct StockSageScanDeltaTests {

    private func idea(_ symbol: String, _ action: TradeAdvice.Action) -> StockSageIdea {
        StockSageIdea(
            symbol: symbol, market: symbol, price: 100,
            advice: TradeAdvice(action: action, conviction: 0.5, regime: .range, rationale: [],
                                stopPrice: nil, targetPrice: nil, suggestedWeight: 0.05, caveat: "x"),
            spark: [])
    }

    @Test func newSymbolAbsentFromPreviousIsNew() {
        let current = [idea("AAA", .buy), idea("BBB", .hold)]
        let previous = ["BBB": "Hold"]
        let result = StockSageScanDelta.deltas(current: current, previous: previous)
        #expect(result.count == 1)
        #expect(result["AAA"] == .new)
        #expect(result["BBB"] == nil)   // unchanged -> absent
    }

    @Test func changedActionIsActionChangedWithRightPrevious() {
        let current = [idea("AAPL", .buy)]
        let previous = ["AAPL": "Hold"]
        let result = StockSageScanDelta.deltas(current: current, previous: previous)
        #expect(result["AAPL"] == .actionChanged(previous: "Hold"))
    }

    @Test func unchangedActionIsAbsentFromResult() {
        let current = [idea("NVDA", .strongBuy)]
        let previous = ["NVDA": "Strong Buy"]   // TradeAdvice.Action.strongBuy.rawValue
        let result = StockSageScanDelta.deltas(current: current, previous: previous)
        #expect(result.isEmpty)
    }

    @Test func symbolMatchIsCaseInsensitive() {
        // Same action under a different symbol casing -> unchanged, not new.
        let unchanged = StockSageScanDelta.deltas(current: [idea("btc-usd", .strongBuy)],
                                                   previous: ["BTC-USD": "Strong Buy"])
        #expect(unchanged.isEmpty)

        // Different action under a different symbol casing -> matched, actionChanged (not new).
        let changed = StockSageScanDelta.deltas(current: [idea("btc-usd", .buy)],
                                                 previous: ["BTC-USD": "Strong Buy"])
        #expect(changed["btc-usd"] == .actionChanged(previous: "Strong Buy"))
    }

    @Test func emptyPreviousIsEmptyResultFirstRunRule() {
        let current = [idea("AAA", .buy), idea("BBB", .hold)]
        let result = StockSageScanDelta.deltas(current: current, previous: [:])
        #expect(result.isEmpty)   // absence of baseline renders nothing, never "everything is new"
    }

    // MARK: - DEG-01: carry-forward baseline for missing-but-tracked symbols
    //
    // Hand-derived per DEG-01 (critique fleet #2): baseline {A: Buy, B: Hold}; this scan only
    // priced A (B is missing-but-tracked — feed miss/429). Without carry-forward, B silently
    // drops from the next baseline, so a later scan that prices B again (unchanged, still
    // Hold) sees no previous entry for B and wrongly reports "New" — B was never new, it was
    // merely throttled once. Expected: nextBaseline == {A: "Buy", B: "Hold"} (B's PRIOR entry
    // carried forward unchanged, not overwritten and not dropped).

    @Test func missingButTrackedSymbolCarriesForwardPriorBaseline() {
        let previous = ["A": "Buy", "B": "Hold"]
        let ranked = [idea("A", .buy)]              // B missing this scan (429/feed miss)
        let missing = ["B"]                          // still tracked, just unpriced
        let next = StockSageScanDelta.nextBaseline(ranked: ranked, missingButTracked: missing, previous: previous)
        #expect(next == ["A": "Buy", "B": "Hold"])   // B retained from prior baseline, unchanged

        // Follow-up scan: B reappears unchanged (still Hold) — must NOT be flagged "New",
        // because the carried-forward baseline already knew about it.
        let followUpCurrent = [idea("A", .buy), idea("B", .hold)]
        let followUpDeltas = StockSageScanDelta.deltas(current: followUpCurrent, previous: next)
        #expect(followUpDeltas["B"] == nil)          // no delta chip — B was never actually new
    }

    @Test func missingButTrackedSymbolWithNoPriorEntryStaysAbsent() {
        // A symbol missing this scan that was NEVER in the previous baseline (e.g. just added
        // to tracking, first scan throttled it) has nothing to carry forward — it simply
        // stays absent from the next baseline, same as before this fix.
        let previous = ["A": "Buy"]
        let ranked = [idea("A", .buy)]
        let missing = ["C"]                           // never seen before, unpriced this scan
        let next = StockSageScanDelta.nextBaseline(ranked: ranked, missingButTracked: missing, previous: previous)
        #expect(next == ["A": "Buy"])                 // C absent, not fabricated as anything
    }

    // MARK: - Chunked-scan shape: delta-baseline computed ONCE over the ACCUMULATED full-scan
    // result (PLAN_2026-07-08_equity2000.md Stage 1 §2 — "scan-end-once semantics"). These
    // pure StockSageScanDelta calls don't know about chunks at all (deltas()/nextBaseline()
    // take one `ranked`/`missing` snapshot) — that IS the invariant: the chunked store must
    // feed them the ACCUMULATED result across every chunk, never call them per chunk. Fixture
    // hand-derived in scratchpad/derive_chunked_deltabaseline.swift, simulating a 2-chunk scan
    // where chunk 1 (A,B) fully prices and chunk 2 (C) times out/misses.

    @Test func chunkedScanDeltaBaselineComputedOnceOverAccumulatedResult() {
        let previous = ["A": "Hold", "B": "Buy", "C": "Sell"]
        // ranked = the ACCUMULATED merge of both chunks (A re-priced Buy, B unchanged Buy);
        // C is absent from `ranked` — it lives only in `missing` (chunk 2's timeout).
        let ranked = [idea("A", .buy), idea("B", .buy)]
        let missing = ["C"]

        // One deltas() call over the accumulated `ranked` — not two per-chunk calls.
        let deltas = StockSageScanDelta.deltas(current: ranked, previous: previous)
        #expect(deltas.count == 1)
        #expect(deltas["A"] == .actionChanged(previous: "Hold"))
        #expect(deltas["B"] == nil)     // unchanged
        #expect(deltas["C"] == nil)     // never entered `current` — deltas() only sees ranked

        // One nextBaseline() call over the accumulated ranked + accumulated missing list.
        let next = StockSageScanDelta.nextBaseline(ranked: ranked, missingButTracked: missing, previous: previous)
        #expect(next == ["A": "Buy", "B": "Buy", "C": "Sell"])   // C carried forward from `previous`, unchanged

        // Follow-up (3rd) scan: C reappears unchanged (still Sell) — must NOT read as "New",
        // proving the once-at-end carry-forward genuinely survived into the persisted baseline.
        let followUpRanked = [idea("A", .buy), idea("B", .buy), idea("C", .sell)]
        let followUpDeltas = StockSageScanDelta.deltas(current: followUpRanked, previous: next)
        #expect(followUpDeltas.isEmpty)
    }
}
