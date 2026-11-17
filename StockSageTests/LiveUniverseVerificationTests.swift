import Testing
import Foundation
@testable import StockSage

// Live verification of the 2026-07-16 Tadawul+NASDAQ universe restriction (NOT a CI test —
// gated on a /tmp sentinel file so it is inert unless the sentinel exists, exactly like
// StrategyBaselineMeasurementTests). Drives the SAME QuoteService call `refresh()` makes over
// the restricted `worldwide`, live against Yahoo, and verifies by measurement:
//   1. the restricted universe is largely PRICEABLE live (coverage > 85% — a wholesale feed
//      failure or a mis-baked symbol set would crater this),
//   2. Aramco (2222.SR) prices — the Tadawul feed works post-restriction,
//   3. AAPL prices — the NASDAQ side works,
//   4. USDSAR=X prices via the infra fetch list — the NEW infraFX plumbing's live dependency
//      (FX left the universe; the .SR honesty corrections depend on this one direct fetch).
// To run: `touch /tmp/salehman_verify_live_universe` then run this test only; read the printed
// "=== LIVE UNIVERSE VERIFICATION ===" block. (File sentinel — env vars don't reliably cross
// the `xcodebuild test` boundary.)
@Suite(.serialized)
struct LiveUniverseVerificationTests {
    @Test("restricted universe live-priceability + infra FX (sentinel-gated, network)")
    func verifyLiveUniverse() async {
        guard FileManager.default.fileExists(atPath: "/tmp/salehman_verify_live_universe") else {
            return   // inert in normal CI runs
        }

        let universe = StockSageUniverse.worldwide.map(\.symbol)
        let quotes = await StockSageQuoteService.fetchQuotes(for: universe)
        let priced = universe.filter { quotes[$0.uppercased()] != nil }
        let unpriced = universe.filter { quotes[$0.uppercased()] == nil }
        let srPriced = priced.filter { $0.uppercased().hasSuffix(".SR") }.count
        let coverage = Double(priced.count) / Double(universe.count)

        let fx = await StockSageQuoteService.fetchQuotes(for: StockSageStore.infraFXSymbols)
        let sarRate = fx["USDSAR=X"]?.price

        print("=== LIVE UNIVERSE VERIFICATION (2026-07-16 restriction) ===")
        print("universe: \(universe.count) | priced: \(priced.count) (\(String(format: "%.1f", coverage * 100))%)")
        print("Tadawul priced: \(srPriced)/29 | AAPL: \(quotes["AAPL"]?.price ?? -1) | 2222.SR: \(quotes["2222.SR"]?.price ?? -1)")
        print("infra USDSAR=X: \(sarRate.map { String(format: "%.4f", $0) } ?? "MISSING")")
        if !unpriced.isEmpty { print("unpriced (\(unpriced.count)): \(unpriced.prefix(30).joined(separator: " "))") }

        #expect(coverage > 0.85, "restricted universe should be largely priceable live")
        #expect(quotes["2222.SR"]?.price ?? 0 > 0, "Aramco must price — the Tadawul feed")
        #expect(quotes["AAPL"]?.price ?? 0 > 0, "AAPL must price — the NASDAQ feed")
        #expect(sarRate ?? 0 > 0, "USDSAR=X must price — the infraFX plumbing's live dependency")
    }
}
