import Testing
import Foundation
import Synchronization
@testable import StockSage

@Suite("Massive bounded tape")
struct StockSageMassiveTicksTests {
    typealias T = StockSageMassiveTicks
    let from = Date(timeIntervalSince1970: 1_517_561_900)
    let to = Date(timeIntervalSince1970: 1_517_562_100)

    @Test func sameDayQuoteDoesNotFallBackPastNewerWithdrawalOrMalformedRow() throws {
        var valid = StockSageNBBO(symbol: "AAPL", bid: 100, ask: 100.1, bidSize: 10, askSize: 10,
            bidExchange: 1, askExchange: 1, timestamp: to.addingTimeInterval(-1), sequence: 1)
        valid.conditions = [701]
        let page = T.Page(quotes: [valid])
        #expect(T.researchQuote(page, symbol: "AAPL", regularConditions: [701], at: to) != nil)
        #expect(T.researchQuote(page, symbol: "MSFT", regularConditions: [701], at: to) == nil)
        #expect(T.researchQuote(page, symbol: "AAPL", regularConditions: [], at: to) == nil)
        #expect(T.researchQuote(page, symbol: "AAPL", regularConditions: [701], at: to.addingTimeInterval(6)) == nil)
        var withdrawn = StockSageNBBO(symbol: "AAPL", bid: 0, ask: 0, bidSize: 0, askSize: 0,
            bidExchange: 1, askExchange: 1, timestamp: to, sequence: 2)
        withdrawn.conditions = [701]
        #expect(T.researchQuote(.init(quotes: [valid, withdrawn]), symbol: "AAPL", regularConditions: [701], at: to) == nil)
        #expect(T.researchQuote(.init(quotes: [valid], rejected: 1), symbol: "AAPL", regularConditions: [701], at: to) == nil)
    }

    @Test func sameDayQuoteRejectsConflictingLatestTiesWithoutSequenceProof() {
        func value(_ bid: Double, sequence: Int64?) -> StockSageNBBO {
            var q = StockSageNBBO(symbol: "AAPL", bid: bid, ask: bid + 0.1, bidSize: 10, askSize: 10,
                bidExchange: 1, askExchange: 1, timestamp: to, sequence: sequence)
            q.conditions = [701]
            return q
        }
        for sequence in [nil, Int64(1), Int64(-1)] {
            for pair in [[value(100, sequence: sequence), value(101, sequence: sequence)],
                         [value(101, sequence: sequence), value(100, sequence: sequence)]] {
                #expect(T.researchQuote(.init(quotes: pair), symbol: "AAPL", regularConditions: [701], at: to) == nil)
            }
        }
        let same = value(100, sequence: nil)
        #expect(T.researchQuote(.init(quotes: [same, same]), symbol: "AAPL", regularConditions: [701], at: to) != nil)
    }

