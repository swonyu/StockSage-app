import Testing
import Foundation
import Synchronization
@testable import StockSage

// Massive REST snapshot source (pipeline-4 M1, 2026-09-06). Every fixture below is either the
// vendor's own documented sample (URL cited at the fixture) or a hand derivation written out in a
// comment — never a value read back from the code under test. No test touches the network.

@Suite("Massive REST snapshot source (M1)")
struct StockSageMassiveTests {

    typealias M = StockSageMassive

    nonisolated private final class AccessFixture: Sendable {
        let key = Mutex("synthetic-A")
        let credential = Mutex<String?>("credential-1")
        let policy = Mutex<String?>("policy-1")
        let allowed = Mutex(true)
        var access: M.Access {
            .init(key: { self.key.withLock { $0 } }, credentialRevision: { self.credential.withLock { $0 } },
                  policyRevision: { self.policy.withLock { $0 } }, allowed: { self.allowed.withLock { $0 } })
        }
        func invalidate(_ mode: String) {
            switch mode {
            case "key": key.withLock { $0 = "synthetic-B" }
            case "credentialRoundTrip":
                key.withLock { $0 = "synthetic-B" }; credential.withLock { $0 = "credential-2" }
                key.withLock { $0 = "synthetic-A" }; credential.withLock { $0 = "credential-3" }
            case "policy": allowed.withLock { $0 = false }
            case "policyRoundTrip":
                allowed.withLock { $0 = false }; policy.withLock { $0 = "policy-2" }
                allowed.withLock { $0 = true }; policy.withLock { $0 = "policy-3" }
            case "cancel": withUnsafeCurrentTask { $0?.cancel() }
            default: break
            }
        }
    }

