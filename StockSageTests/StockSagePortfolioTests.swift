import Testing
import Foundation
@testable import StockSage

/// Pins the Markets Portfolio holdings store: the cost math, the input guards
/// (a fat-fingered form submit must not store garbage), and JSON persistence.
/// Each test uses its OWN UserDefaults suite (cleared first) so the parallel
/// runner never races on a shared key.
@MainActor
struct StockSagePortfolioTests {

    private func freshStore(_ tag: String) -> StockSagePortfolio {
        let name = "test.portfolio.\(tag)"
        UserDefaults().removePersistentDomain(forName: name)
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return StockSagePortfolio(userDefaults: ud)
    }

    @Test func totalCostMultipliesSharesByBasis() {
        #expect(PortfolioPosition(symbol: "X", shares: 10, costBasis: 5).totalCost == 50)
    }

    @Test func addUppercasesAndTrimsSymbol() {
        let p = freshStore("trim")
        p.add(symbol: "  aapl ", shares: 10, costBasis: 100)
        #expect(p.positions.map(\.symbol) == ["AAPL"])
    }

    @Test func addRejectsBlankSymbolAndNonPositiveShares() {
        let p = freshStore("reject")
        p.add(symbol: "", shares: 10, costBasis: 100)
        p.add(symbol: "   ", shares: 10, costBasis: 100)
        p.add(symbol: "X", shares: 0, costBasis: 100)
        p.add(symbol: "Y", shares: -3, costBasis: 100)
        #expect(p.positions.isEmpty)
    }

    @Test func addRejectsNonFiniteSharesAndCostBasis() {
        let p = freshStore("nonfinite")
        p.add(symbol: "X", shares: .infinity, costBasis: 100)
        p.add(symbol: "Y", shares: -.infinity, costBasis: 100)
        p.add(symbol: "Z", shares: .nan, costBasis: 100)
        p.add(symbol: "W", shares: 10, costBasis: .infinity)
        p.add(symbol: "V", shares: 10, costBasis: .nan)
        #expect(p.positions.isEmpty)
    }

    @Test func addAllowsZeroCostBasis() {
        let p = freshStore("zerocost")            // a gifted/vested lot can be free
        p.add(symbol: "GIFT", shares: 5, costBasis: 0)
        #expect(p.positions.count == 1)
        #expect(p.positions[0].totalCost == 0)
    }

    @Test func removeDeletesByIdAndClearEmpties() {
        let p = freshStore("remove")
        p.add(symbol: "A", shares: 1, costBasis: 1)
        p.add(symbol: "B", shares: 2, costBasis: 2)
        p.remove(p.positions[0].id)
        #expect(p.positions.map(\.symbol) == ["B"])
        p.clear()
        #expect(p.positions.isEmpty)
    }

    @Test func holdingsPersistAcrossInstances() {
        let name = "test.portfolio.persist"
        UserDefaults().removePersistentDomain(forName: name)
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        StockSagePortfolio(userDefaults: ud).add(symbol: "AAPL", shares: 10, costBasis: 150)
        let reloaded = StockSagePortfolio(userDefaults: ud)
        #expect(reloaded.positions.map(\.symbol) == ["AAPL"])
        #expect(reloaded.positions.first?.shares == 10)
        #expect(reloaded.positions.first?.totalCost == 1500)
    }

    @Test func qaSeedAssignsInMemoryWithoutTouchingUserDefaults() {
        let name = "test.portfolio.qaseed"
        UserDefaults().removePersistentDomain(forName: name)
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        let p = StockSagePortfolio(userDefaults: ud)
        p.qaSeed([PortfolioPosition(symbol: "AAPL", shares: 30, costBasis: 100)])
        #expect(p.positions.map(\.symbol) == ["AAPL"])
        // Nothing persisted: a FRESH instance on the same suite sees nothing (qaSeed never calls save()).
        let reloaded = StockSagePortfolio(userDefaults: ud)
        #expect(reloaded.positions.isEmpty)
    }
}

/// Pins the "own it" aggregation (sum shares + weighted-average cost basis across multi-lot
/// books) and the unrealized-% math. Expected values are hand-derived in a standalone script
/// (`swift /tmp/derive_ownit.swift`, NOT calling this code), pasted here as literals —
/// gated-scope rule: never derive fixtures by calling the code under test.
///
/// Hand derivation (10sh@90 + 20sh@105):
///   totalShares = 10 + 20 = 30
///   weightedCost = (10*90 + 20*105) / 30 = (900 + 2100) / 30 = 3000 / 30 = 100.0 exactly
///
/// Hand derivation (pct = (price/costBasis − 1) × 100, one decimal):
///   gain:  price=110, cost=100 → (110/100 − 1)×100 = +10.0
///   loss:  price=90,  cost=100 → (90/100  − 1)×100 = −10.0
@MainActor
struct StockSagePortfolioAggregationTests {

    @Test func multiLotAggregatesSharesAndWeightedAverageCost() {
        let positions = [
            PortfolioPosition(symbol: "AAPL", shares: 10, costBasis: 90),
            PortfolioPosition(symbol: "AAPL", shares: 20, costBasis: 105),
        ]
        let held = StockSagePortfolio.holding(for: "AAPL", in: positions)
        #expect(held?.shares == 30)
        #expect(held?.costBasis == 100.0)   // hand-derived exact value above
    }

