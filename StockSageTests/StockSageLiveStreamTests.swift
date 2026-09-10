import Testing
import Foundation
@testable import StockSage

@Suite("Massive live stream")
struct StockSageLiveStreamTests {
    typealias L = StockSageLiveStream
    typealias ExchangeContinuation = CheckedContinuation<[Int64: StockSageMassiveTicks.Exchange], Never>

    @MainActor
    private func waitForContinuation(_ pending: @MainActor () -> ExchangeContinuation?) async throws -> ExchangeContinuation {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while pending() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let continuation = pending()
        return try #require(continuation)
    }

    @Test("whole-market subscription and suffix observations do not depend on the board")
    func wholeMarketRegression() throws {
        let payload = try #require(L.massiveSubscription(symbols: ["AAPL"]))
        #expect(payload.contains("T.*,Q.*"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = L.StreamState()
        _ = state.consume(.status("auth_success"), requested: ["AAPL"], now: now)
        let offBoard = L.Tick(symbol: "MSFT", price: 100, timestamp: now)
        #expect(state.consume(.trade(offBoard), requested: ["AAPL"], now: now) == offBoard)
        let events = L.events(in: #"[{"ev":"T","sym":"BRK.B","p":100,"t":1700000000000},{"ev":"T","sym":"APTVpA","p":25,"t":1700000000000}]"#)
        #expect(events.count == 2)
        #expect(events.contains(.trade(.init(symbol: "APTVpA", price: 25, timestamp: now))))
        #expect(!StockSagePaperAutomation.fresh(.init(symbol: "AAPL", price: 100, previousClose: 99,
            marketTime: now.addingTimeInterval(-10.001), priceSource: .massiveSIP), at: now))
    }

    @Test("distinct same-millisecond trades retain exact sequence ordering")
    func sameMillisecondTradesAreNotDropped() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let events = L.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"T","sym":"AAPL","p":100,"t":1700000000000,"q":9007199254740992},{"ev":"T","sym":"AAPL","p":101,"t":1700000000000,"q":9007199254740993},{"ev":"T","sym":"AAPL","p":99,"t":1700000000000,"q":9007199254740992}]"#)
        var state = L.StreamState()
        let trades = events.compactMap { state.consume($0, requested: ["AAPL"], now: now) }
        #expect(trades.map(\.price) == [100, 101])
    }

    @Test("unknown trade sequences never break ties and quote sequences stay independent")
    func sequenceScopeAndMissingMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for value in ["null", "true", "-1", "1.5", "9223372036854775808", #""bad""#] {
            let events = L.events(in: "{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":100,\"t\":1700000000000,\"q\":\(value)}")
            guard case .trade(let tick) = try #require(events.first) else { Issue.record("missing trade"); continue }
            #expect(tick.sequence == nil)
            #expect(!StockSageStore.acceptsLiveTick(now, after: now,
                massiveTradeSequence: tick.sequence, afterMassiveTradeSequence: 0, now: now))
        }
        let rejected: [(Int64?, Int64?)] = [(nil, 1), (2, nil), (-1, 0), (1, -1), (1, 1), (0, 1)]
        for (incoming, old) in rejected {
            #expect(!StockSageStore.acceptsLiveTick(now, after: now,
                massiveTradeSequence: incoming, afterMassiveTradeSequence: old, now: now))
        }
        #expect(StockSageStore.acceptsLiveTick(now, after: now,
            massiveTradeSequence: 2, afterMassiveTradeSequence: 1, now: now))
        #expect(StockSageStore.acceptsLiveTick(now.addingTimeInterval(86_400), after: now,
            massiveTradeSequence: 0, afterMassiveTradeSequence: 9_000, now: now.addingTimeInterval(86_400)))
        var state = L.StreamState()
        let events = L.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"t":1700000000000,"q":999},{"ev":"T","sym":"AAPL","p":100,"t":1700000000000,"q":1},{"ev":"T","sym":"MSFT","p":200,"t":1700000000000,"q":0}]"#)
        let trades = events.compactMap { state.consume($0, requested: ["AAPL", "MSFT"], now: now) }
        #expect(trades.map(\.symbol) == ["AAPL", "MSFT"])
        #expect(state.latestQuotes["AAPL"]?.sequence == 999)
    }

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
        #expect(payload["params"] == "T.*,Q.*")
        #expect(L.massiveSubscription(symbols: []) != nil)
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
        #expect(state.coveredSymbols(at: now.addingTimeInterval(10)) == ["AAPL"])
        #expect(state.coveredSymbols(at: now.addingTimeInterval(10.001)).isEmpty)
        #expect(!state.hasRecentTrades(at: now.addingTimeInterval(10.001)))
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
        #expect(state.coveredSymbols(at: now).isEmpty, "Future observations cannot claim live coverage")
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
        #expect(state.consume(.trade(.init(symbol: "MSFT", price: 100, timestamp: now)), requested: ["AAPL"], now: now) != nil)
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

    @Test(arguments: [false, true]) @MainActor
    func failedOrEmptyExchangeRetriesIndependentlyAtSixtySeconds(_ empty: Bool) async throws {
        let live = L()
        defer { live.stop(clearNBBO: {}) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var conditionCalls = 0, exchangeCalls = 0
        let conditions: @MainActor () async throws -> Set<Int64> = {
            conditionCalls += 1
            return [801]
        }
        let exchanges: @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange] = {
            exchangeCalls += 1
            if exchangeCalls == 1 {
                if empty { return [:] }
                throw URLError(.cannotConnectToHost)
            }
            return [1: .init(id: 1, mic: "XNAS", acronym: "NASDAQ")]
        }

        let firstRequest = live.refreshReferences(now: now, stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let first = try #require(firstRequest)
        await first.value
        #expect(conditionCalls == 1 && exchangeCalls == 1 && live.exchanges.isEmpty)
        let early = live.refreshReferences(now: now.addingTimeInterval(59), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        #expect(early == nil)
        #expect(conditionCalls == 1 && exchangeCalls == 1)

        let retryRequest = live.refreshReferences(now: now.addingTimeInterval(60), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let retry = try #require(retryRequest)
        await retry.value
        #expect(conditionCalls == 1 && exchangeCalls == 2)
        #expect(live.exchanges[1]?.acronym == "NASDAQ")
    }

    @Test @MainActor
    func conditionAndExchangeFreshnessExpireIndependently() async throws {
        let live = L(), ingress = StockSageFeedIngress()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var conditionCalls = 0, exchangeCalls = 0
        let conditions: @MainActor () async throws -> Set<Int64> = {
            conditionCalls += 1
            if conditionCalls == 1 { throw URLError(.networkConnectionLost) }
            return [801]
        }
        let exchanges: @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange] = {
            exchangeCalls += 1
            return [1: .init(id: 1, mic: "XNAS", acronym: exchangeCalls == 1 ? "FIRST" : "SECOND")]
        }

        let firstRequest = live.refreshReferences(now: now, stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let first = try #require(firstRequest)
        await first.value
        #expect(conditionCalls == 1 && exchangeCalls == 1)
        #expect(live.exchanges[1]?.acronym == "FIRST")

        var quote = StockSageNBBO(symbol: "AAPL", bid: 99, ask: 101, bidSize: 100, askSize: 100,
            bidExchange: 1, askExchange: 1, timestamp: now, sequence: 1)
        quote.condition = 801
        let snapshot = StockSageFeedIngress.Snapshot(authorized: true, quotes: ["AAPL": quote], newestSIP: now)
        let published = live.publish(snapshot, from: ingress, now: now, apply: { _, _, _ in })
        #expect(published)
        #expect(live.quotes["AAPL"]?.costConditionVerified == false,
                "Exchange coverage alone must not qualify quote costs")

        let conditionRequest = live.refreshReferences(now: now.addingTimeInterval(60), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let conditionRetry = try #require(conditionRequest)
        await conditionRetry.value
        #expect(conditionCalls == 2 && exchangeCalls == 1)

        let exchangeRequest = live.refreshReferences(now: now.addingTimeInterval(86_400), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let exchangeRetry = try #require(exchangeRequest)
        await exchangeRetry.value
        #expect(conditionCalls == 2 && exchangeCalls == 2)
        #expect(live.exchanges[1]?.acronym == "SECOND")
        let early = live.refreshReferences(now: now.addingTimeInterval(86_459), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        #expect(early == nil)

        let nextConditionRequest = live.refreshReferences(now: now.addingTimeInterval(86_460), stillValid: { true },
            conditions: conditions, exchangeList: exchanges)
        let nextCondition = try #require(nextConditionRequest)
        await nextCondition.value
        #expect(conditionCalls == 3 && exchangeCalls == 2)
    }

    @Test @MainActor
    func falseStillValidRejectsLateExchangeMetadata() async throws {
        let live = L()
        var exchangeResume: ExchangeContinuation?
        var allowed = true
        defer {
            exchangeResume?.resume(returning: [:])
            live.stop(clearNBBO: {})
        }
        let firstRequest = live.refreshReferences(now: Date(timeIntervalSince1970: 1_700_000_000),
            stillValid: { allowed }, conditions: { [801] }, exchangeList: {
                await withCheckedContinuation { exchangeResume = $0 }
            })
        let first = try #require(firstRequest)
        let pendingExchange = try await waitForContinuation { exchangeResume }
        allowed = false
        pendingExchange.resume(returning: [1: .init(id: 1, mic: "XNAS", acronym: "OLD")])
        exchangeResume = nil
        await first.value
        #expect(live.exchanges.isEmpty)

        allowed = true
        var conditionCalls = 0
        let retryRequest = live.refreshReferences(now: Date(timeIntervalSince1970: 1_700_000_060),
            stillValid: { allowed }, conditions: { conditionCalls += 1; return [999] },
            exchangeList: { [2: .init(id: 2, mic: "XNYS", acronym: "NEW")] })
        let retry = try #require(retryRequest)
        await retry.value
        #expect(conditionCalls == 0 && live.exchanges[2]?.acronym == "NEW")
    }

    @Test @MainActor
    func stoppedExchangeCannotPublishOrClearReplacementTask() async throws {
        let live = L()
        var oldResume: ExchangeContinuation?
        var nextResume: ExchangeContinuation?
        defer {
            oldResume?.resume(returning: [:]); nextResume?.resume(returning: [:])
            live.stop(clearNBBO: {})
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldRequest = live.refreshReferences(now: now, stillValid: { true }, conditions: { [801] },
            exchangeList: { await withCheckedContinuation { oldResume = $0 } })
        let old = try #require(oldRequest)
        let oldContinuation = try await waitForContinuation { oldResume }
        live.stop(clearNBBO: {})
        let replacementRequest = live.refreshReferences(now: now, stillValid: { true }, conditions: { [999] },
            exchangeList: { await withCheckedContinuation { nextResume = $0 } })
        let replacement = try #require(replacementRequest)
        let nextContinuation = try await waitForContinuation { nextResume }

        oldContinuation.resume(returning: [1: .init(id: 1, mic: "XNAS", acronym: "OLD")])
        oldResume = nil
        await old.value
        #expect(live.exchanges.isEmpty)
        var duplicateCalls = 0
        let duplicate = live.refreshReferences(now: now.addingTimeInterval(60), stillValid: { true },
            conditions: { duplicateCalls += 1; return [1] }, exchangeList: { duplicateCalls += 1; return [:] })
        #expect(duplicate == nil)
        #expect(duplicateCalls == 0, "An old completion must not clear the replacement in-flight guard")

        nextContinuation.resume(returning: [2: .init(id: 2, mic: "XNYS", acronym: "NEW")])
        nextResume = nil
        await replacement.value
        #expect(live.exchanges[2]?.acronym == "NEW")
    }
}
