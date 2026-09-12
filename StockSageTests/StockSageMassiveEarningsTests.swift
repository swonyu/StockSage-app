import Foundation
import Testing
@testable import StockSage

@Suite("Massive/Benzinga earnings boundaries")
struct StockSageMassiveEarningsTests {
    private typealias E = StockSageMassiveEarnings
    private let today = Date(timeIntervalSince1970: 1_788_652_800) // 2026-09-06 00:00 UTC

    @Test func denialBelongsToItsCredentialRevisionIncludingLateResponses() throws {
        let name = "provider.denial.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = "synthetic.denial"
        let revisionKey = "stocksage.massive.credentialRevision"
        let until = today.addingTimeInterval(86400)
        defaults.set("A", forKey: revisionKey)
        StockSageMassiveCredential.recordDenial(until, gate: gate, revision: "A", defaults: defaults)
        #expect(StockSageMassiveCredential.denialUntil(gate, defaults: defaults) == until)
        defaults.set("B", forKey: revisionKey)
        #expect(StockSageMassiveCredential.denialUntil(gate, defaults: defaults) == nil)
        StockSageMassiveCredential.recordDenial(until.addingTimeInterval(100), gate: gate, revision: "A", defaults: defaults)
        #expect(StockSageMassiveCredential.denialUntil(gate, defaults: defaults) == nil)
        StockSageMassiveCredential.recordDenial(until, gate: gate, revision: "B", defaults: defaults)
        #expect(StockSageMassiveCredential.denialUntil(gate, defaults: defaults) == until)
        defaults.set(until, forKey: gate)
        #expect(StockSageMassiveCredential.denialUntil(gate, defaults: defaults) == nil,
                "Legacy denial dates have no verifiable credential ownership")
    }

    private func body(_ rows: String, tail: String = "") -> Data {
        Data("{\"status\":\"OK\",\"results\":[\(rows)]\(tail)}".utf8)
    }

    @MainActor @Test(arguments: [200, 403])
    func credentialChangesDiscardInFlightEarningsAndEventResponses(status: Int) async throws {
        let name = "provider.flight.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let revisionKey = "stocksage.massive.credentialRevision"
        let request = try #require(E.request(symbol: "AAPL", now: today, key: "fixture-only"))
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        for events in [false, true] {
            defaults.set("A", forKey: revisionKey)
            let old: (URLRequest) async throws -> (Data, URLResponse) = { _ in
                defaults.set("B", forKey: revisionKey)
                return (Data("{}".utf8), response)
            }
            if events {
                let result = await StockSageMassiveEvents.get(.ratings, request: request, now: Date(), revision: "A",
                    defaults: defaults, allowed: { true }, transport: old)
                guard case .failure(.cancelled) = result else { Issue.record("Old event response escaped"); return }
            } else {
                let result = await E.get(request, revision: "A", defaults: defaults, allowed: { true }, transport: old)
                #expect(result == nil)
            }
            var requests = 0
            let good: (URLRequest) async throws -> (Data, URLResponse) = { _ in
                requests += 1
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if events {
                let result = await StockSageMassiveEvents.get(.ratings, request: request, now: Date(), revision: "B",
                    defaults: defaults, allowed: { true }, transport: good)
                guard case .success = result else { Issue.record("New event credential incorrectly gated"); return }
            } else {
                let result = await E.get(request, revision: "B", defaults: defaults, allowed: { true }, transport: good)
                #expect(result?.1 == 200)
            }
            #expect(requests == 1)
        }
    }

    @Test func requestIsBoundedAndHeaderAuthenticated() throws {
        let r = try #require(E.request(symbol: "aapl", now: today, key: "fixture-only"))
        let url = try #require(r.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "api.massive.com" && url.path == "/benzinga/v1/earnings")
        #expect(q["ticker"] == "AAPL" && q["date.gte"] == "2026-09-06")
        #expect(q["date.lte"] == "2027-10-11" && q["sort"] == "date.asc" && q["limit"] == "100")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        #expect(!url.absoluteString.contains("fixture-only"))
        #expect(E.request(symbol: "2222.SR", now: today, key: "fixture-only") == nil)
        #expect(E.request(symbol: "AAPL&other=X", now: today, key: "fixture-only") == nil)
        #expect(E.request(symbol: "AAPL", now: today, key: "") == nil)
    }

    @Test func todaySurvivesUntilUTCMidnightAndNextDateWinsAfterward() throws {
        let data = body(#"{"ticker":"AAPL","date":"2026-09-07","date_status":"confirmed"},{"ticker":"AAPL","date":"2026-09-06","date_status":"projected","actual_eps":2.5,"importance":5}"#)
        let first = try #require(try E.parseNext(data, symbol: "AAPL", now: today.addingTimeInterval(86_399)))
        #expect(first.date == today && !first.confirmed) // actual EPS/importance do not confer confirmation
        let next = try #require(try E.parseNext(data, symbol: "AAPL", now: today.addingTimeInterval(86_400)))
        #expect(next.date == today.addingTimeInterval(86_400) && next.confirmed)
    }

    @Test func malformedOrPartialIsUnavailableNotAnEmptyObservation() {
        for data in [Data("{}".utf8), body("", tail: #", "next_url":"https://api.massive.com/next""#),
                     body(#"{"ticker":"MSFT","date":"2026-09-07","date_status":"confirmed"}"#),
                     body(#"{"ticker":"AAPL","date":"2026-02-30","date_status":"confirmed"}"#),
                     body(#"{"ticker":"AAPL","date":"2026-09-07","date_status":"unknown"}"#),
                     body(#"{"ticker":"AAPL","date":"2026-09-07"}"#), body("null")] {
            #expect(throws: (any Error).self) { try E.parseNext(data, symbol: "AAPL", now: today) }
        }
    }

    @Test func realEmptyPastOrBeyondWindowHasNoNextDate() throws {
        #expect(try E.parseNext(body(""), symbol: "AAPL", now: today) == nil)
        let rows = #"{"ticker":"AAPL","date":"2026-09-05","date_status":"confirmed"},{"ticker":"AAPL","date":"2027-10-12","date_status":"confirmed"}"#
        #expect(try E.parseNext(body(rows), symbol: "AAPL", now: today) == nil)
    }

    @Test func conflictingSameDayConfirmationIsConservativeAndOrderIndependent() throws {
        let a = #"{"ticker":"AAPL","date":"2026-09-07","date_status":"confirmed"}"#
        let b = #"{"ticker":"AAPL","date":"2026-09-07","date_status":"projected"}"#
        let forward = try #require(try E.parseNext(body(a + "," + b), symbol: "AAPL", now: today))
        let reversed = try E.parseNext(body(b + "," + a), symbol: "AAPL", now: today)
        #expect(forward == reversed && !forward.confirmed)
    }

    @Test func onlyAuthOrEntitlementRejectionClosesTheDailyGate() {
        for status in [401, 402, 403] {
            let until = E.availabilityOutcome(statusCode: status, now: today)
            #expect(until == today.addingTimeInterval(86_400))
            #expect(!E.isAvailable(unavailableUntil: until, now: today.addingTimeInterval(86_399)))
            #expect(E.isAvailable(unavailableUntil: until, now: today.addingTimeInterval(86_400)))
        }
        for status: Int? in [nil, 200, 429, 500, 503] {
            #expect(E.availabilityOutcome(statusCode: status, now: today) == nil)
        }
        #expect(E.isAvailable(unavailableUntil: nil, now: today))
    }

    @Test func benzingaFirstPreservesProviderEstimateAndShortCircuitsFallbacks() async {
        var fallbackCalled = false
        let out = await StockSageCatalystChain.resolve(now: today,
            massiveCalendar: { .answered(.init(date: today, confirmed: false)) },
            yahooCalendar: { fallbackCalled = true; return .answered(nil) },
            history: { fallbackCalled = true; return .answered([]) })
        #expect(!fallbackCalled && out.status == .dateKnown && out.confirmed == false)
        #expect(out.source == "Massive/Benzinga earnings" && out.sourcesAsked == [out.source])
        #expect(out.anySourceAnswered && out.projectionBasis == nil)
        let brief = StockSageCatalystWatch.brief(for: SageFix.idea("AAPL", conviction: 0.5),
            inputs: .init(earningsDate: out.earningsDate, earningsCheckedAt: today, now: today,
                          catalystConfirmed: out.confirmed, catalystSource: out.source))
        #expect(brief.primary.source == out.source)
        #expect(brief.primary.headline.contains("(estimated)") && !brief.primary.headline.contains("(confirmed)"))
    }

    @Test func unavailableAndAnsweredEmptyKeepTheirDifferentProvenance() async {
        for answered in [false, true] {
            let out = await StockSageCatalystChain.resolve(now: today,
                massiveCalendar: { answered ? .answered(nil) : .unavailable },
                yahooCalendar: { .unavailable }, history: { .unavailable })
            #expect(out.anySourceAnswered == answered)
            #expect(out.sourcesAsked == (answered ? ["Massive/Benzinga earnings"] : []))
            #expect(out.status == .unchecked)
        }
    }

    @Test func emptyOrStaleBenzingaDateFallsThroughToYahooInOrder() async {
        for first: E.Row? in [nil, .init(date: today.addingTimeInterval(-86_400), confirmed: true)] {
            var order: [String] = []
            let out = await StockSageCatalystChain.resolve(now: today,
                massiveCalendar: { order.append("massive"); return .answered(first) },
                yahooCalendar: {
                    order.append("yahoo")
                    return .answered(.init(date: self.today.addingTimeInterval(86_400),
                                           dateRangeEnd: nil, isEstimate: true))
                },
                history: { order.append("history"); return .unavailable })
            #expect(order == ["massive", "yahoo"])
            #expect(out.source == "yahoo calendarEvents" && out.status == .dateKnown)
            #expect(out.sourcesAsked == ["Massive/Benzinga earnings", "yahoo calendarEvents"])
        }
    }
}
