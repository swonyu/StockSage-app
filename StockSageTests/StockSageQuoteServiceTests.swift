import Testing
import Foundation
import Synchronization
@testable import StockSage

// MARK: - Quote feed parsing — only-real-data validity guards
// (Named distinctly from `StockSageQuoteServiceTests` in StockSageTests.swift,
// which covers signal recommendations; this one covers history JSON parsing.)

struct StockSageQuoteServiceParsingTests {
    @Test func extendedPricesKeepTheirOwnClockAndDoNotOverrideNewerRegularPrices() throws {
        let f = ISO8601DateFormatter()
        let regular = try #require(f.date(from: "2026-09-21T20:00:00Z"))
        let pre = try #require(f.date(from: "2026-09-22T12:00:00Z"))
        let post = try #require(f.date(from: "2026-09-22T21:00:00Z"))
        func payload(regularAt: Date = regular, extended: Date = pre, price: Any = 105,
                     symbol: String = "AAPL", bars: Bool = false) throws -> Data {
            var meta: [String: Any] = ["symbol": symbol, "regularMarketPrice": 100,
                "regularMarketTime": regularAt.timeIntervalSince1970, "previousClose": 99]
            var result: [String: Any] = [:]
            if bars {
                result["timestamp"] = [regularAt.timeIntervalSince1970, extended.timeIntervalSince1970]
                result["indicators"] = ["quote": [["close": [100, price]]]]
            } else {
                meta["preMarketPrice"] = price; meta["preMarketTime"] = extended.timeIntervalSince1970
            }
            result["meta"] = meta
            return try JSONSerialization.data(withJSONObject: ["chart": ["result": [result]]])
        }
        for at in [pre, post] {
            for bars in [false, true] {
                let q = try #require(StockSageQuoteService.parseChart(payload(extended: at, bars: bars), now: at))
                #expect(q.price == 105 && q.marketTime == at)
                #expect(q.previousClose == 99 && q.previousCloseSource == .yahoo && q.priceSource == .yahoo)
                #expect(!q.paperTradeQualified)
            }
        }
        let newerRegular = try #require(f.date(from: "2026-09-22T14:00:00Z"))
        #expect(try StockSageQuoteService.parseChart(payload(regularAt: newerRegular), now: newerRegular)?.price == 100)
        #expect(try StockSageQuoteService.parseChart(payload(extended: post), now: pre)?.price == 100)
        #expect(try StockSageQuoteService.parseChart(payload(extended: newerRegular), now: newerRegular)?.price == 100)
        #expect(try StockSageQuoteService.parseChart(payload(symbol: "2222.SR"), now: pre)?.price == 100)
        for bad: Any in [0, -1, true, NSNull()] {
            #expect(try StockSageQuoteService.parseChart(payload(price: bad, bars: true), now: pre)?.price == 100)
        }
    }

