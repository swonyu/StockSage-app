import Foundation
import Synchronization
import Testing
@testable import StockSage

@Suite(.serialized) struct StockSageMomentumTests {
    typealias M = StockSageMomentum
    typealias T = StockSageMassiveTicks
    private let now = ISO8601DateFormatter().date(from: "2026-09-18T14:00:20Z")!
    private var access: StockSageMassive.Access {
        .init(key: { "fixture" }, credentialRevision: { "one" }, policyRevision: { "one" }, allowed: { true })
    }
    private func candles(end: Date, base: Double = 100, step: Double = 1, count: Int = 20) -> T.Intraday {
        let bars = (0..<count).map { index -> T.Minute in
            let close = base + Double(index) * step
            return .init(at: end.addingTimeInterval(Double(index - count) * 60), open: close,
                         high: close + 1, low: close - 1, close: close, volume: 100)
        }
        return .init(facts: [], asOf: end, bars: bars, verifiedMinutes: true)
    }
    private var end: Date { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60) }
    private func payload(symbol: String) throws -> Data {
        let rows = candles(end: end).bars.map { bar -> [String: Any] in
            ["t": Int64(bar.at.timeIntervalSince1970 * 1000), "o": bar.open, "h": bar.high,
             "l": bar.low, "c": bar.close, "v": bar.volume]
        }
        return try JSONSerialization.data(withJSONObject: ["status": "OK", "ticker": symbol,
            "adjusted": true, "resultsCount": rows.count, "results": rows])
    }
    private func market(spy: T.Intraday? = nil, qqq: T.Intraday? = nil, at: Date? = nil) -> M.Market {
        let clock = at ?? now
        return M.market(spy: spy ?? candles(end: end, step: 0.5),
                        qqq: qqq ?? candles(end: end, step: 0.25), now: clock)
    }

    @Test func exactCloseBoundariesAndRelativePercentagePointsAreRetained() throws {
        let stock = M.stock(symbol: "TEST", intraday: candles(end: end), market: market(), now: now)
        let five = try #require(stock.series.returns.first { $0.minutes == 5 })
        #expect(five.status == .available && five.start == end.addingTimeInterval(-300) && five.end == end)
        #expect(abs((five.percent ?? 0) - (119.0 / 114.0 - 1) * 100) < 0.0000001)
        let relative = try #require(stock.vsSPY.first { $0.minutes == 5 })
        let expected = ((119.0 / 114.0 - 1) - (109.5 / 107.0 - 1)) * 100
        #expect(abs((relative.differencePercentagePoints ?? 0) - expected) < 0.0000001)
        #expect(relative.start == five.start && relative.end == five.end)
        #expect(stock.facts.allSatisfy(\.required) && market().facts.allSatisfy(\.required))
        #expect(try JSONDecoder().decode(M.Stock.self, from: JSONEncoder().encode(stock)) == stock)
        let m = market()
        #expect(try JSONDecoder().decode(M.Market.self, from: JSONEncoder().encode(m)) == m)
    }

    @Test func relativeComparisonUsesExactSharedEndWithoutRelabelingLatestStockReturn() throws {
        let proxyEnd = end.addingTimeInterval(-60)
        let old = candles(end: proxyEnd, step: 0.5)
        let stock = M.stock(symbol: "TEST", intraday: candles(end: end), market: market(spy: old), now: now)
        let own = try #require(stock.series.returns.first { $0.minutes == 5 })
        let compared = try #require(stock.vsSPY.first { $0.minutes == 5 })
        #expect(own.end == end && compared.end == proxyEnd)
        #expect(compared.start == proxyEnd.addingTimeInterval(-300))
        #expect(abs((compared.stockPercent ?? 0) - (118.0 / 113.0 - 1) * 100) < 0.0000001)
        #expect(compared.differencePercentagePoints != nil)
    }

    @Test(arguments: ["gap", "zeroVolume"])
    func missingOrZeroVolumeInsideIntervalCannotBeReplacedWithZeroReturn(mode: String) throws {
        var input = candles(end: end)
        if mode == "gap" { input.bars.remove(at: 17) }
        else {
            let old = input.bars[17]
            input.bars[17] = .init(at: old.at, open: old.open, high: old.high, low: old.low, close: old.close, volume: 0)
        }
        let stock = M.stock(symbol: "TEST", intraday: input, market: market(), now: now)
        #expect(stock.series.returns.first { $0.minutes == 1 }?.percent != nil)
        #expect(stock.series.returns.first { $0.minutes == 5 }?.status == .gap)
        #expect(stock.series.returns.first { $0.minutes == 5 }?.percent == nil)
        #expect(stock.vsSPY.first { $0.minutes == 5 }?.differencePercentagePoints == nil)
    }

    @Test(arguments: ["stale", "future", "unverified", "fallback", "duplicate", "unsorted", "badOHLC", "offMinute", "wrongDate"])
    func untrustedOrExpiredSeriesNeverSupplyMomentum(mode: String) {
        var input = candles(end: end)
        switch mode {
        case "stale": input = candles(end: end.addingTimeInterval(-240))
        case "future": input = candles(end: end.addingTimeInterval(60))
        case "unverified": input.verifiedMinutes = false
        case "fallback": input = .init(facts: ["SIP fallback"], asOf: end, maximumAge: 120)
        case "duplicate": input.bars.insert(input.bars[10], at: 10)
        case "unsorted": input.bars.swapAt(10, 11)
        case "wrongDate": input = candles(end: end.addingTimeInterval(-86_400))
        default:
            let old = input.bars[10]
            input.bars[10] = .init(at: mode == "offMinute" ? old.at.addingTimeInterval(1) : old.at,
                open: old.open, high: mode == "badOHLC" ? old.close - 1 : old.high,
                low: old.low, close: old.close, volume: old.volume)
        }
        let result = M.stock(symbol: "TEST", intraday: input, market: market(), now: now)
        #expect(result.series.returns.allSatisfy { $0.percent == nil })
        #expect(result.vsSPY.allSatisfy { $0.differencePercentagePoints == nil })
        #expect(result.facts.contains { $0.availability != .available })
    }

    @Test func premarketPostmarketAndSessionTransitionLabelsRemainExplicit() throws {
        for (text, label) in [("2026-09-18T12:00:20Z", "Pre-market"), ("2026-09-18T21:00:20Z", "Post-market")] {
            let capture = ISO8601DateFormatter().date(from: text)!
            let boundary = Date(timeIntervalSince1970: floor(capture.timeIntervalSince1970 / 60) * 60)
            let input = candles(end: boundary)
            let result = M.market(spy: input, qqq: input, now: capture)
            #expect(result.spy.returns.allSatisfy { $0.percent != nil })
            #expect(result.spy.sessionLabel.contains(label))
        }
        let opening = ISO8601DateFormatter().date(from: "2026-09-18T13:35:20Z")!
        let boundary = Date(timeIntervalSince1970: floor(opening.timeIntervalSince1970 / 60) * 60)
        let result = M.market(spy: candles(end: boundary), qqq: candles(end: boundary), now: opening)
        #expect(result.spy.returns.first { $0.minutes == 15 }?.sessionLabel.contains("Pre-market") == true)
        #expect(result.spy.returns.first { $0.minutes == 15 }?.sessionLabel.contains("Regular") == true)
        let sunday = ISO8601DateFormatter().date(from: "2026-09-20T14:00:20Z")!
        #expect(M.market(spy: candles(end: end), qqq: candles(end: end), now: sunday).spy.returns.allSatisfy { $0.percent == nil })
    }

    @Test func oldMarketFactsAreUnavailableAtAssessmentWithoutRenewingCaptureTime() {
        let captured = market()
        let facts = captured.facts(at: now.addingTimeInterval(181))
        #expect(facts.filter { $0.key.hasSuffix("SPY") || $0.key.hasSuffix("QQQ") }.allSatisfy { $0.availability == .missing })
        #expect(facts.contains { $0.text.contains(captured.capturedAt.ISO8601Format()) })
        #expect(captured.facts.contains { $0.key.hasSuffix("SPY") && $0.availability == .available })
    }

    @Test func assessmentRechecksAnOlderRelativeEndpointWithoutRenewingStockCapture() {
        let proxy = candles(end: end.addingTimeInterval(-120))
        let capturedMarket = market(spy: proxy, qqq: proxy)
        let stock = M.stock(symbol: "TEST", intraday: candles(end: end), market: capturedMarket, now: now)
        #expect(stock.vsSPY.allSatisfy { $0.differencePercentagePoints != nil })
        let offered = stock.facts(at: now.addingTimeInterval(50), market: capturedMarket)
        #expect(offered.contains { $0.key == "technical.momentum.stock" && $0.availability == .available })
        #expect(offered.contains { $0.key == "technical.momentum.relative.SPY" && $0.availability == .missing })
        #expect(offered.contains { $0.text.contains("captured " + stock.capturedAt.ISO8601Format()) })
    }

    @Test(arguments: [1.0, -1.0])
    func heavyMomentumRequiresSeparateReturnAndTwentyMinuteVolumeThresholds(direction: Double) throws {
        func input(change: Double, latestVolume: Double = 300) -> T.Intraday {
            let bars = (0..<20).map { index -> T.Minute in
                let close = index < 15 ? 100 : 100 + change * Double(index - 14) / 5
                return .init(at: end.addingTimeInterval(Double(index - 20) * 60), open: close,
                    high: close + 1, low: close - 1, close: close, volume: index < 15 ? 100 : latestVolume)
            }
            return .init(facts: [], asOf: end, bars: bars, verifiedMinutes: true)
        }
        let value = M.stock(symbol: "TEST", intraday: input(change: 3 * direction), market: market(), now: now)
        let trigger = try #require(value.heavyMomentum(profile: .microcap, now: now))
        #expect(trigger.direction == (direction > 0 ? .rising : .falling))
        #expect(trigger.volumeMultiple == 3 && trigger.at == end && trigger.start == end.addingTimeInterval(-300))
        #expect(value.volumeAcceleration.precedingFiveMinuteVolumes == [500, 500, 500])
        #expect(trigger.facts.allSatisfy { $0.required })
        let restored = try JSONDecoder().decode(M.Trigger.self, from: JSONEncoder().encode(trigger))
        #expect(restored == trigger)
        #expect(value.heavyMomentum(profile: .microcap, now: now.addingTimeInterval(181)) == nil)
        let small = M.stock(symbol: "TEST", intraday: input(change: 1.1 * direction), market: market(), now: now)
        #expect(small.heavyMomentum(profile: .microcap, now: now) == nil)
        #expect(small.heavyMomentum(profile: .largecap, now: now) != nil)
        let lowVolume = M.stock(symbol: "TEST", intraday: input(change: 4 * direction, latestVolume: 299), market: market(), now: now)
        #expect(lowVolume.heavyMomentum(profile: .largecap, now: now) == nil)
        var gap = input(change: 4 * direction); gap.bars.removeFirst()
        #expect(M.stock(symbol: "TEST", intraday: gap, market: market(), now: now).heavyMomentum(profile: .microcap, now: now) == nil)
    }

    @Test func marketCollectMakesOnlyTwoBoundedMinuteRequestsAndNeverFallsBackToTrades() async {
        let paths = Mutex<[String]>([])
        let snapshot = await M.collect(now: now, access: access, transport: { request in
            paths.withLock { $0.append(request.url!.path) }
            #expect(request.url?.path.contains("/range/1/minute/") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (Data(#"{"status":"OK","results":[]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now })
        #expect(paths.withLock { $0.count } == 2)
        #expect(snapshot.spy.returns.allSatisfy { $0.percent == nil })
        #expect(snapshot.qqq.returns.allSatisfy { $0.percent == nil })
    }

    @Test func collectedProviderCandlesRetainObservationAndCompletionClocks() async throws {
        let responses = ["SPY": try payload(symbol: "SPY"), "QQQ": try payload(symbol: "QQQ")]
        let result = await M.collect(now: now, access: access, transport: { request in
            let symbol = request.url!.pathComponents[4]
            return (responses[symbol]!, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now.addingTimeInterval(1) })
        #expect(result.capturedAt == now.addingTimeInterval(1))
        #expect(result.spy.asOf == end && result.qqq.asOf == end)
        #expect(result.spy.returns.allSatisfy { $0.percent != nil })
        #expect(result.qqq.returns.allSatisfy { $0.percent != nil })
    }

    @Test(arguments: ["denied", "noKey", "credential", "policy", "cancelled"])
    func interruptedAccessCannotPublishEitherProxy(mode: String) async throws {
        let revision = Mutex("one"), calls = Mutex(0)
        let responses = ["SPY": try payload(symbol: "SPY"), "QQQ": try payload(symbol: "QQQ")]
        let current = StockSageMassive.Access(key: { mode == "noKey" ? "" : "fixture" },
            credentialRevision: { mode == "credential" ? revision.withLock { $0 } : "one" },
            policyRevision: { mode == "policy" ? revision.withLock { $0 } : "one" },
            allowed: { mode != "denied" })
        let result = await Task {
            if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return await M.collect(now: now, access: current, transport: { request in
                calls.withLock { $0 += 1 }; revision.withLock { $0 = "two" }
                let symbol = request.url!.pathComponents[4]
                return (responses[symbol]!,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, clock: { now })
        }.value
        #expect(result.spy.returns.allSatisfy { $0.percent == nil } && result.qqq.returns.allSatisfy { $0.percent == nil })
        if ["denied", "noKey", "cancelled"].contains(mode) { #expect(calls.withLock { $0 } == 0) }
    }
}
