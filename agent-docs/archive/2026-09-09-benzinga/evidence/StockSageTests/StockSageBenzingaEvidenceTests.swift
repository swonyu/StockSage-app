import Foundation
import Testing
@testable import StockSage

@Suite("Benzinga typed evidence", .serialized)
@MainActor
struct StockSageBenzingaEvidenceTests {
    typealias E = StockSageBenzingaEvidence
    typealias Client = StockSageBenzingaEvidenceClient
    private var now: Date { Date(timeIntervalSince1970: 1_788_912_000) } // 2026-09-09 UTC
    private func body(_ rows: [[String: Any]], more: Bool = false) throws -> Data {
        var root: [String: Any] = ["status": "OK", "results": rows]
        if more { root["next_url"] = "https://untrusted.invalid/never-follow" }
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func fixture(_ product: E.Product, id: String = "fixture-1") -> [String: Any] {
        var row: [String: Any] = ["benzinga_id": id, "ticker": "AAPL", "last_updated": "2026-09-08T12:00:01Z"]
        switch product {
        case .earnings:
            row.merge(["date": "2026-09-08", "date_status": "confirmed", "fiscal_period": "Q3", "fiscal_year": 2026,
                "currency": "USD", "eps_method": "gaap", "actual_eps": -0.25, "estimated_eps": -0.4,
                "actual_revenue": 0, "estimated_revenue": 100, "eps_surprise": 0.15]) { _, new in new }
        case .guidance:
            row.merge(["date": "2026-09-08", "fiscal_period": "FY", "fiscal_year": 2026, "currency": "USD",
                "eps_method": "gaap", "min_eps_guidance": -2, "max_eps_guidance": -1,
                "previous_min_eps_guidance": -3, "previous_max_eps_guidance": -2,
                "revenue_method": "gaap", "min_revenue_guidance": 0, "max_revenue_guidance": 100]) { _, new in new }
        case .ratings, .analystInsights:
            row.merge(["date": "2026-09-08", "firm": "Fixture Research", "benzinga_firm_id": "firm-1",
                "benzinga_analyst_id": "analyst-1", "benzinga_rating_id": "rating-1", "analyst": "Fixture Analyst",
                "rating": "buy", "rating_action": "maintains", "currency": "USD", "price_target": 200,
                "previous_price_target": 190, "adjusted_price_target": 100,
                "insight": "Source commentary only", "notes": "Opinion only"]) { _, new in new }
        case .bullsBears:
            row["bull_case"] = "Bull source argument"; row["bear_case"] = "Bear source argument"
        case .analysts:
            row["full_name"] = "Fixture Analyst"; row["benzinga_firm_id"] = "firm-1"
            row["overall_avg_return"] = -2; row["overall_success_rate"] = 50; row["total_ratings"] = 10
        case .firms: row["name"] = "Fixture Research"; row["currency"] = "USD"
        case .consensus:
            row.removeValue(forKey: "last_updated"); row.removeValue(forKey: "benzinga_id")
            row.merge(["strong_buy_ratings": 1, "buy_ratings": 2, "hold_ratings": 3, "sell_ratings": 0, "strong_sell_ratings": 0,
                "ratings_contributors": 6, "price_target_contributors": 5, "consensus_rating": "hold", "consensus_rating_value": 3.5,
                "low_price_target": 100, "high_price_target": 300, "consensus_price_target": 200]) { _, new in new }
        case .news:
            row["benzinga_id"] = 123; row["tickers"] = ["AAPL"]
            row["title"] = "Synthetic headline"; row["author"] = "Fixture Author"
            row["published"] = "2026-09-08T08:00:00.123-04:00"
            row["url"] = "https://www.benzinga.com/news/fixture"
        }
        return row
    }
    private func parse(_ product: E.Product, row: [String: Any]? = nil) throws -> E.Observation {
        let row = row ?? fixture(product)
        return E.parse(try body([row]), product: product, symbol: "AAPL",
                       referenceID: product.isReference ? row["benzinga_id"] as? String : nil, checkedAt: now)
    }

    @Test func pinsAllNineRequestsAndCredentialIsolation() throws {
        for product in E.Product.allCases {
            let request = try #require(E.request(product, symbol: "aapl", referenceID: product.isReference ? "id-1" : nil, key: "synthetic-only"))
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.host == "api.massive.com" && url.scheme == "https")
            #expect(url.path == product.path + (product == .consensus ? "/AAPL" : ""))
            #expect(query["limit"] == "20" && query["apiKey"] == nil)
            #expect(request.timeoutInterval == 12)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only")
            #expect(!url.absoluteString.contains("synthetic-only"))
            if product.isReference {
                #expect(query["benzinga_id"] == "id-1" && query["ticker"] == nil && query["sort"] == nil)
                #expect(E.request(product, symbol: "AAPL", key: "synthetic-only") == nil)
                #expect(E.request(product, symbol: "AAPL", referenceID: "id-1,id-2", key: "synthetic-only") == nil)
            } else if product == .consensus { #expect(query["sort"] == nil && query["ticker"] == nil) }
            else { #expect(query[product == .news ? "tickers" : "ticker"] == "AAPL") }
            #expect(E.request(product, symbol: "../../wrong", key: "synthetic-only") == nil)
            #expect(E.request(product, symbol: "AAPL", key: "bad\r\nkey") == nil)
        }
    }

    @Test func allNineParsersRetainTypedProvenance() throws {
        for product in E.Product.allCases {
            let observation = try parse(product)
            #expect(observation.state == .available, "\(product)")
            let record = try #require(observation.records.first)
            #expect(record.provenance.product == product && record.provenance.symbol == "AAPL")
            #expect(record.provenance.checkedAt == now)
            #expect(record.provenance.revisionID.count == 64)
        }
    }

    @Test func emptyUnavailablePartialAndMalformedStayDistinct() throws {
        #expect(E.parse(try body([]), product: .news, symbol: "AAPL", checkedAt: now).state == .empty)
        for raw in [#"{"status":"OK"}"#, #"{"status":"ERROR","results":[]}"#, #"{"status":"OK","results":null}"#] {
            #expect(E.parse(Data(raw.utf8), product: .news, symbol: "AAPL", checkedAt: now).state == .unavailable)
        }
        let partial = E.parse(try body([fixture(.news), ["invalid": true]], more: true), product: .news, symbol: "AAPL", checkedAt: now)
        #expect(partial.state == .partial && partial.rejectedCount == 1 && partial.hasMore)
        #expect(partial.records.count == 1 && !partial.summary.contains("untrusted.invalid"))
        #expect(E.parse(Data(repeating: 32, count: 2_000_001), product: .news, symbol: "AAPL", checkedAt: now).failure == .responseTooLarge)
        var rows: [[String: Any]] = []
        for index in 0..<22 { var row = fixture(.news); row["benzinga_id"] = index; rows.append(row) }
        let bounded = E.parse(try body(rows), product: .news, symbol: "AAPL", checkedAt: now)
        #expect(bounded.state == .partial && bounded.records.count == 3 && bounded.omittedCount == 19)
    }

    @Test func earningsCalendarIsIndependentOfReportedValues() throws {
        let record = try #require(try parse(.earnings).records.first)
        guard case .earnings(let earnings) = record.payload else { Issue.record("Wrong payload"); return }
        #expect(earnings.actualEPS == -0.25 && earnings.actualRevenue == 0)
        #expect(earnings.estimatedEPS == -0.4 && earnings.dateStatus == "confirmed")
        var future = fixture(.earnings); future["date"] = "2026-09-10"
        #expect(try parse(.earnings, row: future).state == .unavailable)
        future.removeValue(forKey: "actual_eps"); future.removeValue(forKey: "actual_revenue")
        #expect(try parse(.earnings, row: future).state == .available)
        let dateOnly = try StockSageMassiveEarnings.parseNext(try body([future]), symbol: "AAPL", now: now)
        #expect(dateOnly?.confirmed == true)
    }

    @Test func opinionTargetsAndGuidanceAreNotQuotes() throws {
        let rating = try #require(try parse(.ratings).records.first)
        guard case .rating(let opinion) = rating.payload else { Issue.record("Wrong payload"); return }
        #expect(opinion.priceTarget == 200 && opinion.adjustedPriceTarget == 100)
        #expect(opinion.firm == "Fixture Research" && opinion.currency == "USD")
        let insight = try #require(try parse(.analystInsights).records.first)
        #expect(insight.analystID == nil && insight.firmID == "firm-1") // no analyst ID in insight contract
        guard case .insight(let source) = insight.payload else { Issue.record("Wrong payload"); return }
        #expect(source.currency == nil && source.previousPriceTarget == nil)
        let guidance = try #require(try parse(.guidance).records.first)
        guard case .guidance(let outlook) = guidance.payload else { Issue.record("Wrong payload"); return }
        #expect(outlook.eps.direction(currency: outlook.currency) == .raised)
        #expect(outlook.eps.direction(currency: nil) == .unknown)
        var invalid = fixture(.guidance); invalid["min_eps_guidance"] = 2
        #expect(try parse(.guidance, row: invalid).state == .unavailable)
    }

    @Test func rejectsBooleansNumericStringsWrongTickersAndInvalidTime() throws {
        for value: Any in [true, "200", -1] {
            var row = fixture(.ratings); row["price_target"] = value
            #expect(try parse(.ratings, row: row).state == .unavailable)
        }
        var row = fixture(.news); row["tickers"] = ["MSFT"]
        #expect(try parse(.news, row: row).state == .unavailable)
        row = fixture(.news); row["published"] = "2026-09-08T12:00:00"
        #expect(try parse(.news, row: row).state == .unavailable)
        row = fixture(.earnings); row["date"] = "2026-02-30"
        #expect(try parse(.earnings, row: row).state == .unavailable)
        row = fixture(.consensus); row["buy_ratings"] = 2.5
        #expect(try parse(.consensus, row: row).state == .unavailable)
    }

    @Test func sourceTimesRevisionsHeadlineOnlyAndBothSidesSurvive() throws {
        let record = try #require(try parse(.news).records.first)
        #expect(record.provenance.eventTime?.raw == "2026-09-08T08:00:00.123-04:00")
        #expect(record.provenance.updatedTime?.raw == "2026-09-08T12:00:01Z")
        guard case .news(let news) = record.payload else { Issue.record("Wrong payload"); return }
        #expect(news.excerpt == nil)
        var revised = fixture(.news); revised["body"] = "Revised <script>source</script> text"
        let rows = E.parse(try body([fixture(.news), revised]), product: .news, symbol: "AAPL", checkedAt: now)
        #expect(rows.records.count == 2 && rows.records[0].id != rows.records[1].id)
        let consensus = try #require(try parse(.consensus).records.first)
        #expect(consensus.provenance.eventTime == nil && consensus.provenance.updatedTime == nil)
        let pair = try #require(try parse(.bullsBears).records.first)
        guard case .bullsBears(let sides) = pair.payload else { Issue.record("Wrong payload"); return }
        #expect(sides.bull != nil && sides.bear != nil)
        var oneSide = fixture(.bullsBears); oneSide.removeValue(forKey: "bear_case")
        #expect(try parse(.bullsBears, row: oneSide).state == .partial)
    }

    @Test func snapshotReservesAllProductsAndReferenceJoinsUseIDs() throws {
        let rating = try parse(.ratings)
        let analyst = try parse(.analysts, row: fixture(.analysts, id: "analyst-1"))
        let firm = try parse(.firms, row: fixture(.firms, id: "firm-1"))
        let snapshot = E.Snapshot(symbol: "aapl", capturedAt: now, observations: [rating, analyst, firm])
        #expect(snapshot.observations.count == 9)
        #expect(snapshot[.news].failure == .notRequested)
        let record = try #require(rating.records.first)
        #expect(snapshot.analyst(for: record)?.name == "Fixture Analyst")
        #expect(snapshot.firm(for: record)?.name == "Fixture Research")
        #expect(E.parse(try body([fixture(.firms, id: "wrong-id")]), product: .firms,
                       symbol: "AAPL", referenceID: "firm-1", checkedAt: now).state == .unavailable)
    }

