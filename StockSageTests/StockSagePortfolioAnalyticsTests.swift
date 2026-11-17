import Testing
import Foundation
@testable import StockSage

// MARK: - Portfolio risk analytics (pure)

struct StockSagePortfolioAnalyticsTests {

    typealias PA = StockSagePortfolioAnalytics

    @MainActor @Test func benchmarkCannotEraseHoldingLossAndLotsCannotCreateDiversification() async throws {
        let name = "analytics.assembly.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let calendar = Calendar(identifier: .gregorian)
        let start = ISO8601DateFormatter().date(from: "2026-08-23T12:00:00Z")!
        let days = [0, 1, 2, 3, 4, 7, 8, 9, 10, 11].map { start.addingTimeInterval(Double($0) * 86400) }
        func history(_ symbol: String, _ dates: [Date], _ closes: [Double]) -> StockSagePriceHistory {
            .init(symbol: symbol, dates: dates, opens: closes, highs: closes, lows: closes, closes: closes,
                  volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: symbol))
        }
        let holding = history("2222.SR", days, [100, 100, 100, 100, 100, 50, 50, 50, 50, 50])
        let lots = [PortfolioPosition(symbol: "2222.SR", shares: 8, costBasis: 100)]
        await store.applyPortfolioAnalytics(positions: lots, histories: ["2222.SR": holding], benchmark: nil)
        let baseline = try #require(store.analytics)
        #expect(baseline.maxDrawdown == 50)
        let usDays = days.filter { calendar.component(.weekday, from: $0) != 1 }
        let market = history("^GSPC", usDays, Array(repeating: 100, count: usDays.count))
        await store.applyPortfolioAnalytics(positions: lots, histories: ["2222.SR": holding], benchmark: market)
        #expect(store.analytics == baseline, "An optional benchmark must affect beta only")
        let splitLots = (0..<8).map { _ in PortfolioPosition(symbol: "2222.SR", shares: 1, costBasis: 100) }
        await store.applyPortfolioAnalytics(positions: splitLots, histories: ["2222.SR": holding], benchmark: nil)
        #expect(store.analytics == baseline, "Stored lots are not distinct investments")
        #expect(store.correlation == nil)
        #expect(store.analyticsMatches(positions: splitLots))
        #expect(store.analyticsMatches(positions: lots))
        #expect(!store.analyticsMatches(positions: [PortfolioPosition(symbol: "OTHER", shares: 8, costBasis: 100)]))
        #expect(!store.analyticsMatches(positions: [PortfolioPosition(symbol: "2222.SR", shares: 9, costBasis: 100)]))
    }

    @Test func dailyReturnsComputeCorrectly() {
        let r = PA.dailyReturns([100, 110, 99])
        #expect(r.count == 2)
        #expect(abs(r[0] - 0.10) < 1e-9)     // +10%
        #expect(abs(r[1] + 0.10) < 1e-9)     // −10%
    }

    @Test func maxDrawdownIsPeakToTrough() {
        // equity: 1.1 → 1.21 → 0.605 → DD = (1.21−0.605)/1.21 = 0.5
        #expect(abs(PA.maxDrawdown([0.1, 0.1, -0.5]) - 0.5) < 1e-9)
        #expect(PA.maxDrawdown([0.01, 0.01, 0.01]) == 0)   // monotonic up → no drawdown
    }

    @Test func correlationExtremes() {
        #expect(abs((PA.correlation([0.1, 0.2, 0.3], [0.1, 0.2, 0.3]) ?? 0) - 1) < 1e-9)
        #expect(abs((PA.correlation([0.1, -0.1, 0.1, -0.1], [-0.1, 0.1, -0.1, 0.1]) ?? 0) + 1) < 1e-9)
    }

    @Test func correlationIsNilNotZeroForInsufficientOverlap() {
        // n<2 is the SAME "undefined" semantic as zero variance: correlation requires
        // at least two paired observations to be mathematically defined. Must return nil,
        // consistent with the zero-variance convention, so callers exclude it rather than
        // treating a thin/overlapping pair as "uncorrelated". All production callers pre-guard
        // to n≥2 (ClusterCheck ≥2, Precheck minOverlap=5, laneCorrelation filter{≥2}), so
        // this convention is byte-identical to the prior return-0 in practice (F33 2026-07-02).
        #expect(PA.correlation([], []) == nil)                     // n=0
        #expect(PA.correlation([0.1], [0.1]) == nil)               // n=1
        #expect(PA.correlation([0.1, 0.2], [0.1]) == nil)          // min(2,1)=1
        #expect(PA.correlation([0.1], [0.1, 0.2]) == nil)          // min(1,2)=1
        // n=2 is the boundary: with 2 points Pearson IS defined (unless zero variance).
        #expect(PA.correlation([0.1, 0.2], [0.1, 0.2]) != nil)    // n=2 → defined
    }

    @Test func correlationIsNilNotZeroForAZeroVarianceSeries() {
        // A flat/halted/illiquid series has ZERO variance — its correlation with anything is
        // mathematically 0/0 (UNDEFINED), not a real "uncorrelated" 0. Must be nil so callers
        // EXCLUDE it, not silently treat a flat holding as maximally diversifying.
        let flat = [100.0, 100.0, 100.0, 100.0]
        let moving: [Double] = [0.01, -0.02, 0.03, -0.01]
        #expect(PA.correlation(flat, moving) == nil)
        #expect(PA.correlation(moving, flat) == nil)
        #expect(PA.correlation(flat, flat) == nil)   // both flat → still undefined, not "perfectly correlated"
    }

    @Test func averageCorrelationOfSingleHoldingIsOne() {
        #expect(PA.averageCorrelation([[0.1, 0.2, 0.3]]) == 1)          // concentrated
        #expect(abs(PA.averageCorrelation([[0.1, 0.2], [0.1, 0.2]]) - 1) < 1e-9)
    }

    @Test func averageCorrelationExcludesAZeroVarianceHoldingRatherThanTreatingItAsUncorrelated() {
        // Three holdings: two genuinely +1-correlated, one FLAT (zero variance, undefined vs
        // both). If the flat holding were treated as a fake 0, the average would be dragged down
        // (falsely reading as more diversified). Excluded, the average must equal exactly the
        // one real, defined pair (+1) — not a blend that includes a phantom "uncorrelated" 0.
        let a: [Double] = [0.1, 0.2, 0.3, 0.1]
        let identicalToA = a
        let flat: [Double] = [100, 100, 100, 100]
        let avg = PA.averageCorrelation([a, identicalToA, flat])
        #expect(abs(avg - 1) < 1e-9)   // only the (a, identicalToA) pair is defined, and it's +1

        // All-flat (every pair undefined) → no defined pairs → falls back to the existing
        // "no data → assume fully concentrated" convention (1), not a fake 0.
        #expect(PA.averageCorrelation([flat, flat]) == 1)
    }

    @Test func percentileNearestRank() {
        #expect(PA.percentile([1, 2, 3, 4, 5], 0.0) == 1)
        #expect(PA.percentile([1, 2, 3, 4, 5], 1.0) == 5)
        // The legacy rounded-index helper stays stable for its sizing callers.
        #expect(PA.percentile((1...20).map(Double.init), 0.05) == 2)
        #expect(PA.percentile((1...20).map(Double.init), 0.5) == 11)
        #expect(PA.inverseEmpiricalCDF([1, 2, 3, 4, 5], 0.0) == 1)
        #expect(PA.inverseEmpiricalCDF([1, 2, 3, 4, 5], 1.0) == 5)
        let twenty = (1...20).map(Double.init)
        #expect(PA.inverseEmpiricalCDF(twenty, 0.05) == 1)
        #expect(PA.inverseEmpiricalCDF(twenty, 0.95) == 19)
        #expect(PA.inverseEmpiricalCDF((1...11).map(Double.init), 0.95) == 11)
        #expect(PA.inverseEmpiricalCDF([1, 1, 1, 4], 0.75) == 1)
        #expect(PA.inverseEmpiricalCDF([], 0.95).isNaN)
        #expect(PA.inverseEmpiricalCDF([1, 2], .nan).isNaN)
        #expect(PA.inverseEmpiricalCDF([1, .infinity], 0.95).isNaN)
        #expect(PA.inverseEmpiricalCDF([1, 2], -0.1).isNaN)
        #expect(PA.inverseEmpiricalCDF([1, 2], 1.1).isNaN)
    }

    @Test func computeRejectsTooLittleHistory() {
        #expect(PA.compute(holdings: [(1.0, [100, 101, 102])]) == nil)   // 2 returns < 5
        #expect(PA.compute(holdings: []) == nil)
    }

    @Test func computeReturnsSuiteWithCorrectMetadata() {
        let rising = (0..<12).map { 100.0 + Double($0) }
        let a = PA.compute(holdings: [(1000, rising), (1000, rising)])
        #expect(a != nil)
        #expect(a?.holdingsAnalyzed == 2)
        #expect(a?.observations == 11)                  // 12 closes → 11 returns
        #expect(abs((a?.avgCorrelation ?? 0) - 1) < 1e-6)   // identical → fully correlated
        #expect((a?.diversificationScore ?? 100) < 20)      // two identical names = poorly diversified
        #expect(a?.maxDrawdown == 0)                    // monotonic up
        #expect(a?.calmar == nil)   // maxDrawdown == 0 → calmar is UNDEFINED, not a fake 0.00
    }

    @Test func aNonFiniteHoldingWeightMakesTheWholeSuiteUnavailable() {
        let closes = (0..<12).map { 100.0 + Double($0) }
        let poisoned = PA.compute(holdings: [(.infinity, closes), (1000, closes)])
        let clean = PA.compute(holdings: [(1000, closes)])
        // A valid second holding must not hide an unknown first holding's exposure.
        // Reporting the second alone while counting both as analyzed is incomplete.
        #expect(poisoned == nil)
        #expect(clean != nil)
        #expect(PA.portfolioReturns(holdings: [(.infinity, closes), (1000, closes)]).isEmpty)
    }

    @Test func allNonFiniteWeightsReturnNilRatherThanACrashOrNaNSuite() {
        let closes = (0..<12).map { 100.0 + Double($0) }
        #expect(PA.compute(holdings: [(.infinity, closes), (.nan, closes)]) == nil)
    }

    @Test func ratioMetricsAreConsistentWithTheirComponents() {
        // Single holding → portfolio returns == its daily returns, so the ratio
        // metrics can be pinned against the public helpers (no magic annualized
        // numbers). Guards the Sharpe/Sortino/Calmar/VaR formulas from regression.
        let closes: [Double] = [100, 110, 105, 115, 108, 120, 112, 118]   // up & down days
        let a = PA.compute(holdings: [(1000, closes)])!
        let rets = PA.dailyReturns(closes)

        #expect(abs(a.maxDrawdown - PA.maxDrawdown(rets) * 100) < 1e-6)
        #expect(abs(a.valueAtRisk95 - max(0, PA.inverseEmpiricalCDF(rets.map { -$0 * 100 }, 0.95))) < 1e-6)
        #expect(a.annualizedVolatility > 0)
        #expect(a.sharpe != nil)   // defined here (vol > 0)
        // Independent 70-digit Decimal reference from exact decimal closes:
        // mean = 0.02670426536886164215; sample variance = 0.00658495189175896757.
        #expect(abs(a.sharpe! - 5.2240172489552704822) < 1e-10)
        #expect(a.maxDrawdown > 0)
        #expect(a.calmar != nil)   // defined here (maxDrawdown > 0)
        #expect(abs(a.calmar! - a.annualizedReturn / a.maxDrawdown) < 1e-6)
        // Sortino's downside deviation is normalized over ALL observations (the fix);
        // reverting to ÷down-day-count would break this.
        let n = Double(rets.count)
        let downSq = rets.reduce(0.0) { $0 + min($1, 0) * min($1, 0) }
        let downDev = (downSq / n).squareRoot() * (252.0).squareRoot() * 100
        #expect(downDev > 0)
        #expect(a.sortino != nil)   // defined here (downside > 0)
        #expect(abs(a.sortino! - a.annualizedReturn / downDev) < 1e-6)
    }

    @Test func zeroVolatilityYieldsUndefinedSharpeSortino() {
        // No movement → zero realized vol & zero downside → the ratios are UNDEFINED.
        // They must be nil (rendered "n/a"), never a sentinel that reads as a real 100.
        let flat = Array(repeating: 100.0, count: 8)
        let a = PA.compute(holdings: [(1000, flat)])!
        #expect(a.annualizedVolatility == 0)
        #expect(a.sharpe == nil)
        #expect(a.sortino == nil)
    }

    @Test func correlationMatrixIsSymmetricWithUnitDiagonal() {
        let a: [Double] = [0.1, 0.2, 0.3]
        let b: [Double] = [-0.1, -0.2, -0.3]            // perfectly anti-correlated with a
        let m = PA.correlationMatrix([a, b])
        #expect(m.count == 2 && m[0].count == 2)
        #expect(m[0][0] == 1 && m[1][1] == 1)           // unit diagonal
        #expect(abs(m[0][1] - m[1][0]) < 1e-12)         // symmetric
        #expect(abs(m[0][1] + 1) < 1e-9)                // a vs b = −1
        #expect(PA.correlationMatrix([[0.1, 0.2]]) == [[1.0]])   // single series → identity
    }

    @Test func correlationMatrixShowsAZeroFallbackForAnUndefinedZeroVariancePairForDisplayOnly() {
        // The matrix cell for an undefined (zero-variance) pair falls back to 0 for the heatmap's
        // display purposes — the matrix type can't hold nil — but this must NOT leak into
        // averageCorrelation, which recomputes and correctly excludes it (see the test above).
        let a: [Double] = [0.1, 0.2, 0.3]
        let flat: [Double] = [100, 100, 100]
        let m = PA.correlationMatrix([a, flat])
        #expect(m[0][1] == 0)
        #expect(m[1][0] == 0)
    }

    // Audit 2026-07-12 (ideas-card F3): the parallel defined-ness mask lets the heatmap render an
    // undefined (zero-variance) pair as "—" instead of a fabricated green "0.0 independent" cell.
    // The mask must flag exactly the pairs where correlationMatrix stored the display-only 0, and
    // leave a genuinely-measured pair (and the diagonal) defined.
    @Test func correlationDefinedMaskFlagsTheUndefinedZeroVariancePair() {
        let a: [Double] = [0.1, 0.2, 0.3, 0.15]     // real variation
        let b: [Double] = [0.3, 0.1, 0.25, 0.2]     // real variation
        let flat: [Double] = [100, 100, 100, 100]   // zero variance → undefined vs anything
        let mask = PA.correlationDefinedMask([a, b, flat])
        // Diagonal always defined (self-correlation is 1).
        #expect(mask[0][0] && mask[1][1] && mask[2][2])
        // a vs b: both vary → defined.
        #expect(mask[0][1] && mask[1][0])
        // flat vs anything: undefined → false (the cell the heatmap must render as "—").
        #expect(!mask[0][2] && !mask[2][0])
        #expect(!mask[1][2] && !mask[2][1])
        // And the mask lines up with where the matrix stored its display-only 0.
        let m = PA.correlationMatrix([a, b, flat])
        #expect(m[0][2] == 0 && !mask[0][2])   // undefined pair: matrix 0, mask false — the exact contract.
    }

    @Test func computeDoesNotTreatAFlatHoldingAsMaximallyDiversifying() {
        // A flat (zero-variance) holding paired with a real one used to make avgCorrelation()
        // silently read as 0 ("perfectly diversifying") — the worst possible mis-read, since a
        // flat/halted/illiquid name tells you NOTHING about diversification. With the fix, the
        // undefined pair is excluded, so avgCorrelation falls back to the "no defined pairs → 1"
        // (fully concentrated) convention instead of a falsely-reassuring 0.
        let flat = Array(repeating: 100.0, count: 12)
        let moving = (0..<12).map { 100.0 + Double($0 % 3) - 1 }   // some real up/down movement
        let a = PA.compute(holdings: [(1000, flat), (1000, moving)])
        #expect(a != nil)
        #expect(a?.avgCorrelation == 1)   // NOT 0 — the pair is undefined, not "uncorrelated"
    }

    @Test func antiCorrelatedHoldingsScoreWellDiversified() {
        let a: [Double] = [100, 110, 100, 110, 100, 110, 100]   // alternating
        let b: [Double] = [110, 100, 110, 100, 110, 100, 110]   // opposite phase
        let r = PA.compute(holdings: [(1000, a), (1000, b)])
        #expect(r != nil)
        #expect((r?.avgCorrelation ?? 1) < -0.9)        // strongly anti-correlated
        #expect((r?.diversificationScore ?? 0) > 70)    // genuine diversification
    }

    // Preserve the original 20- and 5-observation expected outcomes. Under the
    // explicit LOSS-side inverse empirical CDF, 19 of 20 observations are gains,
    // so 95% loss VaR is floored at zero; the worst 5% still loses 10%.
    // Five observations give a quarter-observation tail, wholly within the worst loss.
    @Test func conditionalVaRAveragesTheTailAndFallsBackToVaRWhenTailIsEmpty() {
        // Twenty equally weighted scenarios: 95% loss quantile is a gain (0% loss
        // after flooring). The one worst scenario is exactly the whole 5% tail.
        var normal = [100.0]
        for r in [-0.10] + (1...19).map({ Double($0) / 100 }) { normal.append(normal.last! * (1 + r)) }
        let a = PA.compute(holdings: [(1000, normal)])!
        #expect(abs(a.cVaR95 - 10.0) < 1e-6)
        #expect(abs(a.valueAtRisk95 - 0.0) < 1e-6)
        #expect(a.cVaR95 > a.valueAtRisk95)   // expected shortfall ≥ VaR when the tail bites

        // Five scenarios: the 95% loss quantile is the maximum 10% loss.
        // Its fractional probability mass also fills the entire 5% ES tail.
        let f = PA.compute(holdings: [(1000, [100, 90, 91, 92, 93, 94])])!
        #expect(abs(f.cVaR95 - 10.0) < 1e-6)
        #expect(f.cVaR95 == f.valueAtRisk95)   // tail is wholly within the worst scenario
    }

    @Test func invalidWeightsRejectBothSingleAndPartlyValidBooks() {
        let closes: [Double] = [100, 110, 105, 108, 104, 106]
        for value in [0.0, -1.0, Double.infinity, -Double.infinity, Double.nan] {
            #expect(PA.compute(holdings: [(value, closes)]) == nil)
            #expect(PA.compute(holdings: [(value, closes), (100, closes)]) == nil)
            #expect(PA.portfolioReturns(holdings: [(value, closes), (100, closes)]).isEmpty)
        }
        #expect(PA.compute(holdings: [(Double.greatestFiniteMagnitude, closes),
                                     (Double.greatestFiniteMagnitude, closes)]) == nil)
    }

    @Test func positiveExposureCannotDisappearThroughNumericUnderflow() {
        let moving: [Double] = [100, Double(100).nextUp, 100, Double(100).nextUp, 100, Double(100).nextUp]
        let flat = [Double](repeating: 100, count: 6)
        #expect(PA.compute(holdings: [(Double.leastNonzeroMagnitude, moving), (1e308, flat)]) == nil)
        #expect(PA.portfolioReturns(holdings: [(Double.leastNonzeroMagnitude, moving), (1e308, flat)]).isEmpty)
        // The normalized1e-308 weight exists, but its nonzero return contribution underflows.
        #expect(PA.compute(holdings: [(1e-308, moving), (1, flat)]) == nil)
        #expect(PA.portfolioReturns(holdings: [(1e-308, moving), (1, flat)]).isEmpty)
    }

    @Test func invalidClosesDoNotLeaveAPartialDailyOrDatedHistory() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        for invalid in [0.0, -1.0, Double.infinity, Double.nan] {
            var closes: [Double] = [100, 101, 102, 103, 104, 105, 106, 107]
            closes[3] = invalid
            #expect(PA.dailyReturns(closes).isEmpty)
            #expect(PA.datedReturns(dates: dates, closes: closes).isEmpty)
            #expect(PA.compute(holdings: [(1000, closes)]) == nil)
        }
    }

    @Test func finiteExtremePricesCannotProduceInfiniteOrCollapsedReturns() {
        let rising: [Double] = [1e-308, 1e308, 1e308, 1e308, 1e308, 1e308]
        let collapsed: [Double] = [1e308, 1e-308, 1e-308, 1e-308, 1e-308, 1e-308]
        for closes in [rising, collapsed] {
            #expect(closes.allSatisfy { $0.isFinite && $0 > 0 })
            #expect(PA.dailyReturns(closes).isEmpty)
            #expect(PA.compute(holdings: [(1000, closes)]) == nil)
            #expect(PA.portfolioReturns(holdings: [(1000, closes)]).isEmpty)
        }
    }

    @Test func annualizationAndVarianceOverflowAreUnavailable() {
        let highGrowth: [Double] = [1, 1e4, 1e8, 1e12, 1e16, 1e20]
        #expect(PA.dailyReturns(highGrowth).count == 5)
        #expect(PA.compute(holdings: [(1, highGrowth)]) == nil)
        let excessiveDispersion: [Double] = [1, 1e200, 1e200, 1e200, 1e200, 1e200]
        #expect(PA.dailyReturns(excessiveDispersion).count == 5)
        #expect(PA.compute(holdings: [(1, excessiveDispersion)]) == nil)
    }

    @Test func annualizationRequiresAPositiveFinitePeriodCount() {
        let closes: [Double] = [100, 110, 105, 108, 104, 106]
        for periods in [0.0, -1.0, Double.infinity, Double.nan] {
            #expect(PA.compute(holdings: [(1000, closes)], periodsPerYear: periods) == nil)
        }
        #expect(PA.compute(holdings: [(1000, closes)], periodsPerYear: 252) != nil)
    }

    @Test func covarianceOverflowIsUnknownRatherThanFalseZeroCorrelation() {
        let huge: [Double] = [1e200, -1e200, 1e200, -1e200, 1e200]
        #expect(PA.correlation(huge, huge) == nil)
        #expect(PA.beta(portfolio: huge, market: huge) == nil)
        let ordinary: [Double] = [0.01, -0.02, 0.03, -0.01, 0.02]
        #expect(abs((PA.beta(portfolio: ordinary.map { $0 * 2 }, market: ordinary) ?? .nan) - 2) < 1e-12)
        #expect(PA.correlation([.infinity, 0.1], [0.2, 0.3]) == nil)
    }

    @Test func normalWeightedReturnsKeepTheirKnownValues() {
        let moving: [Double] = [100, 110, 99, 108.9, 98.01, 107.811]
        let flat = [Double](repeating: 100, count: 6)
        let returns = PA.portfolioReturns(holdings: [(1, moving), (3, flat)])
        let expected: [Double] = [0.025, -0.025, 0.025, -0.025, 0.025]
        #expect(returns.count == expected.count)
        for (actual, wanted) in zip(returns, expected) { #expect(abs(actual - wanted) < 1e-12) }
        let result = PA.compute(holdings: [(1, moving), (3, flat)])
        #expect(result != nil)
        #expect(result?.holdingsAnalyzed == 2)
        #expect(result?.holdingsAttempted == 2)
    }

    @MainActor @Test func invalidPositionOrHistoryClearsStaleAnalyticsAndCanRecover() async throws {
        let name = "analytics.complete.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        func history(_ symbol: String, _ closes: [Double]) -> StockSagePriceHistory {
            .init(symbol: symbol, dates: days, opens: closes, highs: closes, lows: closes, closes: closes,
                  volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: symbol))
        }
        let prices: [Double] = [100, 102, 101, 104, 103, 106, 105, 200]
        let histories = ["AAPL": history("AAPL", prices), "MSFT": history("MSFT", prices)]
        let normal = [PortfolioPosition(symbol: "AAPL", shares: 1, costBasis: 100),
                      PortfolioPosition(symbol: "MSFT", shares: 1, costBasis: 100)]
        await store.applyPortfolioAnalytics(positions: normal, histories: histories, benchmark: nil)
        let original = try #require(store.analytics)
        #expect(store.correlation != nil)
        var overflow = normal
        overflow[0].shares = 1e308
        overflow[0].costBasis = 0
        #expect((overflow[0].shares * overflow[0].costBasis).isFinite)
        await store.applyPortfolioAnalytics(positions: overflow, histories: histories, benchmark: nil)
        #expect(store.analytics == nil && store.correlation == nil && store.portfolioBeta == nil)
        #expect(store.analyticsError?.contains("invalid") == true)
        await store.applyPortfolioAnalytics(positions: normal, histories: histories, benchmark: nil)
        #expect(store.analytics == original)
        #expect(store.analyticsError == nil)
        var invalid = histories
        invalid["AAPL"] = history("AAPL", [100, 102, 0, 104, 103, 106, 105, 200])
        await store.applyPortfolioAnalytics(positions: normal, histories: invalid, benchmark: nil)
        #expect(store.analytics == nil && store.correlation == nil && store.portfolioBeta == nil)
        #expect(store.analyticsError?.contains("invalid") == true)
    }

    @MainActor @Test func missingHistoryStillKeepsItsExplicitExcludedCount() async throws {
        let name = "analytics.missing.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        let closes: [Double] = [100, 102, 101, 104, 103, 106, 105, 108]
        let history = StockSagePriceHistory(symbol: "AAPL", dates: days, opens: closes, highs: closes,
            lows: closes, closes: closes, volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: "AAPL"))
        let positions = [PortfolioPosition(symbol: "AAPL", shares: 1, costBasis: 100),
                         PortfolioPosition(symbol: "MSFT", shares: 1, costBasis: 100)]
        await store.applyPortfolioAnalytics(positions: positions, histories: ["AAPL": history], benchmark: nil)
        #expect(store.analytics?.holdingsAnalyzed == 1)
        #expect(store.analytics?.holdingsAttempted == 2)
        #expect(store.analyticsError == nil)
    }

    @MainActor @Test func invalidOrOverflowingLotsCannotDisappearBeforeAnalysis() async throws {
        let name = "analytics.aggregate-complete.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        let closes: [Double] = [100, 102, 101, 104, 103, 106, 105, 108]
        func history(_ symbol: String) -> StockSagePriceHistory {
            .init(symbol: symbol, dates: days, opens: closes, highs: closes, lows: closes,
                  closes: closes, volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: symbol))
        }
        func lot(_ symbol: String, _ shares: Double, _ cost: Double) -> PortfolioPosition {
            .init(symbol: symbol, shares: shares, costBasis: cost)
        }
        let normal = [lot("AAPL", 1, 100), lot("MSFT", 1, 100)]
        let histories = ["AAPL": history("AAPL"), "MSFT": history("MSFT")]
        let overflowing = [lot("AAPL", 1e308, 0), lot("AAPL", 1e308, 0), lot("MSFT", 1, 100)]
        #expect(StockSagePortfolio.holdingBySymbol(in: overflowing).count == 1,
                "The existing lookup helper omits the overflowing instrument; full-book assembly must catch it")
        let invalidBooks: [[PortfolioPosition]] = [
            overflowing,
            [lot("AAPL", 0, 100), lot("MSFT", 1, 100)],
            [lot("AAPL", .nan, 100), lot("MSFT", 1, 100)],
            [lot("AAPL", .infinity, 100), lot("MSFT", 1, 100)],
            [lot("AAPL", 1, -1), lot("MSFT", 1, 100)],
            [lot("AAPL", 1e308, 1e308), lot("MSFT", 1, 100)],
            [lot(" ", 1, 100), lot("MSFT", 1, 100)]
        ]
        for positions in invalidBooks {
            await store.applyPortfolioAnalytics(positions: normal, histories: histories, benchmark: history("^GSPC"))
            #expect(store.analytics != nil && store.correlation != nil && store.portfolioBeta != nil)
            await store.applyPortfolioAnalytics(positions: positions, histories: histories, benchmark: history("^GSPC"))
            #expect(store.analytics == nil && store.correlation == nil && store.portfolioBeta == nil)
            #expect(store.analyticsError != nil)
            #expect(!store.analyticsMatches(positions: positions))
        }
    }

    @MainActor @Test func allMissingHistoryAndEmptyBookClearEveryPriorAnalysis() async throws {
        let name = "analytics.no-history.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        let closes: [Double] = [100, 102, 101, 104, 103, 106, 105, 108]
        func history(_ symbol: String) -> StockSagePriceHistory {
            .init(symbol: symbol, dates: days, opens: closes, highs: closes, lows: closes,
                  closes: closes, volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: symbol))
        }
        let positions = [PortfolioPosition(symbol: "AAPL", shares: 1, costBasis: 100),
                         PortfolioPosition(symbol: "MSFT", shares: 1, costBasis: 100)]
        let histories = ["AAPL": history("AAPL"), "MSFT": history("MSFT")]
        for newPositions in [positions, []] {
            await store.applyPortfolioAnalytics(positions: positions, histories: histories, benchmark: history("^GSPC"))
            #expect(store.analytics != nil && store.correlation != nil && store.portfolioBeta != nil)
            await store.applyPortfolioAnalytics(positions: newPositions, histories: [:], benchmark: nil)
            #expect(store.analytics == nil && store.correlation == nil && store.portfolioBeta == nil)
            #expect(store.analyticsError != nil)
            #expect(!store.analyticsMatches(positions: positions))
        }
    }

    @MainActor @Test func emptyProductionRefreshClearsAllPriorOutputsWithoutLoading() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.releaseLoad(); probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        let originalPositions = probe.positions
        #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
        #expect(!probe.store.analyticsWeightsApproximate)
        #expect(probe.store.analyticsMatches(positions: originalPositions))
        probe.positions = []
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions },
            disabledReason: { probe.policyCalls += 1; return "Fixture offline" },
            load: { _ in probe.loadCalls += 1; Issue.record("Empty refresh must not call a loader"); return (probe.histories, probe.benchmark) })
        #expect(probe.policyCalls == 0 && probe.loadCalls == 0)
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(!probe.store.analyticsWeightsApproximate)
        #expect(!probe.store.analyticsMatches(positions: originalPositions))
        #expect(probe.store.analyticsError == "Add holdings to your portfolio first.")
        #expect(!probe.store.isLoadingAnalytics)
    }

    @MainActor @Test func blockedProductionRefreshRetainsOnlyAnUnchangedBook() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.releaseLoad(); probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        let analytics = try #require(probe.store.analytics)
        let matrix = try #require(probe.store.correlation).matrix
        let beta = try #require(probe.store.portfolioBeta)
        #expect(!probe.store.analyticsWeightsApproximate)
        let message = "Fixture offline: no provider requests allowed"
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions }, disabledReason: { message },
            load: { _ in probe.loadCalls += 1; Issue.record("Blocked refresh must not call a loader"); return (probe.histories, probe.benchmark) })
        #expect(probe.store.analytics == analytics)
        #expect(probe.store.correlation?.matrix == matrix && probe.store.portfolioBeta == beta)
        #expect(probe.store.analyticsMatches(positions: probe.positions))
        #expect(!probe.store.analyticsWeightsApproximate && probe.store.analyticsError == message)
        probe.positions[0].shares = 2
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions }, disabledReason: { message },
            load: { _ in probe.loadCalls += 1; Issue.record("Changed blocked book must not call a loader"); return (probe.histories, probe.benchmark) })
        #expect(probe.loadCalls == 0)
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: probe.positions))
        #expect(probe.store.analyticsError == message && !probe.store.isLoadingAnalytics)
    }

    @MainActor @Test func changedBookDuringProductionRefreshCannotPublishOldResults() async throws {
        for emptyBook in [true, false] {
            let probe = try PortfolioAnalyticsRefreshProbe()
            defer { probe.releaseLoad(); probe.cleanUp() }
            await probe.seedPopulatedAnalysis()
            #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
            let originalPositions = probe.positions
            let request = probe.startHeldRefresh()
            await probe.waitForLoadOrReturn()
            #expect(probe.loadStarted, "The real refresh must reach its injected loader")
            guard probe.loadStarted else { await request.value; continue }
            #expect(probe.store.isLoadingAnalytics && probe.loadCalls == 1)
            #expect(probe.loadedSymbols == ["AAPL", "NVDA"])
            if emptyBook { probe.positions = [] }
            else { probe.positions[0].shares = 2 }
            // This calls the same public production method while the first load
            // is suspended. Invalidation must precede its busy early-return.
            await probe.store.refreshPortfolioAnalytics(
                positionsSource: { probe.positions }, disabledReason: { nil },
                load: { _ in probe.loadCalls += 1; Issue.record("A second in-flight load is not permitted"); return (probe.histories, probe.benchmark) })
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate)
            probe.releaseLoad()
            await request.value
            #expect(probe.loadCalls == 1 && !probe.store.isLoadingAnalytics)
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: originalPositions))
            #expect(probe.store.analyticsError?.contains("Portfolio changed") == true)
        }
    }

    @MainActor @Test func revokedOrCancelledProductionRefreshCannotPublishResults() async throws {
        for cancelRequest in [false, true] {
            let probe = try PortfolioAnalyticsRefreshProbe()
            defer { probe.releaseLoad(); probe.cleanUp() }
            await probe.seedPopulatedAnalysis()
            #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
            let request = probe.startHeldRefresh()
            await probe.waitForLoadOrReturn()
            #expect(probe.loadStarted)
            guard probe.loadStarted else { await request.value; continue }
            if cancelRequest { request.cancel() }
            else { probe.policyReason = "Fixture policy revoked" }
            // The noncooperative fixture still returns valid data. The request
            // guard, rather than loader cancellation, must reject publication.
            probe.releaseLoad()
            await request.value
            #expect(probe.loadCalls == 1 && !probe.store.isLoadingAnalytics)
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: probe.positions))
            if cancelRequest {
                #expect(probe.store.analyticsError?.contains("cancelled") == true)
            } else {
                #expect(probe.store.analyticsError == "Fixture policy revoked")
            }
        }
    }

    @MainActor @Test func droppedInvalidSymbolCannotRetainAMatchingCacheWhenRefreshIsBlocked() async throws {
        let invalidAdditions: [[PortfolioPosition]] = [
            [PortfolioPosition(symbol: "MSFT", shares: 1e308, costBasis: 0),
             PortfolioPosition(symbol: "MSFT", shares: 1e308, costBasis: 0)],
            [PortfolioPosition(symbol: "MSFT", shares: -1, costBasis: 0)],
            [PortfolioPosition(symbol: "MSFT", shares: 0, costBasis: 0)],
            [PortfolioPosition(symbol: "MSFT", shares: 1, costBasis: .nan)]
        ]
        for additions in invalidAdditions {
            let probe = try PortfolioAnalyticsRefreshProbe()
            defer { probe.releaseLoad(); probe.cleanUp() }
            await probe.seedPopulatedAnalysis()
            let originalPositions = probe.positions
            #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
            #expect(probe.store.analyticsMatches(positions: originalPositions))
            let oldFingerprint = StockSagePortfolio.holdingBySymbol(in: originalPositions).mapValues(\.shares)
            probe.positions += additions
            // This is the real precondition that defeated the old fingerprint:
            // the new invalid instrument disappears from the aggregate map.
            #expect(StockSagePortfolio.holdingBySymbol(in: probe.positions).mapValues(\.shares) == oldFingerprint)
            #expect(!probe.store.analyticsMatches(positions: probe.positions))
            await probe.store.refreshPortfolioAnalytics(
                positionsSource: { probe.positions },
                disabledReason: { probe.policyCalls += 1; return "Fixture offline" },
                load: { _ in probe.loadCalls += 1; Issue.record("Blocked invalid book must not load"); return (probe.histories, probe.benchmark) })
            #expect(probe.policyCalls == 1 && probe.loadCalls == 0)
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate)
            #expect(!probe.store.analyticsMatches(positions: originalPositions))
            #expect(probe.store.analyticsError == "Fixture offline" && !probe.store.isLoadingAnalytics)
        }
    }

    @MainActor @Test func droppedInvalidSymbolInvalidatesBusyRefreshBeforeAnOldLoadCanReturn() async throws {
        let invalidAdditions: [[PortfolioPosition]] = [
            [PortfolioPosition(symbol: "MSFT", shares: 1e308, costBasis: 0),
             PortfolioPosition(symbol: "MSFT", shares: 1e308, costBasis: 0)],
            [PortfolioPosition(symbol: "MSFT", shares: -1, costBasis: 0)]
        ]
        for additions in invalidAdditions {
            let probe = try PortfolioAnalyticsRefreshProbe()
            defer { probe.releaseLoad(); probe.cleanUp() }
            await probe.seedPopulatedAnalysis()
            let originalPositions = probe.positions
            #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
            let oldFingerprint = StockSagePortfolio.holdingBySymbol(in: originalPositions).mapValues(\.shares)
            let request = probe.startHeldRefresh()
            await probe.waitForLoadOrReturn()
            #expect(probe.loadStarted)
            guard probe.loadStarted else { await request.value; continue }
            probe.positions += additions
            #expect(StockSagePortfolio.holdingBySymbol(in: probe.positions).mapValues(\.shares) == oldFingerprint)
            #expect(!probe.store.analyticsMatches(positions: probe.positions))
            await probe.store.refreshPortfolioAnalytics(
                positionsSource: { probe.positions },
                disabledReason: { Issue.record("Busy invalidation must precede the policy branch"); return "Fixture offline" },
                load: { _ in probe.loadCalls += 1; Issue.record("Busy refresh must not start a second load"); return (probe.histories, probe.benchmark) })
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate)
            #expect(probe.store.analyticsError == "Holdings changed. Refresh portfolio analytics.")
            #expect(probe.store.isLoadingAnalytics && probe.loadCalls == 1 && probe.policyCalls == 1)
            probe.releaseLoad()
            await request.value
            #expect(probe.loadCalls == 1 && !probe.store.isLoadingAnalytics)
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: originalPositions))
            #expect(probe.store.analyticsError?.contains("Portfolio changed") == true)
        }
    }


    @Test func zeroBenchmarkSharpeUsesMeanReturnDespiteCompoundingDrag() throws {
        // Exact returns alternate +10%, -10%: arithmetic mean is zero, while
        // compounded growth is 0.99 cubed. CAGR/volatility would falsely be negative.
        let a = try #require(PA.compute(holdings: [(1000, [100, 110, 99, 108.9, 98.01, 107.811, 97.0299])]))
        let sharpe = try #require(a.sharpe)
        #expect(a.annualizedReturn < 0)
        #expect(a.annualizedVolatility > 0)
        #expect(abs(sharpe) < 1e-12)
    }

    @Test func sharpeAnnualizationMatchesIndependentMeanVarianceReferences() throws {
        // Returns [0, .1, 0, .1, 0, .1] have mean .05 and SAMPLE variance .003.
        // Annualized zero-benchmark Sharpe is sqrt(210) for 252 periods and sqrt(10) for 12.
        let holdings: [(weight: Double, closes: [Double])] = [(1000, [100, 100, 110, 110, 121, 121, 133.1])]
        let daily = try #require(PA.compute(holdings: holdings))
        let monthly = try #require(PA.compute(holdings: holdings, periodsPerYear: 12))
        let dailySharpe = try #require(daily.sharpe)
        let monthlySharpe = try #require(monthly.sharpe)
        #expect(abs(dailySharpe - 14.491376746189438574) < 1e-10)
        #expect(abs(monthlySharpe - 3.1622776601683793320) < 1e-10)
    }

    @Test func elevenObservationLossQuantileRetainsTheWorstLoss() throws {
        // One 10% loss and ten 1% gains: only 10/11 scenarios are below the loss.
        // The inverse empirical CDF at .95 must therefore retain the 10% loss.
        var closes = [100.0]
        for r in [-0.10] + [Double](repeating: 0.01, count: 10) { closes.append(closes.last! * (1 + r)) }
        let a = try #require(PA.compute(holdings: [(1000, closes)]))
        #expect(abs(a.valueAtRisk95 - 10) < 1e-10)
        #expect(abs(a.cVaR95 - 10) < 1e-10)
    }

    @Test func expectedShortfallIncludesFractionalAndTiedBoundaryMass() throws {
        // 21 scenarios: worst 5% = 1.05 scenarios. Losses 10% and 5% contribute
        // 1 and .05 units: (10 + .05 * 5) / 1.05 = 205/21 percent.
        var fractional = [100.0]
        for r in [-0.10, -0.05] + [Double](repeating: 0, count: 19) { fractional.append(fractional.last! * (1 + r)) }
        let a = try #require(PA.compute(holdings: [(1000, fractional)]))
        #expect(abs(a.valueAtRisk95 - 5) < 1e-10)
        #expect(abs(a.cVaR95 - 9.761904761904761905) < 1e-10)

        // 100 scenarios: one 10% loss, five tied 5% losses, 94 flat days.
        // The worst five scenario-equivalents average (10 + 4 * 5) / 5 = 6%.
        var tied = [100.0]
        for r in [-0.10] + [Double](repeating: -0.05, count: 5) + [Double](repeating: 0, count: 94) { tied.append(tied.last! * (1 + r)) }
        let b = try #require(PA.compute(holdings: [(1000, tied)]))
        #expect(abs(b.valueAtRisk95 - 5) < 1e-10)
        #expect(abs(b.cVaR95 - 6) < 1e-10)
    }


    @MainActor @Test func mixedCurrencyRefreshClearsEveryOutputAfterMetadataLoads() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.releaseLoad(); probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
        probe.positions.append(PortfolioPosition(symbol: "BP.L", shares: 1, costBasis: 100))
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions },
            disabledReason: { probe.policyCalls += 1; return nil },
            load: { _ in
                probe.loadCalls += 1
                var histories = probe.histories
                var foreign = probe.histories["AAPL"]!
                foreign = StockSagePriceHistory(symbol: "BP.L", dates: foreign.dates, opens: foreign.opens,
                    highs: foreign.highs, lows: foreign.lows, closes: foreign.closes, volumes: foreign.volumes,
                    analyticsBasis: syntheticAnalyticsBasis(for: "BP.L"))
                histories["BP.L"] = foreign
                return (histories, probe.benchmark)
            })
        #expect(probe.policyCalls > 0 && probe.loadCalls == 1)
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: probe.positions))
        #expect(probe.store.analyticsError?.contains("multi-currency") == true)
        #expect(!probe.store.isLoadingAnalytics)
    }

    @MainActor @Test func directAssemblyRejectsMixedOrUnconfirmedCurrenciesEvenWithHistory() async throws {
        for symbols in [["AAPL", "BP.L"], ["AAPL", "UNCONFIRMED.XX"], ["ONE.XX", "TWO.XX"]] {
            let probe = try PortfolioAnalyticsRefreshProbe(symbols: symbols)
            defer { probe.releaseLoad(); probe.cleanUp() }
            await probe.seedPopulatedAnalysis()
            #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
            #expect(!probe.store.analyticsWeightsApproximate && !probe.store.analyticsMatches(positions: probe.positions))
            #expect(probe.store.analyticsError != nil)
        }
    }

    @MainActor @Test func unconfirmedCurrencyRefreshClearsPriorBookAfterMetadataLoads() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.releaseLoad(); probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
        probe.positions.append(PortfolioPosition(symbol: "UNCONFIRMED.XX", shares: 1, costBasis: 100))
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions },
            disabledReason: { probe.policyCalls += 1; return nil },
            load: { _ in
                probe.loadCalls += 1
                var histories = probe.histories
                let old = probe.histories["AAPL"]!
                histories["UNCONFIRMED.XX"] = StockSagePriceHistory(symbol: "UNCONFIRMED.XX",
                    dates: old.dates, opens: old.opens, highs: old.highs, lows: old.lows,
                    closes: old.closes, volumes: old.volumes)
                return (histories, probe.benchmark)
            })
        #expect(probe.policyCalls > 0 && probe.loadCalls == 1)
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(probe.store.analyticsError?.contains("metadata") == true)
        #expect(!probe.store.analyticsMatches(positions: probe.positions) && !probe.store.isLoadingAnalytics)
    }

    @MainActor @Test func currencyChangeDuringBusyRefreshCannotRestoreOldResults() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.releaseLoad(); probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        #expect(probe.store.analytics != nil && probe.store.correlation != nil && probe.store.portfolioBeta != nil)
        let request = probe.startHeldRefresh()
        await probe.waitForLoadOrReturn()
        #expect(probe.loadStarted)
        guard probe.loadStarted else { await request.value; return }
        probe.positions.append(PortfolioPosition(symbol: "BP.L", shares: 1, costBasis: 100))
        await probe.store.refreshPortfolioAnalytics(
            positionsSource: { probe.positions },
            disabledReason: { Issue.record("Currency invalidation must precede busy/policy branches"); return nil },
            load: { _ in Issue.record("Busy currency change must not start a second load"); return (probe.histories, probe.benchmark) })
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(probe.store.analyticsError?.contains("Holdings changed") == true)
        #expect(probe.store.isLoadingAnalytics && probe.loadCalls == 1)
        probe.releaseLoad()
        await request.value
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(!probe.store.analyticsMatches(positions: probe.positions) && !probe.store.isLoadingAnalytics)
        #expect(probe.store.analyticsError?.contains("Portfolio changed") == true)
    }

    @MainActor @Test func singleForeignCurrencyRetainsLocalRiskAndWithholdsIncomparableBeta() async throws {
        let foreign = try PortfolioAnalyticsRefreshProbe(symbols: ["BP.L", "VOD.L"])
        let usd = try PortfolioAnalyticsRefreshProbe()
        defer { foreign.cleanUp(); usd.cleanUp() }
        await foreign.seedPopulatedAnalysis()
        await usd.seedPopulatedAnalysis()
        let local = try #require(foreign.store.analytics)
        let dollar = try #require(usd.store.analytics)
        // Equal-value same-currency fixtures have identical percentage returns.
        #expect(abs(local.annualizedReturn - dollar.annualizedReturn) < 1e-10)
        #expect(abs(local.annualizedVolatility - dollar.annualizedVolatility) < 1e-10)
        #expect(foreign.store.correlation != nil && foreign.store.portfolioBeta == nil)
        #expect(usd.store.portfolioBeta != nil)
        #expect(local.caveat.contains("provider-reported GBP") && local.caveat.contains("beta unavailable"))
        #expect(dollar.caveat.contains("provider-reported USD") && !dollar.caveat.contains("beta unavailable"))
        #expect(!foreign.store.analyticsWeightsApproximate && foreign.store.analyticsError == nil)
        #expect(foreign.store.analyticsMatches(positions: foreign.positions))
    }

    @Test func yahooHistoryMetadataOverridesTickerAssumptionsAndPreservesRawUnits() throws {
        for (symbol, currency, instrument, code, divisor, periods) in [
            ("CSPX.L", "USD", "ETF", "USD", 1.0, 252),
            ("BTC-EUR", "EUR", "CRYPTOCURRENCY", "EUR", 1.0, 365),
            ("BP.L", "GBp", "EQUITY", "GBP", 100.0, 252),
            ("GBP-LISTING", "GBP", "EQUITY", "GBP", 1.0, 252),
            ("ZAR-LISTING", "ZAc", "EQUITY", "ZAR", 100.0, 252)
        ] {
            let meta: [String: Any] = ["symbol": symbol, "currency": currency,
                "instrumentType": instrument, "dataGranularity": "1d", "exchangeTimezoneName": "UTC"]
            let history = try #require(StockSageQuoteService.parseHistory(try yahooHistoryPayload(meta: meta), symbol: symbol))
            let basis = try #require(history.analyticsBasis)
            #expect(history.closes == [100, 101], "Metadata must not mutate displayed raw prices")
            #expect(basis.currencyCode == code && basis.rawUnitsPerMajor.rawValue == divisor)
            #expect(basis.sampling.rawValue == periods && basis.provenance == .yahooChartMetadata)
        }
    }

    @Test func absentOrAmbiguousMetadataPreservesHistoryButCannotAuthorizeRisk() throws {
        let valid: [String: Any] = ["symbol": "AAPL", "currency": "USD", "instrumentType": "EQUITY",
            "dataGranularity": "1d", "exchangeTimezoneName": "America/New_York"]
        var fixtures: [[String: Any]] = []
        for key in valid.keys {
            var value = valid
            value.removeValue(forKey: key)
            fixtures.append(value)
        }
        for (key, value) in [("currency", "usd"), ("currency", "UNKNOWN"), ("currency", " GBP"),
                             ("dataGranularity", "1wk"), ("instrumentType", "UNVERIFIED"),
                             ("exchangeTimezoneName", "Not/A_TimeZone")] {
            var metadata = valid
            metadata[key] = value
            fixtures.append(metadata)
        }
        for metadata in fixtures {
            let history = try #require(StockSageQuoteService.parseHistory(try yahooHistoryPayload(meta: metadata), symbol: "AAPL"))
            #expect(history.latestClose == 101 && history.analyticsBasis == nil)
        }
        var mismatched = valid
        mismatched["symbol"] = "OTHER"
        #expect(StockSageQuoteService.parseHistory(try yahooHistoryPayload(meta: mismatched), symbol: "AAPL") == nil)
    }

    @Test func massiveAggregatesCannotInventUSDFromUSRouting() throws {
        let payload: [String: Any] = ["status": "OK", "ticker": "AAPL", "adjusted": true,
            "results": [["t": 1_700_000_000_000, "o": 100, "h": 102, "l": 99, "c": 101, "v": 100],
                        ["t": 1_700_086_400_000, "o": 101, "h": 103, "l": 100, "c": 102, "v": 100]]]
        let history = try #require(StockSageMassive.parseHistory(try JSONSerialization.data(withJSONObject: payload), symbol: "AAPL"))
        #expect(history.closes == [101, 102] && history.priceSource == .massiveDaily)
        #expect(history.analyticsBasis == nil, "A matching ticker and valid OHLC do not establish denomination")
    }

    @Test func commonPriceEndpointsPrecedeReturnsAcrossWeekendGaps() throws {
        let start = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
        let equityDays = [0, 3, 4].map { start.addingTimeInterval(Double($0) * 86_400) }
        let cryptoDays = (0...4).map { start.addingTimeInterval(Double($0) * 86_400) }
        let equity = metadataHistory("AAPL", [100, 150, 165], dates: equityDays)
        let crypto = metadataHistory("BTC-USD", [100, 110, 140, 150, 165], sampling: .continuousDays365, dates: cryptoDays)
        let aligned = try #require(PA.alignPriceHistories([equity, crypto]))
        #expect(aligned.closes == [[100, 150, 165], [100, 150, 165]])
        let returns = PA.dailyReturns(aligned.closes[1])
        #expect(abs(returns[0] - 0.5) < 1e-12, "Monday must use Friday's common endpoint, not Sunday's private endpoint")
        #expect(abs(returns[1] - 0.1) < 1e-12)
    }

    @Test func priceAlignmentRejectsDuplicateUnorderedAndInvalidSessionDates() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let next = start.addingTimeInterval(86_400)
        for dates in [[start, start], [next, start], [start, Date(timeIntervalSince1970: .infinity)]] {
            #expect(PA.alignPriceHistories([metadataHistory("AAPL", [100, 101], dates: dates)]) == nil)
        }
        var unknown = metadataHistory("AAPL", [100, 101])
        unknown.analyticsBasis = nil
        #expect(PA.alignPriceHistories([unknown]) == nil)
        #expect(PA.alignPriceHistories([metadataHistory("AAPL", [100, 0])]) == nil)
    }

    @Test func exchangeSessionDatesDoNotShiftPacificPricesToYesterday() throws {
        let formatter = ISO8601DateFormatter()
        let nzDates = ["2026-01-04T20:00:00Z", "2026-01-05T20:00:00Z"].map { formatter.date(from: $0)! }
        let usDates = ["2026-01-05T14:30:00Z", "2026-01-06T14:30:00Z"].map { formatter.date(from: $0)! }
        let nz = metadataHistory("NZ-FIXTURE", [100, 110], zone: "Pacific/Auckland", dates: nzDates)
        let us = metadataHistory("US-FIXTURE", [100, 110], zone: "America/New_York", dates: usDates)
        let aligned = try #require(PA.alignPriceHistories([nz, us]))
        #expect(aligned.sessionDays.count == 2 && aligned.closes == [[100, 110], [100, 110]])
    }

    @MainActor @Test func loadedMetadataBlocksCrossCurrencyAndMixedCalendarBooks() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.cleanUp() }
        await probe.seedPopulatedAnalysis()
        let closes: [Double] = [100, 110, 99, 108.9, 98.01, 100]
        let stock = metadataHistory("AAPL", closes)
        let positions = [PortfolioPosition(symbol: "AAPL", shares: 1, costBasis: 100),
                         PortfolioPosition(symbol: "BTC-EUR", shares: 1, costBasis: 100)]
        let euro = metadataHistory("BTC-EUR", closes, currency: "EUR", sampling: .continuousDays365)
        await probe.store.applyPortfolioAnalytics(positions: positions,
            histories: ["AAPL": stock, "BTC-EUR": euro], benchmark: nil)
        #expect(probe.store.analytics == nil && probe.store.correlation == nil && probe.store.portfolioBeta == nil)
        #expect(probe.store.analyticsError?.contains("multi-currency") == true)
        let dollarCrypto = metadataHistory("BTC-EUR", closes, sampling: .continuousDays365)
        await probe.store.applyPortfolioAnalytics(positions: positions,
            histories: ["AAPL": stock, "BTC-EUR": dollarCrypto], benchmark: nil)
        #expect(probe.store.analytics == nil && probe.store.analyticsError?.contains("mixed trading-day") == true)
    }

    @MainActor @Test func verifiedRawUnitsProduceCorrectWeightsWithoutTickerConversion() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.cleanUp() }
        let moving: [Double] = [100, 110, 99, 108.9, 98.01, 100]
        let flat = [Double](repeating: 100, count: 6)
        for (movingSymbol, flatSymbol, currency, flatMultiplier) in [
            ("CSPX.L", "AAPL", "USD", 1.0),
            ("GBP-MAJOR", "GBP-PENCE", "GBP", 100.0)
        ] {
            let positions = [PortfolioPosition(symbol: movingSymbol, shares: 1, costBasis: 100),
                             PortfolioPosition(symbol: flatSymbol, shares: 1, costBasis: 100)]
            let a = metadataHistory(movingSymbol, moving, currency: currency)
            let b = metadataHistory(flatSymbol, flat.map { $0 * flatMultiplier }, currency: currency,
                                    units: flatMultiplier == 100 ? .hundredths : .major)
            await probe.store.applyPortfolioAnalytics(positions: positions,
                histories: [movingSymbol: a, flatSymbol: b], benchmark: nil)
            let analytics = try #require(probe.store.analytics)
            // At the final common close both positions are exactly 100 major
            // currency units. The moving holding's 10% loss contributes 5%.
            #expect(abs(analytics.valueAtRisk95 - 5) < 1e-10)
            #expect(analytics.caveat.contains("provider-reported \(currency)"))
        }
    }

    @MainActor @Test func differentTradingGridsCannotAnnualizeCompressedIntervals() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.cleanUp() }
        let closes: [Double] = [100, 110, 99, 108.9, 98.01, 107.811, 100, 102]
        let first = metadataHistory("AAPL", closes)
        let positions: [PortfolioPosition] = [.init(symbol: "AAPL", shares: 1, costBasis: 100),
                                             .init(symbol: "MSFT", shares: 1, costBasis: 100)]
        let retained = first.dates.indices.filter { $0 != 3 }
        let incomplete = metadataHistory("MSFT", retained.map { closes[$0] }, dates: retained.map { first.dates[$0] })
        await probe.store.applyPortfolioAnalytics(positions: positions,
            histories: ["AAPL": first, "MSFT": incomplete], benchmark: nil)
        #expect(probe.store.analytics == nil && probe.store.analyticsError?.contains("different session-date grids") == true)
        let differentCalendar = metadataHistory("MSFT", closes, zone: "Asia/Riyadh", dates: first.dates)
        await probe.store.applyPortfolioAnalytics(positions: positions,
            histories: ["AAPL": first, "MSFT": differentCalendar], benchmark: nil)
        #expect(probe.store.analytics == nil && probe.store.analyticsError?.contains("different trading calendars") == true)
        // A benchmark gap is allowed to reduce only beta's common sample.
        let identical = metadataHistory("MSFT", closes)
        await probe.store.applyPortfolioAnalytics(positions: positions,
            histories: ["AAPL": first, "MSFT": identical], benchmark: incomplete)
        #expect(probe.store.analytics != nil && probe.store.analytics?.observations == 7)
    }

    @MainActor @Test func continuousDailyHistoryUses365DayAnnualization() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.cleanUp() }
        let closes: [Double] = [100, 110, 99, 108.9, 98.01, 107.811, 97.0299]
        let history = metadataHistory("BTC-USD", closes, sampling: .continuousDays365)
        await probe.store.applyPortfolioAnalytics(positions: [.init(symbol: "BTC-USD", shares: 1, costBasis: 100)],
            histories: ["BTC-USD": history], benchmark: nil)
        let analytics = try #require(probe.store.analytics)
        // Independent 70-digit Decimal reference: six alternating +/-10%
        // returns, sample variance0.012, growth0.99^3; annualize with365 periods.
        #expect(abs(analytics.annualizedVolatility - 209.2844953645634973) < 1e-9)
        #expect(abs(analytics.annualizedReturn + 84.02565667944650376) < 1e-9)
        #expect(analytics.caveat.contains("365 calendar-day periods"))
        let gaps = [0, 1, 2, 3, 4, 5, 7].map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400) }
        let incomplete = metadataHistory("BTC-USD", closes, sampling: .continuousDays365, dates: gaps)
        await probe.store.applyPortfolioAnalytics(positions: [.init(symbol: "BTC-USD", shares: 1, costBasis: 100)],
            histories: ["BTC-USD": incomplete], benchmark: nil)
        #expect(probe.store.analytics == nil && probe.store.analyticsError?.contains("missing price dates") == true)
    }

    @MainActor @Test func betaRequiresVerifiedComparableDenominationAndUsesCommonPrices() async throws {
        let probe = try PortfolioAnalyticsRefreshProbe()
        defer { probe.cleanUp() }
        let closes: [Double] = [100, 110, 99, 108.9, 98.01, 100]
        let holding = metadataHistory("GBP-FIXTURE", closes, currency: "GBP")
        let positions: [PortfolioPosition] = [.init(symbol: "GBP-FIXTURE", shares: 1, costBasis: 100)]
        var benchmark = metadataHistory("^GSPC", closes)
        await probe.store.applyPortfolioAnalytics(positions: positions, histories: ["GBP-FIXTURE": holding], benchmark: benchmark)
        #expect(probe.store.analytics != nil && probe.store.portfolioBeta == nil)
        // A synthetic reference explicitly supplied in the same currency may be
        // compared. Production does not fetch or manufacture a converted series.
        benchmark = metadataHistory("^GSPC", closes, currency: "GBP")
        await probe.store.applyPortfolioAnalytics(positions: positions, histories: ["GBP-FIXTURE": holding], benchmark: benchmark)
        #expect(abs((probe.store.portfolioBeta ?? .nan) - 1) < 1e-12)
        benchmark.analyticsBasis = nil
        await probe.store.applyPortfolioAnalytics(positions: positions, histories: ["GBP-FIXTURE": holding], benchmark: benchmark)
        #expect(probe.store.analytics != nil && probe.store.portfolioBeta == nil)
    }

    private func yahooHistoryPayload(meta: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chart": ["result": [["meta": meta,
            "timestamp": [1_700_000_000, 1_700_086_400], "indicators": ["quote": [[
                "open": [100, 101], "high": [100, 101], "low": [100, 101],
                "close": [100, 101], "volume": [100, 100]]]]]]]])
    }

    private func metadataHistory(_ symbol: String, _ closes: [Double], currency: String = "USD",
        units: StockSageHistoryBasis.RawUnitsPerMajor = .major,
        sampling: StockSageHistoryBasis.DailySampling = .tradingDays252,
        zone: String = "UTC", dates: [Date]? = nil) -> StockSagePriceHistory {
        let basis = StockSageHistoryBasis(currencyCode: currency, rawUnitsPerMajor: units,
            sampling: sampling, exchangeTimeZoneIdentifier: zone, provenance: .syntheticFixture)!
        let dateValues = dates ?? (0..<closes.count).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400) }
        return StockSagePriceHistory(symbol: symbol, dates: dateValues, opens: closes, highs: closes,
            lows: closes, closes: closes, volumes: Array(repeating: 100, count: closes.count), analyticsBasis: basis)
    }


}


