import Foundation
import Testing
@testable import StockSage

@Suite("Massive/Benzinga earnings boundaries")
struct StockSageMassiveEarningsTests {
    private typealias E = StockSageMassiveEarnings
    private let today = Date(timeIntervalSince1970: 1_788_652_800) // 2026-09-06 00:00 UTC

    @Test func earningsDatesUseCivilLabelsAndTheFullForwardSessionWindow() throws {
        let asOf = try Date("2026-09-15T13:00:00Z", strategy: .iso8601)
        let cases: [(String, E.Window.Relation, E.Window.Relation)] = [
            ("2026-09-15", .boundary, .boundary), ("2026-09-16", .boundary, .boundary),
            ("2026-09-17", .inside, .inside), ("2026-09-20", .inside, .inside),
            ("2026-09-24", .boundary, .inside), ("2026-09-25", .outside, .inside),
            ("2026-10-05", .outside, .boundary), ("2026-10-27", .outside, .outside),
            ("2026-11-24", .outside, .outside)
        ]
        for (day, week, fortnight) in cases {
            let date = try Date(day + "T00:00:00Z", strategy: .iso8601)
            let receipt = E.Observation(outcome: .answered(.init(date: date, confirmed: false)),
                checkedAt: asOf.addingTimeInterval(-2), recordedAt: asOf)
            let short = E.Window(observation: receipt, asOf: asOf, horizon: .week)
            let long = E.Window(observation: receipt, asOf: asOf, horizon: .fortnight)
            #expect(short.relation == week && long.relation == fortnight, "\(day)")
            #expect(short.fact.contains("2026-09-16 through 2026-09-24"))
            #expect(long.fact.contains("2026-09-16 through 2026-10-05"))
            #expect(short.fact.contains("Provider date \(day), projected, not announced"))
        }
    }

