import Testing
@testable import StockSage

// MARK: - missingAfterScan (CONCURRENCY #3) — one snapshot, no false failure banners.

struct StockSageIdeasMissingTests {

    @Test func filtersByTrackedAnalyzedAndIndexClass() {
        // By hand: AAPL — tracked ✓, not analyzed ✓, Equity ✓ → MISSING.
        //          GONE — removed mid-await (not in stillTracked) → dropped.
        //          ^GSPC — Index class → never "missing" (not buyable).
        //          2222.SR — analyzed → not missing.
        //          nvda — lowercase in universe, tracked as NVDA → MISSING (case-insensitive), casing preserved.
        let missing = StockSageStore.missingAfterScan(
            universe: ["AAPL", "GONE", "^GSPC", "2222.SR", "nvda"],
            analyzed: ["2222.SR"],
            stillTracked: ["AAPL", "^GSPC", "2222.SR", "NVDA"])
        #expect(missing == ["AAPL", "nvda"])
    }

    @Test func tickerAddedDuringTheAwaitIsNeverBanneredAsAFailure() {
        // NEWB was added (and priced, on the board) DURING the retry await: it is in the CURRENT
        // tracked set but NOT in the pre-await universe snapshot — it must not appear as a
        // "couldn't be fetched" failure. The old code re-read trackedDefs() post-await and did
        // exactly that.
        let missing = StockSageStore.missingAfterScan(
            universe: ["AAPL"],
            analyzed: [],
            stillTracked: ["AAPL", "NEWB"])
        #expect(missing == ["AAPL"])
        #expect(!missing.contains("NEWB"))
    }
}