    @Test @MainActor func paperTradeTiesUseSIPThenSequenceRegardlessOfResponseOrder() throws {
        func row(_ price: Int, sipAge: Int64, sequence: Int64) -> [String: Any] {
            ["price": price, "size": 10, "conditions": [701], "correction": 0,
             "participant_timestamp": (Int64(to.timeIntervalSince1970) - 3) * 1_000_000_000,
             "sip_timestamp": (Int64(to.timeIntervalSince1970) - sipAge) * 1_000_000_000,
             "sequence_number": sequence]
        }
        for older in [row(99, sipAge: 2, sequence: 21), row(99, sipAge: 1, sequence: 19)] {
            let newer = row(100, sipAge: 1, sequence: 20)
            for rows in [[newer, older], [older, newer]] {
                let data = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows])
                let page = try T.parse(data, kind: .trades, symbol: "AAPL", from: from, to: to)
                let quote = try #require(T.paperQuote(page.trades, symbol: "AAPL", allowed: [701], now: to))
                #expect(quote.price == 100 && quote.massiveTradeSequence == 20)
                #expect(quote.marketTime == to.addingTimeInterval(-3), "Do not refresh the participant clock")
                #expect(T.paperQuote(page.trades, symbol: "AAPL", allowed: [701], now: to.addingTimeInterval(121)) == nil)
            }
        }
    }

    @Test func intradayRequiresCompletedFreshValidBarsWithoutPaddingGaps() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_030)
        let from = now.addingTimeInterval(-3600)
        func row(_ seconds: Int64, high: Double = 102) -> [String: Any] {
            ["t": seconds * 1_000, "o":100, "h":high, "l":99, "c":101, "v":20]
        }
        func parse(_ rows: [[String: Any]], ticker: String = "AAPL", next: Bool = false, verified: Bool = false) throws -> T.Intraday? {
            var root: [String: Any] = ["status":"OK", "ticker":ticker, "results":rows]
            if next { root["next_url"] = "more" }
            if verified { root["adjusted"] = true; root["resultsCount"] = rows.count }
            return T.parseIntradayFacts(try JSONSerialization.data(withJSONObject: root), symbol: "AAPL", from: from, now: now)
        }
        let valid = try #require(try parse([row(1_799_999_880), row(1_799_999_940), row(1_800_000_000)]))
        #expect(valid.facts.count == 3 && valid.asOf == Date(timeIntervalSince1970: 1_800_000_000), "Current incomplete bar excluded")
        #expect(valid.bars.count == 2, "Retain typed completed bars; never reconstruct prices from prose")
        #expect(!valid.verifiedMinutes, "Missing adjustment/count metadata cannot qualify a same-day pick")
        #expect(try parse([row(1_799_999_880), row(1_799_999_940)], verified: true)?.verifiedMinutes == true)
        #expect(valid.fresh(at: now) && !valid.fresh(at: now.addingTimeInterval(181)))
        #expect(try parse([row(1_799_999_880), row(1_799_999_940)], ticker: "MSFT") == nil)
        #expect(try parse([row(1_799_999_880), row(1_799_999_940)], next: true) == nil)
        #expect(try parse([row(1_799_999_880), row(1_799_999_940, high: 98)]) == nil)
        #expect(try parse([row(1_799_999_880), row(1_799_999_880)]) == nil)
        #expect(try parse([row(1_799_999_880)]) == nil)
        #expect(try parse([row(1_799_999_580), row(1_799_999_640)]) == nil)
    }

    @Test func intradayTickFallbackRequiresDistinctQualifiedFreshObservations() throws {
        let now = to
        func trade(age: TimeInterval, conditions: [Int64] = [701]) -> T.Trade {
            .init(price: 100, size: 10, exchange: nil, timestamp: now.addingTimeInterval(-age),
                  sequence: nil, conditions: conditions, participantTime: now.addingTimeInterval(-age), correction: 0)
        }
        func facts(_ trades: [T.Trade]) -> T.Intraday? {
            T.intradayTradeFacts(T.eligiblePaperTrades(trades, allowed: [701], now: now), now: now)
        }
        let result = try #require(facts([trade(age: 10), trade(age: 2), trade(age: 1, conditions: [999])]))
        #expect(result.facts.count == 3 && result.asOf == now.addingTimeInterval(-2))
        #expect(result.facts[0].contains("NOT OHLC candles"))
        #expect(result.fresh(at: now.addingTimeInterval(118)))
        #expect(!result.fresh(at: now.addingTimeInterval(119)))
        #expect(facts([trade(age: 1)]) == nil)
        #expect(facts([trade(age: 1), trade(age: 1)]) == nil)
        #expect(facts([trade(age: 121), trade(age: 1)]) == nil)
        #expect(facts([trade(age: 2, conditions: [999]), trade(age: 1)]) == nil)
        #expect(facts([trade(age: -1), trade(age: 1)]) == nil)
    }

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

    @Test func restQuoteConditionsAndIndicatorsSurviveParsing() throws {
        let data = Data(#"{"status":"OK","results":[{"bid_price":100,"ask_price":101,"bid_size":10,"ask_size":20,"conditions":[801],"indicators":[9],"participant_timestamp":1517562000000000000,"sip_timestamp":1517562000065700400}]}"#.utf8)
        let page = try T.parse(data, kind: .quotes, symbol: "AAPL", from: from, to: to)
        let quote = try #require(page.quotes.first)
        #expect(quote.condition == 801)
        #expect(quote.conditions == [801])
        #expect(quote.indicators == [9])
        #expect(quote.participantTime == StockSageMassive.date(fromNanoseconds: 1_517_562_000_000_000_000))
        #expect(quote.participantTime != quote.timestamp)
        #expect(!quote.qualifyingCosts(regularConditions: [801]).costConditionVerified)
    }

    @Test func restQuoteMetadataUnknownsAreNotSilentlyQualified() throws {
        func parse(_ extra: [String: Any]) throws -> StockSageNBBO {
            var row: [String: Any] = ["bid_price":100, "ask_price":101, "bid_size":10, "ask_size":20,
                "sip_timestamp": Int64(1_517_562_000_000_000_000)]
            row.merge(extra) { _, new in new }
            return try #require(T.parse(JSONSerialization.data(withJSONObject: ["status":"OK", "results":[row]]),
                                        kind: .quotes, symbol: "AAPL", from: from, to: to).quotes.first)
        }
        for conditions: Any in [NSNull(), [801, true], [801, -1], "801", [801, 802], []] {
            let quote = try parse(["conditions": conditions])
            #expect(quote.condition == nil && !quote.qualifyingCosts(regularConditions: [801, 802]).costConditionVerified)
        }
        #expect(try parse(["conditions":[801,802]]).conditions == [801,802])
        #expect(try parse([:]).conditions == nil)
        #expect(try parse([:]).indicators == [])
        #expect(try parse(["conditions":[]]).conditions == [])
        for indicators: Any in [NSNull(), [true], [-1], "9"] {
            let quote = try parse(["conditions":[801], "indicators":indicators])
            #expect(quote.indicators == nil && !quote.qualifyingCosts(regularConditions: [801]).costConditionVerified)
        }
        let ordinary = try parse(["conditions":[801], "indicators":[]])
        #expect(ordinary.qualifyingCosts(regularConditions: [801]).costConditionVerified)
        #expect(!ordinary.qualifyingCosts(regularConditions: []).costConditionVerified)
        for value: Any in [true, -1, 0, 1.5, NSNull(), "bad"] {
            #expect(try parse(["participant_timestamp":value]).participantTime == nil)
        }
        let old = try parse(["participant_timestamp":Int64(1_517_561_000_000_000_000)])
        let future = try parse(["participant_timestamp":Int64(1_517_563_000_000_000_000)])
        #expect(old.participantTime! < old.timestamp && future.participantTime! > future.timestamp,
                "Preserve exchange clock evidence; a later consumer must reject old/future event times for fills")
        var scalar = ordinary
        scalar.condition = 802
        #expect(scalar.conditions == [802])
        scalar.condition = nil
        #expect(scalar.conditions == nil)
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


