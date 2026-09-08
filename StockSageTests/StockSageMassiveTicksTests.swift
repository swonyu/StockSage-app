import Testing
import Foundation
@testable import StockSage

@Suite("Massive bounded tape")
struct StockSageMassiveTicksTests {
    typealias T = StockSageMassiveTicks
    let from = Date(timeIntervalSince1970: 1_517_561_900)
    let to = Date(timeIntervalSince1970: 1_517_562_100)

    @Test @MainActor func paperFallbackRejectsAveragesPriorReferencesAndLateReports() throws {
        let reference = Data(#"{"status":"OK","results":[{"id":701,"name":"Form T/Extended Hours","asset_class":"stocks","data_types":["trade"]},{"id":702,"name":"Odd Lot Trade","asset_class":"stocks","data_types":["trade"]},{"id":703,"name":"Prior Reference Price","asset_class":"stocks","data_types":["trade"]},{"id":704,"name":"Average Price Trade","asset_class":"stocks","data_types":["trade"]}]}"#.utf8)
        let allowed = try T.parsePaperTradeConditions(reference)
        #expect(allowed == [701, 702], "Resolve live reference identities, not assumed production IDs")
        let now = to
        func row(_ conditions: Any, age: Int64 = 1, participantAge: Int64 = 2, correction: Any = 0) -> [String: Any] {
            ["price": 100, "size": 10, "conditions": conditions, "correction": correction,
             "sip_timestamp": (Int64(now.timeIntervalSince1970) - age) * 1_000_000_000,
             "participant_timestamp": (Int64(now.timeIntervalSince1970) - participantAge) * 1_000_000_000]
        }
        let rows = [row([701,702]), row([701,703]), row([701,704]), row([701,true]),
                    row([701,999]), row([]), row([701], participantAge: 300),
                    row([701], participantAge: -1), row([701], correction: 1), row([701], correction: true)]
        for (index, raw) in rows.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["status":"OK","results":[raw]])
            let page = try T.parse(data, kind: .trades, symbol: "AAPL", from: from, to: now)
            let quote = T.paperQuote(page.trades, symbol: "AAPL", allowed: allowed, now: now)
            #expect((quote != nil) == (index == 0))
            if let quote { #expect(quote.marketTime == now.addingTimeInterval(-2)) }
        }
        let data = try JSONSerialization.data(withJSONObject: ["status":"OK","results":[row([701,703]), row([701,702], age: 3, participantAge: 4)]])
        let page = try T.parse(data, kind: .trades, symbol: "AAPL", from: from, to: now)
        #expect(T.paperQuote(page.trades, symbol: "AAPL", allowed: allowed, now: now)?.marketTime == now.addingTimeInterval(-4))
        #expect(T.paperQuote(page.trades, symbol: "AAPL", allowed: allowed, now: now.addingTimeInterval(121)) == nil)
        #expect(T.paperQuote(page.trades, symbol: "AAPL", allowed: [], now: now) == nil)
        #expect(throws: (any Error).self) { try T.parsePaperTradeConditions(Data(#"{"status":"OK","results":[],"next_url":"more"}"#.utf8)) }
    }