    @Test func cacheExpiryGenerationPolicyAndResponseCap() async throws {
        var time = now, allowed = true, calls = 0
        let data = try body([fixture(.news)])
        let client = Client(key: { "synthetic-only" }, permitted: { allowed }, now: { time }) { request, cap in
            calls += 1; #expect(cap == 2_000_000 && request.timeoutInterval == 12)
            return .success(.init(data: data, status: 200))
        }
        #expect(await client.fetch(.news, symbol: "AAPL").state == .available)
        _ = await client.fetch(.news, symbol: "AAPL"); #expect(calls == 1)
        time.addTimeInterval(30); _ = await client.fetch(.news, symbol: "AAPL"); #expect(calls == 2)
        allowed = false; #expect(await client.fetch(.news, symbol: "AAPL").failure == .policyDenied)
        allowed = true; client.invalidate(); _ = await client.fetch(.news, symbol: "AAPL"); #expect(calls == 3)
        #expect(client.cachedQueryCount == 1)
        let oversized = Client(key: { "synthetic-only" }, permitted: { true }, now: { self.now }) { _, _ in
            .success(.init(data: Data(repeating: 0, count: 2_000_001), status: 200))
        }
        #expect(await oversized.fetch(.news, symbol: "AAPL").failure == .responseTooLarge)
    }

