import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageMicrocapScreenTests {
    typealias S = StockSageMicrocapScreen
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    var now: Date { date("2026-09-18T14:00:42Z") }
    func listing(_ symbol: String = "MICRO", exchange: String = "XNAS", type: String = "CS") -> S.Listing {
        .init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
            type: type, currency_name: "usd", primary_exchange: exchange)
    }
    func reference(_ cap: Double = 100_000_000) -> S.Reference {
        .init(marketCap: cap, requestedDate: "2026-09-18", retrievedAt: now)
    }
    func float(_ shares: Double = 10_000_000, age: TimeInterval = 86_400) -> S.FloatRecord {
        .init(shares: shares, effectiveDate: now.addingTimeInterval(-age))
    }
    @Test(arguments: [50_000_000.0, 300_000_000.0]) func inclusiveMarketCapBoundariesRemainEligible(cap: Double) {
        let row = S.classify(listing(), reference: reference(cap), float: float(), at: now)
        #expect(row.status == .unassessed)
        #expect(row.marketCap == cap && row.freeFloat == 10_000_000)
        #expect(row.marketCapRequestedDate == "2026-09-18" && row.floatEffectiveDate == float().effectiveDate)
    }
    @Test func missingInputsNeverBecomeZeroAndRulesDoNotAdmitOtherInstruments() {
        #expect(S.classify(listing(), reference: nil, float: float(), at: now).status == .unavailable)
        #expect(S.classify(listing(), reference: reference(), float: nil, at: now).status == .unavailable)
        for cap in [49_999_999.0, 300_000_001] {
            #expect(S.classify(listing(), reference: reference(cap), float: float(), at: now).status == .excluded)
        }
        #expect(S.classify(listing(), reference: reference(), float: float(20_000_000), at: now).status == .excluded)
        #expect(S.classify(listing(exchange: "XNYS"), reference: reference(), float: float(), at: now).status == .excluded)
        #expect(S.classify(listing(type: "ETF"), reference: reference(), float: float(), at: now).status == .excluded)
    }
    @Test func staleFutureAndInvalidSourceDatesCannotQualify() {
        for age in [-1.0, S.floatMaximumAge + 1] {
            #expect(S.classify(listing(), reference: reference(), float: float(age: age), at: now).status == .unavailable)
        }
        let future = S.Reference(marketCap: 100_000_000, requestedDate: "2026-09-19", retrievedAt: now)
        #expect(S.classify(listing(), reference: future, float: float(), at: now).status == .unavailable)
        let stale = S.Reference(marketCap: 100_000_000, requestedDate: "2026-09-17", retrievedAt: now)
        #expect(S.classify(listing(), reference: stale, float: float(), at: now).status == .unavailable)
    }
    @Test func capClassificationPrecedesTwentyFourDetailLimitAndPreservesRemainingRows() throws {
        let symbols = (0..<27).map { "M\($0)" }
        let rows = symbols.enumerated().map { index, symbol in
            S.classify(listing(symbol), reference: reference(index == 26 ? 900_000_000 : 100_000_000), float: float(), at: now)
        }
        let activity = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($0.element, Double($0.offset + 1)) })
        let selected = S.detailSymbols(rows: rows, activity: activity)
        #expect(selected.count == 24 && selected.first == "M25" && selected.last == "M2")
        #expect(!selected.contains("M26"))
        #expect(rows.count == 27 && rows.filter { $0.status == .unassessed }.count == 26)
        let receipt = S.Result(policyVersion: S.policyVersion, startedAt: now, cutoff: now, finishedAt: now,
            directoryCount: rows.count, detailedCount: 24, unassessedCount: 2, rows: rows, blocker: nil)
        let decoded = try JSONDecoder().decode(S.Result.self, from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
    }
    @Test func windowUsesCompletedMinutesAndExchangeLocalTimeAcrossDST() throws {
        let value = try S.window(at: date("2026-03-09T14:00:42Z"))
        #expect(value.cutoff == date("2026-03-09T14:00:00Z"))
        #expect(value.current.open == date("2026-03-09T13:30:00Z"))
        #expect(value.previous.count == 20)
        #expect(value.previous.last?.open == date("2026-03-06T14:30:00Z"))
        #expect(value.cutoff.timeIntervalSince(value.current.open) == 1800)
    }
    @Test func closedUnverifiedAndUnmatchedEarlyCloseWindowsAreUnavailable() {
        for timestamp in ["2026-09-20T14:00:00Z", "2026-09-18T13:59:59Z", "2026-09-18T19:55:00Z",
                          "2027-03-09T15:00:00Z", "2026-11-30T19:00:00Z"] {
            #expect(throws: (any Error).self) { try S.window(at: date(timestamp)) }
        }
    }
    func bars(_ window: S.Window) -> [S.Minute] {
        var values: [S.Minute] = []
        for session in window.previous {
            values.append(.init(at: session.open, open: 10, high: 10, low: 10, close: 10, volume: 100))
            values.append(.init(at: session.close.addingTimeInterval(-60), open: 10, high: 10, low: 10, close: 10, volume: 10))
        }
        values.append(.init(at: window.current.open, open: 11, high: 11, low: 11, close: 11, volume: 490))
        values.append(.init(at: window.cutoff.addingTimeInterval(-60), open: 11, high: 11.25, low: 11, close: 11.25, volume: 10))
        return values.sorted { $0.at < $1.at }
    }
    func close(_ window: S.Window, value: Double = 10) -> S.SessionClose {
        .init(date: String(window.previous.last!.open.ISO8601Format().prefix(10)), close: value, retrievedAt: window.cutoff)
    }
    @Test func gapUsesOpeningPriceAndRvolUsesTwentyMatchedWindowsNotFullDayVolume() throws {
        let window = try S.window(at: now)
        let measured = try S.measure(bars(window), in: window, previousClose: close(window))
        #expect(abs(measured.openingGap - 0.10) < 0.000_001)
        #expect(measured.relativeVolume == 5 && measured.volume == 500 && measured.baselineVolume == 100)
        #expect(measured.baselineSessions == 20 && measured.previousRegularClose == 10 && measured.openingPrice == 11)
        #expect(abs(measured.momentum - (11.25 / 11 - 1)) < 0.000_001)
        #expect(measured.annualizedVolatility == 0)
        #expect(measured.observedAt == window.cutoff.addingTimeInterval(-60))
    }
    @Test func missingSessionOpeningCloseAndAmbiguousShareBasisFailExplicitly() throws {
        let window = try S.window(at: now)
        let complete = bars(window)
        let first = try #require(window.previous.first)
        let last = try #require(window.previous.last)
        for bad in [complete.filter { $0.at != first.open },
                    complete.filter { $0.at != window.current.open },
                    complete.filter { $0.at != last.close.addingTimeInterval(-60) }] {
            #expect(throws: (any Error).self) { try S.measure(bad, in: window, previousClose: close(window)) }
        }
        #expect(throws: (any Error).self) { try S.measure(complete, in: window, previousClose: close(window), hasSplit: true) }
    }
    @Test func openingGapUsesDatedRegularCloseEvenWhenFinalMinuteAndAfterHoursDiffer() throws {
        let window = try S.window(at: now)
        let payload: [String: Any] = ["status": "OK", "symbol": "MICRO", "from": "2026-09-17",
            "close": 10.5, "afterHours": 9, "open": 10]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reference = try S.parseClose(data, symbol: "MICRO", date: "2026-09-17", retrievedAt: now)
        let measured = try S.measure(bars(window), in: window, previousClose: reference)
        #expect(abs(measured.openingGap - (11 / 10.5 - 1)) < 0.000_001)
        #expect(measured.openingGap < 0.10 && measured.previousRegularClose == 10.5)
        #expect(measured.previousRegularCloseDate == "2026-09-17")
        #expect(measured.annualizedVolatility == 0, "Minute-close volatility stays a separately labelled proxy.")
        #expect(throws: (any Error).self) { try S.measure(bars(window), in: window) }
        let wrong = S.SessionClose(date: "2026-09-16", close: 10.5, retrievedAt: now)
        #expect(throws: (any Error).self) { try S.measure(bars(window), in: window, previousClose: wrong) }
        for (field, value): (String, Any) in [("symbol", "OTHER"), ("from", "2026-09-16"),
                                           ("close", NSNull()), ("close", true), ("adjusted", false), ("adjusted", 1)] {
            var invalid = payload; invalid[field] = value
            let data = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self) { try S.parseClose(data, symbol: "MICRO", date: "2026-09-17", retrievedAt: now) }
        }
        let request = try #require(S.closeRequest(symbol: "MICRO", date: "2026-09-17", key: "fixture"))
        #expect(request.url?.absoluteString == "https://api.massive.com/v1/open-close/MICRO/2026-09-17?adjusted=true")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    }
    @Test func deniedRunNeverStartsHTTP() async {
        let result = await S.select(key: "fixture-not-a-key", allowed: { false }, now: now, clock: { now }, transport: { _ in
            Issue.record("Denied screen must not start a request")
            throw URLError(.cancelled)
        })
        #expect(result.listings.isEmpty && result.receipt.blocker != nil)
    }

    func minutePayload(_ bars: [S.Minute], extra: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["status": "OK", "ticker": "MICRO", "adjusted": true,
            "resultsCount": bars.count, "queryCount": bars.count,
            "results": bars.map { ["t": $0.at.timeIntervalSince1970 * 1000, "o": $0.open,
                "h": $0.high, "l": $0.low, "c": $0.close, "v": $0.volume] }]
        root.merge(extra) { _, value in value }
        return try JSONSerialization.data(withJSONObject: root)
    }
    @Test func minutePayloadMustProveWholeBoundedAdjustedWindow() throws {
        let window = try S.window(at: now), original = bars(window)
        let parsed = try S.parseMinutes(minutePayload(original), symbol: "MICRO", window: window)
        #expect(parsed == original)
        for extra: [String: Any] in [["next_url": "https://api.massive.com/next"], ["queryCount": 50_000],
                                    ["adjusted": false], ["adjusted": 1], ["ticker": "OTHER"], ["resultsCount": 1]] {
            let data = try minutePayload(original, extra: extra)
            #expect(throws: (any Error).self) { try S.parseMinutes(data, symbol: "MICRO", window: window) }
        }
        let duplicate = original + [original.last!]
        let data = try minutePayload(duplicate)
        #expect(throws: (any Error).self) { try S.parseMinutes(data, symbol: "MICRO", window: window) }
        let request = try #require(S.minuteRequest(symbol: "MICRO", window: window, key: "fixture"))
        #expect(request.url?.absoluteString.contains("/range/1/minute/") == true)
        #expect(request.url?.absoluteString.contains("limit=50000") == true)
        #expect(request.url?.absoluteString.contains("fixture") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    }
    @Test func floatIsTypedDatedAndPaginationNeverMovesCredential() throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": [
            ["ticker": "MICRO", "free_float": 12_000_000, "effective_date": "2026-09-17"],
            ["ticker": "BOOL", "free_float": true, "effective_date": "2026-09-17"],
            ["ticker": "OUTSTANDING", "weighted_shares_outstanding": 12_000_000, "effective_date": "2026-09-17"],
            ["ticker": "NODATE", "free_float": 12_000_000]
        ]])
        let page = try S.parseFloats(data)
        #expect(page.count == 4 && page.records.count == 1 && page.records["MICRO"]?.shares == 12_000_000)
        for url in ["https://evil.example/stocks/vX/float?cursor=a", "https://api.massive.com/v3/reference/tickers?cursor=a",
                    "https://api.massive.com/stocks/vX/float?apiKey=secret", "https://user@api.massive.com/stocks/vX/float?cursor=a",
                    "http://api.massive.com/stocks/vX/float?cursor=a", "https://api.massive.com/stocks/vX/float?cursor=a#fragment"] {
            #expect(S.floatRequest(key: "fixture", next: url) == nil)
        }
        let request = try #require(S.floatRequest(key: "fixture", next: "https://api.massive.com/stocks/vX/float?cursor=abc&limit=5000"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.url?.absoluteString.contains("fixture") == false)
    }
    @Test func datedReferenceRequiresSameTickerClassificationAndNumericCap() throws {
        var detail: [String: Any] = ["ticker": "MICRO", "active": true, "market": "stocks", "locale": "us",
            "primary_exchange": "XNAS", "type": "CS", "currency_name": "usd", "market_cap": 50_000_000]
        func payload(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["status": "OK", "results": row]) }
        let parsed = try S.parseReference(payload(detail), listing: listing(), requestedDate: "2026-09-18", retrievedAt: now)
        #expect(parsed.marketCap == 50_000_000 && parsed.requestedDate == "2026-09-18")
        for (key, value): (String, Any) in [("ticker", "OTHER"), ("market_cap", true), ("market_cap", "50000000"), ("primary_exchange", "XNYS")] {
            var changed = detail; changed[key] = value
            let data = try payload(changed)
            #expect(throws: (any Error).self) { try S.parseReference(data, listing: listing(), requestedDate: "2026-09-18", retrievedAt: now) }
        }
        detail.removeValue(forKey: "market_cap")
        detail["weighted_shares_outstanding"] = 50_000_000
        let missing = try payload(detail)
        #expect(throws: (any Error).self) { try S.parseReference(missing, listing: listing(), requestedDate: "2026-09-18", retrievedAt: now) }
        #expect(S.referenceRequest(symbol: "BAD/../../route", date: "2026-09-18", key: "fixture") == nil)
    }

    actor FixtureTransport {
        let bodies: [String: Data]
        var requests: [URLRequest] = []
        var active = 0
        var peak = 0
        init(_ bodies: [String: Data]) { self.bodies = bodies }
        func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request); active += 1; peak = max(peak, active)
            defer { active -= 1 }
            await Task.yield()
            let url = try #require(request.url)
            let body = try #require(bodies[url.path])
            return (body, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        func recorded() -> ([URLRequest], Int) { (requests, peak) }
    }
    @MainActor final class CaptureClock {
        var now: Date
        var allowed = true
        init(_ value: Date) { now = value }
    }
    func fixtureBodies(symbols: [String], window: S.Window) throws -> [String: Data] {
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let directory = symbols.map { symbol in
            ["ticker": symbol, "name": symbol, "market": "stocks", "locale": "us", "active": true,
             "type": "CS", "currency_name": "usd", "primary_exchange": "XNAS"] as [String: Any]
        }
        var bodies: [String: Data] = [
            "/v3/reference/tickers": try data(["status": "OK", "count": symbols.count, "results": directory]),
            "/stocks/vX/float": try data(["status": "OK", "results": symbols.map {
                ["ticker": $0, "free_float": $0 == "HIGHFLOAT" ? 30_000_000 : 10_000_000,
                 "effective_date": "2026-09-17"] as [String: Any]
            }]),
            "/stocks/v1/splits": try data(["status": "OK", "results": []]),
            "/v2/aggs/grouped/locale/us/market/stocks/2026-09-18": try data([
                "status": "OK", "adjusted": true, "resultsCount": symbols.count,
                "results": symbols.enumerated().map {
                    ["T": $0.element, "t": window.current.open.timeIntervalSince1970 * 1000,
                     "v": Double($0.offset + 1), "vw": 10] as [String: Any]
                }])
        ]
        for (index, symbol) in symbols.enumerated() {
            var reference = directory[index]; reference["market_cap"] = symbol == "TOOBIG" ? 900_000_000 : 100_000_000
            bodies["/v3/reference/tickers/\(symbol)"] = try data(["status": "OK", "results": reference])
            let previousDate = String(window.previous.last!.open.ISO8601Format().prefix(10))
            bodies["/v1/open-close/\(symbol)/\(previousDate)"] = try data(["status": "OK", "symbol": symbol,
                "from": previousDate, "close": 10, "afterHours": 90])
            let path = try #require(S.minuteRequest(symbol: symbol, window: window, key: "fixture")?.url?.path)
            bodies[path] = try minutePayload(bars(window), extra: ["ticker": symbol])
        }
        return bodies
    }
    @Test func collectorPreservesWholeClassificationBoundsDetailsAndFreezesCutoffAfterReferenceWork() async throws {
        let symbols = (65...90).map { "M" + String(UnicodeScalar($0)!) } + ["TOOBIG", "HIGHFLOAT"]
        let afterReference = now.addingTimeInterval(120), window = try S.window(at: afterReference)
        let fixture = FixtureTransport(try fixtureBodies(symbols: symbols, window: window))
        let capture = CaptureClock(now)
        let result = await S.select(key: "fixture", allowed: { capture.allowed }, now: now, clock: { capture.now }, transport: { request in
            let response = try await fixture.reply(request)
            if request.url?.path.hasPrefix("/v3/reference/tickers/") == true {
                await MainActor.run { capture.now = afterReference }
            }
            return response
        })
        #expect(result.receipt.blocker == nil)
        #expect(result.listings.count == 24 && result.listings.first?.ticker == "MZ" && result.listings.last?.ticker == "MC")
        #expect(result.receipt.rows.count == 28 && result.receipt.directoryCount == 28)
        #expect(result.receipt.detailedCount == 24 && result.receipt.unassessedCount == 2)
        #expect(result.receipt.cutoff == window.cutoff && result.receipt.startedAt == now)
        #expect(result.receipt.rows.first(where: { $0.symbol == "TOOBIG" })?.status == .excluded)
        #expect(result.receipt.rows.first(where: { $0.symbol == "HIGHFLOAT" })?.marketCap == nil)
        let (requests, peak) = await fixture.recorded()
        #expect(peak <= 4)
        #expect(requests.filter { $0.url?.path.contains("/range/1/minute/") == true }.count == 24)
        #expect(!requests.contains { $0.url?.path == "/v3/reference/tickers/HIGHFLOAT" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" && $0.url?.absoluteString.contains("fixture") == false })
        let facts = result.receipt.facts(for: "MZ")
        #expect(facts.count == 4 && facts.allSatisfy(\.required))
        #expect(facts.contains { $0.text.contains("not unique shares or investor identity") })
        #expect(result.receipt.facts(for: "MA").isEmpty)
        let restored = try JSONDecoder().decode(S.Result.self, from: JSONEncoder().encode(result.receipt))
        #expect(restored == result.receipt)
    }
    @Test func accessChangeAfterFloatResponseStopsBeforeAnyCapOrDetailAndKeepsDiscoveredRows() async throws {
        let fixture = FixtureTransport(try fixtureBodies(symbols: ["MICRO"], window: S.window(at: now)))
        let capture = CaptureClock(now)
        let result = await S.select(key: "fixture", allowed: { capture.allowed }, now: now, clock: { capture.now }, transport: { request in
            let response = try await fixture.reply(request)
            if request.url?.path == "/stocks/vX/float" { await MainActor.run { capture.allowed = false } }
            return response
        })
        #expect(result.listings.isEmpty && result.receipt.blocker != nil && result.receipt.rows.count == 1)
        let (requests, _) = await fixture.recorded()
        #expect(requests.count == 2)
    }
    @Test func substitutedResponseURLCannotSupplyDirectoryData() async throws {
        let result = await S.select(key: "fixture", allowed: { true }, now: now, clock: { now }, transport: { _ in
            let url = URL(string: "https://evil.example/directory")!
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(result.listings.isEmpty && result.receipt.rows.isEmpty && result.receipt.blocker != nil)
    }
}
