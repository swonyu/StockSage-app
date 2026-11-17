import Foundation
import Synchronization
import Testing
@testable import StockSage

/// Synthetic boundaries only. Every request operation is injected; no key lookup or shared Store.
struct StockSageHistoryBoundaryTests {
    typealias M = StockSageMassive
    typealias Q = StockSageQuoteService

    nonisolated private static let massiveBody = Data(#"{"adjusted":true,"status":"OK","ticker":"AAPL","results":[{"o":100,"h":101,"l":99,"c":100,"v":100000,"t":1700000000000},{"o":100,"h":101,"l":99,"c":100,"v":100000,"t":1700086400000}]}"#.utf8)
    nonisolated private static let yahooBody = Data(#"{"chart":{"result":[{"timestamp":[1700000000,1700086400],"indicators":{"quote":[{"open":[100,100],"high":[101,101],"low":[99,99],"close":[100,100],"volume":[100000,100000]}]}}]}}"#.utf8)
    nonisolated private static var request: URLRequest {
        URLRequest(url: URL(string: "https://example.invalid/history")!)
    }
    nonisolated private static func response(_ request: URLRequest, status: Int = 200,
                                              body: Data = massiveBody) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated private static func bars(_ symbol: String) -> StockSagePriceHistory {
        let end = Date()
        return .init(symbol: symbol, dates: (0..<32).map { end.addingTimeInterval(-Double(31 - $0) * 86_400) },
              opens: Array(repeating: 100, count: 32), highs: Array(repeating: 101, count: 32),
              lows: Array(repeating: 99, count: 32), closes: Array(repeating: 100, count: 32),
              volumes: Array(repeating: 100_000, count: 32), priceSource: .massiveDaily)
    }

    @Test @MainActor func revisitedStudiesReplaceOldInputsAndInvalidationWinsInFlight() async throws {
        let suite = "derived.refresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let h = Self.bars("AAPL")
        await store.refreshLiquidity(symbol: "AAPL", allowed: { true }, history: { _, _ in h })
        #expect(store.liquidity["AAPL"] != nil)
        var requests = 0
        await store.refreshLiquidity(symbol: "AAPL", allowed: { true }, history: { _, _ in requests += 1; return nil })
        #expect(requests == 1 && store.liquidity["AAPL"] == nil, "A failed fresh check cannot leave the old result looking current")
        await store.refreshTrailingStop(symbol: "AAPL", allowed: { true }, history: { _, _ in
            store.invalidateDerivedResearch()
            return h
        })
        #expect(store.trailingStop["AAPL"] == nil, "Older work cannot repopulate studies after a new scan")
        await store.refreshMultiTimeframe(symbol: "AAPL", allowed: { true }, history: { _, _, _ in
            store.invalidateDerivedResearch()
            return h
        })
        #expect(store.multiTimeframe["AAPL"] == nil)
        await store.refreshLiquidity(symbol: "AAPL", allowed: { true }, history: { _, _ in h })
        await store.refreshTrailingStop(symbol: "AAPL", allowed: { true }, history: { _, _ in h })
        await store.refreshLiquidity(symbol: "MSFT", allowed: { true }, history: { _, _ in Self.bars("MSFT") })
        await store.refreshLiquidity(symbol: "AAPL", allowed: { false }, history: { _, _ in Issue.record("Denied fetch"); return h })
        await store.refreshTrailingStop(symbol: "AAPL", allowed: { false }, history: { _, _ in Issue.record("Denied fetch"); return h })
        #expect(store.liquidity["AAPL"] == nil && store.trailingStop["AAPL"] == nil && store.liquidity["MSFT"] != nil)
    }

    @Test @MainActor func weeklyPeriodStartRemainsUsableAcrossMondayHoliday() async throws {
        let suite = "weekly.coverage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        let now = date("2026-09-08T12:00:00Z")
        func bars(end: Date, step: Double) -> StockSagePriceHistory {
            let c = (1...250).map(Double.init)
            return .init(symbol: "AAPL", dates: (0..<250).map { end.addingTimeInterval(-Double(249 - $0) * step) },
                opens: c, highs: c, lows: c, closes: c, volumes: Array(repeating: 1, count: 250), priceSource: .yahooBars)
        }
        let daily = bars(end: date("2026-09-04T13:30:00Z"), step: 86_400)
        let weekly = bars(end: date("2026-08-31T04:00:00Z"), step: 7 * 86_400)
        #expect(StockSageRegime.historyAsOf(weekly, now: now) == nil, "Daily-age rule is intentionally too strict for a weekly start")
        await store.refreshMultiTimeframe(symbol: "AAPL", allowed: { true }, now: { now }, history: { _, _, interval in
            interval == "1wk" ? weekly : daily
        })
        #expect(store.multiTimeframe["AAPL"] != nil)
        await store.refreshMultiTimeframe(symbol: "AAPL", allowed: { false }, now: { now }, history: { _, _, _ in
            Issue.record("Denied fetch"); return nil
        })
        #expect(store.multiTimeframe["AAPL"] == nil)
    }

    @Test(arguments: [false, true])
    func massiveHistoryRejectsInvalidationInsideTransport(cancel: Bool) async {
        let permitted = Mutex(true), calls = Mutex(0)
        let task = Task {
            await M.fetchHistory(symbol: "AAPL", request: Self.request,
                allowed: { permitted.withLock { $0 } }, transport: { req in
                    calls.withLock { $0 += 1 }
                    // Deterministic in-flight invalidation; transport intentionally returns success anyway.
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    else { permitted.withLock { $0 = false } }
                    return Self.response(req)
                })
        }
        let result = await task.value
        #expect(calls.withLock { $0 } == 1)
        #expect(result == nil)
    }

    @Test(arguments: [false, true])
    func massiveHistoryRejectsInvalidationBeforeTransport(cancel: Bool) async {
        let calls = Mutex(0)
        let task = Task {
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return await M.fetchHistory(symbol: "AAPL", request: Self.request, allowed: { cancel },
                transport: { req in calls.withLock { $0 += 1 }; return Self.response(req) })
        }
        #expect(await task.value == nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [200, 503], [false, true])
    func actualPrimaryInvalidationCannotReturnBarsOrEnterFallback(status: Int, cancel: Bool) async {
        let permitted = Mutex(true), calls = Mutex([String]())
        let task = Task {
            await Q.fetchHistory("AAPL", range: "3mo", interval: "1d", allowed: { permitted.withLock { $0 } },
                massive: { symbol, range, interval in
                    #expect(symbol == "AAPL" && range == "3mo" && interval == "1d")
                    calls.withLock { $0.append("massive") }
                    return await M.fetchHistory(symbol: symbol, request: Self.request,
                        allowed: { permitted.withLock { $0 } }, transport: { req in
                            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                            else { permitted.withLock { $0 = false } }
                            return Self.response(req, status: status)
                        })
                }, yahoo: { _ in calls.withLock { $0.append("yahoo") }; return Self.yahooBody })
        }
        #expect(await task.value == nil)
        #expect(calls.withLock { $0 } == ["massive"], "Revocation stops routing, not just the inner provider")
    }

    @Test(arguments: [false, true])
    func historyRoutingRejectsInvalidationBeforeEitherProvider(cancel: Bool) async {
        let calls = Mutex(0)
        let task = Task {
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return await Q.fetchHistory("AAPL", range: "3mo", interval: "1d", allowed: { cancel },
                massive: { _, _, _ in calls.withLock { $0 += 1 }; return nil },
                yahoo: { _ in calls.withLock { $0 += 1 }; return Self.yahooBody })
        }
        #expect(await task.value == nil)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func historyRoutingRejectsInvalidationInsideYahoo(cancel: Bool) async {
        let permitted = Mutex(true), calls = Mutex([String]())
        let task = Task {
            await Q.fetchHistory("AAPL", range: "3mo", interval: "1d", allowed: { permitted.withLock { $0 } },
                massive: { _, _, _ in calls.withLock { $0.append("massive") }; return nil },
                yahoo: { _ in
                    calls.withLock { $0.append("yahoo") }
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    else { permitted.withLock { $0 = false } }
                    return Self.yahooBody
                })
        }
        #expect(await task.value == nil)
        #expect(calls.withLock { $0 } == ["massive", "yahoo"])
    }

    @Test(arguments: ["primary", "unavailable", "malformed"])
    func validHistoryStillUsesTheExistingProviderOrder(mode: String) async throws {
        let calls = Mutex([String]())
        let result = await Q.fetchHistory("AAPL", range: "3mo", interval: "1d", allowed: { true },
            massive: { symbol, _, _ in
                calls.withLock { $0.append("massive") }
                return await M.fetchHistory(symbol: symbol, request: Self.request, allowed: { true },
                    transport: { req in Self.response(req, status: mode == "unavailable" ? 503 : 200,
                        body: mode == "malformed" ? Data("{}".utf8) : Self.massiveBody) })
            }, yahoo: { req in
                #expect(req.url?.host == "query1.finance.yahoo.com")
                calls.withLock { $0.append("yahoo") }
                return Self.yahooBody
            })
        let history = try #require(result)
        #expect(history.closes == [100, 100] && history.symbol == "AAPL")
        #expect(history.priceSource == (mode == "primary" ? .massiveDaily : .yahooBars))
        #expect(calls.withLock { $0 } == (mode == "primary" ? ["massive"] : ["massive", "yahoo"]))
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func invalidatedHistoryCannotPopulateDerivedCache(cancel: Bool, trailing: Bool) async throws {
        let suite = "StockSageHistoryBoundaryTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let bars = Self.bars("AAPL")
        #expect(StockSageLiquidity.profile(closes: bars.closes, volumes: bars.volumes)?.avgDollarVolume == 10_000_000)
        #expect(StockSageTrailingStop.suggest(highs: bars.highs, lows: bars.lows, closes: bars.closes)?.level == 95)
        await store.refreshLiquidity(symbol: "MSFT", allowed: { true }, history: { symbol, _ in Self.bars(symbol) })
        await store.refreshTrailingStop(symbol: "MSFT", allowed: { true }, history: { symbol, _ in Self.bars(symbol) })
        let liquidity = store.liquidity, stops = store.trailingStop
        var permitted = true
        var calls = 0
        let task = Task { @MainActor in
            let history: (String, String) async -> StockSagePriceHistory? = { symbol, range in
                #expect(symbol == "AAPL" && range == (trailing ? "6mo" : "3mo"))
                calls += 1
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                else { permitted = false }
                return bars
            }
            if trailing {
                await store.refreshTrailingStop(symbol: "AAPL", allowed: { permitted }, history: history)
            } else {
                await store.refreshLiquidity(symbol: "AAPL", allowed: { permitted }, history: history)
            }
        }
        await task.value
        #expect(calls == 1)
        #expect(store.liquidity == liquidity && store.trailingStop == stops,
                "Invalidation must preserve existing peers and leave the new cache entry absent")
        // A later legitimate request is still accepted; invalidation does not poison the cache.
        if trailing {
            await store.refreshTrailingStop(symbol: "AAPL", allowed: { true }, history: { _, _ in bars })
            #expect(store.trailingStop["AAPL"]?.level == 95 && store.trailingStop["MSFT"] == stops["MSFT"])
        } else {
            await store.refreshLiquidity(symbol: "AAPL", allowed: { true }, history: { _, _ in bars })
            #expect(store.liquidity["AAPL"]?.avgDollarVolume == 10_000_000 && store.liquidity["MSFT"] == liquidity["MSFT"])
        }
    }
}
