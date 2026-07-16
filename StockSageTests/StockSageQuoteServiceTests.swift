import Testing
import Foundation
@testable import StockSage

// MARK: - Quote feed parsing — only-real-data validity guards
// (Named distinctly from `StockSageQuoteServiceTests` in StockSageTests.swift,
// which covers signal recommendations; this one covers history JSON parsing.)

struct StockSageQuoteServiceParsingTests {

    @Test func parseChartCapturesMarketTimeWhenPresent() {
        let withTime = #"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":150,"previousClose":148,"regularMarketTime":1700000000}}]}}"#
        let q = StockSageQuoteService.parseChart(Data(withTime.utf8))
        #expect(q?.price == 150)
        #expect(q?.marketTime == Date(timeIntervalSince1970: 1_700_000_000))
        // No regularMarketTime → nil (still parses the quote, just no freshness stamp).
        let noTime = #"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":150,"previousClose":148}}]}}"#
        let q2 = StockSageQuoteService.parseChart(Data(noTime.utf8))
        #expect(q2?.price == 150 && q2?.marketTime == nil)
    }

    @Test func parseChartFlagsANewListingOnlyWhenTheFallbackActuallyFired() {
        // No previousClose AND no chartPreviousClose → falls back to price; isNewListing must be
        // true so the UI reads "unevaluated," not a real 0%-move hold signal.
        let noClose = #"{"chart":{"result":[{"meta":{"symbol":"IPOX","regularMarketPrice":42}}]}}"#
        let q = StockSageQuoteService.parseChart(Data(noClose.utf8))
        #expect(q?.previousClose == 42 && q?.isNewListing == true)
        // A REAL previousClose that happens to equal price (a genuinely flat session) must NOT
        // be flagged — the flag is set precisely at the fallback site, never inferred from equality.
        let genuinelyFlat = #"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":150,"previousClose":150}}]}}"#
        let q2 = StockSageQuoteService.parseChart(Data(genuinelyFlat.utf8))
        #expect(q2?.previousClose == 150 && q2?.isNewListing == false)
        // chartPreviousClose fallback (indices) is a REAL prior close, not a new listing.
        let indexFallback = #"{"chart":{"result":[{"meta":{"symbol":"^GSPC","regularMarketPrice":5000,"chartPreviousClose":4950}}]}}"#
        let q3 = StockSageQuoteService.parseChart(Data(indexFallback.utf8))
        #expect(q3?.previousClose == 4950 && q3?.isNewListing == false)
    }

    // L3-08 (AUDIT_2026-07-07_stocksage.md): previousClose <= 0 (or non-finite) must flow through
    // the SAME missing-previousClose path as a truly absent field — never fabricate a flat 0.00%.
    @Test func parseChartTreatsNonPositivePreviousCloseAsMissing() {
        // previousClose: 0 → same as absent: falls back to price, isNewListing true.
        let zeroClose = #"{"chart":{"result":[{"meta":{"symbol":"ZERO","regularMarketPrice":88,"previousClose":0}}]}}"#
        let qZero = StockSageQuoteService.parseChart(Data(zeroClose.utf8))
        #expect(qZero?.previousClose == 88 && qZero?.isNewListing == true)

        // previousClose: -5 (corrupt/negative) → same treatment.
        let negClose = #"{"chart":{"result":[{"meta":{"symbol":"NEG","regularMarketPrice":30,"previousClose":-5}}]}}"#
        let qNeg = StockSageQuoteService.parseChart(Data(negClose.utf8))
        #expect(qNeg?.previousClose == 30 && qNeg?.isNewListing == true)

        // previousClose: NaN (via a non-finite string Yahoo would never legitimately send but a
        // corrupt payload might) → number() already rejects non-finite, exercising the same path.
        let nanClose = #"{"chart":{"result":[{"meta":{"symbol":"NANX","regularMarketPrice":15,"previousClose":"nan"}}]}}"#
        let qNan = StockSageQuoteService.parseChart(Data(nanClose.utf8))
        #expect(qNan?.previousClose == 15 && qNan?.isNewListing == true)

        // Regression pin: a normal positive previousClose is unaffected.
        let normal = #"{"chart":{"result":[{"meta":{"symbol":"OK","regularMarketPrice":100,"previousClose":95}}]}}"#
        let qOk = StockSageQuoteService.parseChart(Data(normal.utf8))
        #expect(qOk?.previousClose == 95 && qOk?.isNewListing == false)
    }

    @Test func parseHistoryRejectsNonPositiveBars() {
        // 4 bars: bar 2 has a 0 close, bar 4 has a negative low — both must be dropped so a
        // garbage price can never become latestClose → price×shares / EV / sizing.
        let json = """
        {"chart":{"result":[{"timestamp":[1,2,3,4],
          "indicators":{"quote":[{
            "open":[10,11,12,13],
            "high":[11,12,13,14],
            "low":[9,10,11,-1],
            "close":[10,0,12,13],
            "volume":[100,100,100,100]}]}}]}}
        """
        let h = StockSageQuoteService.parseHistory(Data(json.utf8), symbol: "TEST")
        #expect(h != nil)
        if let h {
            #expect(h.closes.count == 2)               // bars 1 and 3 only
            #expect(h.closes.allSatisfy { $0 > 0 })
            #expect(h.closes == [10, 12])
        }
        // All-bad input → fewer than 2 valid bars → nil (existing guard).
        let bad = """
        {"chart":{"result":[{"timestamp":[1,2],
          "indicators":{"quote":[{"open":[1,1],"high":[1,1],"low":[1,1],"close":[0,-5],"volume":[0,0]}]}}]}}
        """
        #expect(StockSageQuoteService.parseHistory(Data(bad.utf8), symbol: "X") == nil)
    }
}
