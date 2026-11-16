import Foundation

// MARK: - Portfolio heat (total open risk vs equity)
//
// Each trade sized at "1% risk" feels safe in isolation, but ten of them open at once is
// 10% of the account on the line — exposure a single bad day (or a correlated gap) hits
// all at once, and nothing else in the app surfaces it. Heat = Σ (shares · |entry−stop|)
// ÷ account: the fraction of equity you'd lose if every open stop filled. Pure +
// deterministic. Honest: assumes each stop fills AT its level — a gap can lose more.

struct PortfolioHeat: Sendable, Equatable {
    let dollarsAtRisk: Double   // Σ open risk in account currency
    let accountSize: Double
    let openCount: Int
    nonisolated var heatPct: Double { accountSize > 0 ? dollarsAtRisk / accountSize : 0 }

    enum Level: String, Sendable { case cool, warm, hot }
    /// <5% cool, <10% warm, ≥10% hot.
    nonisolated var level: Level { heatPct < 0.05 ? .cool : (heatPct < 0.10 ? .warm : .hot) }

    nonisolated var percentageText: String? {
        StockSageRiskDisplay.percentageText(heatPct * 100)
    }

    nonisolated var verdict: String {
        guard let percentageText else { return "Stop-risk percentage unavailable." }
        return "\(percentageText)% of the entered account at planned stop risk."
    }

    nonisolated var accessibilitySummary: String {
        guard let percentageText else { return "Portfolio stop-risk percentage unavailable." }
        return "Portfolio stop risk: \(percentageText) percent of the entered account across \(openCount) trades."
    }
    nonisolated var caveat: String {
        "Assumes each stop fills AT its level; a correlated gap can hit several at once for more than this."
    }
}

enum StockSagePortfolioHeat {
    /// Complete finite open risk divided by a finite positive account value.
    /// An invalid leg or arithmetic overflow makes the whole total unavailable;
    /// an omitted leg must never become a reassuring partial/zero total.
    nonisolated static func compute(openTrades: [(shares: Double, entry: Double, stop: Double)],
                                    accountSize: Double) -> PortfolioHeat? {
        guard accountSize.isFinite, accountSize > 0 else { return nil }
        var atRisk = 0.0
        for trade in openTrades {
            guard trade.shares.isFinite, trade.shares > 0,
                  trade.entry.isFinite, trade.entry > 0,
                  trade.stop.isFinite, trade.stop > 0 else { return nil }
            let distance = abs(trade.entry - trade.stop)
            let risk = trade.shares * distance
            guard risk.isFinite, risk >= 0, distance == 0 || risk > 0 else { return nil }
            let total = atRisk + risk
            guard total.isFinite else { return nil }
            atRisk = total
        }
        let percentage = atRisk / accountSize * 100
        guard percentage.isFinite, atRisk == 0 || percentage > 0 else { return nil }
        return PortfolioHeat(dollarsAtRisk: atRisk, accountSize: accountSize, openCount: openTrades.count)
    }

    /// Convert EVERY recorded trade to USD before calculating a total. Missing,
    /// invalid or overflowing FX leaves the entire result unknown, including the
    /// paper-book value written to the widget. No network or shared state is used.
    nonisolated static func compute(trades: [TradeRecord], accountSize: Double,
                                    ratesToUSD: [String: Double]) -> PortfolioHeat? {
        var legs: [(shares: Double, entry: Double, stop: Double)] = []
        legs.reserveCapacity(trades.count)
        for trade in trades {
            let currency = StockSageCurrency.conversionCurrencyForSymbol(trade.symbol)
            guard let rate = currency == "USD" ? 1 : ratesToUSD[currency],
                  rate.isFinite, rate > 0 else { return nil }
            let entry = StockSageCurrency.majorUnitValue(symbol: trade.symbol, rawValue: trade.entry) * rate
            let stop = StockSageCurrency.majorUnitValue(symbol: trade.symbol, rawValue: trade.stop) * rate
            guard trade.entry == trade.stop || entry != stop else { return nil }
            legs.append((shares: trade.shares, entry: entry, stop: stop))
        }
        return compute(openTrades: legs, accountSize: accountSize)
    }
}