    @Test func singleFlightAndLateGenerationResultsAreSuppressed() async throws {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let data = try body([fixture(.news)])
        let client = Client(key: { "synthetic-only" }, permitted: { true }, now: { self.now }) { _, _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
            return .success(.init(data: data, status: 200))
        }
        let first = Task { await client.fetch(.news, symbol: "AAPL") }
        while release == nil { await Task.yield() }
        let second = Task { await client.fetch(.news, symbol: "AAPL") }
        await Task.yield(); await Task.yield()
        #expect(calls == 1)
        client.invalidate(); release?.resume()
        #expect(await first.value.failure == .configurationChanged)
        #expect(await second.value.failure == .configurationChanged)
        #expect(client.cachedQueryCount == 0)
    }

    @Test func latePolicyDenialAndThrottleCannotBecomeEmptyOrBypassed() async throws {
        var allowed = true, calls = 0
        let revoked = Client(key: { "synthetic-only" }, permitted: { allowed }, now: { self.now }) { _, _ in
            allowed = false; return .success(.init(data: Data(#"{"status":"OK","results":[]}"#.utf8), status: 200))
        }
        #expect(await revoked.fetch(.news, symbol: "AAPL").failure == .policyDenied)
        let throttled = Client(key: { "synthetic-only" }, permitted: { true }, now: { self.now }) { _, _ in
            calls += 1; return .success(.init(data: Data(), status: 429, retryAfter: 600))
        }
        #expect(await throttled.fetch(.news, symbol: "AAPL").failure == .http(429))
        throttled.invalidate()
        #expect(await throttled.fetch(.news, symbol: "AAPL", bypassAuthorizationCache: true).failure == .cooldown)
        #expect(calls == 1)
    }

    @Test func metadataIsFetchedOnlyForRetainedIDsAndCachesAreBounded() async throws {
        var requests: [URLRequest] = []
        let client = Client(key: { "synthetic-only" }, permitted: { true }, now: { self.now }) { request, _ in
            requests.append(request)
            let product = E.Product.allCases.first { request.url!.path == $0.path || request.url!.path.hasPrefix($0.path + "/") }!
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let id = query.first { $0.name == "benzinga_id" }?.value ?? "fixture-1"
            return .success(.init(data: try! self.body([self.fixture(product, id: id)]), status: 200))
        }
        let snapshot = await client.snapshot(symbol: "AAPL")
        #expect(snapshot.observations.count == 9 && requests.count == 9)
        #expect(snapshot[.analysts].records.count == 1 && snapshot[.firms].records.count == 1)
        let empty = Client(key: { "synthetic-only" }, permitted: { true }, now: { self.now }) { _, _ in
            .success(.init(data: Data(#"{"status":"OK","results":[]}"#.utf8), status: 200))
        }
        for index in 0..<501 { _ = await empty.fetch(.firms, symbol: "AAPL", referenceID: "id-\(index)") }
        #expect(empty.cachedQueryCount == 500)
        #expect(await empty.snapshot(symbol: "AAPL")[.analysts].failure == .missingReference)
    }
}
