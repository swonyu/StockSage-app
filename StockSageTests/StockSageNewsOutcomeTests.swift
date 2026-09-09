import Foundation
import Testing
@testable import StockSage

@MainActor @Suite("News observation boundaries")
struct StockSageNewsOutcomeTests {
    typealias N = StockSageNewsService
    let now = Date(timeIntervalSince1970: 1_788_220_800)
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func row(_ title: String = "Guidance update", date: String = "2026-08-31T23:59:59.123Z") -> [String: Any] {
        ["title": title, "published_utc": date, "tickers": ["AAPL"], "description": "Revenue rose 12%.",
         "publisher": ["name": "Fixture"], "article_url": "https://example.com/story"]
    }
    private func request(_ provider: N.Provider) -> URLRequest? {
        switch provider {
        case .massive: N.massiveRequest(symbol: "AAPL", key: "fixture-only", now: now)
        case .eodhd: N.eodhdRequest(symbol: "AAPL", key: "fixture-only", limit: 5)
        }
    }
    private func response(_ req: URLRequest, _ status: Int, _ body: Data) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    @Test("HTTP failure differs from answered empty at actual transport boundary")
    func httpVersusEmpty() async throws {
        for status in [200, 503] {
            var calls = 0
            let empty = try data(["status": "OK", "results": []])
            let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
                calls += 1
                return response(req, status, calls == 1 ? empty : Data("[]".utf8))
            }
            #expect(calls == 2 && result.items.isEmpty)
            #expect(result.attempts.map(\.provider) == [.massive, .eodhd])
            #expect(result.attempts.first?.status == (status == 200 ? .answered : .unavailable(.http)))
            #expect(result.summary.contains(status == 200 ? "answered; selected 0" : "unavailable (http)"))
        }
    }
    @Test("Empty primary retains provenance with fallback success or failure")
    func emptyFallback() async throws {
        for success in [true, false] {
            var calls = 0
            let empty = try data(["status": "OK", "results": []])
            let fallback = try data([["title": "Fallback story", "date": "2026-08-31T20:00:00-03:00"]])
            let checked = now.addingTimeInterval(2)
            let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { checked }, request: request) { req in
                calls += 1
                return response(req, calls == 2 && !success ? 500 : 200, calls == 1 ? empty : fallback)
            }
            #expect(calls == 2 && result.attempts[0].status == .answered)
            #expect(result.attempts[1].status == (success ? .answered : .unavailable(.http)))
            #expect(result.items.count == (success ? 1 : 0))
            #expect(result.attempts.allSatisfy { $0.checkedAt == checked })
            #expect(result.summary.contains("Massive:") && result.summary.contains("EODHD:"))
            if success {
                #expect(result.items[0].source == "EODHD news")
                #expect(N.instant(result.items[0].date) == "2026-08-31T23:00:00.000Z")
                #expect(result.items[0].date != checked)
            }
        }
    }
    @Test("Usable primary stops after one request and returns attributed story")
    func primarySuccess() async throws {
        var calls = 0
        let body = try data(["status": "OK", "results": [row()]])
        let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
            calls += 1; return response(req, 200, body)
        }
        #expect(calls == 1 && result.attempts.count == 1 && result.items.count == 1)
        let line = StockSageCatalystNarrator.sourceLine(number: 1, source: .init(news: result.items[0]))
        #expect(line.contains("2026-08-31T23:59:59.123Z Massive news · Fixture"))
    }
    @Test("No access or unsupported request never builds a credential-bearing request")
    func notChecked() async {
        for (symbol, allowed, reason) in [("AAPL", false, N.Failure.policyDenied), ("2222.SR", true, .unsupported)] {
            var calls = 0
            let result = await N.observe(for: symbol, now: now, allowed: { allowed }, clock: { now }, request: { _ in
                calls += 1; return nil
            }, transport: { _ in calls += 1; throw URLError(.notConnectedToInternet) })
            #expect(calls == 0 && result.attempts[0].status == .notChecked(reason))
            #expect(result.summary.contains("not checked") && result.summary.contains("recorded"))
        }
        let missing = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: { _ in nil },
            transport: { _ in Issue.record("unexpected network"); throw URLError(.badURL) })
        #expect(missing.attempts.count == 2 && missing.attempts.allSatisfy { $0.status == .notChecked(.missingKey) })
    }
    @Test("Policy revoked across either await discards late news and stops fallback")
    func revokedAfterAwait() async throws {
        for revokeOn in [1, 2] {
            var permitted = true
            var calls = 0
            let empty = try data(["status": "OK", "results": []])
            let article = try data(["status": "OK", "results": [row()]])
            let fallback = try data([["title": "Late story", "date": "2026-08-31T23:00:00Z"]])
            let result = await N.observe(for: "AAPL", now: now, allowed: { permitted }, clock: { now }, request: request) { req in
                calls += 1
                await Task.yield()
                if calls == revokeOn { permitted = false }
                return response(req, 200, calls == 1 ? (revokeOn == 1 ? article : empty) : fallback)
            }
            #expect(calls == revokeOn && result.items.isEmpty)
            #expect(result.attempts.last?.status == .unavailable(.policyDenied))
        }
    }
    @Test("Cancellation after transport returns no evidence and never starts fallback")
    func cancellation() async throws {
        let body = try data(["status": "OK", "results": [row()]])
        let task = Task {
            await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
                withUnsafeCurrentTask { $0?.cancel() }
                await Task.yield()
                return response(req, 200, body)
            }
        }
        let result = await task.value
        #expect(result.items.isEmpty && result.attempts.count == 1)
        #expect(result.attempts[0].status == .unavailable(.cancelled))
    }
    @Test("Transport throws safe failure class without error text")
    func transportFailure() async {
        let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { _ in
            throw NSError(domain: "must-never-appear", code: 123)
        }
        #expect(result.attempts.count == 2 && result.attempts.allSatisfy { $0.status == .unavailable(.transport) })
        #expect(!result.summary.contains("must-never-appear"))
    }
    @Test("Malformed and oversized bodies are unavailable, valid excluded rows are answered")
    func parserOutcomes() throws {
        for (body, failure) in [(Data("{}".utf8), N.Failure.malformed), (Data(repeating: 32, count: 2_000_001), .oversized)] {
            #expect(N.parseObservation(body, provider: .massive, symbol: "AAPL", now: now, checkedAt: now).status == .unavailable(failure))
        }
        let oversized = try data(["results": Array(repeating: row(), count: 1_001)])
        #expect(N.parseObservation(oversized, provider: .massive, symbol: "AAPL", now: now, checkedAt: now).status == .unavailable(.oversized))
        let body = try data(["results": [row(date: "2026-08-24T23:59:59Z"), row(date: "2026-09-01T00:00:00.001Z"),
                                         row(date: "bad"), row(""), row(date: "2026-08-25T00:00:00Z")]])
        let parsed = N.parseObservation(body, provider: .massive, symbol: "AAPL", now: now, checkedAt: now)
        #expect(parsed.status == .answered && parsed.items.count == 1)
        #expect(parsed.excluded == .init(stale: 1, future: 1, missingDate: 1, invalid: 1))
        let summary = N.Observation(attempts: [parsed]).summary
        #expect(summary.contains("stale 1, future 1, missing/invalid date 1, other invalid 1"))
    }
    @Test("Exact duplicates collapse; revisions, opposite numbers and publishers survive")
    func revisions() throws {
        let original = row()
        var changed = original; changed["description"] = "Revenue fell -12%."
        var publisher = original; publisher["publisher"] = ["name": "Other Fixture"]
        var longA = original; longA["description"] = String(repeating: "Detail ", count: 100) + "rose 12%"
        var longB = longA; longB["description"] = String(repeating: "Detail ", count: 100) + "fell -12%"
        let items = N.parseMassiveNews(try data(["results": [original, original, changed, publisher, longA, longB]]), symbol: "AAPL", now: now)
        #expect(items.count == 5 && Set(items.map(\.id)).count == 5)
    }
    @Test("Invalid bounds and permission revoked during request construction stop transport")
    func beforeTransport() async {
        for days in [Double.nan, -1, 8] {
            let result = await N.observe(for: "AAPL", maxAgeDays: days, now: now, allowed: { true }, clock: { now },
                request: { _ in Issue.record("request should not be built"); return nil },
                transport: { _ in Issue.record("unexpected transport"); throw URLError(.badURL) })
            #expect(result.attempts.first?.status == .notChecked(.invalidBounds))
        }
        var permitted = true
        let result = await N.observe(for: "AAPL", now: now, allowed: { permitted }, clock: { now }, request: { provider in
            permitted = false; return request(provider)
        }, transport: { _ in Issue.record("unexpected transport"); throw URLError(.badURL) })
        #expect(result.attempts.count == 1 && result.attempts[0].status == .notChecked(.policyDenied))
    }
    @Test("Fallback malformed and excluded responses keep primary failure and safe counts")
    func fallbackParser() async throws {
        for malformed in [true, false] {
            var calls = 0
            let body = malformed ? Data("{}".utf8) : try data([
                ["title": "Missing date"], ["title": "Future", "date": "2026-09-01T00:00:01Z"],
                ["title": "Old", "date": "2026-08-24T23:59:59Z"]])
            let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
                calls += 1; return response(req, calls == 1 ? 503 : 200, body)
            }
            #expect(calls == 2 && result.items.isEmpty && result.attempts[0].status == .unavailable(.http))
            #expect(result.attempts[1].status == (malformed ? .unavailable(.malformed) : .answered))
            if !malformed { #expect(result.attempts[1].excluded == .init(stale: 1, future: 1, missingDate: 1)) }
        }
    }
    @Test("Cancellation on fallback and withholding after collection preserve primary provenance")
    func fallbackCancellationAndWithholding() async throws {
        let task = Task {
            var calls = 0
            return await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
                calls += 1
                if calls == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                return response(req, 200, calls == 1 ? Data(#"{"results":[]}"#.utf8) : Data("[]".utf8))
            }
        }
        let result = await task.value
        #expect(result.attempts.count == 2 && result.items.isEmpty)
        #expect(result.attempts[0].status == .answered && result.attempts[1].status == .unavailable(.cancelled))
        let attempt = N.parseObservation(try data(["results": [row()]]), provider: .massive, symbol: "AAPL", now: now, checkedAt: now)
        var withheld = N.Observation(attempts: [attempt]); withheld.withholdingReason = .policyDenied
        #expect(withheld.items.isEmpty && withheld.attempts[0].status == .answered)
        #expect(withheld.summary.contains("Evidence withheld (external access off)"))
    }
    @Test("Original publication timezone and subseconds survive citation and Chat JSON")
    func exactPublication() throws {
        let rawTime = "2026-09-01T02:59:59.123456+03:00"
        let body = try data(["results": [row(date: rawTime)]])
        let parsed = N.parseObservation(body, provider: .massive, symbol: "AAPL", now: now, checkedAt: now)
        let item = try #require(parsed.items.first)
        #expect(item.publicationTime == rawTime)
        for future in ["2026-09-01T00:00:00.000001Z", "2026-09-01T00:00:00.000000001Z"] {
            let excluded = N.parseObservation(try data(["results": [row(date: future)]]), provider: .massive, symbol: "AAPL", now: now, checkedAt: now)
            #expect(excluded.items.isEmpty && excluded.excluded.future == 1)
        }
        #expect(StockSageCatalystNarrator.sourceDate(.init(news: item)) == rawTime)
        let snapshot = StockSageChat.addingResearch(to: .init(at: now, facts: [], context: "Fixture"), symbol: "AAPL",
            observation: .init(attempts: [parsed]), leads: nil, webAllowed: true)
        #expect(snapshot.sources?.first?.publicationTime == rawTime)
        #expect(StockSageChat.prompt(question: "AAPL?", snapshot: snapshot, history: [])?.contains(rawTime) == true)
        #expect(N.parseMassiveNews(try data(["results": [row(date: rawTime + " instructions")]]), symbol: "AAPL", now: now).isEmpty)
        let dayOnly = StockSageCatalystNarrator.CitedSource(date: now, source: "SEC", title: "Filing", snippet: "", link: nil)
        #expect(StockSageCatalystNarrator.sourceDate(dayOnly) == "2026-09-01")
    }
    @Test("Typed outcome reaches bounded Chat status without becoming a fact or source")
    func chatPresentation() throws {
        let base = StockSageChat.Snapshot(at: now, facts: [], context: "Fixture")
        let failure = N.Observation(attempts: [.init(provider: .massive, checkedAt: now, status: .unavailable(.http))])
        let result = StockSageChat.addingResearch(to: base, symbol: "AAPL", observation: failure, leads: nil, webAllowed: true)
        #expect(result.facts.isEmpty && result.sources?.isEmpty == true)
        #expect(result.researchStatus?.contains("Massive: unavailable (http)") == true)
        let body = try data(["results": (0..<10).map { row("Story \($0)") }])
        let parsed = N.parseObservation(body, provider: .massive, symbol: "AAPL", now: now, checkedAt: now)
        let enriched = StockSageChat.addingResearch(to: base, symbol: "AAPL", observation: .init(attempts: [parsed]), leads: nil, webAllowed: true)
        #expect(parsed.items.count == 5 && enriched.sources?.count == 3 && enriched.facts == base.facts)
        #expect(enriched.sources?.allSatisfy { $0.excerpt.count <= 400 } == true)
        let revoked = StockSageChat.addingResearch(to: base, symbol: "AAPL", observation: .init(attempts: [parsed]), leads: nil, webAllowed: false)
        #expect(revoked.sources?.isEmpty == true && revoked.researchStatus?.contains("withheld") == true)
        // Existing persisted snapshot shape, with no newly required fields.
        let old = try JSONDecoder().decode(StockSageChat.Snapshot.self, from: Data(#"{"at":0,"facts":[],"context":"old"}"#.utf8))
        #expect(old.sources == nil && old.researchStatus == nil)
        #expect(try JSONDecoder().decode(StockSageChat.Snapshot.self, from: JSONEncoder().encode(enriched)) == enriched)
    }
}
