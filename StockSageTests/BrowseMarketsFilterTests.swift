import Testing
import Foundation
@testable import StockSage

// Post-restriction (2026-07-16, owner: "only keep Tadawul and NASDAQ"): the Browse asset-class
// filter row is DATA-DRIVEN — only filters matching ≥1 catalog name are offered, so the
// Crypto/Forex segments (permanently empty once those markets left the universe) disappear
// instead of sitting as stale affordances. Hand-derived expectation from the restricted
// catalog (901 = 29 .SR incl. ^TASI.SR + 872 NASDAQ incl. the ETF-group QQQ/TLT):
//   .all (always) · .stocks (AAPL…) · .etf (QQQ/TLT carry the "ETFs" group label) ·
//   .index (^TASI.SR) — present;  .crypto (no -USD) · .fx (no =X) — absent.
@MainActor
struct BrowseMarketsFilterTests {
    typealias F = BrowseMarketsView.AssetFilter

    @Test func availableFiltersDropPermanentlyEmptyClasses() {
        let avail = BrowseMarketsView.availableFilters
        #expect(avail.contains(.all))
        #expect(avail.contains(.stocks))
        #expect(avail.contains(.etf))          // QQQ/TLT — NASDAQ-listed, ETF group label
        #expect(avail.contains(.index))        // ^TASI.SR — Tadawul's own index
        #expect(!avail.contains(.crypto))      // crypto left the universe 2026-07-16
        #expect(!avail.contains(.fx))          // forex left the universe 2026-07-16
    }

    // The static classifier itself, pinned on hand-built symbols (never via the catalog).
    @Test func staticClassifierMatchesEachClassBySuffixRule() {
        func sym(_ s: String, market: String = "M") -> StockSageSymbol {
            StockSageSymbol(symbol: s, market: market)
        }
        #expect(BrowseMarketsView.matches(sym("BTC-USD"), filter: .crypto))
        #expect(BrowseMarketsView.matches(sym("USDSAR=X"), filter: .fx))
        #expect(BrowseMarketsView.matches(sym("^TASI.SR"), filter: .index))
        #expect(BrowseMarketsView.matches(sym("QQQ", market: "ETFs (broad)"), filter: .etf))
        #expect(BrowseMarketsView.matches(sym("AAPL"), filter: .stocks))
        #expect(!BrowseMarketsView.matches(sym("AAPL"), filter: .crypto))
        #expect(!BrowseMarketsView.matches(sym("^TASI.SR"), filter: .stocks))   // index ≠ stock
        #expect(BrowseMarketsView.matches(sym("ANY"), filter: .all))
    }
}
