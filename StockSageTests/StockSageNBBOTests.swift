import Testing
import Foundation
@testable import StockSage

@Suite("Massive NBBO boundaries")
struct StockSageNBBOTests {
    typealias L = StockSageLiveStream
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func quote(bid: Double = 100.01, ask: Double = 100.03, size: Double = 100,
               offset: TimeInterval = 0, sequence: Int64? = 10, symbol: String = "AAPL") -> StockSageNBBO {
        .init(symbol: symbol, bid: bid, ask: ask, bidSize: size, askSize: size,
              bidExchange: 4, askExchange: 7, timestamp: now.addingTimeInterval(offset), sequence: sequence)
    }

    @Test("documented Q fields retain share sizes and exact sequence integers")
    func fixture() throws {
        let events = L.events(in: #"[{"ev":"Q","sym":"MSFT","bp":114.125,"bs":100,"bx":4,"ap":114.128,"as":160,"ax":7,"t":1536036818784,"q":9007199254740993}]"#)
        guard case .quote(let q) = try #require(events.first) else { Issue.record("Missing quote"); return }
        #expect(q.bid == 114.125 && q.ask == 114.128)
        #expect(q.bidSize == 100 && q.askSize == 160)
        #expect(q.bidExchange == 4 && q.askExchange == 7)
        #expect(q.sequence == 9_007_199_254_740_993)
        #expect(q.timestamp == Date(timeIntervalSince1970: 1_536_036_818.784))
    }

    @Test("spread is full round-trip crossing width, with freshness and validity gates")
    func spreadBoundaries() throws {
        let q = quote()
        #expect(abs(try #require(q.spreadBps(at: now)) - (0.02 / 100.02 * 10_000)) < 1e-9)
        #expect(q.spreadBps(at: now.addingTimeInterval(5)) != nil)
        #expect(q.spreadBps(at: now.addingTimeInterval(5.001)) == nil)
        #expect(q.spreadBps(at: now.addingTimeInterval(-0.001)) == nil)
        #expect(quote(bid: 100, ask: 100).spreadBps(at: now) == nil)
        for invalid in [quote(bid: 0), quote(ask: 0), quote(size: 0), quote(bid: 101),
                        quote(bid: .nan), quote(ask: .infinity), quote(size: -1)] {
            #expect(invalid.spreadBps(at: now) == nil)
        }
    }

    @Test("quote sequence only breaks equal-time ties for the same symbol and channel")
    func sequenceBoundaries() {
        let old = quote(sequence: 9_007_199_254_740_992)
        #expect(quote(sequence: 9_007_199_254_740_993).supersedes(old, now: now))
        #expect(!old.supersedes(old, now: now))
        #expect(!quote(sequence: nil).supersedes(old, now: now))
        #expect(!quote(sequence: 11).supersedes(quote(sequence: nil), now: now))
        #expect(!quote(offset: -1, sequence: Int64.max).supersedes(old, now: now))
        #expect(!quote(sequence: Int64.max, symbol: "MSFT").supersedes(old, now: now))
        #expect(quote(offset: 60, sequence: 1).supersedes(old, now: now))
        #expect(!quote(offset: 60.001).supersedes(old, now: now))
        #expect(quote(offset: 86_400, sequence: 1).supersedes(old, now: now.addingTimeInterval(86_400)))
    }

    @Test("authenticated quotes never suppress last-trade gap polling; withdrawal replaces old book")
    func independentClocks() {
        var state = L.StreamState()
        let q = quote()
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
        _ = state.consume(.status("auth_success"), requested: ["AAPL"], now: now)
        _ = state.consume(.quote(quote(symbol: "MSFT")), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes["AAPL"] == q)
        #expect(state.coveredSymbols(at: now).isEmpty)
        #expect(!state.hasRecentTrades(at: now))
        let withdrawal = quote(ask: 0, sequence: 11)
        _ = state.consume(.quote(withdrawal), requested: ["AAPL"], now: now)
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes["AAPL"] == withdrawal)
        #expect(state.latestQuotes["AAPL"]?.spreadBps(at: now) == nil)
        _ = state.consume(.status("success"), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.count == 1)
        _ = state.consume(.status("auth_failed"), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
    }

    @Test("mixed batches retain quotes and trades but reject malformed and boolean quote values")
    func mixedAndMalformedFrames() {
        let events = L.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":100,"ap":101,"bs":100,"as":100,"t":1700000000000,"q":1},{"ev":"T","sym":"AAPL","p":100.5,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":100,"ap":101,"bs":true,"as":100,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":100,"ap":"nan","bs":100,"as":100,"t":1700000000000}]"#)
        #expect(events.count == 3)
        var state = L.StreamState()
        let trades = events.compactMap { state.consume($0, requested: ["AAPL"], now: now) }
        #expect(trades.count == 1)
        #expect(state.latestQuotes.count == 1)
        #expect(state.coveredSymbols(at: now) == ["AAPL"])
    }
}