@MainActor
private final class PortfolioAnalyticsRefreshProbe {
    let domain: String
    let defaults: UserDefaults
    let store: StockSageStore
    var positions: [PortfolioPosition]
    let histories: [String: StockSagePriceHistory]
    let benchmark: StockSagePriceHistory
    var policyReason: String?
    var policyCalls = 0
    var loadCalls = 0
    private(set) var loadedSymbols: [String] = []
    private(set) var loadStarted = false
    private var refreshReturned = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var loadContinuation: CheckedContinuation<([String: StockSagePriceHistory], StockSagePriceHistory?), Never>?

    init(symbols: [String] = ["AAPL", "NVDA"]) throws {
        domain = "analytics.production-refresh.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        positions = symbols.map { PortfolioPosition(symbol: $0, shares: 1, costBasis: 100) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let days = (0..<8).map { start.addingTimeInterval(Double($0) * 86400) }
        let closes: [Double] = [100, 102, 101, 104, 103, 106, 105, 108]
        func history(_ symbol: String) -> StockSagePriceHistory {
            .init(symbol: symbol, dates: days, opens: closes, highs: closes, lows: closes,
                  closes: closes, volumes: Array(repeating: 100, count: closes.count), analyticsBasis: syntheticAnalyticsBasis(for: symbol))
        }
        histories = Dictionary(uniqueKeysWithValues: symbols.map { ($0, history($0)) })
        benchmark = history("^GSPC")
    }

