import Testing
import Foundation
@testable import StockSage

// Per-row quote staleness: crypto (24/7) flags fast, equities/FX tolerate an overnight gap but
// flag a multi-day weekend/holiday close. Fixed `now` so the dates are deterministic.
@MainActor
struct StockSageStalenessTests {
    private func sym(_ ticker: String, at marketTime: Date?) -> StockSageSymbol {
        StockSageSymbol(symbol: ticker, market: "M",
                        quotes: [StockSageQuote(price: 100, previousPrice: 100, marketTime: marketTime)])
    }

    @Test func equityToleratesOvernightCryptoFlagsFast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Equity: a 1-day-old quote is fine (overnight), a 60h one (a long weekend) is stale.
        #expect(sym("AAPL", at: now.addingTimeInterval(-24 * 3600)).isStale(asOf: now) == false)
        #expect(sym("AAPL", at: now.addingTimeInterval(-60 * 3600)).isStale(asOf: now) == true)
        // Crypto trades 24/7 → tighter: fresh at 3h, stale by 12h.
        #expect(sym("BTC-USD", at: now.addingTimeInterval(-3 * 3600)).isStale(asOf: now) == false)
        #expect(sym("BTC-USD", at: now.addingTimeInterval(-12 * 3600)).isStale(asOf: now) == true)
        // No quote → can't judge → not stale (no false alarm).
        #expect(StockSageSymbol(symbol: "AAPL", market: "M").isStale(asOf: now) == false)
        // A quote with NO market time (feed omitted it) → can't judge → not stale, even if very old.
        #expect(sym("AAPL", at: nil).isStale(asOf: now) == false)
    }

    @Test func closeableQuoteAsOfIgnoresAlwaysOnCrypto() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let freshCrypto = sym("BTC-USD", at: now.addingTimeInterval(-60))         // 24/7 → always live
        let staleEquity = sym("AAPL", at: now.addingTimeInterval(-72 * 3600))     // days-old weekend close
        // The "live" banner's freshness must reflect the CLOSEABLE (equity) board, not the crypto quote.
        #expect(StockSageStore.closeableQuoteAsOf([freshCrypto, staleEquity]) == now.addingTimeInterval(-72 * 3600))
        // All-crypto board → nil (no closeable asset; crypto genuinely is live).
        #expect(StockSageStore.closeableQuoteAsOf([freshCrypto]) == nil)
    }

    @Test func sharedFreshnessRuleMatchesPerClassTolerances() {
        // The one rule used by BOTH the display badge and the price-alert firing gate.
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: now.addingTimeInterval(-60 * 3600), asOf: now))
        #expect(!StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: now.addingTimeInterval(-24 * 3600), asOf: now))
        #expect(StockSageQuoteFreshness.isStale(symbol: "BTC-USD", marketTime: now.addingTimeInterval(-12 * 3600), asOf: now))
        #expect(!StockSageQuoteFreshness.isStale(symbol: "BTC-USD", marketTime: now.addingTimeInterval(-3 * 3600), asOf: now))
        // nil market time → NOT stale (don't suppress a fire / don't false-badge when feed omits it).
        #expect(!StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: nil, asOf: now))
    }
}