    @Test func requestedQuoteIdentityMustMatchAndNumericStringsRemainSupported() {
        let data = Data(#"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":"150.25","previousClose":"148.50"}}]}}"#.utf8)
        #expect(StockSageQuoteService.parseChart(data, requestedSymbol: "MSFT") == nil)
        #expect(StockSageQuoteService.parseChart(data, requestedSymbol: "aapl")?.price == 150.25)
    }

    @Test func booleansAreNotPricesBaselinesOrBars() {
        let quote = #"{"chart":{"result":[{"meta":{"symbol":"AAPL","regularMarketPrice":150,"previousClose":148}}]}}"#
        #expect(StockSageQuoteService.parseChart(Data(quote.replacingOccurrences(of: "150", with: "true").utf8)) == nil)
        let missing = StockSageQuoteService.parseChart(Data(quote.replacingOccurrences(of: "148", with: "true").utf8))
        #expect(missing?.isNewListing == true && missing?.previousCloseSource == nil)
        let history = #"{"chart":{"result":[{"meta":{"symbol":"AAPL"},"timestamp":[1,2],"indicators":{"quote":[{"open":[1,1],"high":[2,2],"low":[1,1],"close":[true,1]}]}}]}}"#
        #expect(StockSageQuoteService.parseHistory(Data(history.utf8), symbol: "AAPL") == nil)
        #expect(StockSageQuoteService.parseHistory(Data(history.replacingOccurrences(of: "true", with: "1").utf8), symbol: "MSFT") == nil)
    }

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


struct StockSageQuoteTransportTests {
    typealias Q = StockSageQuoteService

    @Test func quoteFallbackRequestsExtendedMinuteObservations() async {
        let result = await Q.fetchQuoteBatch(for: ["AAPL"], keyPresent: false, allowed: { true },
            massive: { _ in [:] }, transport: { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(items.contains(URLQueryItem(name: "includePrePost", value: "true")))
                #expect(items.contains(URLQueryItem(name: "interval", value: "1m")))
                return Self.response(request)
            })
        #expect(result.quotes["AAPL"]?.price == 101)
    }

    nonisolated private static func response(_ request: URLRequest, status: Int = 200,
        symbol: String = "AAPL", url: URL? = nil, headers: [String: String]? = nil,
        body: Data? = nil) -> (Data, URLResponse) {
        let json = "{\"chart\":{\"result\":[{\"meta\":{\"symbol\":\"\(symbol)\",\"regularMarketPrice\":101,\"previousClose\":100,\"regularMarketTime\":1700000000}}]}}"
        return (body ?? Data(json.utf8), HTTPURLResponse(url: url ?? request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!)
    }

    @Test(arguments: [429, 503])
    func providerThrottleStopsTheSweepWithinItsFirstBatch(status: Int) async {
        let calls = Mutex([String]()), sleeps = Mutex(0)
        let names = (0..<19).map { "TEST\($0)" }
        let result = await Q.fetchQuoteBatch(for: names, concurrency: 6, keyPresent: false,
            allowed: { true }, massive: { _ in [:] }, transport: { request in
                calls.withLock { $0.append(request.url!.lastPathComponent) }
                return Self.response(request, status: status)
            }, sleep: { _ in sleeps.withLock { $0 += 1 } })
        #expect(result.stop == .yahooThrottled && result.quotes.isEmpty)
        let requested = calls.withLock { $0 }
        #expect(!requested.isEmpty && requested.count <= 6)
        #expect(Set(requested).isSubset(of: Set(names.prefix(6))))
        #expect(sleeps.withLock { $0 } == 0, "Do not retry each symbol during a provider-wide throttle")
    }

    @Test func aThrottleRetainsValidPrimaryAndEarlierFallbackQuotes() async {
        let calls = Mutex([String]())
        let primary = Q.LiveQuote(symbol: "AAPL", price: 100, previousClose: 99, priceSource: .massiveSIP)
        let result = await Q.fetchQuoteBatch(for: ["AAPL", "MSFT", "NVDA", "AMD"], concurrency: 1,
            keyPresent: true, allowed: { true }, massive: { _ in ["AAPL": primary] },
            transport: { request in
                let symbol = request.url!.lastPathComponent
                calls.withLock { $0.append(symbol) }
                return Self.response(request, status: symbol == "NVDA" ? 429 : 200, symbol: symbol)
            }, sleep: { _ in })
        #expect(result.stop == .yahooThrottled)
        #expect(Set(result.quotes.keys) == ["AAPL", "MSFT"])
        #expect(result.quotes["AAPL"] == primary && result.quotes["MSFT"]?.priceSource == .yahoo)
        #expect(calls.withLock { $0 } == ["MSFT", "NVDA"])
    }

    @Test(arguments: ["primary", "fallback"])
    func invalidatedSweepDropsAccumulatedQuotesAndStopsRouting(at phase: String) async {
        let allowed = Mutex(true), calls = Mutex([String]())
        let result = await Q.fetchQuoteBatch(for: ["AAPL", "MSFT", "NVDA"], concurrency: 1,
            keyPresent: true, allowed: { allowed.withLock { $0 } }, massive: { _ in
                if phase == "primary" { allowed.withLock { $0 = false } }
                return ["AAPL": .init(symbol: "AAPL", price: 100, previousClose: 99)]
            }, transport: { request in
                calls.withLock { $0.append(request.url!.lastPathComponent) }
                allowed.withLock { $0 = false }
                return Self.response(request, symbol: request.url!.lastPathComponent)
            }, sleep: { _ in })
        #expect(result.stop == .invalidated && result.quotes.isEmpty)
        #expect(calls.withLock { $0 }.count == (phase == "primary" ? 0 : 1))
    }

    @Test(arguments: ["different-url", "declared-too-large", "actual-too-large", "redirect"])
    func yahooRejectsUntrustedOrOversizedResponses(mode: String) async {
        let request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=1d&interval=1d")!)
        let result = await Q.yahooResponse(for: request, allowed: { true }, transport: { request in
            Self.response(request, status: mode == "redirect" ? 302 : 200,
                url: mode == "different-url" ? URL(string: "https://example.invalid/replaced") : nil,
                headers: mode == "declared-too-large" ? ["Content-Length": String(Q.maximumYahooBytes + 1)] : nil,
                body: mode == "actual-too-large" ? Data(repeating: 32, count: Q.maximumYahooBytes + 1) : nil)
        }, sleep: { _ in })
        guard case .unavailable = result else { Issue.record("Unsafe response was accepted: \(mode)"); return }
    }

    @Test(arguments: ["credential", "policy"])
    func capturedGenerationRejectsRoundTripsDuringFallback(kind: String) async {
        let revision = Mutex(0), calls = Mutex(0)
        let access = StockSageMassive.Access(key: { "fixture" },
            credentialRevision: { kind == "credential" ? String(revision.withLock { $0 }) : "fixed" },
            policyRevision: { kind == "policy" ? String(revision.withLock { $0 }) : "fixed" }, allowed: { true }).capture()
        let result = await Q.fetchQuoteBatch(for: ["AAPL", "MSFT", "NVDA"], concurrency: 1,
            keyPresent: true, allowed: access.isCurrent,
            massive: { _ in ["AAPL": .init(symbol: "AAPL", price: 100, previousClose: 99)] },
            transport: { request in
                calls.withLock { $0 += 1 }
                revision.withLock { $0 += 2 } // Original key/access restored, generation still changed.
                return Self.response(request, symbol: request.url!.lastPathComponent)
            }, sleep: { _ in })
        #expect(result.stop == .invalidated && result.quotes.isEmpty && calls.withLock { $0 } == 1)
    }

    @Test(arguments: [0, -1])
    func nonpositiveConcurrencyStillProcessesTheRequestedSymbols(concurrency: Int) async {
        let result = await Q.fetchQuoteBatch(for: ["AAPL"], concurrency: concurrency, keyPresent: false,
            allowed: { true }, massive: { _ in [:] }, transport: { Self.response($0) }, sleep: { _ in })
        #expect(result.stop == .finished && result.quotes["AAPL"]?.price == 101)
    }

    @Test(arguments: ["exact", "overflow", "declared"])
    func nativeYahooTransportEnforcesStreamingBounds(mode: String) async throws {
        #expect(Q.yahooSession.delegate is StockSageHTTP.NoRedirect)
        let configuration = Q.yahooSession.configuration
        #expect(configuration.timeoutIntervalForResource == 30 && configuration.urlCache == nil
                && configuration.urlCredentialStorage == nil && configuration.httpCookieStorage == nil)
        configuration.protocolClasses = [QuoteBodyProtocol.self]
        let session = URLSession(configuration: configuration, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/\(mode)")!)
        do {
            let (data, _) = try await Q.yahooTransport(request, session: session)
            #if os(iOS)
            Issue.record("Phone transport must not request provider bytes, including with a local URLProtocol")
            #else
            #expect(mode == "exact" && data.count == Q.maximumYahooBytes)
            #endif
        } catch {
            #if os(iOS)
            #expect((error as? URLError)?.code == .notConnectedToInternet)
            #else
            #expect(mode != "exact" && (error as? URLError)?.code == .dataLengthExceedsMaximum)
            #endif
        }
    }

    @Test func aCredentialChangeStopsHistoryRetriesAtTheOriginalGeneration() async {
        let revision = Mutex(0), calls = Mutex(0), sleeps = Mutex(0)
        let captured = StockSageMassive.Access(key: { "fixture" },
            credentialRevision: { String(revision.withLock { $0 }) }, policyRevision: { "fixed" }, allowed: { true }).capture()
        let request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=1y&interval=1d")!)
        let result = await Q.yahooResponse(for: request, allowed: captured.isCurrent, transport: { request in
            calls.withLock { $0 += 1 }
            revision.withLock { $0 += 2 }
            return Self.response(request, status: 503)
        }, sleep: { _ in sleeps.withLock { $0 += 1 } })
        guard case .unavailable = result else { Issue.record("Obsolete retries must fail closed"); return }
        #expect(calls.withLock { $0 } == 1 && sleeps.withLock { $0 } == 0)
    }

    @Test func standaloneHistoryTransportKeepsItsBoundedRetryPolicy() async {
        let calls = Mutex(0), sleeps = Mutex([Duration]())
        let request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?range=1y&interval=1d")!)
        let result = await Q.yahooResponse(for: request, allowed: { true }, transport: { request in
            let attempt = calls.withLock { $0 += 1; return $0 }
            return Self.response(request, status: attempt < 3 ? 503 : 200)
        }, sleep: { delay in sleeps.withLock { $0.append(delay) } })
        guard case .data = result else { Issue.record("A successful bounded retry should retain the body"); return }
        #expect(calls.withLock { $0 } == 3 && sleeps.withLock { $0 } == [.seconds(1), .seconds(2)])
    }
}


// Restates URLProtocol's inherited conformance; adds no stored state or asynchronous callbacks.
private nonisolated final class QuoteBodyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, maximum = StockSageQuoteService.maximumYahooBytes
        let headers = url.lastPathComponent == "declared" ? ["Content-Length": String(maximum + 1)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let count = url.lastPathComponent == "overflow" ? maximum + 1 : maximum
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