    nonisolated private static func response(_ request: URLRequest, url: URL? = nil,
        declaredLength: Int? = nil, actualLength: Int? = nil) -> (Data, URLResponse) {
        let history = request.url?.path.contains("/aggs/") == true
        let symbol = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "tickers" })?.value?.split(separator: ",").first.map(String.init) ?? "AAPL"
        var body = Data((history
            ? #"{"adjusted":true,"status":"OK","ticker":"AAPL","results":[{"o":100,"h":101,"l":99,"c":100,"v":100,"t":1700000000000},{"o":100,"h":101,"l":99,"c":100,"v":100,"t":1700086400000}]}"#
            : "{\"status\":\"OK\",\"count\":1,\"tickers\":[{\"ticker\":\"\(symbol)\",\"lastTrade\":{\"c\":[0],\"p\":100,\"t\":1700000000000000000},\"prevDay\":{\"c\":99}}]}").utf8)
        let reference = request.url?.path == "/v3/reference/conditions"
        if reference {
            body = Data(#"{"status":"OK","results":[{"id":0,"asset_class":"stocks","data_types":["trade"],"update_rules":{"consolidated":{"updates_open_close":true}}}]}"#.utf8)
        }
        if !reference, let actualLength, actualLength > body.count { body.append(Data(repeating: 32, count: actualLength - body.count)) }
        let headers = declaredLength.map { ["Content-Length": String($0)] }
        return (body, HTTPURLResponse(url: url ?? request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    @MainActor private func accepted(_ endpoint: String, access: M.Access,
                                     transport: @escaping M.Transport) async -> Bool {
        switch endpoint {
        case "snapshots": return !(await M.fetchSnapshots(for: ["AAPL"], access: access, transport: transport)).isEmpty
        case "market": return await M.fetchMarketSnapshot(access: access, transport: transport) != nil
        case "history": return await M.fetchHistory(symbol: "AAPL", range: "1y", interval: "1d", access: access, transport: transport) != nil
        default: return await M.probe(access: access, transport: transport).hasPrefix("Connected")
        }
    }

    @Test(arguments: ["snapshots", "market", "history", "probe"],
          ["key", "credentialRoundTrip", "policy", "policyRoundTrip", "cancel"])
    @MainActor func legacyTransportRejectsAccessChangesAfterAwait(endpoint: String, mode: String) async {
        let fixture = AccessFixture(), calls = Mutex(0)
        let task = Task { @MainActor in
            await accepted(endpoint, access: fixture.access, transport: { request in
                calls.withLock { $0 += 1 }
                fixture.invalidate(mode)
                return Self.response(request)
            })
        }
        #expect(await task.value == false)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: ["credentialRoundTrip", "policyRoundTrip", "policy", "cancel"])
    @MainActor func snapshotInvalidationDropsEarlierChunksAndStopsFurtherRequests(mode: String) async {
        let fixture = AccessFixture(), calls = Mutex(0)
        let symbols = (0..<501).map { "Q" + String(UnicodeScalar(65 + $0 / 26)!) + String(UnicodeScalar(65 + $0 % 26)!) }
        let task = Task { @MainActor in
            await M.fetchSnapshots(for: symbols, access: fixture.access, transport: { request in
                if request.url?.path == "/v3/reference/conditions" { return Self.response(request) }
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 2 { fixture.invalidate(mode) }
                return Self.response(request)
            })
        }
        #expect(await task.value.isEmpty, "Earlier accepted chunks cannot survive an invalidated batch")
        #expect(calls.withLock { $0 } == 2, "No third request may follow credential or policy invalidation")
    }

    @Test(arguments: ["snapshots", "market", "history", "probe"])
    @MainActor func legacyTransportRejectsChangedFinalResponseURL(endpoint: String) async {
        let accepted = await accepted(endpoint, access: AccessFixture().access, transport: { request in
            Self.response(request, url: URL(string: "https://api.massive.com/different-resource")!)
        })
        #expect(!accepted, "Even a response on the approved host must match the exact requested resource")
    }

    @Test(arguments: ["snapshots", "market", "history", "probe"])
    @MainActor func legacyTransportRejectsExcessDeclaredResponseLength(endpoint: String) async {
        let limit = endpoint == "market" ? M.marketMaximumBytes : endpoint == "history" ? M.historyMaximumBytes : M.snapshotMaximumBytes
        #expect(await accepted(endpoint, access: AccessFixture().access, transport: { request in
            Self.response(request, declaredLength: limit + 1)
        }) == false)
    }

    @Test(arguments: ["snapshots", "history", "probe"])
    @MainActor func legacyTransportBoundsActualResponseLength(endpoint: String) async {
        let limit = endpoint == "history" ? M.historyMaximumBytes : M.snapshotMaximumBytes
        #expect(await accepted(endpoint, access: AccessFixture().access, transport: { request in
            Self.response(request, actualLength: limit + 1)
        }) == false)
        #expect(await accepted(endpoint, access: AccessFixture().access, transport: { request in
            Self.response(request, actualLength: limit)
        }), "A valid body exactly at the limit remains usable")
    }

    @Test(arguments: ["snapshots", "market", "history", "probe"], ["policy", "cancel"])
    @MainActor func legacyTransportDeniedBeforeStartMakesNoRequest(endpoint: String, mode: String) async {
        let fixture = AccessFixture(), calls = Mutex(0)
        let task = Task { @MainActor in
            fixture.invalidate(mode)
            return await accepted(endpoint, access: fixture.access, transport: { request in
                calls.withLock { $0 += 1 }; return Self.response(request)
            })
        }
        #expect(await task.value == false && calls.withLock { $0 } == 0)
    }

    @Test(arguments: ["unavailable", "missing", "saved", "environment"])
    @MainActor func credentialReadFailureIsDistinctFromMissingAndNeverStartsHTTP(mode: String) async throws {
        typealias C = StockSageMassiveCredential
        let suite = "Massive.credential-probe.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secret = "synthetic-credential-probe-secret"
        if mode == "unavailable" { defaults.set(secret, forKey: M.keyDefaultsKey) }
        let storage = C.Storage(read: {
            if mode == "unavailable" {
                throw NSError(domain: "\(secret) https://invalid.example/private", code: 1)
            }
            return mode == "saved" ? "synthetic-A" : nil
        }, write: { _ in Issue.record("A connection check must not write credentials") })
        let readKey: () throws -> String = {
            try C.resolve(defaults: defaults, storage: storage,
                environment: mode == "unavailable" ? secret : mode == "environment" ? "synthetic-A" : nil)
        }
        let blocker = M.credentialAccessBlocker(readKey: readKey)
        let calls = Mutex(0)
        let result = await M.probe(access: AccessFixture().access, readKey: readKey, transport: { request in
            calls.withLock { $0 += 1 }
            return Self.response(request)
        })
        switch mode {
        case "unavailable":
            #expect(blocker == "Keychain unavailable — unlock your device or allow StockSage to read its saved key, then retry Settings → Data sources → Test connection.")
            #expect(result == blocker && calls.withLock { $0 } == 0)
            #expect(defaults.string(forKey: M.keyDefaultsKey) == secret,
                    "A failed secure read must preserve legacy bytes and never use either fallback")
        case "missing":
            #expect(blocker == "No market data key is configured. Add it in Settings → Data sources.")
            #expect(result == blocker && calls.withLock { $0 } == 0)
        default:
            #expect(blocker == nil && result.hasPrefix("Connected") && calls.withLock { $0 } == 1)
        }
        #expect(!result.contains(secret) && !result.contains("https://"))
    }

    @Test @MainActor func probeFailureNeverDisclosesCredentialURLOrRawError() async {
        let result = await M.probe(access: AccessFixture().access, transport: { request in
            throw NSError(domain: "synthetic-A https://api.massive.com/private-credential-context", code: 1)
        })
        #expect(result == "No response — check the network.")
        #expect(!result.contains("synthetic-A") && !result.contains("https://"))
    }

    @Test(arguments: ["exact", "overflow", "declared"])
    func nativeRESTTransportBoundsBodyWithoutPersistedSessionState(mode: String) async throws {
        #expect(M.restSession.delegate is StockSageHTTP.NoRedirect)
        let configuration = M.restSession.configuration
        #expect(configuration.urlCache == nil && configuration.urlCredentialStorage == nil
                && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies
                && configuration.timeoutIntervalForResource == 30)
        configuration.protocolClasses = [MassiveBodyProtocol.self]
        let session = URLSession(configuration: configuration, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://api.massive.com/\(mode)")!)
        do {
            let (data, _) = try await M.restTransport(request, maximumBytes: M.snapshotMaximumBytes, session: session)
            #expect(mode == "exact" && data.count == M.snapshotMaximumBytes)
        } catch {
            #expect(mode != "exact" && (error as? URLError)?.code == .dataLengthExceedsMaximum)
        }
    }

    @Test func environmentFallbackLaunchDoesNotInheritAnotherLaunchDenial() throws {
        typealias C = StockSageMassiveCredential
        let suite = "Massive.environment-launch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved: String?
        let storage = C.Storage(read: { saved }, write: { saved = $0 })
        try C.beginLaunch(defaults: defaults, storage: storage, environment: "synthetic-A")
        let first = try #require(M.credentialRevision(defaults))
        C.recordDenial(Date().addingTimeInterval(86400), gate: "denial", revision: first, defaults: defaults)
        #expect(C.denialUntil("denial", defaults: defaults) != nil)
        try C.beginLaunch(defaults: defaults, storage: storage, environment: "synthetic-B")
        #expect(M.credentialRevision(defaults) != first)
        #expect(C.denialUntil("denial", defaults: defaults) == nil)
        let second = M.credentialRevision(defaults)
        saved = "synthetic-secure"
        try C.beginLaunch(defaults: defaults, storage: storage, environment: "synthetic-C")
        #expect(M.credentialRevision(defaults) == second, "An unchanged saved credential retains its gate")
        #expect(defaults.string(forKey: M.keyDefaultsKey) == nil)
        saved = nil
        C.recordDenial(Date().addingTimeInterval(86400), gate: "denial", revision: second, defaults: defaults)
        let locked = C.Storage(read: { throw C.Failure.unavailable }, write: { _ in Issue.record("Must not write while locked") })
        #expect(throws: C.Failure.self) {
            try C.beginLaunch(defaults: defaults, storage: locked, environment: "synthetic-D")
        }
        #expect(C.denialUntil("denial", defaults: defaults) == nil)
        #expect(try C.resolve(defaults: defaults, storage: storage, environment: "synthetic-D") == "synthetic-D")
    }

    @Test func inaccessibleStorageDoesNotSelectAnEnvironmentCredential() throws {
        typealias C = StockSageMassiveCredential
        let suite = "Massive.locked.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var writes = 0
        let storage = C.Storage(read: { throw C.Failure.unavailable }, write: { _ in writes += 1 })
        for legacy in [nil, "synthetic-legacy"] as [String?] {
            defaults.set(legacy, forKey: M.keyDefaultsKey)
            #expect(throws: C.Failure.self) {
                try C.resolve(defaults: defaults, storage: storage, environment: "synthetic-environment")
            }
            #expect(defaults.string(forKey: M.keyDefaultsKey) == legacy && writes == 0)
        }
    }

    @Test func failedVerificationAfterEffectiveWritesStillInvalidatesEvidence() throws {
        typealias C = StockSageMassiveCredential
        let suite = "Massive.partial-write.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var value: String? = "synthetic-A"
        var failRead = false
        let storage = C.Storage(read: {
            if failRead { failRead = false; throw C.Failure.unavailable }
            return value
        }, write: { value = $0; failRead = true })
        defaults.set("synthetic-legacy", forKey: M.keyDefaultsKey)
        let before = M.credentialRevision(defaults)
        #expect(throws: C.Failure.self) { try M.setAPIKey("synthetic-B", defaults: defaults, storage: storage) }
        let changed = M.credentialRevision(defaults)
        #expect(changed != before && value == "synthetic-B")
        #expect(throws: C.Failure.self) { try M.setAPIKey("synthetic-A", defaults: defaults, storage: storage) }
        #expect(M.credentialRevision(defaults) != before && M.credentialRevision(defaults) != changed)
        #expect(value == "synthetic-A" && defaults.string(forKey: M.keyDefaultsKey) == "synthetic-legacy")
    }

    @Test func credentialRoundTripDoesNotReviveOldEvidence() throws {
        let suite = "StockSageMassiveTests.credentials." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved: String?
        let storage = StockSageMassiveCredential.Storage(read: { saved }, write: { saved = $0 })
        #expect(M.credentialRevision(defaults) == nil)
        #expect(try M.setAPIKey("synthetic-A", defaults: defaults, storage: storage))
        let first = M.credentialRevision(defaults)
        #expect(first != nil)
        #expect(try !M.setAPIKey("synthetic-A", defaults: defaults, storage: storage))
        #expect(M.credentialRevision(defaults) == first)
        #expect(try M.setAPIKey("synthetic-B", defaults: defaults, storage: storage))
        let second = M.credentialRevision(defaults)
        #expect(second != first)
        #expect(try M.setAPIKey("synthetic-A", defaults: defaults, storage: storage))
        #expect(M.credentialRevision(defaults) != first && M.credentialRevision(defaults) != second)
        #expect(defaults.string(forKey: M.keyDefaultsKey) == nil && saved == "synthetic-A")
        #expect(try M.setAPIKey("", defaults: defaults, storage: storage))
        #expect(saved == nil && defaults.string(forKey: M.keyDefaultsKey) == nil)
    }

    @Test func legacyCredentialMigrationRequiresVerifiedSecureStorage() throws {
        typealias C = StockSageMassiveCredential
        let suite = "StockSageMassiveTests.migration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for mode in ["success", "existing", "failed-write", "failed-readback"] {
            defaults.set("synthetic-legacy", forKey: M.keyDefaultsKey)
            var saved: String? = mode == "existing" ? "synthetic-secure" : nil
            let storage = C.Storage(read: { saved }, write: { value in
                if mode == "failed-write" { throw C.Failure.unavailable }
                if mode != "failed-readback" { saved = value }
            })
            do {
                try C.migrate(defaults: defaults, storage: storage)
                #expect(mode == "success" || mode == "existing")
                #expect(defaults.string(forKey: M.keyDefaultsKey) == nil)
                #expect(saved == (mode == "existing" ? "synthetic-secure" : "synthetic-legacy"))
            } catch {
                #expect(mode == "failed-write" || mode == "failed-readback")
                #expect(defaults.string(forKey: M.keyDefaultsKey) == "synthetic-legacy")
            }
        }
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
        // Market data must never be served from URLSession's on-disk cache: a replayed 200 would
        // present an old print as a current one, which is what every freshness gate exists to stop.
        // The default is .useProtocolCachePolicy, so this was the shipped behaviour until 2026-09-11.
        for r in M.requests(for: ["AAPL", "MSFT"], key: "unit-test-key") {
            #expect(r.cachePolicy == .reloadIgnoringLocalCacheData,
                    "a quote request may be answered from disk")
        }
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
        let out = M.parseSnapshot(Self.docsSample, requestedSymbols: ["bcat"], allowedTradeConditions: [0, 14, 41])
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
        let q = try #require(M.parseSnapshot(Self.docsSample, requestedSymbols: ["BCAT"], allowedTradeConditions: [0, 14, 41])["BCAT"])
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
        let out = M.parseSnapshot(Self.docsSample, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41])
        #expect(out.isEmpty)                                      // BCAT came back but was never asked for
        let both = M.parseSnapshot(Self.docsSample, requestedSymbols: ["AAPL", "BCAT"], allowedTradeConditions: [0, 14, 41])
        #expect(both.count == 1)
        #expect(both["AAPL"] == nil)                              // absent ⇒ caller's fallback chain, never fabricated
    }

    @Test("missing or non-positive prevDay.c → flat placeholder + isNewListing (EODHD/Yahoo parity)")
    func missingPrevDayCloseFlagsNewListing() throws {
        let noPrev: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": 50.0, "t": 1605192894630916600]]
        let q1 = try #require(M.parseTicker(noPrev, requestedSymbol: "X", allowedTradeConditions: [0]))
        #expect(q1.previousClose == q1.price)
        #expect(q1.isNewListing)
        let zeroPrev: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": 50.0, "t": 1605192894630916600], "prevDay": ["c": 0]]
        let q2 = try #require(M.parseTicker(zeroPrev, requestedSymbol: "X", allowedTradeConditions: [0]))
        #expect(q2.previousClose == q2.price)
        #expect(q2.isNewListing)
        let realPrev: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": 50.0, "t": 1605192894630916600], "prevDay": ["c": 49.0]]
        let q3 = try #require(M.parseTicker(realPrev, requestedSymbol: "X", allowedTradeConditions: [0]))
        #expect(q3.previousClose == 49.0)
        #expect(!q3.isNewListing)
    }

    @Test("no lastTrade (plan without trades), zero/negative/non-finite price → no quote, never day.c")
    func missingLastTradeRejected() {
        let noTrade: [String: Any] = ["ticker": "X", "day": ["c": 20.5], "prevDay": ["c": 20.0]]
        #expect(M.parseTicker(noTrade, requestedSymbol: "X", allowedTradeConditions: [0]) == nil)
        let zero: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": 0, "t": 1], "prevDay": ["c": 20.0]]
        #expect(M.parseTicker(zero, requestedSymbol: "X", allowedTradeConditions: [0]) == nil)
        let negative: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": -1.0, "t": 1]]
        #expect(M.parseTicker(negative, requestedSymbol: "X", allowedTradeConditions: [0]) == nil)
        let inf: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": Double.infinity, "t": 1]]
        #expect(M.parseTicker(inf, requestedSymbol: "X", allowedTradeConditions: [0]) == nil)
        let nan: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": Double.nan, "t": 1]]
        #expect(M.parseTicker(nan, requestedSymbol: "X", allowedTradeConditions: [0]) == nil)
    }

    @Test("a missing lastTrade.t yields marketTime nil (downstream nil ⇒ stale), not a fetch-time Date")
    func missingTimestampIsNil() throws {
        let row: [String: Any] = ["ticker": "X", "lastTrade": ["c": [0], "p": 50.0], "prevDay": ["c": 49.0]]
        let q = try #require(M.parseTicker(row, requestedSymbol: "X", allowedTradeConditions: [0]))
        #expect(q.marketTime == nil)
    }

    @Test("malformed, empty, non-object, and tickers-not-an-array payloads all parse to [:]")
    func malformedRejected() {
        #expect(M.parseSnapshot(Data(), requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot("not json".data(using: .utf8)!, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot("{}".data(using: .utf8)!, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot("[]".data(using: .utf8)!, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot(#"{"status":"OK","tickers":"AAPL"}"#.data(using: .utf8)!, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot(#"{"status":"OK","tickers":[{"ticker":"AAPL"}]}"#.data(using: .utf8)!, requestedSymbols: ["AAPL"], allowedTradeConditions: [0, 14, 41]).isEmpty)
    }

    // MARK: Key handling — by name only

    @Test("apiKey: Settings field (trimmed) wins; blank/whitespace falls back to the MASSIVE_API_KEY env var; never printed")
    func apiKeyResolution() {
        #expect(M.keyDefaultsKey == "stocksage.massive." + "key")
        #expect(M.keyEnvName == "MASSIVE_API_KEY")
        #expect(M.resolvedKey(saved: nil, environment: nil).isEmpty)
        #expect(M.resolvedKey(saved: "  ", environment: " synthetic-env ") == "synthetic-env")
        #expect(M.resolvedKey(saved: " synthetic-saved ", environment: "synthetic-env") == "synthetic-saved")
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

    @Test func restIdentityCannotBeRelabelledOrCaseFolded() throws {
        #expect(M.parseHistory(Self.aggregateSample, symbol: "MSFT") == nil)
        let snapshot = #"{"tickers":[{"ticker":"APTVpA","lastTrade":{"p":20,"t":1700000000000000000},"prevDay":{"c":19}}]}"#
        #expect(M.parseSnapshot(Data(snapshot.utf8), requestedSymbols: ["APTVPA"], allowedTradeConditions: [0, 14, 41]).isEmpty)
        #expect(M.parseSnapshot(Data(snapshot.utf8), requestedSymbols: ["APTVpA"], allowedTradeConditions: [0, 14, 41]).isEmpty,
                "The legacy uppercase board must not merge case-sensitive instruments")
    }

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

