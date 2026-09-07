import Foundation
import Testing
@testable import StockSage

@Suite("Massive company catalysts")
struct StockSageMassiveEventsTests {
    private typealias E = StockSageMassiveEvents
    private typealias W = StockSageCatalystWatch
    private let now = Date(timeIntervalSince1970: 1_788_652_800) // 2026-09-06 UTC

    private func body(_ rows: String, tail: String = "") -> Data {
        Data("{\"status\":\"OK\",\"results\":[\(rows)]\(tail)}".utf8)
    }
    private func fixture(_ feed: E.Feed) -> String {
        switch feed {
        case .filing8K:
            #"{"tickers":["AAPL"],"accession_number":"0001-26-001","filing_date":"2026-09-06","primary_category":"Material agreement","supporting_text":"An agreement was filed.","filing_url":"https://www.sec.gov/Archives/example.htm"}"#
        case .ratings:
            #"{"ticker":"AAPL","benzinga_id":123,"date":"2026-09-06","firm":"Fixture Research","rating_action":"upgrades","previous_rating":"Hold","rating":"Buy","price_target":110,"previous_price_target":100,"adjusted_price_target":999,"currency":"USD"}"#
        case .guidance:
            #"{"ticker":"AAPL","benzinga_id":"456","date":"2026-09-06","fiscal_period":"Q3","fiscal_year":2026,"release_type":"official","currency":"USD","eps_method":"gaap","min_eps_guidance":-1,"max_eps_guidance":0,"previous_min_eps_guidance":-2,"previous_max_eps_guidance":0,"revenue_method":"gaap","min_revenue_guidance":90,"max_revenue_guidance":100,"previous_min_revenue_guidance":100,"previous_max_revenue_guidance":110}"#
        case .dividends:
            #"{"ticker":"AAPL","id":"div1","ex_dividend_date":"2026-09-06","pay_date":"2026-09-20","cash_amount":0.25,"currency":"USD"}"#
        case .insider:
            #"{"tickers":["AAPL"],"accession_number":"0002-26-001","filing_date":"2026-09-06","transaction_date":"2026-09-04","transaction_code":"P","transaction_acquired_disposed":"A","transaction_shares":25,"transaction_price_per_share":100,"owner_name":"Fixture Owner","officer_title":"Director","security_type":"non-derivative","form_type":"4","aff_10b5_one":true,"filing_url":"https://www.sec.gov/Archives/example.htm"}"#
        }
    }
    private func event(_ feed: E.Feed, offset: Int = 0, symbol: String = "AAPL") -> E.Event {
        .init(id: feed.rawValue, symbol: symbol, feed: feed, date: now.addingTimeInterval(Double(offset) * 86_400),
              headline: "Observed \(feed.rawValue)", details: [feed.source], link: nil)
    }

    @Test func imminentProjectionPrecedesVolumeWithoutBecomingConfirmed() {
        let signal = StockSageCatalyst.Signal(symbol: "AAPL", rvol: 8, priceChangePct: 5,
            tier: .major, likelyMechanicalFlow: false, caveat: StockSageCatalyst.caveat)
        let brief = StockSageCatalystWatch.brief(for: SageFix.idea("AAPL", conviction: 0.5),
            inputs: .init(volumeMove: signal, now: now,
                catalystProjectedDate: now.addingTimeInterval(2 * 86_400),
                catalystProjectionBasis: "Prior report intervals; not announced"))
        #expect(brief.primary.kind == .projectedEarnings)
        #expect(brief.secondary.first?.kind == .volumeMove)
        #expect(brief.primary.headline.contains("not announced"))
    }

