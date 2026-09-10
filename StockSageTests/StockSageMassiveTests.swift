import Testing
import Foundation
@testable import StockSage

// Massive REST snapshot source (pipeline-4 M1, 2026-09-06). Every fixture below is either the
// vendor's own documented sample (URL cited at the fixture) or a hand derivation written out in a
// comment — never a value read back from the code under test. No test touches the network.

@Suite("Massive REST snapshot source (M1)")
struct StockSageMassiveTests {

    typealias M = StockSageMassive

    @Test func credentialRoundTripDoesNotReviveOldEvidence() throws {
        let suite = "StockSageMassiveTests.credentials." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(M.credentialRevision(defaults) == nil)
        #expect(M.setAPIKey("synthetic-A", defaults: defaults))
        let first = M.credentialRevision(defaults)
        #expect(first != nil)
        #expect(!M.setAPIKey("synthetic-A", defaults: defaults))
        #expect(M.credentialRevision(defaults) == first)
        #expect(M.setAPIKey("synthetic-B", defaults: defaults))
        let second = M.credentialRevision(defaults)
        #expect(second != first)
        #expect(M.setAPIKey("synthetic-A", defaults: defaults))
        #expect(M.credentialRevision(defaults) != first && M.credentialRevision(defaults) != second)
        #expect(defaults.string(forKey: M.keyDefaultsKey) == "synthetic-A")
    }

    // MARK: Coverage / routing

    @Test("US-equities classification stays bare alphabetic tickers only")
    func coversExistingClassificationFixtures() {
        let fixtures: [(symbol: String, covered: Bool)] = [
            ("AAPL", true), ("NVDA", true), ("msft", true), ("Å", true),
            ("2222.SR", false), ("^TASI.SR", false), ("EURUSD=X", false),
            ("BTC-USD", false), ("A1", false), ("", false)
        ]
        for fixture in fixtures {
            #expect(M.covers(fixture.symbol) == fixture.covered)
        }
    }

    @Test("routing table: key present/absent × covered/uncovered")
    func routingTable() {
        let input = ["AAPL", "2222.SR", "nvda", "^TASI.SR", "BTC-USD"]
        // key present: covered → snapshot, uncovered → per-symbol; order preserved within each.
        let withKey = M.partition(input, keyPresent: true)
        #expect(withKey.snapshot == ["AAPL", "nvda"])
        #expect(withKey.perSymbol == ["2222.SR", "^TASI.SR", "BTC-USD"])
        // key absent: EVERYTHING per-symbol (pre-M1 behaviour), nothing to the snapshot path.
        let noKey = M.partition(input, keyPresent: false)
        #expect(noKey.snapshot == [])
        #expect(noKey.perSymbol == input)
        // Nothing lost or duplicated by the split, in either mode.
        #expect((withKey.snapshot + withKey.perSymbol).sorted() == input.sorted())
        #expect(M.partition([], keyPresent: true).snapshot.isEmpty)
    }

    // MARK: Chunking

    @Test("chunking straddles the 250 cap: 249 → 1, 250 → 1, 251 → 2 ([250, 1])")
    func chunkStraddleAtCap() {
        #expect(M.maxTickersPerRequest == 250)      // the documented unified-snapshot cap (doc URL in source)
        func syms(_ n: Int) -> [String] { (0..<n).map { "S\($0)" } }
        #expect(M.chunks(syms(0)).count == 0)
        #expect(M.chunks(syms(1)).map(\.count) == [1])
        #expect(M.chunks(syms(249)).map(\.count) == [249])
        #expect(M.chunks(syms(250)).map(\.count) == [250])
        #expect(M.chunks(syms(251)).map(\.count) == [250, 1])
        #expect(M.chunks(syms(500)).map(\.count) == [250, 250])
        #expect(M.chunks(syms(501)).map(\.count) == [250, 250, 1])
        // Contiguous and order-preserving: the flattened chunks ARE the input.
        #expect(M.chunks(syms(501)).flatMap { $0 } == syms(501))
    }

