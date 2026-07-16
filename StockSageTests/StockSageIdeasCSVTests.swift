import Testing
import Foundation
@testable import StockSage

// MARK: - Ideas board CSV export (pure)

struct StockSageIdeasCSVTests {
    private func idea(_ symbol: String, _ price: Double, _ action: TradeAdvice.Action,
                      conviction: Double = 0.5, stop: Double? = nil, target: Double? = nil,
                      weight: Double = 0.05, regime: TradeAdvice.Regime = .bullTrend,
                      rationale: [String] = []) -> StockSageIdea {
        StockSageIdea(
            symbol: symbol, market: "M", price: price,
            advice: TradeAdvice(action: action, conviction: conviction, regime: regime,
                                rationale: rationale, stopPrice: stop, targetPrice: target,
                                suggestedWeight: weight, caveat: "x"),
            spark: [])
    }

    @Test func headerAndRowCount() {
        let csv = StockSageIdeasCSV.csv([idea("AAPL", 100, .buy), idea("NVDA", 200, .strongBuy)])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(csv.hasPrefix(StockSageIdeasCSV.header))
        #expect(lines.count == 3)   // header + 2 rows
    }

    @Test func emptyIdeasYieldsHeaderOnly() {
        #expect(StockSageIdeasCSV.csv([]) == StockSageIdeasCSV.header)
    }

    @Test func rankReflectsListOrderAndFieldsAreCorrect() {
        let csv = StockSageIdeasCSV.csv([
            idea("NVDA", 200, .strongBuy, conviction: 0.9, stop: 180, target: 260, weight: 0.12),
            idea("AAPL", 100, .buy),
        ])
        let rows = csv.split(separator: "\n").map(String.init)
        #expect(rows[1].hasPrefix("1,NVDA,M,200.0,Strong Buy,0.90,180.0,260.0,12.0,Bullish trend,"))
        #expect(rows[2].hasPrefix("2,AAPL,M,100.0,Buy,"))
    }

    @Test func missingStopTargetRenderEmpty() {
        let csv = StockSageIdeasCSV.csv([idea("AAPL", 100, .hold, stop: nil, target: nil)])
        // ...,conviction,stop,target,... → two empty fields back to back
        #expect(csv.contains(",0.50,,,"))
    }

    @Test func rationaleWithCommaIsQuoted() {
        let csv = StockSageIdeasCSV.csv([idea("AAPL", 100, .buy, rationale: ["RSI low", "MACD up"])])
        // joined with "; " → "RSI low; MACD up" (no comma) stays unquoted;
        // a comma inside a bullet must be quoted.
        let csv2 = StockSageIdeasCSV.csv([idea("AAPL", 100, .buy, rationale: ["up, then flat"])])
        #expect(!csv.contains("\""))
        #expect(csv2.contains("\"up, then flat\""))
    }

    // EXPORT-04: hand-derived row for a held/traded symbol.
    // idea = NVDA, 200, strongBuy, conviction 0.9, stop 180, target 260, weight 0.12, regime bullTrend, rationale [].
    // Base fields (unchanged from rankReflectsListOrderAndFieldsAreCorrect):
    //   1,NVDA,M,200.0,Strong Buy,0.90,180.0,260.0,12.0,Bullish trend,
    // heldShares["NVDA"] = 10 → "10.0"; closedTrades["NVDA"] = 3 → "3".
    // A2: the idea() helper sets no priceAsOf ⇒ trailing empty priceAsOf column.
    // Full row: 1,NVDA,M,200.0,Strong Buy,0.90,180.0,260.0,12.0,Bullish trend,,10.0,3,
    @Test func heldAndClosedTrailingColumnsPopulateFromContext() {
        let csv = StockSageIdeasCSV.csv(
            [idea("NVDA", 200, .strongBuy, conviction: 0.9, stop: 180, target: 260, weight: 0.12)],
            heldShares: ["NVDA": 10],
            closedTrades: ["NVDA": 3])
        let rows = csv.split(separator: "\n").map(String.init)
        #expect(rows[0].hasSuffix(",closedTrades,priceAsOf"))
        #expect(rows[1] == "1,NVDA,M,200.0,Strong Buy,0.90,180.0,260.0,12.0,Bullish trend,,10.0,3,")
    }

    @Test func heldAndClosedTrailingColumnsEmptyWhenUnresolved() {
        let csv = StockSageIdeasCSV.csv([idea("AAPL", 100, .buy)])
        // no context passed → defaults to [:] → rationale, heldShares, closedTrades, priceAsOf all empty:
        // 1,AAPL,M,100.0,Buy,0.50,,,5.0,Bullish trend,,,,
        let rows = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(rows[1] == "1,AAPL,M,100.0,Buy,0.50,,,5.0,Bullish trend,,,,")
    }

    // A2: price-freshness column. Date(timeIntervalSince1970: 1_704_067_200) is exactly
    // 2024-01-01T00:00:00Z (54*365 + 13 leap days = 19723 days * 86400), so
    // .iso8601.year().month().day() in the GMT default renders "2024-01-01". nil ⇒ empty.
    @Test func priceAsOfColumnRendersUTCDateAndEmptyWhenNil() {
        let dated = StockSageIdea(
            symbol: "AAPL", market: "M", price: 100,
            advice: TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend,
                                rationale: [], stopPrice: nil, targetPrice: nil,
                                suggestedWeight: 0.05, caveat: "x"),
            spark: [], priceAsOf: Date(timeIntervalSince1970: 1_704_067_200))
        let rows = StockSageIdeasCSV.csv([dated]).split(separator: "\n").map(String.init)
        #expect(rows[0].hasSuffix(",priceAsOf"))
        #expect(rows[1].hasSuffix(",2024-01-01"))
        // nil priceAsOf (the idea() helper) ⇒ trailing empty field, never a fabricated date.
        let undated = StockSageIdeasCSV.csv([idea("NVDA", 200, .buy)]).split(separator: "\n").map(String.init)
        #expect(undated[1].hasSuffix("Bullish trend,,,,"))
    }
}