extension StockSageMassiveTicksTests {
    @Test @MainActor func tapeDropsAllPagesWhenAccessChangesAndBoundsInjectedResponses() async {
        for mode in ["credential", "policy", "oversize", "redirect"] {
            let revision = Mutex("one"), calls = Mutex(0)
            let access = StockSageMassive.Access(key: { "fixture" },
                credentialRevision: { revision.withLock { $0 } },
                policyRevision: { revision.withLock { $0 } }, allowed: { true })
            let result = await T.fetch(symbol: "AAPL", from: from, to: to, access: access, transport: { request in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 2 && (mode == "credential" || mode == "policy") { revision.withLock { $0 = "two" } }
                var data = Data(#"{"status":"OK","results":[{"price":100,"size":1,"sip_timestamp":1517562000000000000}],"next_url":"https://api.massive.com/v3/trades/AAPL?cursor=two"}"#.utf8)
                if mode == "oversize" { data = Data(repeating: 32, count: T.maximumBytes + 1) }
                let url = mode == "redirect" ? URL(string: "https://example.invalid/other")! : request.url!
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            #expect(result.trades.isEmpty && result.quotes.isEmpty)
            #expect(!result.notices.isEmpty)
            if mode == "credential" || mode == "policy" { #expect(calls.withLock { $0 } == 2) }
        }
    }

    @Test func displayConditionsUseTradeConsolidatedPriceRules() throws {
        let bytes = Data(#"{"status":"OK","results":[{"id":901,"asset_class":"stocks","data_types":["trade"],"update_rules":{"consolidated":{"updates_open_close":true}}},{"id":902,"asset_class":"stocks","data_types":["trade"],"update_rules":{"consolidated":{"updates_open_close":false}}},{"id":903,"asset_class":"stocks","data_types":["quote"],"update_rules":{"consolidated":{"updates_open_close":true}}}]}"#.utf8)
        let allowed = try T.parseDisplayTradeConditions(bytes)
        #expect(allowed == [901])
        #expect(T.qualifiesDisplayTrade(conditions: [901], allowed: allowed, sip: to, participant: to.addingTimeInterval(-1)))
        for codes: [Int64]? in [nil, [], [901,902], [999]] {
            #expect(!T.qualifiesDisplayTrade(conditions: codes, allowed: allowed, sip: to, participant: to))
        }
        #expect(!T.qualifiesDisplayTrade(conditions: [901], allowed: allowed, sip: to, participant: to.addingTimeInterval(-121)))
        #expect(!T.qualifiesDisplayTrade(conditions: [901], allowed: allowed, sip: to, participant: to.addingTimeInterval(1)))
    }
}


extension StockSageMassiveTicksTests {
    @Test @MainActor func streamRestartCannotRenewAnOlderSharedReferenceWithoutTransport() async throws {
        let savedExchanges = T.exchangeCache, savedTrades = T.tradeReferenceCache
        let live = StockSageLiveStream()
        defer {
            T.exchangeCache = savedExchanges; T.tradeReferenceCache = savedTrades
            live.stop(clearNBBO: {})
        }
        let restartedAt = Date(), fetchedAt = restartedAt.addingTimeInterval(-23 * 3_600)
        let exchanges: [Int64: T.Exchange] = [1: .init(id: 1, mic: "XNAS", acronym: "OLD")]
        let bytes = Data(#"{"status":"OK","results":[{"id":901,"asset_class":"stocks","data_types":["trade"],"update_rules":{"consolidated":{"updates_open_close":true}}}]}"#.utf8)
        T.exchangeCache = (fetchedAt, exchanges, { true })
        T.tradeReferenceCache = (fetchedAt, bytes, { true })
        // An empty injected key prevents transport. Shared cache consumers can still read
        // these explicitly seeded, current fixture records until their original expiry.
        let access = StockSageMassive.Access(key: { "" }, credentialRevision: { nil },
            policyRevision: { nil }, allowed: { true })
        #expect(try await T.exchanges(now: restartedAt, access: access) == exchanges)
        #expect(try await T.displayTradeConditions(access: access) == [901])
        await live.refreshReferences(now: fetchedAt, stillValid: { true },
            displayConditions: { [901] }, conditions: { [] }, exchangeList: { exchanges })?.value
        live.stop(clearNBBO: {})
        await live.refreshReferences(now: restartedAt, stillValid: { true },
            displayConditions: { try await T.displayTradeConditions(access: access, bypassCache: true) },
            conditions: { [] },
            exchangeList: { try await T.exchanges(now: restartedAt, access: access, bypassCache: true) })?.value
        #expect(live.displayTradePolicy(at: restartedAt).conditions.isEmpty)
        #expect(live.exchangeReference(at: restartedAt).isEmpty,
                "Restart must not stamp a 23-hour-old shared reference with a new 24-hour lifetime")
        #expect(T.exchangeCache?.at == fetchedAt && T.tradeReferenceCache?.at == fetchedAt)
        #expect(try await T.exchanges(now: restartedAt, access: access) == exchanges,
                "Other consumers retain the shared cache and its original age")
    }

    @Test(arguments: ["exchanges", "quoteConditions", "displayConditions", "paperQuote", "nbbo", "intraday"],
          ["credentialRoundTrip", "policyRoundTrip", "oversize", "redirect"])
    @MainActor func allTickRequestConsumersRejectObsoleteOrUnboundedResponses(endpoint: String, mode: String) async {
        let revision = Mutex("one"), calls = Mutex(0)
        let access = StockSageMassive.Access(key: { "fixture" },
            credentialRevision: { revision.withLock { $0 } },
            policyRevision: { revision.withLock { $0 } }, allowed: { true })
        let wire: StockSageMassive.Transport = { request in
            calls.withLock { $0 += 1 }
            if mode.hasSuffix("RoundTrip") { revision.withLock { $0 = "two" } }
            let bytes = mode == "oversize" ? Data(repeating: 32, count: T.maximumBytes + 1)
                : Data(#"{"status":"OK","results":[]}"#.utf8)
            let url = mode == "redirect" ? URL(string: "https://example.invalid/changed")! : request.url!
            return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        switch endpoint {
        case "exchanges": #expect((try? await T.exchanges(access: access, transport: wire)) == nil)
        case "quoteConditions": #expect((try? await T.regularQuoteConditions(access: access, transport: wire)) == nil)
        case "displayConditions": #expect((try? await T.displayTradeConditions(access: access, transport: wire)) == nil)
        case "paperQuote": #expect(await T.freshPaperQuote(symbol: "AAPL", access: access, transport: wire) == nil)
        case "nbbo": #expect(await T.freshResearchNBBO(symbol: "AAPL", regularConditions: [701], access: access, transport: wire) == nil)
        default: #expect(await T.intradayFacts(symbol: "AAPL", from: from, now: to, access: access, transport: wire) == nil)
        }
        #expect(calls.withLock { $0 } == 1 || (endpoint == "intraday" && !mode.hasSuffix("RoundTrip") && calls.withLock { $0 } == 2))
    }
}
