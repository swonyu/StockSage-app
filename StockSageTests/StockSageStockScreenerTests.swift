import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageStockScreenerTests {
    typealias S = StockSageStockScreener
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
    private var access: StockSageMassive.Access {
        .init(key: { "fixture" }, credentialRevision: { "one" }, policyRevision: { "one" }, allowed: { true })
    }
    private func listing(_ symbol: String, exchange: String = "XNAS") -> StockSageHorizonResearch.Listing {
        .init(ticker: symbol, name: "Company \(symbol)", market: "stocks", locale: "us", active: true,
              type: "CS", currency_name: "usd", primary_exchange: exchange)
    }
    private func raw(_ symbol: String, cap: Double = 100_000_000) -> [String: Any] {
        ["ticker": symbol, "date": "2026-09-18", "market_cap": cap, "price": 12.0,
         "earnings_per_share": 2.0, "price_to_earnings": 6.0, "return_on_assets": 0.08,
         "debt_to_equity": 0.5]
    }
    private func payload(_ rows: [[String: Any]], next: String? = nil) throws -> Data {
        var root: [String: Any] = ["status": "OK", "results": rows]
        if let next { root["next_url"] = next }
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func row(_ symbol: String, cap: Double = 100_000_000) throws -> S.Row {
        try S.parseRow(raw(symbol, cap: cap), asOf: now)
    }

    @Test func filtersRespectInclusiveCapsRatioFractionsAndMissingValues() throws {
        let filters = S.Filters(minimumCap: 50_000_000, maximumCap: 300_000_000,
                                maximumPE: 10, minimumROA: 0.08, maximumDebtEquity: 0.5)
        for cap in [50_000_000.0, 300_000_000] {
            #expect(filters.classify(try row("TEST", cap: cap)).status == .matched)
        }
        #expect(filters.classify(try row("TEST", cap: 49_999_999)).status == .excluded)
        var absent = raw("TEST"); absent.removeValue(forKey: "return_on_assets")
        let missing = try S.parseRow(absent, asOf: now)
        #expect(missing.value("return_on_assets") == nil)
        #expect(filters.classify(missing).status == .unavailable)
        #expect(S.Filters().classify(missing).status == .matched)
        var loss = raw("TEST"); loss["earnings_per_share"] = -1.0
        #expect(filters.classify(try S.parseRow(loss, asOf: now)).status == .unavailable)
        #expect(!S.Filters(minimumCap: 300, maximumCap: 50).isValid)
        #expect(!S.Filters(minimumROA: .nan).isValid)
    }

    @Test func largeCapRangeIncludesMegaCapsWithoutInventedUpperLimit() throws {
        let filters = S.Filters(minimumCap: 10_000_000_000, maximumCap: nil)
        #expect(filters.isValid)
        #expect(filters.classify(try row("TEST", cap: 9_999_999_999)).status == .excluded)
        for cap in [10_000_000_000.0, 4_000_000_000_000] {
            #expect(filters.classify(try row("TEST", cap: cap)).status == .matched)
        }
        #expect(!S.Filters(minimumCap: 10_000_000_000, maximumCap: .infinity).isValid)
        #expect(!S.Filters(minimumCap: -.infinity, maximumCap: nil).isValid)
    }

    @Test func malformedFutureAndStaleMeasurementsNeverBecomeMatches() throws {
        for bad: Any in [true, "100000000", Double.infinity] {
            var value = raw("TEST"); value["market_cap"] = bad
            #expect(throws: (any Error).self) { try S.parseRow(value, asOf: now) }
        }
        var future = raw("TEST"); future["date"] = "2026-09-21"
        #expect(throws: (any Error).self) { try S.parseRow(future, asOf: now) }
        var old = raw("TEST"); old["date"] = "2026-09-01"
        let stale = try S.parseRow(old, asOf: now)
        #expect(stale.marketCap == 100_000_000 && stale.date == "2026-09-01")
        #expect(S.Filters().classify(stale).status == .unavailable)
    }

    @Test func sortingIsDeterministicAndMissingValuesStayLastInEitherDirection() throws {
        let missing = S.Row(symbol: "AAA", name: "Missing", date: nil, marketCap: nil, metrics: [], note: "No row")
        let values = [try row("ZZZ"), missing, try row("BBB"), try row("CCC", cap: 200_000_000)]
        #expect(S.sorted(values, by: .marketCap, ascending: true).map(\.symbol) == ["BBB", "ZZZ", "CCC", "AAA"])
        #expect(S.sorted(values, by: .marketCap, ascending: false).map(\.symbol) == ["CCC", "BBB", "ZZZ", "AAA"])
    }

    @Test func paginationCannotForwardCredentialsToAnotherResource() throws {
        let request = try #require(S.request(key: "fixture"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && request.timeoutInterval == 30)
        #expect(request.url?.path == S.ratiosPath && request.url?.query == "limit=1000")
        for next in ["https://evil.example/stocks/financials/v1/ratios?cursor=x",
                     "https://api.massive.com/other?cursor=x",
                     "https://api.massive.com\(S.ratiosPath)?apiKey=secret",
                     "https://user@api.massive.com\(S.ratiosPath)?cursor=x"] {
            #expect(S.request(key: "fixture", next: next) == nil)
        }
    }

    @Test func joinedUniverseRetainsMissingRowsAndOnlySupportedMembership() throws {
        let provenance = StockSageSP500Constituents.Provenance(sourceURL: StockSageSP500Constituents.sourceURL,
            sha256: String(repeating: "a", count: 64), retrievedAt: now, reportedCount: 503)
        let membership = StockSageSP500Constituents.Snapshot(symbols: ["MEMBER"], provenance: provenance)
        let universe = S.Universe(listings: [listing("TEST"), listing("MISSING"),
            listing("MEMBER", exchange: "XNYS"), listing("OTHER", exchange: "XNYS")], membership: membership)
        let rows = try S.join(universe: universe, ratios: ["TEST": row("TEST"), "OTHER": row("OTHER")], at: now)
        #expect(rows.map(\.symbol) == ["MEMBER", "MISSING", "TEST"])
        #expect(rows.filter { S.Filters().classify($0).status == .unavailable }.count == 2)
        #expect(rows.first?.note.contains("No usable") == true)
    }

    @Test func partialPageFailureRetainsCapturedRowsAndMarksCoverageIncomplete() async throws {
        let bytes = try payload([raw("TEST")], next: "https://api.massive.com\(S.ratiosPath)?cursor=second")
        let result = try await S.collect(access: access, transport: { request in
            let url = try #require(request.url)
            if url.query?.contains("second") == true { throw URLError(.timedOut) }
            return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now }, universe: { _, _, _ in
            .init(listings: [listing("TEST"), listing("MISSING")], membership: nil)
        })
        #expect(result.partial && result.receivedRows == 1 && result.rows.count == 2)
        #expect(result.rows.first { $0.symbol == "TEST" }?.marketCap == 100_000_000)
        #expect(result.note.contains("incomplete"))
    }

    @Test func duplicateRowsFailClosedAndCannotReplaceEarlierMeasurements() async throws {
        let bytes = try payload([raw("TEST"), raw("TEST", cap: 250_000_000)])
        await #expect(throws: (any Error).self) {
            try await S.collect(access: access, transport: { request in
                (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, clock: { now }, universe: { _, _, _ in .init(listings: [listing("TEST")], membership: nil) })
        }
    }

    @Test func deniedAccessDoesNotFetchAndCancelledLoadCannotPublish() async throws {
        let denied = S(access: .init(key: { "fixture" }, credentialRevision: { nil }, policyRevision: { nil }, allowed: { false }), transport: { _ in
            Issue.record("Denied screener fetched data"); throw URLError(.cancelled)
        }, clock: { now })
        await denied.load()
        #expect(denied.snapshot == nil && !denied.isBusy)
        #expect(denied.status.contains("unavailable"))

        let bytes = try payload([raw("TEST")])
        let gate = Gate()
        let model = S(access: access, transport: { request in
            await gate.wait()
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now }, universe: { _, _, _ in .init(listings: [listing("TEST")], membership: nil) })
        let operation = Task { await model.load() }
        let deadline = Date().addingTimeInterval(3)
        while !(await gate.started), Date() < deadline { await Task.yield() }
        guard await gate.started else { operation.cancel(); Issue.record("Fixture request did not start"); return }
        model.cancel()
        await gate.release()
        await operation.value
        #expect(model.snapshot == nil && !model.isBusy && model.status.contains("Cancelled"))
    }

    @Test func changedCredentialOrPolicyAtResponseReturnCannotPublishRows() async throws {
        let bytes = try payload([raw("TEST")])
        for credential in [true, false] {
            let revision = Revision()
            let model = S(access: .init(key: { "fixture" },
                credentialRevision: { credential ? revision.get() : "one" },
                policyRevision: { credential ? "one" : revision.get() }, allowed: { true }), transport: { request in
                revision.replace()
                return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, clock: { now }, universe: { _, _, _ in .init(listings: [listing("TEST")], membership: nil) })
            await model.load()
            #expect(model.snapshot == nil && !model.isBusy && model.status.contains("unavailable"))
        }
    }

    @Test func companyQualityIsExplicitAndInjectedCollectionCannotEscapeToSEC() async throws {
        var ratio = raw("TEST"); ratio["cik"] = "0000001234"
        let bytes = try payload([ratio])
        let counter = Counter()
        let model = S(access: access, transport: { request in
            await counter.increment()
            let url = try #require(request.url)
            return (bytes, HTTPURLResponse(url: url, statusCode: url.path == S.ratiosPath ? 200 : 403,
                                           httpVersion: nil, headerFields: nil)!)
        }, clock: { now }, universe: { _, _, _ in .init(listings: [listing("TEST")], membership: nil) })
        #expect(await counter.value == 0)
        await model.load()
        #expect(await counter.value == 1)
        #expect(model.quality == nil)
        let selected = try #require(model.snapshot?.rows.first)
        await model.companyQuality(for: selected)
        #expect(await counter.value == 5)
        let detail = try #require(model.quality)
        #expect(detail.symbol == "TEST" && !model.isBusy)
        #expect(detail.sources.contains { $0.name.contains("SEC") && $0.status == "unavailable" })
        #expect(detail.providerRatios.first { $0.key == "return_on_assets" }?.value == 0.08)
    }

    @Test func childCollectionCannotAdoptCredentialsReplacedAfterOuterCapture() async throws {
        let bytes = try payload([raw("TEST")])
        for qualityRequest in [false, true] {
            let key = ChangingKey(), requests = Counter()
            let model = S(access: .init(key: { key.read() }, credentialRevision: { nil },
                policyRevision: { nil }, allowed: { true }), transport: { request in
                await requests.increment()
                return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, clock: { now }, universe: { _, _, _ in .init(listings: [listing("TEST")], membership: nil) })
            if qualityRequest {
                await model.load()
                #expect(await requests.value == 1)
                let selected = try #require(model.snapshot?.rows.first)
                // Capture and immediate admission see A; the child would formerly recapture B.
                key.arm(replaceOnRead: 3)
                await model.companyQuality(for: selected)
                #expect(await requests.value == 1)
                #expect(model.quality == nil && model.snapshot != nil && !model.isBusy)
            } else {
                // The outer capture sees A, but a subsequent child key read sees B.
                key.arm(replaceOnRead: 2)
                await model.load()
                #expect(await requests.value == 0)
                #expect(model.snapshot == nil && !model.isBusy)
            }
        }
    }

    nonisolated private final class ChangingKey: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var replaceAt: Int?
        func arm(replaceOnRead: Int) {
            lock.lock(); defer { lock.unlock() }
            reads = 0; replaceAt = replaceOnRead
        }
        func read() -> String {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return replaceAt.map { reads >= $0 } == true ? "fixture-B" : "fixture-A"
        }
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    nonisolated private final class Revision: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "one"
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
        func replace() { lock.lock(); defer { lock.unlock() }; value = "two" }
    }

    private actor Gate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