/// Real URLSession bytes, served entirely in process without credentials or a provider call.
private nonisolated final class MassiveBodyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, maximum = StockSageMassive.snapshotMaximumBytes
        let headers = url.lastPathComponent == "declared" ? ["Content-Length": String(maximum + 1)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let count = url.lastPathComponent == "overflow" ? maximum + 1 : maximum
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


extension StockSageMassiveTests {
    @Test func snapshotSpecialAndUnknownTradeConditionsCannotUpdateOrdinaryPrice() throws {
        for codes: Any in [[901], [901,902], [999], [], [true], NSNull()] {
            let row: [String: Any] = ["ticker":"AAPL", "lastTrade":["p":100, "t":Int64(1_700_000_000_000_000_000), "c":codes]]
            let data = try JSONSerialization.data(withJSONObject: ["status":"OK", "count":1, "tickers":[row]])
            let expected = (codes as? [Int]) == [901]
            #expect((M.parseSnapshot(data, requestedSymbols: ["AAPL"], allowedTradeConditions: [901])["AAPL"] != nil) == expected)
            #expect((M.parseMarketSnapshot(data, allowedTradeConditions: [901])?.rows.count == 1) == expected)
        }
        #expect(M.parseSnapshot(Self.docsSample, requestedSymbols: ["BCAT"]).isEmpty,
                "Unavailable reference must not implicitly trust numeric condition codes")
    }
}