    @Test("budget: the 872-name allowlist costs exactly ceil(872/250) = 4 requests, none dropped, key in header only")
    func budget872SymbolsIsFourRequests() throws {
        let universe = StockSageUniverse.nasdaqListed.sorted()
        #expect(universe.count == 872)                            // stage: allowlist literal, counted (design doc: 872)
        // ceil(872 / 250): 250 + 250 + 250 + 122 = 872 → 4 requests.
        let reqs = M.requests(for: universe, key: "unit-test-key")
        #expect(reqs.count == 4)
        #expect(reqs.count == Int((Double(872) / Double(M.maxTickersPerRequest)).rounded(.up)))
        var seen: [String] = []
        for r in reqs {
            let url = try #require(r.url)
            #expect(url.absoluteString.hasPrefix("https://api.massive.com/v2/snapshot/locale/us/markets/stocks/tickers?tickers="))
            #expect(!url.absoluteString.contains("unit-test-key"))          // key NEVER in the URL
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
            let list = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "tickers" }?.value)
            let tickers = list.split(separator: ",").map(String.init)
            #expect(tickers.count <= M.maxTickersPerRequest)
            seen += tickers
        }
        #expect(seen.count == 872)
        #expect(Set(seen) == Set(universe))                       // every allowlist name is requested exactly once
        #expect(M.requests(for: [], key: "unit-test-key").isEmpty)
        #expect(M.requests(for: ["AAPL"], key: "").isEmpty)       // no key ⇒ no request can even be built
    }

    // MARK: Parsing — the vendor's documented sample

    /// Verbatim sample response from
    /// https://massive.com/docs/rest/stocks/snapshots/full-market-snapshot.md (fetched 2026-09-06).
    static let docsSample = """
    {
      "count": 1,
      "status": "OK",
      "tickers": [
        {
          "day": { "c": 20.506, "dv": "37216.0", "h": 20.64, "l": 20.506, "o": 20.64, "v": 37216, "vw": 20.616 },
          "lastQuote": { "P": 20.6, "S": 22, "p": 20.5, "s": 13, "t": 1605192959994246100 },
          "lastTrade": { "c": [ 14, 41 ], "ds": "2416.0", "i": "71675577320245", "p": 20.506, "s": 2416, "t": 1605192894630916600, "x": 4 },
          "min": { "av": 37216, "c": 20.506, "dav": "37216.0", "dv": "5000.0", "h": 20.506, "l": 20.506, "n": 1, "o": 20.506, "t": 1684428600000, "v": 5000, "vw": 20.5105 },
          "prevDay": { "c": 20.63, "h": 21, "l": 20.5, "o": 20.79, "v": 292738, "vw": 20.6939 },
          "ticker": "BCAT",
          "todaysChange": -0.124,
          "todaysChangePerc": -0.601,
          "updated": 1605192894630916600
        }
      ]
    }
    """.data(using: .utf8)!

    @Test("docs sample parses: lastTrade.p, prevDay.c, and the nanosecond lastTrade.t → exact Date")
    func parsesDocsSampleFixture() throws {
        let out = M.parseSnapshot(Self.docsSample, requestedSymbols: ["bcat"])
        let q = try #require(out["BCAT"])
        #expect(q.symbol == "bcat")                               // the spelling WE asked for is preserved
        #expect(abs(q.price - 20.506) < 1e-9)                     // lastTrade.p (equals day.c here by coincidence — see missingLastTradeRejected)
        #expect(abs(q.previousClose - 20.63) < 1e-9)              // prevDay.c
        #expect(!q.isNewListing)
        // Hand derivation: 1605192894630916600 ns = 1605192894 s + 630916600 ns
        //                = 1605192894.6309166 s → 2020-11-12T14:54:54.6309166Z.
        let t = try #require(q.marketTime)
        #expect(abs(t.timeIntervalSince1970 - 1605192894.6309166) < 1e-6)
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: t).year
        #expect(year == 2020)                                     // ms or s misreads would land in year 52,000+ / 50 billion
    }

    @Test("marketTime comes from lastTrade.t (ns), never min.t (ms) or a misapplied unit")
    func minTNotUsed() throws {
        // The SAME sample carries min.t = 1684428600000 (13-digit MILLISECONDS = 2023-05-18) next to
        // lastTrade.t = 1605192894630916600 (19-digit ns = 2020-11-12). A parser that read min.t, or
        // treated the ns value as ms/s, could not produce 2020-11-12.
        let q = try #require(M.parseSnapshot(Self.docsSample, requestedSymbols: ["BCAT"])["BCAT"])
        let t = try #require(q.marketTime)
        #expect(abs(t.timeIntervalSince1970 - 1684428600.0) > 86_400 * 365)       // not the ms field
        #expect(abs(t.timeIntervalSince1970 - 1605192894630916.6) > 1e12)         // not "ns read as ms"
        #expect(abs(t.timeIntervalSince1970 - 1605192894.6309166) < 1e-6)
    }

    @Test("nanosecond → Date split is exact to the Double's resolution (no single-Double detour)")
    func nanosecondSplitIsExact() {
        #expect(M.date(fromNanoseconds: 0) == Date(timeIntervalSince1970: 0))
        #expect(M.date(fromNanoseconds: 1_000_000_000) == Date(timeIntervalSince1970: 1))
        #expect(M.date(fromNanoseconds: 1_500_000_000) == Date(timeIntervalSince1970: 1.5))
        // 1605192894630916600 = 1605192894 s + 0.6309166 s (hand split).
        let d = M.date(fromNanoseconds: 1605192894630916600)
        #expect(abs(d.timeIntervalSince1970 - (1605192894.0 + 0.6309166)) < 1e-7)
    }

    // MARK: Parsing — fail-closed edges

    @Test("an unrequested ticker in the payload is ignored; a requested one that is absent is simply missing")
    func onlyRequestedTickersEmitted() {
        let out = M.parseSnapshot(Self.docsSample, requestedSymbols: ["AAPL"])
        #expect(out.isEmpty)                                      // BCAT came back but was never asked for
        let both = M.parseSnapshot(Self.docsSample, requestedSymbols: ["AAPL", "BCAT"])
        #expect(both.count == 1)
        #expect(both["AAPL"] == nil)                              // absent ⇒ caller's fallback chain, never fabricated
    }

    @Test("missing or non-positive prevDay.c → flat placeholder + isNewListing (EODHD/Yahoo parity)")
    func missingPrevDayCloseFlagsNewListing() throws {
        let noPrev: [String: Any] = ["ticker": "X", "lastTrade": ["p": 50.0, "t": 1605192894630916600]]
        let q1 = try #require(M.parseTicker(noPrev, requestedSymbol: "X"))
        #expect(q1.previousClose == q1.price)
        #expect(q1.isNewListing)
        let zeroPrev: [String: Any] = ["ticker": "X", "lastTrade": ["p": 50.0, "t": 1605192894630916600], "prevDay": ["c": 0]]
        let q2 = try #require(M.parseTicker(zeroPrev, requestedSymbol: "X"))
        #expect(q2.previousClose == q2.price)
        #expect(q2.isNewListing)
        let realPrev: [String: Any] = ["ticker": "X", "lastTrade": ["p": 50.0, "t": 1605192894630916600], "prevDay": ["c": 49.0]]
        let q3 = try #require(M.parseTicker(realPrev, requestedSymbol: "X"))
        #expect(q3.previousClose == 49.0)
        #expect(!q3.isNewListing)
    }

    @Test("no lastTrade (plan without trades), zero/negative/non-finite price → no quote, never day.c")
    func missingLastTradeRejected() {
        let noTrade: [String: Any] = ["ticker": "X", "day": ["c": 20.5], "prevDay": ["c": 20.0]]
        #expect(M.parseTicker(noTrade, requestedSymbol: "X") == nil)
        let zero: [String: Any] = ["ticker": "X", "lastTrade": ["p": 0, "t": 1], "prevDay": ["c": 20.0]]
        #expect(M.parseTicker(zero, requestedSymbol: "X") == nil)
        let negative: [String: Any] = ["ticker": "X", "lastTrade": ["p": -1.0, "t": 1]]
        #expect(M.parseTicker(negative, requestedSymbol: "X") == nil)
        let inf: [String: Any] = ["ticker": "X", "lastTrade": ["p": Double.infinity, "t": 1]]
        #expect(M.parseTicker(inf, requestedSymbol: "X") == nil)
        let nan: [String: Any] = ["ticker": "X", "lastTrade": ["p": Double.nan, "t": 1]]
        #expect(M.parseTicker(nan, requestedSymbol: "X") == nil)
    }

    @Test("a missing lastTrade.t yields marketTime nil (downstream nil ⇒ stale), not a fetch-time Date")
    func missingTimestampIsNil() throws {
        let row: [String: Any] = ["ticker": "X", "lastTrade": ["p": 50.0], "prevDay": ["c": 49.0]]
        let q = try #require(M.parseTicker(row, requestedSymbol: "X"))
        #expect(q.marketTime == nil)
    }

    @Test("malformed, empty, non-object, and tickers-not-an-array payloads all parse to [:]")
    func malformedRejected() {
        #expect(M.parseSnapshot(Data(), requestedSymbols: ["AAPL"]).isEmpty)
        #expect(M.parseSnapshot("not json".data(using: .utf8)!, requestedSymbols: ["AAPL"]).isEmpty)
        #expect(M.parseSnapshot("{}".data(using: .utf8)!, requestedSymbols: ["AAPL"]).isEmpty)
        #expect(M.parseSnapshot("[]".data(using: .utf8)!, requestedSymbols: ["AAPL"]).isEmpty)
        #expect(M.parseSnapshot(#"{"status":"OK","tickers":"AAPL"}"#.data(using: .utf8)!, requestedSymbols: ["AAPL"]).isEmpty)
        #expect(M.parseSnapshot(#"{"status":"OK","tickers":[{"ticker":"AAPL"}]}"#.data(using: .utf8)!, requestedSymbols: ["AAPL"]).isEmpty)
    }

    // MARK: Key handling — by name only

    @Test("apiKey: Settings field (trimmed) wins; blank/whitespace falls back to the MASSIVE_API_KEY env var; never printed")
    func apiKeyResolution() {
        ToolPolicyTestLock.lock.lock()
        defer { ToolPolicyTestLock.lock.unlock() }
        let d = UserDefaults.standard
        let priorArguments = d.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { d.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain) }
        #expect(M.keyDefaultsKey == "stocksage.massive." + "key")
        #expect(M.keyEnvName == "MASSIVE_API_KEY")
        // The env fallback on THIS machine, trimmed — compared, never printed.
        let envFallback = ProcessInfo.processInfo.environment[M.keyEnvName]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        ToolPolicyTestLock.set("", forKey: M.keyDefaultsKey)
        let blankUsesFallback = M.apiKey == envFallback
        #expect(blankUsesFallback)
        #expect(M.isConfigured == !envFallback.isEmpty)
        ToolPolicyTestLock.set("  settings-key-123  ", forKey: M.keyDefaultsKey)
        let settingsOverrideIsTrimmed = M.apiKey == "settings-key-123"
        #expect(settingsOverrideIsTrimmed)
        #expect(M.isConfigured)
        ToolPolicyTestLock.set("   ", forKey: M.keyDefaultsKey)
        let whitespaceUsesFallback = M.apiKey == envFallback
        #expect(whitespaceUsesFallback)
    }

    @Test("an empty symbol list never builds a request (fetchSnapshots is a no-op without work)")
    func emptyListIsNoop() async {
        #expect(M.requests(for: [], key: "unit-test-key").isEmpty)
        let out = await M.fetchSnapshots(for: [])
        #expect(out.isEmpty)
    }

    // MARK: Split-adjusted aggregate history (M1b)

    /// Result rows from the documented Massive custom-bars sample:
    /// https://www.massive.com/docs/rest/stocks/aggregates/custom-bars
    static let aggregateSample = """
    {"adjusted":true,"results":[
      {"o":74.06,"h":75.15,"l":73.7975,"c":75.0875,"v":135647456,"t":1577941200000},
      {"o":74.2875,"h":75.145,"l":74.125,"c":74.3575,"v":146535512,"t":1578027600000}
    ],"status":"OK","ticker":"AAPL"}
    """.data(using: .utf8)!

    @Test("split-adjusted aggregate bars map byte-for-byte into the existing history shape")
    func parsesAggregateHistory() throws {
        let h = try #require(M.parseHistory(Self.aggregateSample, symbol: "AAPL"))
        #expect(h.symbol == "AAPL")
        #expect(h.count == 2)
        #expect(h.opens == [74.06, 74.2875])
        #expect(h.highs == [75.15, 75.145])
        #expect(h.lows == [73.7975, 74.125])
        #expect(h.closes == [75.0875, 74.3575])
        #expect(h.volumes == [135647456, 146535512])
        #expect(h.dates == [Date(timeIntervalSince1970: 1_577_941_200), Date(timeIntervalSince1970: 1_578_027_600)])
    }

    @Test("aggregate history fails closed and preserves the Yahoo fallback contract")
    func aggregateAdjustmentMetadataCannotContradictTheRequest() throws {
        var root = try #require(JSONSerialization.jsonObject(with: Self.aggregateSample) as? [String: Any])
        for adjusted: Any in [false, "false", 0, NSNull()] {
            root["adjusted"] = adjusted
            #expect(M.parseHistory(try JSONSerialization.data(withJSONObject: root), symbol: "AAPL") == nil)
        }
        root["adjusted"] = true
        #expect(M.parseHistory(try JSONSerialization.data(withJSONObject: root), symbol: "AAPL")?.closes == [75.0875, 74.3575])
        root.removeValue(forKey: "adjusted")
        #expect(M.parseHistory(try JSONSerialization.data(withJSONObject: root), symbol: "AAPL") != nil,
                "Retain compatibility with omitted metadata; the request explicitly asks for adjusted bars")
    }

    @Test("aggregate history rejects empty and malformed bodies")
    func aggregateHistoryRejectsMalformedOrTooShortBodies() {
        #expect(M.parseHistory(Data(), symbol: "AAPL") == nil)
        #expect(M.parseHistory(#"{"status":"OK","results":[]}"#.data(using: .utf8)!, symbol: "AAPL") == nil)
        #expect(M.parseHistory(#"{"status":"OK","results":[{"o":1,"h":1,"l":1,"c":1,"t":0}]}"#.data(using: .utf8)!, symbol: "AAPL") == nil)
        #expect(M.parseHistory(#"{"status":"ERROR","results":[]}"#.data(using: .utf8)!, symbol: "AAPL") == nil)
    }

    @Test("daily history routes only supported Yahoo ranges through Massive")
    func historyRangeAndRequestRouting() throws {
        let now = Date(timeIntervalSince1970: 1_725_177_600) // 2024-09-01T00:00:00Z
        #expect(M.historyDates(for: "1y", now: now)?.from == "2023-09-01")
        #expect(M.historyDates(for: "5y", now: now)?.from == "2019-09-01")
        #expect(M.historyDates(for: "max", now: now) == nil)
        let req = try #require(M.historyRequest(symbol: "AAPL", from: "2023-09-01", to: "2024-09-01", key: "unit-test-key"))
        #expect(req.url?.absoluteString.contains("/v2/aggs/ticker/AAPL/range/1/day/2023-09-01/2024-09-01") == true)
        #expect(req.url?.absoluteString.contains("unit-test-key") == false)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-key")
        #expect(M.historyRequest(symbol: "2222.SR", from: "2023-09-01", to: "2024-09-01", key: "unit-test-key") == nil)
    }
}
