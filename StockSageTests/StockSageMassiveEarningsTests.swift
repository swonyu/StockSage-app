import Foundation
import Testing
@testable import StockSage

@Suite("Massive/Benzinga earnings boundaries")
struct StockSageMassiveEarningsTests {
    private typealias E = StockSageMassiveEarnings
    private let today = Date(timeIntervalSince1970: 1_788_652_800) // 2026-09-06 00:00 UTC

    private func body(_ rows: String, tail: String = "") -> Data {
        Data("{\"status\":\"OK\",\"results\":[\(rows)]\(tail)}".utf8)
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
            eodhdCalendar: { fallbackCalled = true; return .answered(nil) },
            yahooCalendar: { fallbackCalled = true; return .answered(nil) },
            history: { fallbackCalled = true; return .answered([]) })
        #expect(!fallbackCalled && out.status == .dateKnown && out.confirmed == false)
        #expect(out.source == "Massive/Benzinga earnings" && out.sourcesAsked == [out.source])
        #expect(out.anySourceAnswered && out.projectionBasis == nil)
        let brief = StockSageCatalystWatch.brief(for: SageFix.idea("AAPL", conviction: 0.5),
            inputs: .init(earningsDate: out.earningsDate, now: today,
                          catalystConfirmed: out.confirmed, catalystSource: out.source))
        #expect(brief.primary.source == out.source)
        #expect(brief.primary.headline.contains("(estimated)") && !brief.primary.headline.contains("(confirmed)"))
    }

    @Test func unavailableAndAnsweredEmptyKeepTheirDifferentProvenance() async {
        for answered in [false, true] {
            let out = await StockSageCatalystChain.resolve(now: today,
                massiveCalendar: { answered ? .answered(nil) : .unavailable },
                eodhdCalendar: { .unavailable }, yahooCalendar: { .unavailable }, history: { .unavailable })
            #expect(out.anySourceAnswered == answered)
            #expect(out.sourcesAsked == (answered ? ["Massive/Benzinga earnings"] : []))
            #expect(out.status == .unchecked)
        }
    }

    @Test func emptyOrStaleBenzingaDateFallsThroughToEodhdInOrder() async {
        for first: E.Row? in [nil, .init(date: today.addingTimeInterval(-86_400), confirmed: true)] {
            var order: [String] = []
            let out = await StockSageCatalystChain.resolve(now: today,
                massiveCalendar: { order.append("massive"); return .answered(first) },
                eodhdCalendar: {
                    order.append("eodhd")
                    return .answered(.init(code: "AAPL.US", reportPeriod: nil,
                        date: self.today.addingTimeInterval(86_400), beforeAfterMarket: nil,
                        estimate: nil, actual: nil))
                }, yahooCalendar: { order.append("yahoo"); return .unavailable },
                history: { order.append("history"); return .unavailable })
            #expect(order == ["massive", "eodhd"])
            #expect(out.source == "eodhd calendar" && out.status == .dateKnown)
            #expect(out.sourcesAsked == ["Massive/Benzinga earnings", "eodhd calendar"])
        }
    }
}
