import Testing
import Foundation
@testable import StockSage

@Suite("Massive live stream")
struct StockSageLiveStreamTests {
    typealias L = StockSageLiveStream

    @Test("Massive trade frames require ev:T and preserve millisecond SIP timestamps")
    func parsesMassiveTradeFrame() throws {
        #expect(L.events(in: #"[{"ev":"T","sym":"msft","p":114.125,"t":1536036818784}]"#) == [
            .trade(.init(symbol: "MSFT", price: 114.125, timestamp: Date(timeIntervalSince1970: 1_536_036_818.784))),
        ])
        #expect(L.events(in: #"[{"ev":"Q","sym":"MSFT","bp":114.12,"t":1536036818784}]"#).isEmpty)
        #expect(L.events(in: #"[{"ev":"T","sym":"MSFT","p":114.125}]"#).isEmpty)
    }

    @Test("Massive subscribes only after auth_success")
    func massiveAuthThenSubscription() throws {
        #expect(L.events(in: #"[{"ev":"status","status":"connected"}]"#) == [.status("connected")])
        #expect(L.events(in: #"[{"ev":"status","status":"auth_success"}]"#) == [.status("auth_success")])
        let subscription = try #require(L.massiveSubscription(symbols: ["MSFT", "AAPL"]))
        let data = try #require(subscription.data(using: .utf8))
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(payload["action"] == "subscribe")
        #expect(payload["params"] == "T.AAPL,Q.AAPL,T.MSFT,Q.MSFT")
        #expect(L.massiveSubscription(symbols: []) == nil)
    }

    @Test("only Massive-covered US symbols are streamable")
    func streamableMatchesCoverage() {
        #expect(L.streamable(["AAPL", "2222.SR", "BTC-USD", "EURUSD=X", "^VIX", "msft", "MSFT"]) == ["AAPL", "MSFT"])
    }

    @Test("reconnect backoff doubles then caps at 30 seconds")
    func backoffDoublesAndCaps() {
        #expect(L.backoffSeconds(attempt: 0) == 1)
        #expect(L.backoffSeconds(attempt: 4) == 16)
        #expect(L.backoffSeconds(attempt: 5) == 30)
        #expect(L.backoffSeconds(attempt: 99) == 30)
        #expect(L.backoffSeconds(attempt: -3) == 1)
    }

    @Test("auth alone does not suppress polling; delivered coverage expires per symbol")
    func coverageRequiresRecentDelivery() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = L.StreamState()
        let tick = L.Tick(symbol: "AAPL", price: 100, timestamp: now)
        #expect(state.consume(.trade(tick), requested: ["AAPL", "MSFT"], now: now) == nil)
        _ = state.consume(.status("auth_success"), requested: ["AAPL", "MSFT"], now: now)
        #expect(state.coveredSymbols(at: now).isEmpty)
        #expect(state.consume(.trade(tick), requested: ["AAPL", "MSFT"], now: now) == tick)
        #expect(state.coveredSymbols(at: now) == ["AAPL"])
        #expect(state.hasRecentTrades(at: now))
        #expect(state.coveredSymbols(at: now.addingTimeInterval(45)) == ["AAPL"])
        #expect(state.coveredSymbols(at: now.addingTimeInterval(45.001)).isEmpty)
        #expect(!state.hasRecentTrades(at: now.addingTimeInterval(45.001)))
    }

    @Test("missing, equal and older ticks cannot rewind a quote")
    func liveTicksRequireStrictlyNewerMarketTime() {
        let current = Date(timeIntervalSince1970: 1_000)
        #expect(!StockSageStore.acceptsLiveTick(nil, after: current))
        #expect(!StockSageStore.acceptsLiveTick(current, after: current))
        #expect(!StockSageStore.acceptsLiveTick(Date(timeIntervalSince1970: 999), after: current))
        #expect(StockSageStore.acceptsLiveTick(Date(timeIntervalSince1970: 1_001), after: current))
        #expect(StockSageStore.acceptsLiveTick(current.addingTimeInterval(60), after: current, now: current))
        #expect(!StockSageStore.acceptsLiveTick(current.addingTimeInterval(60.001), after: current, now: current))
        #expect(!StockSageStore.acceptsLiveTick(Date(timeIntervalSince1970: .nan), after: nil))
    }

    @Test("mixed multi-event batches preserve all valid trades and event order")
    func mixedBatchesKeepEveryValidTrade() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = L.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"T","sym":"AAPL","p":100,"t":1700000000000},null,{"ev":"T","sym":"BAD","p":true,"t":1700000000000},{"ev":"status","status":"success"},{"ev":"T","sym":"MSFT","p":"200.5","t":1700000000001},{"ev":"T","sym":"AAPL","p":101,"t":1700000000002}]"#)
        #expect(events.count == 5)
        var state = L.StreamState()
        let trades = events.compactMap { state.consume($0, requested: ["AAPL", "MSFT"], now: now) }
        #expect(trades.map(\.symbol) == ["AAPL", "MSFT", "AAPL"])
        #expect(trades.map(\.price) == [100, 200.5, 101])
        #expect(state.isAuthorized)
        #expect(state.coveredSymbols(at: now) == ["AAPL", "MSFT"])
    }

    @Test("informational status preserves auth; auth failure clears delivery proof")
    func statusTransitions() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = L.StreamState()
        _ = state.consume(.status("auth_success"), requested: ["AAPL"], now: now)
        _ = state.consume(.trade(.init(symbol: "AAPL", price: 100, timestamp: now)), requested: ["AAPL"], now: now)
        _ = state.consume(.status("success"), requested: ["AAPL"], now: now)
        #expect(state.isAuthorized)
        #expect(state.coveredSymbols(at: now) == ["AAPL"])
        _ = state.consume(.status("auth_failed"), requested: ["AAPL"], now: now)
        #expect(!state.isAuthorized)
        #expect(state.coveredSymbols(at: now).isEmpty)
        #expect(state.consume(.trade(.init(symbol: "AAPL", price: 101, timestamp: now.addingTimeInterval(1))),
                              requested: ["AAPL"], now: now) == nil)
    }

    @Test("unsolicited, duplicate, old and future trades do not establish coverage")
    func rejectsUntrustedTrades() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = L.StreamState()
        _ = state.consume(.status("auth_success"), requested: ["AAPL"], now: now)
        #expect(state.consume(.trade(.init(symbol: "MSFT", price: 100, timestamp: now)), requested: ["AAPL"], now: now) == nil)
        #expect(state.consume(.trade(.init(symbol: "AAPL", price: 100, timestamp: now.addingTimeInterval(61))), requested: ["AAPL"], now: now) == nil)
        let tick = L.Tick(symbol: "AAPL", price: 100, timestamp: now)
        #expect(state.consume(.trade(tick), requested: ["AAPL"], now: now) == tick)
        #expect(state.consume(.trade(tick), requested: ["AAPL"], now: now) == nil)
        #expect(state.consume(.trade(.init(symbol: "AAPL", price: 99, timestamp: now.addingTimeInterval(-1))), requested: ["AAPL"], now: now) == nil)
    }

    @Test("malformed frames, boolean numbers and nonfinite values never become trades")
    func rejectsMalformedFrames() {
        for text in ["not json", "[]", "null", #"{"ev":"T","sym":"AAPL","p":true,"t":1700000000000}"#,
                     #"{"ev":"T","sym":"AAPL","p":100,"t":true}"#,
                     #"{"ev":"T","sym":"AAPL","p":"nan","t":1700000000000}"#,
                     #"{"ev":"T","sym":"AAPL","p":100,"t":0}"#] {
            #expect(L.events(in: text).isEmpty)
        }
    }
}