    func seedPopulatedAnalysis() async {
        await store.applyPortfolioAnalytics(positions: positions, histories: histories, benchmark: benchmark)
    }

    func startHeldRefresh() -> Task<Void, Never> {
        Task {
            await self.store.refreshPortfolioAnalytics(
                positionsSource: { self.positions },
                disabledReason: { self.policyCalls += 1; return self.policyReason },
                load: { await self.holdLoad($0) })
            self.refreshReturned = true
            self.resumeStartWaiter()
        }
    }

    func waitForLoadOrReturn() async {
        guard !loadStarted && !refreshReturned else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            startWaiter = waiter
        }
    }

    private func holdLoad(_ symbols: [String]) async -> ([String: StockSagePriceHistory], StockSagePriceHistory?) {
        loadCalls += 1
        loadedSymbols = symbols
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
            loadStarted = true
            resumeStartWaiter()
        }
    }

    private func resumeStartWaiter() {
        let waiter = startWaiter
        startWaiter = nil
        waiter?.resume()
    }

    func releaseLoad() {
        let continuation = loadContinuation
        loadContinuation = nil
        continuation?.resume(returning: (histories, benchmark))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
    }
}

// Explicit declarations for named synthetic fixtures only. Production never
// calls this helper and never infers metadata from these ticker names.
private func syntheticAnalyticsBasis(for symbol: String) -> StockSageHistoryBasis? {
    let currencies = ["AAPL": "USD", "NVDA": "USD", "MSFT": "USD", "^GSPC": "USD",
                      "2222.SR": "SAR", "BP.L": "GBP", "VOD.L": "GBP"]
    guard let currency = currencies[symbol] else { return nil }
    return StockSageHistoryBasis(currencyCode: currency, rawUnitsPerMajor: .major,
        sampling: .tradingDays252, exchangeTimeZoneIdentifier: "UTC", provenance: .syntheticFixture)
}
