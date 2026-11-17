import Foundation

/// Arithmetic over explicit observation and recorded cost denominations. No ticker
/// inference or FX occurs here; different currencies remain different totals.
nonisolated enum StockSageRecordedValuation {
    struct Holding: Equatable, Sendable {
        let currency: String
        let value: Double
        let cost: Double?
        let profit: Double?
    }

    struct CurrencyTotal: Equatable, Sendable, Identifiable {
        let currency: String
        let value: Double
        let cost: Double?
        let profit: Double?
        let pricedLots: Int
        var id: String { currency }
    }

    static func holding(_ position: PortfolioPosition, quote: StockSageQuote?, now: Date) -> Holding? {
        guard position.shares.isFinite, position.shares > 0,
              let quote, let rawPrice = quote.usableHoldingPrice(isSampleData: false, now: now),
              let unit = quote.denomination,
              let majorPrice = unit.majorValue(rawValue: rawPrice) else { return nil }
        let value = majorPrice * position.shares
        guard value.isFinite, value > 0 else { return nil }
        var cost: Double?
        if let costUnit = position.costDenomination, costUnit.currencyCode == unit.currencyCode,
           position.costBasis >= 0, let majorCost = costUnit.majorValue(rawValue: position.costBasis) {
            let amount = majorCost * position.shares
            if amount.isFinite, majorCost == 0 || amount > 0 { cost = amount }
        }
        let profit = cost.flatMap { cost -> Double? in
            let result = value - cost
            return result.isFinite ? result : nil
        }
        return Holding(currency: unit.currencyCode, value: value, cost: cost, profit: profit)
    }

    /// nil means an arithmetic failure, not an empty portfolio. Missing marks are
    /// counted by the caller; the resulting rows are explicitly priced-lot totals.
    static func totals(_ holdings: [Holding]) -> [CurrencyTotal]? {
        let grouped = Dictionary(grouping: holdings, by: \.currency)
        var totals: [CurrencyTotal] = []
        for currency in grouped.keys.sorted() {
            guard let rows = grouped[currency] else { continue }
            let value = rows.reduce(0) { $0 + $1.value }
            guard value.isFinite else { return nil }
            let cost: Double?
            if rows.allSatisfy({ $0.cost != nil }) {
                let sum = rows.reduce(0) { $0 + $1.cost! }
                guard sum.isFinite else { return nil }
                cost = sum
            } else { cost = nil }
            let profit = cost.map { value - $0 }
            guard profit?.isFinite ?? true else { return nil }
            totals.append(CurrencyTotal(currency: currency, value: value, cost: cost,
                profit: profit, pricedLots: rows.count))
        }
        return totals
    }
}