    @Test("REST fixture uses SIP nanoseconds and fractional shares, never listing tape as venue")
    func tradeFixture() throws {
        // https://massive.com/docs/rest/stocks/trades-quotes/trades (fractional size variation).
        let data = Data(#"{"status":"OK","results":[{"exchange":11,"id":"1","price":171.55,"size":100,"decimal_size":"100.125","sip_timestamp":1517562000016036600,"sequence_number":1063,"tape":3}]}"#.utf8)
        let page = try T.parse(data, kind: .trades, symbol: "AAPL", from: from, to: to)
        let trade = try #require(page.trades.first)
        #expect(trade.size == 100.125 && trade.price == 171.55)
        #expect(trade.exchange == 11 && trade.sequence == 1063)
        #expect(trade.timestamp == StockSageMassive.date(fromNanoseconds: 1_517_562_000_016_036_600))
        #expect(page.rejected == 0 && page.quotes.isEmpty)
        #expect(!T.isNasdaq(trade.exchange, exchanges: [:]))
    }

    @Test("one-sided quote fixture remains one-sided; malformed data cannot create liquidity")
    func quoteFixture() throws {
        // https://massive.com/docs/rest/stocks/trades-quotes/quotes.
        let data = Data(#"{"status":"OK","results":[{"ask_exchange":0,"ask_price":0,"ask_size":0,"bid_exchange":11,"bid_price":102.7,"bid_size":60,"sip_timestamp":1517562000065700400,"sequence_number":2060,"tape":3},{"bid_price":true,"sip_timestamp":1517562000065700400},null]}"#.utf8)
        let page = try T.parse(data, kind: .quotes, symbol: "AAPL", from: from, to: to)
        let q = try #require(page.quotes.first)
        #expect(q.bid == 102.7 && q.bidSize == 60)
        #expect(q.ask == 0 && q.askSize == 0 && !q.hasTwoSides)
        #expect(q.spreadBps(at: q.timestamp) == nil)
        #expect(page.rejected == 2)
        #expect(throws: (any Error).self) { try T.parse(Data(#"{"status":"OK"}"#.utf8), kind: .quotes, symbol: "AAPL", from: from, to: to) }
        #expect(throws: (any Error).self) { try T.parse(Data(#"{"status":"ERROR","results":[]}"#.utf8), kind: .trades, symbol: "AAPL", from: from, to: to) }
        let outside = try T.parse(data, kind: .quotes, symbol: "AAPL", from: to, to: to.addingTimeInterval(1))
        #expect(outside.quotes.isEmpty)
    }

    @Test("Nasdaq attribution resolves MIC dynamically and fails closed for unknown IDs")
    func exchangeResolution() throws {
        // Stub IDs deliberately differ from any assumed production number.
        let values = try T.parseExchanges(Data(#"{"status":"OK","results":[{"id":701,"mic":"XNAS","acronym":"NASDAQ"},{"id":702,"mic":"XNYS","acronym":"NYSE"},{"id":true,"mic":"XNAS"}]}"#.utf8))
        #expect(values.count == 2)
        #expect(T.isNasdaq(701, exchanges: values))
        #expect(!T.isNasdaq(702, exchanges: values))
        #expect(!T.isNasdaq(3, exchanges: values))
        #expect(!T.isNasdaq(nil, exchanges: values))
        #expect(values[701]?.label == "NASDAQ")
        let singleton = try T.parseExchanges(Data(#"{"status":"OK","results":{"id":91,"mic":"XNAS"}}"#.utf8))
        #expect(singleton[91]?.label == "XNAS")
    }

    @Test("tape request pins symbol, window and page size; bearer key never rides in URL")
    func requestContract() throws {
        let request = try #require(T.request(kind: .trades, symbol: "aapl", from: from, to: to, key: "test-only"))
        let url = try #require(request.url)
        #expect(url.path == "/v3/trades/AAPL")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        #expect(!url.absoluteString.contains("test-only"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "limit", value: "100")))
        #expect(query.contains(.init(name: "order", value: "desc")))
        #expect(query.contains(.init(name: "timestamp.gte", value: "1517561900000000000")))
        #expect(T.request(kind: .quotes, symbol: "2222.SR", from: from, to: to, key: "test") == nil)
        #expect(T.request(kind: .quotes, symbol: "AAPL", from: to, to: from, key: "test") == nil)
        #expect(T.request(kind: .quotes, symbol: "AAPL", from: from, to: to, key: "") == nil)
        #expect(T.request(kind: .quotes, symbol: "AAPL", from: from, to: Date(timeIntervalSince1970: .infinity), key: "test") == nil)
    }

    @Test("pagination stops at the cap and rejects credential or cross-origin cursor tricks")
    func paginationBoundary() {
        let good = "https://api.massive.com/v3/trades/AAPL?cursor=abc"
        #expect(T.nextRequest(good, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: 1, visited: []) != nil)
        #expect(T.nextRequest(good, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: 2, visited: []) != nil)
        #expect(T.nextRequest(good, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: 3, visited: []) == nil)
        #expect(T.nextRequest(good, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: 1, visited: [good]) == nil)
        for bad in ["https://example.test/v3/trades/AAPL?cursor=abc",
                    "http://api.massive.com/v3/trades/AAPL?cursor=abc",
                    "https://api.massive.com:444/v3/trades/AAPL?cursor=abc",
                    "https://user@api.massive.com/v3/trades/AAPL?cursor=abc",
                    "https://api.massive.com/v3/quotes/AAPL?cursor=abc",
                    "https://api.massive.com/v3/trades/MSFT?cursor=abc",
                    good + "&apiKey=untrusted", good + "#fragment"] {
            #expect(T.nextRequest(bad, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: 1, visited: []) == nil)
        }
        var pages = 1
        while T.nextRequest(good, kind: .trades, symbol: "AAPL", key: "test", pagesLoaded: pages, visited: []) != nil { pages += 1 }
        #expect(pages == T.pageLimit)
    }

    @Test("shared numeric trust boundary rejects booleans, fractions and overflow")
    func numbers() {
        #expect(StockSageMassive.finite(true) == nil)
        #expect(StockSageMassive.int64(true) == nil)
        #expect(StockSageMassive.int64(1.5) == nil)
        #expect(StockSageMassive.int64(Double.infinity) == nil)
        #expect(StockSageMassive.int64(1e30) == nil)
        #expect(StockSageMassive.int64(1e3) == 1000)
        #expect(StockSageMassive.int64("9007199254740993") == 9_007_199_254_740_993)
        #expect(StockSageMassive.parseTicker(["lastTrade": ["p": true]], requestedSymbol: "AAPL") == nil)
    }
}