    @Test func aggregationIgnoresOtherSymbolsAndIsCaseInsensitive() {
        let positions = [
            PortfolioPosition(symbol: "AAPL", shares: 10, costBasis: 90),
            PortfolioPosition(symbol: "MSFT", shares: 5, costBasis: 300),
        ]
        #expect(StockSagePortfolio.holding(for: "aapl", in: positions)?.shares == 10)
        #expect(StockSagePortfolio.holding(for: "MSFT", in: positions)?.costBasis == 300)
    }

    @Test func aggregationReturnsNilWhenSymbolNotHeld() {
        let positions = [PortfolioPosition(symbol: "AAPL", shares: 10, costBasis: 90)]
        #expect(StockSagePortfolio.holding(for: "TSLA", in: positions) == nil)
    }

    // PERF-4: holdingBySymbol is a batch convenience for the ideas board (one O(P) pass instead
    // of O(P) per card); holding(for:in:) stays the semantic source of truth. This proves the
    // dict agrees with the per-symbol function for every symbol present, including a symbol whose
    // only lot has zero shares (must be ABSENT, matching holding(for:in:) returning nil).
    @Test func holdingBySymbolMatchesHoldingForEverySymbol() {
        let zeroShareLot = PortfolioPosition(symbol: "TSLA", shares: 0, costBasis: 200)
        let positions = [
            PortfolioPosition(symbol: "AAPL", shares: 10, costBasis: 90),
            PortfolioPosition(symbol: "AAPL", shares: 20, costBasis: 105),
            PortfolioPosition(symbol: "MSFT", shares: 5, costBasis: 300),
            zeroShareLot,
        ]
        let dict = StockSagePortfolio.holdingBySymbol(in: positions)
        for sym in ["AAPL", "MSFT", "TSLA"] {
            #expect(dict[sym] == StockSagePortfolio.holding(for: sym, in: positions))
        }
        #expect(dict["TSLA"] == nil)   // zero-share lot → nil, same as holding(for:in:)
        #expect(dict.count == 2)       // AAPL + MSFT only
    }

    @Test func unrealizedPctPositiveCase() {
        let held = AggregatedHolding(symbol: "X", shares: 1, costBasis: 100)
        #expect(held.unrealizedPct(vs: 110) == 10.0)   // hand-derived above
    }

    @Test func unrealizedPctNegativeCase() {
        let held = AggregatedHolding(symbol: "X", shares: 1, costBasis: 100)
        #expect(held.unrealizedPct(vs: 90) == -10.0)   // hand-derived above
    }

    @Test func unrealizedPctNilOnNonPositiveCostOrPrice() {
        let heldZeroCost = AggregatedHolding(symbol: "X", shares: 1, costBasis: 0)
        #expect(heldZeroCost.unrealizedPct(vs: 100) == nil)
        let heldPositiveCost = AggregatedHolding(symbol: "X", shares: 1, costBasis: 100)
        #expect(heldPositiveCost.unrealizedPct(vs: 0) == nil)
        #expect(heldPositiveCost.unrealizedPct(vs: -5) == nil)
    }

    // Hand derivation (pct = (price/costBasis − 1) × 100, one decimal), computed independently
    // of the code under test:
    //   cost=97.25, price=103.7 → (103.7/97.25 − 1)×100 = 6.632390... → rounds to 6.6
    @Test func unrealizedPctRoundsToOneDecimalPin() {
        let held = AggregatedHolding(symbol: "X", shares: 1, costBasis: 97.25)
        #expect(held.unrealizedPct(vs: 103.7) == 6.6)
    }

    // -0.0 boundary: cost=100, price=99.96 → (99.96/100 − 1)×100 = −0.04 → rounds to −0.0 (IEEE),
    // which unrealizedPct normalizes to 0. Also pins the rendered string never shows "+-0.0".
    @Test func unrealizedPctNormalizesNegativeZero() {
        let held = AggregatedHolding(symbol: "X", shares: 1, costBasis: 100)
        let pct = held.unrealizedPct(vs: 99.96)
        #expect(pct == 0.0)
        let up = pct! >= 0
        let rendered = "\(up ? "+" : "")\(String(format: "%.1f", pct!))% vs avg cost"
        #expect(rendered == "+0.0% vs avg cost")
        #expect(!rendered.contains("+-"))
    }

    // MARK: save() cross-process reconciliation (2026-07-09 C8 — the paper store's
    // LIVE-evidenced lost-update class applied to the REAL position book. Lots are
    // immutable once added, so the only hazard is a stale save DROPPING a foreign lot.)

    @Test func foreignLotSurvivesAStaleProcessSave() {
        let suite = "portfolio.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = StockSagePortfolio(userDefaults: defaults)
        let b = StockSagePortfolio(userDefaults: defaults)   // second instance, loads empty
        a.add(symbol: "AAA", shares: 10, costBasis: 100)     // process A's lot lands on disk
        b.add(symbol: "BBB", shares: 5, costBasis: 50)       // stale B saves — pre-fix this dropped AAA
        let final = StockSagePortfolio(userDefaults: defaults)
        #expect(Set(final.positions.map(\.symbol)) == ["AAA", "BBB"])
    }

    @Test func removeAndClearStillDeleteDespiteTheReconcilingSave() {
        let suite = "portfolio.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = StockSagePortfolio(userDefaults: defaults)
        a.add(symbol: "AAA", shares: 10, costBasis: 100)
        let id = a.positions[0].id
        a.remove(id)
        #expect(StockSagePortfolio(userDefaults: defaults).positions.isEmpty)
        a.add(symbol: "AAA", shares: 10, costBasis: 100)
        a.clear()
        #expect(StockSagePortfolio(userDefaults: defaults).positions.isEmpty)
    }
}