    @Test func everyRequestUsesTheActualContractAndHeaderOnlyAuth() throws {
        for feed in E.Feed.allCases {
            let request = try #require(E.request(feed, symbol: "aapl", now: now, key: "fixture-only"))
            let url = try #require(request.url)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let q = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.host == "api.massive.com" && url.path == feed.path)
            #expect(q[feed.pluralTicker ? "tickers" : "ticker"] == "AAPL")
            #expect(q[feed.dateField + (feed == .dividends ? ".gte" : ".lte")] == "2026-09-06")
            #expect(q["sort"] == feed.dateField + (feed == .dividends ? ".asc" : ".desc"))
            #expect(q["limit"] == "100" && !url.absoluteString.contains("fixture-only"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
            #expect(E.request(feed, symbol: "2222.SR", now: now, key: "fixture-only") == nil)
            #expect(E.request(feed, symbol: "AAPL", now: now, key: "") == nil)
        }
    }

    @Test func parserAndCopyPinsForAllFiveFeeds() throws {
        let headlines = ["8-K filed", "Analyst update", "Company guidance update", "Ex-dividend", "Form 4 purchase filed"]
        for (index, feed) in E.Feed.allCases.enumerated() {
            let parsed = try #require(try E.parse(body(fixture(feed)), feed: feed, symbol: "AAPL", now: now))
            #expect(parsed.headline == headlines[index] + " · " + W.dateStr(now))
            #expect(parsed.details.first == feed.source + " · " + W.dateStr(now) + ".")
            let brief = W.brief(for: SageFix.idea("AAPL", conviction: 0.5), inputs: .init(now: now, companyEvents: [parsed]))
            #expect(brief.primary.kind == feed.kind && brief.primary.date == now)
            #expect(brief.primary.source == feed.source && brief.primary.caveat == feed.caveat)
            #expect(brief.primary.watch == "Read the attributed record and verify subsequent updates; no direction is implied.")
            #expect(brief.primary.sourceURL == parsed.link)
        }
    }

    @Test func guidanceUsesPairedBoundsIncludingEqualBoundsAndNegativeEPS() throws {
        let cases: [(Double?, Double?, Double?, Double?, E.Direction)] = [
            (2, 3, 1, 3, .raised), (1, 2, 1, 3, .lowered), (1, 3, 1, 3, .unchanged),
            (0, 4, 1, 3, .mixed), (-1, 0, -2, 0, .raised), (2, 2, 1, 1, .raised),
            (nil, nil, 1, 3, .unknown), (2, 1, 1, 3, .unknown), (.infinity, 3, 1, 3, .unknown)]
        for (lo, hi, oldLo, oldHi, want) in cases {
            #expect(E.direction(lower: lo, upper: hi, previousLower: oldLo, previousUpper: oldHi) == want)
        }
        let parsed = try #require(try E.parse(body(fixture(.guidance)), feed: .guidance, symbol: "AAPL", now: now))
        #expect(parsed.details.contains("EPS (gaap): raised, USD -2–0 → USD -1–0."))
        #expect(parsed.details.contains("REVENUE (gaap): lowered, USD 100–110 → USD 90–100."))
        let missing = #"{"ticker":"AAPL","benzinga_id":"456","date":"2026-09-06","fiscal_period":"Q3","fiscal_year":2026,"notes":"withdrawn according to someone"}"#
        let unknown = try #require(try E.parse(body(missing), feed: .guidance, symbol: "AAPL", now: now))
        #expect(unknown.details.joined().contains("comparison unknown"))
        #expect(!unknown.details.joined().contains("withdrawn"))
    }

