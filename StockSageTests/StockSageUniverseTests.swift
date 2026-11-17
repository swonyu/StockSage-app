import Testing
import Foundation
@testable import StockSage

// MARK: - Universe + catalog search (pure)
// (Named distinctly from `StockSageUniverseTests` in StockSageTests.swift, which
// covers `worldwide`; this one covers the discovery `catalog` + `search`.)

struct StockSageUniverseCatalogTests {
    typealias U = StockSageUniverse

    // PLAN_2026-07-08_equity2000.md Stage 2 promoted `worldwide` to groups+catalogExtra (same
    // dedup as `catalog`), so `catalog` is no longer a STRICT superset of `worldwide` — they are
    // now the same deduped set (verified equal, not merely catalog >= worldwide, so a future
    // divergence between the two builders is caught either direction). Mismatch vs the
    // pre-promotion assertion (`catalog.count > worldwide.count`) is the honest re-derivation,
    // not a bent assertion — `catalog`'s superset role is preserved w.r.t. the OLD 210-name core,
    // just no longer w.r.t. the promoted `worldwide`.
    @Test func catalogAndWorldwideAreTheSameDedupedSetPostPromotion() {
        let coreSyms = Set(U.worldwide.map { $0.symbol.uppercased() })
        let catSyms = Set(U.catalog.map { $0.symbol.uppercased() })
        #expect(catSyms == coreSyms)                       // same underlying set post-promotion
        #expect(U.catalog.count == U.worldwide.count)       // same size
        #expect(catSyms.count == U.catalog.count)          // catalog is deduped (no repeats)
        #expect(coreSyms.count == U.worldwide.count)        // worldwide is deduped too
    }

    @Test func searchRanksExactThenPrefixThenSubstring() {
        #expect(U.search("AAPL").first?.symbol == "AAPL")              // exact match first
        #expect(U.search("aap").contains { $0.symbol == "AAPL" })      // case-insensitive prefix
        // OWNER DIRECTIVE 2026-07-16 (Tadawul+NASDAQ only): crypto left the catalog — the old
        // "crypto discoverable" pin is re-ratified to its inverse under the new spec.
        #expect(!U.search("BTC-USD").contains { $0.symbol == "BTC-USD" })   // crypto NOT discoverable
        #expect(U.search("A", limit: 5).count <= 5)                    // bounded by limit
        #expect(U.search("").isEmpty)                                  // empty query → nothing
        #expect(U.search("ZZZZNOPE").isEmpty)                          // no match → nothing
    }
}