    @Test func missingOrInvalidEarningsNeverEstablishAnEmptyWindow() throws {
        let asOf = try Date("2026-09-15T13:00:00Z", strategy: .iso8601)
        let row = E.Row(date: try Date("2026-09-18T00:00:00Z", strategy: .iso8601), confirmed: true)
        let receipts: [E.Observation?] = [nil,
            .init(outcome: .answered(nil), checkedAt: asOf, recordedAt: asOf),
            .init(outcome: .unavailable, checkedAt: asOf, recordedAt: asOf),
            .init(outcome: .notRequested, checkedAt: nil, recordedAt: asOf),
            .init(outcome: .answered(row), checkedAt: asOf.addingTimeInterval(-301), recordedAt: asOf),
            .init(outcome: .answered(row), checkedAt: asOf.addingTimeInterval(1), recordedAt: asOf),
            .init(outcome: .answered(row), checkedAt: asOf, recordedAt: asOf.addingTimeInterval(1)),
            .init(outcome: .answered(.init(date: .distantPast, confirmed: true)), checkedAt: asOf, recordedAt: asOf)
        ]
        for receipt in receipts {
            let window = E.Window(observation: receipt, asOf: asOf, horizon: .fortnight)
            #expect(window.relation == .unknown)
            #expect(window.fact.contains("Missing data is not absence"))
        }
        #expect(E.Window(observation: nil, asOf: .distantFuture, horizon: .week).relation == .unknown)
        let beforeHoliday = try Date("2026-09-03T13:00:00Z", strategy: .iso8601)
        #expect(E.Window(observation: nil, asOf: beforeHoliday, horizon: .week)
            .fact.contains("2026-09-04 through 2026-09-15"), "Labor Day is excluded")
    }

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

    @Test func onlyAuthenticationRejectionClosesTheShortGate() {
        let until = E.availabilityOutcome(statusCode: 401, now: today)
        #expect(until == today.addingTimeInterval(300))
        #expect(!E.isAvailable(unavailableUntil: until, now: today))
        #expect(!E.isAvailable(unavailableUntil: until, now: today.addingTimeInterval(299)))
        #expect(E.isAvailable(unavailableUntil: until, now: today.addingTimeInterval(300)))
        for status: Int? in [nil, 200, 402, 403, 429, 500, 503] {
            #expect(E.availabilityOutcome(statusCode: status, now: today) == nil)
        }
        #expect(E.isAvailable(unavailableUntil: nil, now: today))
    }

    @Test func legacyDailyAndInvalidDenialClocksCannotBlockFreshRequests() {
        #expect(E.isAvailable(unavailableUntil: today.addingTimeInterval(86_400), now: today))
        #expect(E.isAvailable(unavailableUntil: today.addingTimeInterval(300), now: today.addingTimeInterval(-1)),
            "A backwards clock cannot lengthen a short authentication suppression")
        #expect(E.isAvailable(unavailableUntil: Date(timeIntervalSince1970: .infinity), now: today))
        #expect(E.isAvailable(unavailableUntil: Date(timeIntervalSince1970: .nan), now: today))
        #expect(E.availabilityOutcome(statusCode: 401, now: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @MainActor @Test(arguments: ["oversized", "different URL"])
    func earningsTransportRejectsAnOversizedOrMismatchedResponse(scenario: String) async throws {
        let name = "provider.earnings.bounds.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let request = try #require(E.request(symbol: "AAPL", now: today, key: "fixture-only"))
        let other = try #require(E.request(symbol: "MSFT", now: today, key: "fixture-only"))
        var requests = 0
        let result = await E.get(request, revision: nil, defaults: defaults, allowed: { true }, transport: { _ in
            requests += 1
            let data = scenario == "oversized" ? Data(repeating: 32, count: 2_000_001) : Data("{}".utf8)
            let url = scenario == "different URL" ? other.url! : request.url!
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(requests == 1 && result == nil)
    }

    @MainActor @Test(arguments: [402, 403])
    func unqualifiedDenialsDoNotSuppressOtherSymbols(status: Int) async throws {
        let name = "provider.earnings.denial.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        for symbol in ["AAPL", "MSFT"] {
            let request = try #require(E.request(symbol: symbol, now: today, key: "fixture-only"))
            let result = await E.get(request, revision: nil, defaults: defaults, allowed: { true }, transport: { req in
                requests += 1
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            #expect(result?.1 == status)
        }
        #expect(requests == 2, "A query-specific denial does not establish product-wide entitlement")
    }

    @MainActor @Test func legacyDailyGateDoesNotPreventEarningsTransport() async throws {
        let name = "provider.earnings.legacy-gate.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        StockSageMassiveCredential.recordDenial(Date().addingTimeInterval(86_400),
            gate: "stocksage.massive.earningsUnavailableUntil", revision: nil, defaults: defaults)
        let request = try #require(E.request(symbol: "AAPL", now: today, key: "fixture-only"))
        var requests = 0
        let result = await E.get(request, revision: nil, defaults: defaults, allowed: { true }, transport: { req in
            requests += 1
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(requests == 1 && result?.1 == 200)
    }

    @MainActor @Test func observationsKeepProviderEmptySeparateFromLocalSuppressionAndPreserveOrigin() async throws {
        let name = "provider.earnings.receipt.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var clock = today
        var requests = 0
        let transport: (URLRequest) async throws -> (Data, URLResponse) = { req in
            requests += 1
            return (Data(#"{"status":"OK","results":[]}"#.utf8),
                HTTPURLResponse(url: req.url!, statusCode: requests == 1 ? 401 : 200, httpVersion: nil, headerFields: nil)!)
        }
        let rejected = await E.observe("AAPL", now: today, key: "fixture-only", revision: nil,
            defaults: defaults, allowed: { true }, clock: { clock }, transport: transport)
        #expect(rejected.outcome == .unavailable && rejected.checkedAt == today)
        #expect(rejected.notRequestedReason == nil)
        clock = today.addingTimeInterval(10)
        let suppressed = await E.observe("MSFT", now: today, key: "fixture-only", revision: nil,
            defaults: defaults, allowed: { true }, clock: { clock }, transport: transport)
        #expect(requests == 1 && suppressed.outcome == .notRequested)
        #expect(suppressed.checkedAt == nil && suppressed.recordedAt == clock)
        #expect(suppressed.notRequestedReason == .priorAuthenticationRejection(checkedAt: today))
        clock = today.addingTimeInterval(300)
        let empty = await E.observe("MSFT", now: today, key: "fixture-only", revision: nil,
            defaults: defaults, allowed: { true }, clock: { clock }, transport: transport)
        #expect(requests == 2 && empty.outcome == .answered(nil))
        #expect(empty.checkedAt == clock && empty.recordedAt == clock && empty.notRequestedReason == nil)
    }

    @MainActor @Test func observationPreservesActualAttemptOnFailureAndWithholdsAfterAccessChange() async throws {
        let name = "provider.earnings.receipt-failure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for failure in ["transport", "malformed", "policy", "credential"] {
            defaults.set("A", forKey: "stocksage.massive.credentialRevision")
            var allowed = true
            var requests = 0
            let result = await E.observe("AAPL", now: today, key: "fixture-only", revision: "A",
                defaults: defaults, allowed: { allowed }, clock: { self.today }, transport: { req in
                    requests += 1
                    if failure == "transport" { throw URLError(.notConnectedToInternet) }
                    if failure == "policy" { allowed = false }
                    if failure == "credential" { defaults.set("B", forKey: "stocksage.massive.credentialRevision") }
                    let body = failure == "malformed" ? "{}" : #"{"status":"OK","results":[]}"#
                    return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            #expect(requests == 1 && result.outcome == .unavailable && result.checkedAt == today)
            #expect(result.recordedAt == today && result.notRequestedReason == nil)
        }
    }

    @MainActor @Test func observationDoesNotInventProviderChecksWhenAdmissionFails() async throws {
        let name = "provider.earnings.receipt-admission.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        for policy in [false, true] {
            let result = await E.observe("AAPL", now: today, key: "", revision: nil,
                defaults: defaults, allowed: { policy }, clock: { self.today }, transport: { req in
                    requests += 1
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            #expect(result.outcome == .notRequested && result.checkedAt == nil && result.recordedAt == today)
            #expect(result.notRequestedReason == (policy ? .requestUnavailable : .externalAccessDisabled))
        }
        #expect(requests == 0)
    }

    @MainActor @Test func cancellationReceiptsDistinguishBeforeAndAfterTransport() async throws {
        let name = "provider.earnings.receipt-cancellation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for before in [true, false] {
            var requests = 0
            let task = Task { @MainActor in
                if before { withUnsafeCurrentTask { $0?.cancel() } }
                return await E.observe("AAPL", now: self.today, key: "fixture-only", revision: nil,
                    defaults: defaults, allowed: { true }, clock: { self.today }, transport: { req in
                        requests += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        return (Data(#"{"status":"OK","results":[]}"#.utf8),
                            HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    })
            }
            let result = await task.value
            #expect(requests == (before ? 0 : 1))
            #expect(result.outcome == (before ? .notRequested : .unavailable))
            #expect(result.checkedAt == (before ? nil : today))
            #expect(result.notRequestedReason == (before ? .cancelled : nil))
        }
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
