import Testing
import Foundation
@testable import StockSage

// MARK: - Portfolio beta vs market (pure)

struct StockSagePortfolioBetaTests {

    typealias PA = StockSagePortfolioAnalytics

    private let market: [Double] = [0.01, -0.02, 0.015, 0.00, -0.01, 0.03, -0.005, 0.02]

    @Test func betaOfMarketAgainstItselfIsOne() {
        #expect(abs(PA.beta(portfolio: market, market: market)! - 1.0) < 1e-9)
    }

    @Test func twiceTheMarketIsBetaTwo() {
        let levered = market.map { 2 * $0 }
        #expect(abs(PA.beta(portfolio: levered, market: market)! - 2.0) < 1e-9)
    }

    @Test func invertedMarketIsNegativeBeta() {
        let inverse = market.map { -$0 }
        #expect(abs(PA.beta(portfolio: inverse, market: market)! + 1.0) < 1e-9)
    }

    @Test func flatMarketHasNoDefinedBeta() {
        let flat = [Double](repeating: 0, count: 8)
        #expect(PA.beta(portfolio: market, market: flat) == nil)   // zero market variance
    }

    @Test func tooFewPointsIsNil() {
        #expect(PA.beta(portfolio: [0.1, 0.2], market: [0.1, 0.2]) == nil)
    }

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

    @Test func datedReturnsTagEndDate() {
        let d = [day(0), day(1), day(2)]
        let r = PA.datedReturns(dates: d, closes: [100, 110, 121])
        #expect(r.count == 2)
        #expect(r[0].date == day(1) && abs(r[0].ret - 0.10) < 1e-9)
        #expect(r[1].date == day(2) && abs(r[1].ret - 0.10) < 1e-9)
    }

    @Test func alignByDateIntersectsCommonDays() {
        let a = [(date: day(1), ret: 0.01), (date: day(2), ret: 0.02), (date: day(3), ret: 0.03)]
        let b = [(date: day(1), ret: 0.10), (date: day(3), ret: 0.30), (date: day(4), ret: 0.40)]
        let aligned = PA.alignByDate([a, b])
        #expect(aligned[0] == [0.01, 0.03])   // common days 1 & 3
        #expect(aligned[1] == [0.10, 0.30])
    }

    @Test func betaIsDateAlignedNotPositionShifted() {
        // Market on days 1…6; portfolio is the SAME returns but MISSING day 3 (a
        // holiday). Positional suffix-alignment would shift and corrupt beta;
        // date alignment must recover beta = 1 over the common days.
        let m = [0.01, -0.02, 0.015, 0.00, -0.01, 0.03]
        let mkt = (1...6).map { (date: day($0), ret: m[$0 - 1]) }
        let port = [1, 2, 4, 5, 6].map { (date: day($0), ret: m[$0 - 1]) }
        let aligned = PA.alignByDate([port, mkt])
        #expect(aligned[0] == aligned[1])                                   // same-day values match
        #expect(abs(PA.beta(portfolio: aligned[0], market: aligned[1])! - 1.0) < 1e-9)
    }

    @Test func portfolioReturnsAreValueWeighted() {
        // Two holdings, equal weight: one up 10%/day step, one flat → port return is the mean.
        let up: [Double] = [110, 121, 133.1]      // +10% each step
        let flat: [Double] = [100, 100, 100]
        let port = PA.portfolioReturns(holdings: [(weight: 1, closes: up), (weight: 1, closes: flat)])
        // Each step: (0.10 + 0.0)/2 = 0.05
        #expect(port.count == 2)
        #expect(abs(port[0] - 0.05) < 1e-9)
        #expect(abs(port[1] - 0.05) < 1e-9)
    }
}
