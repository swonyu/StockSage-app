import Foundation
import Testing
@testable import StockSage

@MainActor @Suite("Benzinga pure contracts and bounded projections")
struct StockSageBenzingaTests {
    typealias B = StockSageBenzinga
    let now = try! Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")

    private func query(_ product: B.Product, subject: String = "AAPL",
                       from: String? = nil, through: String? = nil) -> B.Query {
        .init(product: product, subject: subject, from: from, through: through)
    }
    private func body(_ rows: [Any], next: Any? = nil) throws -> Data {
        var root: [String: Any] = ["status": "OK", "results": rows]
        if let next { root["next_url"] = next }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    private func row(_ product: B.Product) -> [String: Any] {
        var value: [String: Any] = ["benzinga_id": "event1", "ticker": "AAPL",
            "date": "2026-09-10", "last_updated": "2026-09-10T11:00:00Z"]
        switch product {
        case .earnings:
            value.merge(["date_status": "confirmed", "actual_eps": -1, "actual_revenue": 0,
                         "fiscal_period": "Q3", "fiscal_year": 2026, "currency": "USD",
                         "eps_method": "gaap", "time": "07:00:00"]) { _, new in new }
        case .guidance:
            value.merge(["fiscal_period": "Q3", "fiscal_year": 2026, "currency": "USD",
                         "eps_method": "gaap", "min_eps_guidance": -1, "max_eps_guidance": 0,
                         "previous_min_eps_guidance": -2, "previous_max_eps_guidance": 0,
                         "estimated_eps_guidance": -0.5, "time": "07:00:00"]) { _, new in new }
        case .ratings:
            value.merge(["firm": "Fixture Firm", "rating_action": "upgrades", "rating": "buy",
                         "previous_rating": "hold", "price_target": 110, "previous_price_target": 100,
                         "currency": "USD", "benzinga_analyst_id": "AnalystA",
                         "benzinga_firm_id": "FirmA", "time": "07:00:00"]) { _, new in new }
        case .analystInsights:
            value.merge(["firm": "Fixture Firm", "insight": "Demand is uncertain.",
                         "benzinga_firm_id": "FirmA", "benzinga_rating_id": "event1"]) { _, new in new }
        case .bullsBearsSay:
            value.removeValue(forKey: "date")
            value["bull_case"] = "Demand may grow."
            value["bear_case"] = "Margins may fall."
        case .news:
            value = ["benzinga_id": 123, "tickers": ["AAPL"], "author": "Fixture Author",
                     "title": "Company update", "url": "https://www.benzinga.com/news/123",
                     "published": "2026-09-10T07:00:00.123456789-04:00",
                     "last_updated": "2026-09-10T11:30:00Z"]
        case .analysts:
            value = ["benzinga_id": "AnalystA", "benzinga_firm_id": "FirmA",
                     "full_name": "Fixture Analyst", "firm_name": "Fixture Firm",
                     "last_updated": "2026-09-09T12:00:00Z", "total_ratings": 12.5]
        case .firms:
            value = ["benzinga_id": "FirmA", "name": "Fixture Firm", "currency": NSNull()]
        case .consensusRatings:
            value = ["ticker": "AAPL", "buy_ratings": 2, "hold_ratings": 1, "sell_ratings": 0,
                     "strong_buy_ratings": 1, "strong_sell_ratings": 0,
                     "price_target_contributors": 3, "ratings_contributors": 3,
                     "consensus_price_target": 123, "consensus_rating_value": 2,
                     "consensus_rating": "buy"]
        }
        return value
    }
    private func page(_ product: B.Product, rows: [[String: Any]]? = nil,
                      subject: String? = nil, generation: String? = "epoch",
                      companyName: String? = nil) throws -> B.Page {
        let subject = subject ?? (product == .analysts ? "AnalystA" : product == .firms ? "FirmA" : "AAPL")
        return B.parse(try body(rows ?? [row(product)]), query: query(product, subject: subject),
                       checkedAt: now, credentialGeneration: generation, companyName: companyName)
    }

    @Test func etfProjectionWithholdsCorporateRecordsWithoutCallingThemBudgetTrimming() throws {
        let pages = try [B.Product.earnings, .consensusRatings, .news].map { try page($0) }
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: pages)
        let before = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000))
        #expect(before.records.contains { $0.product == .earnings })
        #expect(before.records.contains { $0.product == .consensusRatings })
        let identity = StockSageResearchInstrument(symbol: "AAPL", name: "Synthetic ETF", providerType: "ETF")
        let filtered = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000,
                                                excludingProducts: identity.excludedProducts))
        #expect(filtered.records.allSatisfy { $0.product == .news })
        #expect(filtered.records.count == 1)
        #expect(filtered.inapplicableRecordCount == 2)
        #expect(filtered.trimmedRecordCount == 0)
        #expect(filtered.text.contains("not applicable to supplied instrument"))
        #expect(snapshot.pages.count == 3, "Raw captured evidence remains available for receipts")
        let original = B.Projection(statusLines: [], records: [], omittedRecordCount: 0)
        let data = try JSONEncoder().encode(original)
        #expect(!String(decoding: data, as: UTF8.self).contains("inapplicableRecordCount"))
        #expect(try JSONDecoder().decode(B.Projection.self, from: data) == original)
    }

    @Test func emptyBodyTeaserRevisionsCannotCollapseIntoOneFingerprint() throws {
        var first = row(.news)
        first["body"] = ""
        first["teaser"] = "AAPL revenue rose 12%."
        var second = first
        second["teaser"] = "AAPL revenue fell -12%."
        let captured = try page(.news, rows: [first, second])
        #expect(captured.records.count == 2)
        #expect(Set(captured.records.compactMap(\.contentFingerprint)).count == 2)
        #expect(StockSageNewsService.benzingaAttempt(captured, symbol: "AAPL", now: now).items.count == 2)
    }

    @Test func requestsUseNineExactContractsWithoutCredentialURLs() throws {
        let paths = ["earnings", "guidance", "ratings", "analyst-insights", "bulls-bears-say",
                     "news", "analysts", "firms", "consensus-ratings/AAPL"]
        try #require(paths.count == B.Product.allCases.count)
        for (index, product) in B.Product.allCases.enumerated() {
            let subject = product == .analysts || product == .firms ? "CaseSensitiveID" : "aapl"
            let request = try #require(B.request(for: query(product, subject: subject), key: "synthetic-only"))
            let url = try #require(request.url)
            #expect(url.scheme == "https" && url.host == "api.massive.com")
            #expect(url.path == "/benzinga/\(product == .news ? "v2" : "v1")/" + paths[index])
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(fields["limit"] == "20")
            #expect(request.timeoutInterval == 12)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only")
            #expect(!url.absoluteString.contains("synthetic-only") && fields["apiKey"] == nil)
            if product == .analysts || product == .firms {
                #expect(fields["benzinga_id"] == "CaseSensitiveID")
                #expect(fields["benzinga_firm_id"] == nil && fields["ticker"] == nil)
            } else if product != .consensusRatings {
                #expect(fields[product == .news ? "tickers" : "ticker"] == "AAPL")
            } else { #expect(fields["sort"] == nil) }
        }
        #expect(B.Product.news.cacheTTL == 30)
        #expect(B.Product.guidance.cacheTTL == 300)
        #expect(B.Product.consensusRatings.cacheTTL == 7200)
        #expect(B.Product.analysts.cacheTTL == 86400 && B.Product.firms.cacheTTL == 86400)
    }

    @Test func invalidRequestsFailClosedAndBoundsUseProductFields() throws {
        #expect(B.request(for: query(.news), key: "") == nil)
        #expect(B.request(for: query(.news), key: "bad\r\nheader") == nil)
        #expect(B.request(for: query(.consensusRatings, subject: "../AAPL"), key: "fixture") == nil)
        #expect(B.request(for: query(.firms, from: "2026-09-01"), key: "fixture") == nil)
        #expect(B.request(for: query(.earnings, from: "2026-02-30"), key: "fixture") == nil)
        #expect(B.request(for: query(.earnings, from: "2026-09-10", through: "2026-09-01"), key: "fixture") == nil)
        for (product, field, lower, upper) in [
            (B.Product.earnings, "date", "2026-09-01", "2026-09-10"),
            (.news, "published", "2026-09-01T00:00:00Z", "2026-09-10T12:00:00Z"),
            (.bullsBearsSay, "last_updated", "2026-09-01T00:00:00Z", "2026-09-10T12:00:00Z")] {
            let request = try #require(B.request(for: query(product, from: lower, through: upper), key: "fixture"))
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(items.contains(.init(name: field + ".gte", value: lower)))
            #expect(items.contains(.init(name: field + ".lte", value: upper)))
        }
    }

    @Test func allNineDecodeWithOriginalIdentityAndCodableCapture() throws {
        let pages = try B.Product.allCases.map { try page($0) }
        for page in pages {
            #expect(page.status == .answered && page.records.count == 1)
            #expect(page.credentialGeneration == "epoch" && page.checkedAt == now)
            let record = try #require(page.records.first)
            #expect(record.product == page.query.product)
            #expect(record.id.contains(record.revision) && !record.revision.isEmpty)
            #expect(record.source.contains("Massive/Benzinga"))
        }
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: pages)
        #expect(snapshot.omittedRecordCount == 0)
        #expect(try JSONDecoder().decode(B.Snapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func emptyMalformedPartialAndBoundsAreDifferent() throws {
        let q = query(.news)
        #expect(B.parse(try body([]), query: q, checkedAt: now, credentialGeneration: nil).status == .answered)
        #expect(B.parse(Data("{}".utf8), query: q, checkedAt: now, credentialGeneration: nil).status == .unavailable(.malformed))
        let partial = B.parse(try body([row(.news)], next: "https://untrusted.invalid/?apiKey=never-retain"),
                              query: q, checkedAt: now, credentialGeneration: "epoch")
        #expect(partial.status == .partial && partial.hasMore && partial.records.count == 1)
        #expect(!String(decoding: try JSONEncoder().encode(partial), as: UTF8.self).contains("never-retain"))
        let bad = B.parse(try body([NSNull()]), query: q, checkedAt: now, credentialGeneration: nil)
        #expect(bad.status == .partial && bad.excludedCount == 1 && bad.records.isEmpty)
        let oversized = B.parse(Data(repeating: 32, count: 2_000_001), query: q, checkedAt: now, credentialGeneration: nil)
        #expect(oversized.status == .unavailable(.oversized))
        #expect(B.parse(try body(Array(repeating: row(.news), count: 21)), query: q,
                        checkedAt: now, credentialGeneration: nil).status == .unavailable(.malformed))
    }

    @Test func revisionsRemainDistinctEvenBeyondExcerptCap() throws {
        var first = row(.news), second = row(.news)
        first["body"] = String(repeating: "Same words ", count: 100) + "profit"
        second["body"] = String(repeating: "Same words ", count: 100) + "loss"
        let parsed = try page(.news, rows: [first, first, second])
        try #require(parsed.records.count == 2)
        #expect(Set(parsed.records.map(\.id)).count == 2)
        #expect(parsed.records.compactMap(\.contentFingerprint).count == 2
                && parsed.records[0].contentFingerprint != parsed.records[1].contentFingerprint)
        #expect(Set(parsed.records.map(\.vendorID)) == ["123"])
        #expect(parsed.records.allSatisfy { ($0.excerpt?.count ?? 0) <= 400 })
        #expect(parsed.records[0].excerpt == parsed.records[1].excerpt)
    }

    @Test func newsSelectsRawCompanyPassageBeforeRecordExcerptCap() throws {
        var value = row(.news)
        value["company_name"] = "Acme Holdings"
        value["body"] = String(repeating: "Background context. ", count: 80)
            + "<div>Acme Holdings reported revenue of 12.5% and $1,250.50.</div>"
        let record = try #require(try page(.news, rows: [value], companyName: "Acme Holdings").records.first)
        #expect(record.excerpt?.contains("Acme Holdings reported revenue of 12.5% and $1,250.50.") == true)
        #expect(record.excerpt?.contains("Background") == false)
        #expect(record.excerpt?.contains("<div>") == false)
    }

    @Test func newsKeepsHeadlineOnlyAndExactPublicationBoundary() throws {
        let record = try #require(try page(.news).records.first)
        #expect(record.excerpt == nil && record.vendorID == "123")
        #expect(record.published == "2026-09-10T07:00:00.123456789-04:00")
        #expect(record.sourceText.contains("published 2026-09-10T07:00:00.123456789-04:00"))
        #expect(record.sourceText.contains("updated 2026-09-10T11:30:00Z"))
        var exact = row(.news)
        exact["published"] = "2026-09-10T12:00:00Z"
        #expect(try page(.news, rows: [exact]).records.count == 1)
        exact["published"] = "2026-09-10T12:00:00.000000001Z"
        #expect(try page(.news, rows: [exact]).records.isEmpty)
        exact = row(.news); exact["tickers"] = ["MSFT"]
        #expect(try page(.news, rows: [exact]).status == .partial)
        exact = row(.news); exact["benzinga_id"] = true
        #expect(try page(.news, rows: [exact]).records.isEmpty)
        let bounded = B.parse(try body([row(.news)]), query: query(.news, from: "2026-09-10T11:01:00Z"),
                              checkedAt: now, credentialGeneration: nil)
        #expect(bounded.records.isEmpty && bounded.excludedCount == 1)
    }

    @Test func existingRatingAndGuidanceSemanticsAreReused() throws {
        for (product, feed) in [(B.Product.ratings, StockSageMassiveEvents.Feed.ratings), (.guidance, .guidance)] {
            let event = try #require(try StockSageMassiveEvents.parse(body([row(product)]), feed: feed, symbol: "AAPL", now: now))
            let record = try #require(try page(product).records.first)
            #expect(record.headline == event.headline)
            #expect(event.details.allSatisfy { record.details.contains($0) })
        }
        let guidance = try #require(try page(.guidance).records.first)
        #expect(guidance.sourceText.contains("Analyst EPS estimate"))
        #expect(guidance.timeZone == nil && guidance.sourceText.contains("zone unknown"))
        let rating = try #require(try page(.ratings).records.first)
        #expect(rating.timeZone == "UTC" && rating.analystIDs == ["AnalystA"] && rating.firmIDs == ["FirmA"])
        // The "must be a change" rule now applies to CATALYSTS only (2026-09-11). A maintained
        // rating with an unchanged target is not news, but it IS what a named firm currently says,
        // so Chat evidence keeps it — carrying its own date, so a weeks-old opinion cannot read as
        // fresh. Both halves are asserted here; before, only the first existed and the evidence
        // path silently inherited a rule written for catalysts.
        var unchanged = row(.ratings)
        unchanged["rating_action"] = "maintains"; unchanged["price_target"] = 100
        let keptAsEvidence = try page(.ratings, rows: [unchanged]).records
        #expect(keptAsEvidence.count == 1, "Chat evidence must keep a maintained rating")
        #expect(try #require(keptAsEvidence.first).sourceText.contains("maintains"))
        let asCatalyst = try StockSageMassiveEvents.parse(
            try body([unchanged]), feed: .ratings, symbol: "AAPL", now: now)
        #expect(asCatalyst == nil, "a maintained rating with an unchanged target is still not a catalyst")
    }

    @Test func genuineTimesAndNumericMeaningAreNotInvented() throws {
        let earnings = try #require(try page(.earnings).records.first)
        #expect(earnings.sourceText.contains("Actual EPS: -1"))
        #expect(earnings.sourceText.contains("Actual revenue: 0"))
        #expect(earnings.timeZone == "EST")
        let consensus = try #require(try page(.consensusRatings).records.first)
        #expect(consensus.vendorID == nil && consensus.date == nil && consensus.published == nil && consensus.lastUpdated == nil)
        #expect(!consensus.sourceText.contains("USD") && consensus.sourceText.contains("currency unknown"))
        let pair = try #require(try page(.bullsBearsSay).records.first)
        #expect(pair.sourceText.contains("Bull: Demand may grow.") && pair.sourceText.contains("Bear: Margins may fall."))
        for key in ["buy_ratings", "ratings_contributors"] {
            var invalid = row(.consensusRatings); invalid[key] = 1.5
            #expect(try page(.consensusRatings, rows: [invalid]).records.isEmpty)
        }
        var invalid = row(.earnings); invalid["actual_eps"] = true
        #expect(try page(.earnings, rows: [invalid]).records.isEmpty)
    }

    @Test func metadataUsesExactIDsNotNamesOrTickerDefaults() throws {
        let insight = try #require(try page(.analystInsights).records.first)
        #expect(insight.ratingIDs == ["event1"] && insight.firmIDs == ["FirmA"] && insight.analystIDs.isEmpty)
        #expect(try page(.analysts, subject: "analysta").records.isEmpty)
        #expect(try page(.firms, subject: "UnrelatedID").records.isEmpty)
        let analyst = try #require(try page(.analysts).records.first)
        #expect(analyst.symbol == nil && analyst.firmIDs == ["FirmA"])
        #expect(analyst.sourceText.contains("12.5"))
    }

    @Test func snapshotsTrimAcrossQueriesWithoutLosingStatusesAndCountPriorOmissions() throws {
        let pages = try (0..<5).map { index -> B.Page in
            var row = row(.analysts); row["benzinga_id"] = "Analyst\(index)"
            return try page(.analysts, rows: [row], subject: "Analyst\(index)")
        }
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch",
                                  pages: pages, omittedRecordCount: 7)
        #expect(snapshot.pages.count == 5 && snapshot.pages.flatMap(\.records).count == 3)
        #expect(snapshot.pages.allSatisfy { $0.status == .answered && $0.checkedAt == now })
        #expect(snapshot.omittedRecordCount == 9)
        let projection = try #require(B.projection(snapshot, maximumUTF8Bytes: 1200))
        #expect(projection.records.isEmpty) // No retained parent references these metadata IDs.
        #expect(projection.omittedRecordCount == 12)
    }

    @Test func decodingRejectsOversizedOrCorruptCaptureWithoutNormalizingIt() throws {
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch",
                                  pages: [try page(.news)], omittedRecordCount: 4)
        let bytes = try JSONEncoder().encode(snapshot)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let page = try #require((original["pages"] as? [[String: Any]])?.first)
        #expect(try JSONDecoder().decode(B.Snapshot.self, from: bytes) == snapshot)
        var cases: [[String: Any]] = []
        var four = original; four["pages"] = Array(repeating: page, count: 4); cases.append(four)
        var emptyPage = page; emptyPage["records"] = [Any]()
        var many = original; many["pages"] = Array(repeating: emptyPage, count: 14); cases.append(many)
        var negative = original; negative["omittedRecordCount"] = -1; cases.append(negative)
        var invalidPage = page; invalidPage["excludedCount"] = -1
        var excluded = original; excluded["pages"] = [invalidPage]; cases.append(excluded)
        invalidPage = page
        invalidPage["checkedAt"] = now.addingTimeInterval(1).timeIntervalSinceReferenceDate
        var future = original; future["pages"] = [invalidPage]; cases.append(future)
        invalidPage = page
        invalidPage["query"] = ["product": "news", "subject": "AAPL",
                                "from": "2026-09-10T12:00:00Z", "through": "2026-09-01T00:00:00Z"]
        var reversed = original; reversed["pages"] = [invalidPage]; cases.append(reversed)
        for value in cases {
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(B.Snapshot.self, from: data) }
        }
        var nonfinite = original; nonfinite["capturedAt"] = "NaN"
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
        let data = try JSONSerialization.data(withJSONObject: nonfinite)
        #expect(throws: (any Error).self) { try decoder.decode(B.Snapshot.self, from: data) }
    }

    @Test func optionalConsensusTickerDoesNotInventOrAcceptContradictoryIdentity() throws {
        var value = row(.consensusRatings)
        value.removeValue(forKey: "ticker")
        let missing = try page(.consensusRatings, rows: [value])
        #expect(missing.status == .answered && missing.records.first?.symbol == "AAPL")
        value["ticker"] = "MSFT"
        #expect(try page(.consensusRatings, rows: [value]).records.isEmpty)
        value["ticker"] = 123
        #expect(try page(.consensusRatings, rows: [value]).status == .partial)
    }

    @Test func revenueAmountsAndTargetsRejectImpossibleValuesButMissesAndEPSRemainValid() throws {
        for field in ["actual_revenue", "estimated_revenue", "previous_revenue"] {
            var value = row(.earnings); value[field] = -1
            #expect(try page(.earnings, rows: [value]).records.isEmpty)
        }
        var miss = row(.earnings)
        miss["revenue_surprise"] = -10
        miss["revenue_surprise_percent"] = -5
        miss["estimated_eps"] = -2
        #expect(try page(.earnings, rows: [miss]).records.count == 1)
        var guidance = row(.guidance); guidance["estimated_revenue_guidance"] = -1
        #expect(try page(.guidance, rows: [guidance]).records.isEmpty)
        for product in [B.Product.consensusRatings, .analystInsights] {
            let fields = product == .consensusRatings
                ? ["consensus_price_target", "low_price_target", "high_price_target"] : ["price_target"]
            for field in fields {
                for value in [0, -1] {
                    var bad = row(product); bad[field] = value
                    #expect(try page(product, rows: [bad]).records.isEmpty)
                }
            }
        }
        var inverted = row(.consensusRatings)
        inverted["low_price_target"] = 150; inverted["high_price_target"] = 100
        #expect(try page(.consensusRatings, rows: [inverted]).records.isEmpty)
        inverted["high_price_target"] = 150
        #expect(try page(.consensusRatings, rows: [inverted]).records.count == 1)
    }

    @Test func ratingAnalystEvidenceKeepsActionDateCurrencyAndNamedOriginalBasisTargets() throws {
        let record = try #require(try page(.ratings).records.first)
        let evidence = try #require(record.analystEvidence)
        #expect(evidence.action == "upgrades" && evidence.consensus == nil)
        #expect(evidence.date == "2026-09-10" && evidence.currency == "USD")
        #expect(evidence.targets == [
            .init(field: .ratingCurrent, amount: Decimal(110)),
            .init(field: .ratingPrevious, amount: Decimal(100))
        ])
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: [try page(.ratings)])
        let text = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000)).text
        #expect(text.contains("Analyst provenance: same provider record; action upgrades; provider date 2026-09-10; target currency USD; target fields rating original-basis current target; rating original-basis previous target."))
        #expect(text.components(separatedBy: record.id).count == 2)
        #expect(!record.sourceText.contains("amount "))
    }

    @Test func insightAnalystEvidenceKeepsMissingCurrencyMissingRatherThanBorrowingIt() throws {
        var row = row(.analystInsights)
        row["rating_action"] = "maintains"
        row["price_target"] = 95
        row.removeValue(forKey: "currency")
        let record = try #require(try page(.analystInsights, rows: [row]).records.first)
        let evidence = try #require(record.analystEvidence)
        #expect(evidence.action == "maintains" && evidence.consensus == nil)
        #expect(evidence.date == "2026-09-10" && evidence.currency == nil)
        #expect(evidence.targets == [.init(field: .insight, amount: Decimal(95))])
        #expect(record.sourceText.contains("Analyst target; currency unknown: 95.0"))
        #expect(record.sourceText.contains("target currency not supplied; target fields insight target."))
    }

    @Test func consensusAnalystEvidenceKeepsConsensusAndUnknownDateCurrencySeparate() throws {
        var row = row(.consensusRatings)
        row["low_price_target"] = 90
        row["high_price_target"] = 150
        let record = try #require(try page(.consensusRatings, rows: [row]).records.first)
        let evidence = try #require(record.analystEvidence)
        #expect(evidence.action == nil && evidence.consensus == "buy")
        #expect(evidence.date == nil && evidence.currency == nil)
        #expect(evidence.targets == [
            .init(field: .consensus, amount: Decimal(123)),
            .init(field: .low, amount: Decimal(90)),
            .init(field: .high, amount: Decimal(150))
        ])
        #expect(record.sourceText.contains("source time unknown"))
        #expect(record.sourceText.contains("Analyst provenance: same provider record; consensus buy; target currency not supplied; target fields consensus target; consensus low target; consensus high target."))
    }

    @Test func targetProvenanceUsesEachExactRecordAndNamedFieldEvenForEqualAmounts() throws {
        var first = row(.ratings), second = row(.ratings)
        second["benzinga_id"] = "event2"
        second["price_target"] = 110
        second["previous_price_target"] = 110
        let records = try page(.ratings, rows: [first, second]).records
        #expect(records.count == 2 && records[0].id != records[1].id)
        #expect(records.allSatisfy { $0.analystEvidence?.targets.contains(.init(field: .ratingCurrent, amount: Decimal(110))) == true })
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch",
                                  pages: [try page(.ratings, rows: [first, second])])
        let text = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000)).text
        for record in records {
            #expect(text.components(separatedBy: record.id).count == 2)
            #expect(text.contains("[\(record.id)] " + record.sourceText))
            #expect(record.sourceText.contains("same provider record"))
            #expect(record.sourceText.contains("target fields rating original-basis current target; rating original-basis previous target."))
        }
    }

    @Test func analystEvidencePreservesNonIntegerTargetDecimalAcrossCaptureAndCodableRoundTrip() throws {
        let target = try #require(Decimal(string: "123.456789123456789", locale: Locale(identifier: "en_US_POSIX")))
        var row = row(.consensusRatings)
        row["consensus_price_target"] = NSDecimalNumber(decimal: target)
        let record = try #require(try page(.consensusRatings, rows: [row]).records.first)
        #expect(record.analystEvidence?.targets.first == .init(field: .consensus, amount: target))
        let restored = try JSONDecoder().decode(B.Record.self, from: JSONEncoder().encode(record))
        #expect(restored.analystEvidence?.targets.first == .init(field: .consensus, amount: target))
    }

    @Test func typedAnalystEvidencePreservesExistingTargetGuardsAndOlderCapturesDecode() throws {
        var invalid = row(.ratings)
        invalid["price_target"] = 0
        #expect(try page(.ratings, rows: [invalid]).records.isEmpty)
        invalid = row(.analystInsights)
        invalid["price_target"] = -1
        #expect(try page(.analystInsights, rows: [invalid]).records.isEmpty)

        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: [try page(.ratings)])
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var pages = try #require(encoded["pages"] as? [[String: Any]])
        var records = try #require(pages[0]["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "analystEvidence")
        pages[0]["records"] = records
        encoded["pages"] = pages
        let restored = try JSONDecoder().decode(B.Snapshot.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(restored.pages[0].records[0].analystEvidence == nil)
    }


    @Test func projectionReservesNineCompactStatusesAndWholeUTF8Records() throws {
        let empty = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: [])
        let base = try #require(B.projection(empty, maximumUTF8Bytes: 1200))
        #expect(base.statusLines.count == 9 && base.statusLines.allSatisfy { $0.count <= 30 })
        #expect(base.text.utf8.count < 600)
        #expect(B.projection(empty, maximumUTF8Bytes: base.text.utf8.count - 1) == nil)
        var news = row(.news)
        news["body"] = "خبر قصير عن الشركة."
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: [try page(.news, rows: [news])])
        let full = try #require(B.projection(snapshot, maximumUTF8Bytes: 1200))
        #expect(full.records.count == 1 && full.text.utf8.count <= 1200)
        let small = try #require(B.projection(snapshot, maximumUTF8Bytes: base.text.utf8.count + 100))
        #expect(small.statusLines.count == 9 && small.records.isEmpty && small.omittedRecordCount == 1)
        #expect(full.records.first == snapshot.pages.first?.records.first)
    }

    @Test func projectionDoesNotOfferWrongGenerationSymbolOrUnreferencedMetadata() throws {
        let pages = [try page(.ratings), try page(.analysts), try page(.firms)]
        let snapshot = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "epoch", pages: pages)
        let projection = try #require(B.projection(snapshot, maximumUTF8Bytes: 12000))
        #expect(Set(projection.records.map(\.product)) == [.ratings, .analysts, .firms])
        let obsolete = B.Snapshot(symbol: "AAPL", capturedAt: now, credentialGeneration: "new", pages: pages)
        #expect(try #require(B.projection(obsolete, maximumUTF8Bytes: 1200)).records.isEmpty)
        let wrong = B.Snapshot(symbol: "MSFT", capturedAt: now, credentialGeneration: "epoch", pages: pages)
        #expect(try #require(B.projection(wrong, maximumUTF8Bytes: 1200)).records.isEmpty)
    }
}