    @Test func noInventedTargetBasisOrCurrencyAndNoTradingMutation() throws {
        let parsed = try #require(try E.parse(body(fixture(.ratings)), feed: .ratings, symbol: "AAPL", now: now))
        #expect(parsed.details.contains("Analyst price target (original basis): USD 100 → USD 110; not an app target."))
        #expect(!parsed.details.joined().contains("999"))
        let idea = SageFix.idea("AAPL", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: .init(now: now, companyEvents: [parsed]))
        #expect(brief.idea.advice.targetPrice == idea.advice.targetPrice)
        #expect(brief.idea.advice.stopPrice == idea.advice.stopPrice)
        #expect(brief.idea.advice.conviction == idea.advice.conviction)
        let noCurrency = fixture(.ratings).replacingOccurrences(of: #""currency":"USD""#, with: #""currency":null"#)
        let missing = try #require(try E.parse(body(noCurrency), feed: .ratings, symbol: "AAPL", now: now))
        #expect(missing.details.last == "Comparable original-basis price targets/currency not supplied.")
        #expect(!missing.details.joined().contains("USD"))
    }

    @Test func invalidPartialOrWrongSymbolIsNotCheckedEmpty() {
        for feed in E.Feed.allCases {
            for invalid in [Data("{}".utf8), body("null"), body("", tail: #", "next_url":"https://api.massive.com/next""#),
                            body(fixture(feed).replacingOccurrences(of: "AAPL", with: "MSFT")),
                            body(fixture(feed).replacingOccurrences(of: "2026-09-06", with: "2026-02-30"))] {
                #expect(throws: (any Error).self) { try E.parse(invalid, feed: feed, symbol: "AAPL", now: now) }
            }
        }
        let badNumber = fixture(.dividends).replacingOccurrences(of: "0.25", with: "true")
        #expect(throws: (any Error).self) { try E.parse(body(badNumber), feed: .dividends, symbol: "AAPL", now: now) }
    }

    @Test func windowsStraddleSevenFourteenThirtyAndRespectUTC() {
        for feed in E.Feed.allCases {
            let sign = feed == .dividends ? 1 : -1
            let boundary = event(feed, offset: sign * feed.days)
            let expired = event(feed, offset: sign * (feed.days + 1))
            #expect(E.inWindow(boundary.date, feed: feed, now: now.addingTimeInterval(86_399)))
            #expect(!E.inWindow(expired.date, feed: feed, now: now))
            #expect(!E.inWindow(event(feed, offset: -sign).date, feed: feed, now: now))
            let b = W.brief(for: SageFix.idea("AAPL", conviction: 0.5), inputs: .init(now: now, companyEvents: [boundary, expired]))
            #expect(b.primary.kind == feed.kind && b.primary.date == boundary.date)
            #expect(b.all.count == 1)
            let wrongSymbol = W.brief(for: SageFix.idea("MSFT", conviction: 0.5), inputs: .init(now: now, companyEvents: [boundary]))
            #expect(!wrongSymbol.all.contains { $0.kind == feed.kind })
        }
    }

    @Test func insiderExcludesGrantsDerivativesAndDisclosesLagPlanAndAmendment() throws {
        for changed in [fixture(.insider).replacingOccurrences(of: #""transaction_code":"P""#, with: #""transaction_code":"A""#),
                        fixture(.insider).replacingOccurrences(of: "non-derivative", with: "derivative")] {
            #expect(try E.parse(body(changed), feed: .insider, symbol: "AAPL", now: now) == nil)
        }
        let amended = fixture(.insider).replacingOccurrences(of: #""form_type":"4""#, with: #""form_type":"4/A""#)
        let parsed = try #require(try E.parse(body(amended), feed: .insider, symbol: "AAPL", now: now))
        #expect(parsed.details.contains("Amendment, not an additional transaction."))
        #expect(parsed.details.contains("Reported under a Rule 10b5-1 plan."))
        #expect(parsed.details.joined().contains("Sep 4, 2026"))
        #expect(E.Feed.insider.caveat.contains("Filing-lagged"))
        let missingSecurity = fixture(.insider).replacingOccurrences(of: #""security_type":"non-derivative""#, with: #""security_type":null"#)
        #expect(throws: (any Error).self) { try E.parse(body(missingSecurity), feed: .insider, symbol: "AAPL", now: now) }
        let numericPlan = fixture(.insider).replacingOccurrences(of: #""aff_10b5_one":true"#, with: #""aff_10b5_one":1"#)
        #expect(throws: (any Error).self) { try E.parse(body(numericPlan), feed: .insider, symbol: "AAPL", now: now) }
    }

    @Test func insiderLiveSecuritySpellingMatchesDocumentedSpellingWithoutAcceptingUnknownTypes() {
        // GILD HTTP200 replay, 2026-09-07: live rows use non_derivative; docs use non-derivative.
        for (code, side) in [("P", "A"), ("S", "D")] {
            let row = fixture(.insider)
                .replacingOccurrences(of: #""transaction_code":"P""#, with: "\"transaction_code\":\"\(code)\"")
                .replacingOccurrences(of: #""transaction_acquired_disposed":"A""#, with: "\"transaction_acquired_disposed\":\"\(side)\"")
            let expected = E.observation(.success(body(row)), feed: .insider, symbol: "AAPL", now: now)
            let live = E.observation(.success(body(row.replacingOccurrences(of: "non-derivative", with: "non_derivative"))),
                                     feed: .insider, symbol: "AAPL", now: now)
            #expect(expected.outcome == .answered && expected.event != nil)
            #expect(live == expected)
            for security in ["derivative", "unknown", "non derivative", "NON_DERIVATIVE"] {
                let result = E.observation(.success(body(row.replacingOccurrences(of: "non-derivative", with: security))),
                                           feed: .insider, symbol: "AAPL", now: now)
                #expect(result.event == nil)
                #expect(result.outcome == (security == "derivative" ? .answered : .unavailable))
                #expect(result.failure == (security == "derivative" ? nil : .invalidPayload))
            }
        }
    }

    @Test func contradictoryInsiderDirectionIsExplainedWithoutInventingACorrectedTrade() throws {
        let message = "Filing has conflicting purchase/sale and acquired/disposed fields; transaction direction is unverified."
        for row in [fixture(.insider).replacingOccurrences(of: #""transaction_acquired_disposed":"A""#, with: #""transaction_acquired_disposed":"D""#),
                    fixture(.insider).replacingOccurrences(of: #""transaction_code":"P""#, with: #""transaction_code":"S""#)] {
            let record = E.observation(.success(body(row)), feed: .insider, symbol: "AAPL", now: now)
            #expect(record.outcome == .unavailable && record.event == nil)
            #expect(record.failure?.message == message)
            let restored = try JSONDecoder().decode(E.Observation.self, from: JSONEncoder().encode(record))
            #expect(restored == record)
            let copy = E.statusLine(.insider, observation: restored, now: now)
            #expect(copy.contains(message) && copy.contains("not an empty result"))
        }
    }

    @Test func completeEmptyIsDifferentFromUnavailableAndCacheRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m6-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var records: [E.Observation] = []
        for feed in E.Feed.allCases {
            #expect(try E.parse(body(""), feed: feed, symbol: "AAPL", now: now) == nil)
            let empty = E.Observation(symbol: "AAPL", feed: feed, checkedAt: now, outcome: .answered, event: nil)
            let unavailable = E.Observation(symbol: "AAPL", feed: feed, checkedAt: now, outcome: .unavailable, event: nil)
            #expect(E.statusLine(feed, observation: empty, now: now).contains("no qualifying event"))
            #expect(E.statusLine(feed, observation: unavailable, now: now).contains("not an empty result"))
            #expect(E.statusLine(feed, observation: nil, now: now).contains("not checked"))
            #expect(empty.fresh(at: now.addingTimeInterval(86_399)) && !empty.fresh(at: now.addingTimeInterval(86_400)))
            #expect(unavailable.fresh(at: now.addingTimeInterval(899)) && !unavailable.fresh(at: now.addingTimeInterval(900)))
            #expect(!empty.fresh(at: now.addingTimeInterval(-1)))
            records += [empty, unavailable]
        }
        #expect(StockSageCompanyEventCache(entries: records).save(to: url))
        #expect(StockSageCompanyEventCache.load(from: url)?.entries == records)
        let late = E.Observation(symbol: "AAPL", feed: .dividends, checkedAt: now.addingTimeInterval(86_000), outcome: .answered, event: nil)
        #expect(!late.fresh(at: now.addingTimeInterval(86_400)))
    }

    @Test func failuresKeepSafeReasonsThroughTheRealResponseCacheAndUISeam() throws {
        let sentinel = "FIXTURE_SECRET_DO_NOT_RENDER"
        let cases: [(Result<Data, E.Failure>, E.Failure)] = [
            (.failure(.http(401)), .http(401)), (.failure(.http(403)), .http(403)),
            (.failure(.http(429)), .http(429)), (.failure(.http(503)), .http(503)),
            (.failure(.transport), .transport), (.failure(.timedOut), .timedOut), (.failure(.cooldown), .cooldown),
            (.failure(.externalAccessDisabled), .externalAccessDisabled),
            (.failure(.cancelled), .cancelled), (.failure(.requestUnavailable), .requestUnavailable),
            (.success(Data("{\"error\":\"\(sentinel)\"}".utf8)), .invalidPayload),
            (.success(body("", tail: ",\"next_url\":\"https://api.massive.com/next?apiKey=\(sentinel)\"")), .incompleteResponse),
            (.success(Data(repeating: 0, count: 2_000_001)), .responseTooLarge)]
        for (response, reason) in cases {
            let record = E.observation(response, feed: .insider, symbol: "AAPL", now: now)
            #expect(record.outcome == .unavailable && record.event == nil && record.failure == reason)
            let encoded = try JSONEncoder().encode(record)
            let restored = try JSONDecoder().decode(E.Observation.self, from: encoded)
            #expect(restored == record)
            let copy = E.statusLine(.insider, observation: restored, now: now)
            #expect(copy.contains(reason.message) && copy.contains("not an empty result"))
            #expect(!copy.contains(sentinel) && !String(decoding: encoded, as: UTF8.self).contains(sentinel))
        }
        let empty = E.observation(.success(body("")), feed: .insider, symbol: "AAPL", now: now)
        #expect(empty.outcome == .answered && empty.failure == nil && empty.event == nil)
        let legacy = E.Observation(symbol: "AAPL", feed: .insider, checkedAt: now, outcome: .unavailable, event: nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "failure")
        let decoded = try JSONDecoder().decode(E.Observation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.failure == nil && decoded.outcome == .unavailable)
        #expect(E.statusLine(.insider, observation: decoded, now: now).contains("reason not recorded"))
    }

    @Test func linksStayOnTheirAttributedPublisherAndChangedFactsInvalidateNarration() {
        #expect(E.sourceLink("https://www.sec.gov/Archives/example.htm", feed: .insider) != nil)
        #expect(E.sourceLink("https://www.benzinga.com/news/example", feed: .ratings) != nil)
        for link in ["http://www.sec.gov/a", "https://sec.gov.evil.test/a", "https://user:pass@sec.gov/a", "https://127.0.0.1/a"] {
            #expect(E.sourceLink(link, feed: .filing8K) == nil)
        }
        let idea = SageFix.idea("AAPL", conviction: 0.5)
        let old = W.brief(for: idea, inputs: .init(now: now, companyEvents: [event(.ratings)]))
        let new = W.brief(for: idea, inputs: .init(now: now, companyEvents: [event(.guidance)]))
        let facts = StockSageCatalystNarrator.facts(for: old)
        #expect(facts != StockSageCatalystNarrator.facts(for: new))
        #expect(facts.joined().contains("not StockSage's target"))
    }

    @Test func reportedDatesUseRecentBucketAndExDatesUseUpcomingBuckets() {
        let events = E.Feed.allCases.map { event($0, offset: $0 == .dividends ? 2 : -2) }
        let brief = W.brief(for: SageFix.idea("AAPL", conviction: 0.5), inputs: .init(now: now, companyEvents: events))
        let rows = W.calendar([brief], now: now)
        #expect(rows.count == 5)
        for row in rows { #expect(row.bucket == (row.item.kind == .exDividend ? .thisWeek : .recent)) }
        #expect(W.Bucket.recent.title == "Recently reported")
    }

    @Test func selectionIsOrderIndependentAndDividendsChooseTheNextDate() throws {
        for feed in E.Feed.allCases {
            let current = fixture(feed)
            let another = current.replacingOccurrences(of: "2026-09-06", with: feed == .dividends ? "2026-09-07" : "2026-09-05")
            let forward = try E.parse(body(current + "," + another), feed: feed, symbol: "AAPL", now: now)
            let reverse = try E.parse(body(another + "," + current), feed: feed, symbol: "AAPL", now: now)
            #expect(forward == reverse && forward?.date == now)
        }
    }

    @Test func knownEarningsSuppressContradictoryHistoryProjection() {
        let date = now.addingTimeInterval(2 * 86_400)
        let brief = W.brief(for: SageFix.idea("AAPL", conviction: 0.5), inputs: .init(earningsDate: date, now: now,
            catalystConfirmed: true, catalystProjectedDate: date, catalystProjectionBasis: "Historical guess",
            companyEvents: E.Feed.allCases.map { event($0) }))
        #expect(brief.primary.kind == .earnings)
        #expect(!brief.all.contains { $0.kind == .projectedEarnings })
        #expect(brief.all.count == 6)
    }

    @Test func cacheRejectsCrossSymbolProvenanceAndUnsafeLinks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m6-invalid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = E.Observation(symbol: "MSFT", feed: .ratings, checkedAt: now, outcome: .answered, event: event(.ratings))
        #expect(StockSageCompanyEventCache(entries: [corrupt]).save(to: url))
        #expect(StockSageCompanyEventCache.load(from: url) == nil)
        let event = E.Event(id: "unsafe", symbol: "AAPL", feed: .filing8K, date: now, headline: "Filing", details: [], link: URL(string: "https://127.0.0.1/admin"))
        let unsafe = E.Observation(symbol: "AAPL", feed: .filing8K, checkedAt: now, outcome: .answered, event: event)
        #expect(StockSageCompanyEventCache(entries: [unsafe]).save(to: url))
        #expect(StockSageCompanyEventCache.load(from: url) == nil)
    }

    @Test func exhaustiveNewAxesIndependentPrecedenceOracle() {
        // 3^5 feed states (absent/boundary/expired) ×7 earnings states ×2 volume states =3,402.
        // Existing157,500-grid remains unchanged for technical/risk/seasonality/copy axes.
        let feeds = E.Feed.allCases
        var checked = 0
        for mask in 0..<243 { for earnings in 0..<7 { for volume in [false, true] {
            var code = mask
            var events: [E.Event] = []
            var active = Set<E.Feed>()
            for feed in feeds {
                let state = code % 3; code /= 3
                if state > 0 {
                    events.append(event(feed, offset: (feed == .dividends ? 1 : -1) * (feed.days + (state == 2 ? 1 : 0))))
                    if state == 1 { active.insert(feed) }
                }
            }
            let projection = earnings == 3 || earnings == 6
            let date = earnings == 0 ? nil : now.addingTimeInterval((earnings <= 3 ? 2 : 30) * 86_400)
            let signal: StockSageCatalyst.Signal? = volume ? .init(symbol: "AAPL", rvol: 8, priceChangePct: 5,
                tier: .major, likelyMechanicalFlow: false, caveat: StockSageCatalyst.caveat) : nil
            let brief = W.brief(for: SageFix.idea("AAPL", conviction: 0.5), inputs: .init(
                earningsDate: projection ? nil : date, volumeMove: signal, now: now,
                catalystConfirmed: earnings == 2 || earnings == 5 ? false : true,
                catalystProjectedDate: projection ? date : nil, catalystProjectionBasis: projection ? "Prior reports" : nil,
                companyEvents: events))
            var expected: [W.Kind] = []
            if earnings > 0 && earnings <= 3 { expected.append(projection ? .projectedEarnings : .earnings) }
            for feed in [E.Feed.filing8K, .ratings, .guidance] where active.contains(feed) { expected.append(feed.kind) }
            if volume { expected.append(.volumeMove) }
            if earnings >= 4 { expected.append(projection ? .projectedEarnings : .earnings) }
            for feed in [E.Feed.dividends, .insider] where active.contains(feed) { expected.append(feed.kind) }
            if expected.isEmpty { expected = [.none] }
            #expect(brief.all.map(\.kind) == expected, "mask=\(mask), earnings=\(earnings), volume=\(volume)")
            #expect(Set(brief.all.map(\.id)).count == brief.all.count)
            checked += 1
        } } }
        #expect(checked == 3_402)
    }
}
