import Testing
@testable import StockSage

// MARK: - newListings badge reconcile (L3-03, 2026-07-07 audit)
//
// `refresh()` was the only writer of StockSageStore.newListings; mergeLiveQuotes(...) and
// addSymbol(...) received LiveQuote data but dropped isNewListing, so in watchlist-only mode
// (refresh paused) the badge could never appear for a genuinely new listing.
//
// The store itself is a private-init @MainActor singleton (StockSageStore.shared) that hits
// UserDefaults.standard and the real network — every existing StockSageStore test in this
// file's neighborhood (StockSageBuildIdeasDirectTests, StockSageIdeasMissingTests,
// StockSageRankScoreTests, StockSageEarningsTests, StockSageStalenessTests) avoids the singleton
// entirely and only exercises `nonisolated static` pure helpers. There is no honest unit seam on
// the instance methods without store surgery, so — matching that established pattern, and the
// same "thin shell over a tested rule" shape StockSageMonitorTests documents for
// shouldPushStrongSignal — the actual reconcile decision was extracted into
// `StockSageStore.reconcileNewListings(current:pricedQuotes:)`, a pure, side-effect-free static
// func that is mergeLiveQuotes's and addSymbol's ONLY source of truth for the flag. This test
// pins that function directly; a vacuous test against the entangled instance methods would
// violate WHIPPYX (a test that can't fail is worse than none).

private func quote(_ symbol: String, price: Double = 100, isNewListing: Bool) -> StockSageQuoteService.LiveQuote {
    StockSageQuoteService.LiveQuote(symbol: symbol, price: price, previousClose: price, isNewListing: isNewListing)
}

struct StockSageNewListingReconcileTests {
    typealias Store = StockSageStore

    @Test func insertsWhenFeedSaysNewListing() {
        // Empty starting set + a feed quote flagged isNewListing==true -> symbol gets inserted.
        // This is the exact bug being fixed: with refresh() paused, mergeLiveQuotes previously
        // dropped this flag entirely, so a genuinely new listing's badge never appeared.
        let result = Store.reconcileNewListings(current: [], pricedQuotes: ["NEWCO": quote("NEWCO", isNewListing: true)])
        #expect(result.contains("NEWCO"))
    }

    @Test func removesWhenFeedNowSaysFalse() {
        // Symmetric clear: a stale flag from a prior cycle must clear once the feed stops
        // reporting the symbol as new — never left stuck forever.
        let result = Store.reconcileNewListings(current: ["STALE"], pricedQuotes: ["STALE": quote("STALE", isNewListing: false)])
        #expect(!result.contains("STALE"))
    }

    @Test func leavesUnrelatedSymbolsUntouched() {
        // A merge batch that doesn't mention a symbol must not disturb its existing flag —
        // mergeLiveQuotes only ever touches the rows it actually has fresh quotes for.
        let result = Store.reconcileNewListings(current: ["UNTOUCHED"], pricedQuotes: ["OTHER": quote("OTHER", isNewListing: true)])
        #expect(result.contains("UNTOUCHED"))
        #expect(result.contains("OTHER"))
    }

    @Test func neverInsertsWithoutTheFeedSayingSo() {
        // Honesty direction: a quote for a symbol NOT already flagged, reported as
        // isNewListing==false, must never get inferred into the set.
        let result = Store.reconcileNewListings(current: [], pricedQuotes: ["ORDINARY": quote("ORDINARY", isNewListing: false)])
        #expect(result.isEmpty)
    }

    // FIX (2nd-read hunt, 2026-07-08): refresh(scope:)'s newListings assignment previously used
    // `.subtracting(scopedKeys)` — wrongly dropping the flag for an in-scope symbol the feed
    // THROTTLED/MISSED this cycle (present in scopedKeys, absent from quotes.keys), fabricating a
    // "+0.0%" flat tile instead of "N/A (new)". It now reads `reconcileNewListings(current:
    // pricedQuotes: quotes)` directly — this test hand-derives the exact three-way scenario the
    // fix must resolve: a throttled user-added new listing (in scopedKeys, NOT in quotes.keys)
    // KEEPS its flag; a re-priced non-new symbol (in quotes.keys, isNewListing==false) LOSES it;
    // an out-of-scope symbol (not in quotes.keys, e.g. a .core tick skipping a .full-only name)
    // KEEPS it (preserves the existing equity-2000 scoped-refresh carry-forward).
    @Test func throttledUserNewListingKeepsFlagWhileRepricedAndOutOfScopeResolveCorrectly() {
        let current: Set<String> = ["THROTTLED_NEW", "REPRICED_NOW_ORDINARY", "OUT_OF_SCOPE_NEW"]
        // This cycle's `quotes` — THROTTLED_NEW and OUT_OF_SCOPE_NEW are both absent (neither was
        // fetched: one throttled by the feed despite being in scope, the other never in scope this
        // cycle). Only REPRICED_NOW_ORDINARY was actually fetched, and the feed now reports it as
        // no longer new.
        let quotes: [String: StockSageQuoteService.LiveQuote] = [
            "REPRICED_NOW_ORDINARY": quote("REPRICED_NOW_ORDINARY", isNewListing: false),
        ]
        let result = Store.reconcileNewListings(current: current, pricedQuotes: quotes)
        #expect(result.contains("THROTTLED_NEW"))          // throttled in-scope symbol: flag survives
        #expect(!result.contains("REPRICED_NOW_ORDINARY"))  // actually re-priced non-new: flag clears
        #expect(result.contains("OUT_OF_SCOPE_NEW"))         // out-of-scope symbol: flag survives
    }

    @Test func mixedBatchReconcilesEachSymbolIndependently() {
        // One batch, three symbols, three different starting states — each must resolve on its
        // own flag, matching the per-quote loop in mergeLiveQuotes/addSymbol.
        let result = Store.reconcileNewListings(
            current: ["ALREADY_FLAGGED_STAYS_TRUE", "WAS_FLAGGED_NOW_CLEARS"],
            pricedQuotes: [
                "ALREADY_FLAGGED_STAYS_TRUE": quote("ALREADY_FLAGGED_STAYS_TRUE", isNewListing: true),
                "WAS_FLAGGED_NOW_CLEARS": quote("WAS_FLAGGED_NOW_CLEARS", isNewListing: false),
                "FRESH_INSERT": quote("FRESH_INSERT", isNewListing: true),
            ]
        )
        #expect(result == ["ALREADY_FLAGGED_STAYS_TRUE", "FRESH_INSERT"])
    }
}
