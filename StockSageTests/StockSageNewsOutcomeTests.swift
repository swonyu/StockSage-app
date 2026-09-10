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
        case .benzinga: nil // Dedicated stage is always injected as a Page, never live.
        case .massive: N.massiveRequest(symbol: "AAPL", key: "fixture-only", now: now)
        }
    }
    private func response(_ req: URLRequest, _ status: Int, _ body: Data) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    @Test("Generic news failure dispatches only the retained Massive transport")
    func genericFailureDispatchesOnlyMassive() async {
        var hosts: [String] = []
        let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request,
            transport: { req in
                hosts.append(req.url?.host ?? "")
                return response(req, 503, Data())
            })
        #expect(hosts == ["api.massive.com"])
        #expect(result.items.isEmpty)
        #expect(result.attempts.map(\.provider) == [.massive])
        #expect(result.attempts.map(\.status) == [.unavailable(.http)])
    }

    @Test("Missing Massive news remains unavailable without admitting another provider stage")
    func missingMassiveNewsStaysUnavailable() async {
        var requested: [N.Provider] = []
        let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: { provider in
            requested.append(provider)
            return nil
        }, transport: { _ in
            Issue.record("missing request must not reach transport")
            throw URLError(.badURL)
        })
        #expect(requested == [.massive])
        #expect(result.attempts.map(\.status) == [.notChecked(.missingKey)])
        #expect(result.items.isEmpty)
    }

    @Test("Failed Massive news remains unavailable without admitting another provider stage")
    func failedMassiveNewsStaysUnavailable() async {
        var requested: [N.Provider] = []
        var transports = 0
        let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: { provider in
            requested.append(provider)
            return URLRequest(url: URL(string: "https://example.invalid/news")!)
        }, transport: { _ in
            transports += 1
            throw URLError(.notConnectedToInternet)
        })
        #expect(requested == [.massive])
        #expect(transports == 1)
        #expect(result.attempts.map(\.status) == [.unavailable(.transport)])
        #expect(result.items.isEmpty)
    }
    @Test("HTTP failure differs from answered empty at actual transport boundary")
    func httpVersusEmpty() async throws {
        for status in [200, 503] {
            var calls = 0
            let empty = try data(["status": "OK", "results": []])
            let result = await N.observe(for: "AAPL", now: now, allowed: { true }, clock: { now }, request: request) { req in
                calls += 1
                return response(req, status, empty)
            }
            #expect(calls == 1 && result.items.isEmpty)
            #expect(result.attempts.map(\.provider) == [.massive])
            #expect(result.attempts.first?.status == (status == 200 ? .answered : .unavailable(.http)))
            #expect(result.summary.contains(status == 200 ? "answered; selected 0" : "unavailable (http)"))
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
        #expect(missing.attempts.map(\.status) == [.notChecked(.missingKey)])
    }
    @Test("Policy revoked across the generic transport discards late news")
    func revokedAfterAwait() async throws {
        var permitted = true
        var calls = 0
        let article = try data(["status": "OK", "results": [row()]])
        let result = await N.observe(for: "AAPL", now: now, allowed: { permitted }, clock: { now }, request: request) { req in
            calls += 1
            await Task.yield()
            permitted = false
            return response(req, 200, article)
        }
        #expect(calls == 1 && result.items.isEmpty)
        #expect(result.attempts.map(\.status) == [.unavailable(.policyDenied)])
    }
    @Test("Cancellation after transport returns no evidence")
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
        #expect(result.attempts.count == 1 && result.attempts[0].status == .unavailable(.transport))
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
    @Test("Withholding after collection preserves the answered attempt provenance")
    func withholdingAfterCollectionPreservesAttemptProvenance() throws {
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
    @Test("Explicit legacy news provenance survives citation conversion")
    func legacyNewsProvenance() {
        let item = N.NewsItem(date: now, title: "Historical fixture", snippet: "Attributed excerpt",
                              link: nil, sentiment: nil, source: "EODHD news")
        #expect(StockSageCatalystNarrator.CitedSource(news: item).source == "EODHD news")
        let snapshot = StockSageChat.addingResearch(to: .init(at: now, facts: [], context: "Fixture"),
            symbol: "AAPL", news: [item], leads: nil, webAllowed: true)
        #expect(snapshot.sources?.first?.attribution == "EODHD news")
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

    typealias B = StockSageBenzinga
    private func benzingaRecord(_ revision: String = "one", published: String = "2026-08-31T23:59:59.123456789Z",
                                symbol: String = "AAPL", excerpt: String? = nil) -> B.Record {
        .init(id: "news:42:" + revision, vendorID: "42", revision: revision, product: .news,
              symbol: symbol, source: "Benzinga via Massive", date: nil, time: nil, timeZone: nil,
              published: published, lastUpdated: "2026-09-01T00:00:00Z", headline: "Guidance update",
              details: [], excerpt: excerpt, bullCase: nil, bearCase: nil,
              link: URL(string: "https://example.com/story"), analystIDs: [], firmIDs: [], ratingIDs: [])
    }
    private func benzingaPage(_ status: B.Status = .answered, records: [B.Record] = [],
                              excluded: Int = 0, more: Bool = false, symbol: String = "AAPL") -> B.Page {
        .init(query: .init(product: .news, subject: symbol, from: nil, through: nil),
              checkedAt: now.addingTimeInterval(-10), credentialGeneration: "opaque-fixture",
              status: status, records: records, excludedCount: excluded, hasMore: more)
    }

    @Test("Captured Benzinga page is reused unchanged, including empty and failed pages")
    func benzingaCapturedPageReuse() async throws {
        for page in [benzingaPage(records: [benzingaRecord()]), benzingaPage(),
                     benzingaPage(.unavailable(.unauthorized))] {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(page)
            var loads = 0, transports = 0
            let result = await N.observe(for: "AAPL", now: now, benzingaPage: page,
                loadBenzinga: { loads += 1; return benzingaPage() },
                isCurrent: { $0 == "opaque-fixture" }, allowed: { true }, clock: { now }, request: request,
                transport: { req in
                    transports += 1; return response(req, 200, Data(#"{"results":[]}"#.utf8))
                })
            #expect(loads == 0 && transports == (page.records.isEmpty ? 1 : 0))
            #expect(result.attempts.map(\.provider) == (page.records.isEmpty ? [.benzinga, .massive] : [.benzinga]))
            #expect(result.attempts.first?.checkedAt == page.checkedAt)
            #expect(try encoder.encode(page) == before)
            if !page.records.isEmpty { #expect(result.items.count == 1) }
        }
    }

    @Test("Dedicated news precedes generic fallback and preserves partial usable evidence")
    func benzingaOrderedFallback() async throws {
        for partial in [false, true] {
            var order: [N.Provider] = []
            let page = benzingaPage(partial ? .partial : .answered,
                                    records: partial ? [benzingaRecord()] : [], excluded: partial ? 2 : 0, more: partial)
            let result = await N.observe(for: "AAPL", now: now,
                loadBenzinga: { order.append(.benzinga); await Task.yield(); return page },
                isCurrent: { $0 == "opaque-fixture" }, allowed: { true }, clock: { now }, request: request,
                transport: { req in
                    order.append(.massive); return response(req, 200, try data(["results": [row()]]))
                })
            #expect(order == (partial ? [.benzinga] : [.benzinga, .massive]))
            #expect(result.items.count == 1)
            #expect(result.attempts.first?.status == (partial ? .partial : .answered))
            if partial { #expect(result.summary.contains("partial") && result.summary.contains("provider excluded 2")) }
        }
    }

    @Test("Benzinga normalization retains headline-only publication/update and material revisions")
    func benzingaNormalization() throws {
        let original = benzingaRecord()
        let changed = benzingaRecord("two")
        let page = benzingaPage(records: [original, original, changed])
        let attempt = N.benzingaAttempt(page, symbol: "AAPL", now: now)
        #expect(attempt.status == .answered && attempt.items.count == 2)
        #expect(Set(attempt.items.map(\.id)).count == 2)
        let item = try #require(attempt.items.first)
        #expect(item.snippet.isEmpty && item.sentiment == nil && item.insight == nil)
        #expect(item.publicationTime == original.published && item.updatedTime == original.lastUpdated)
        #expect(item.date != page.checkedAt && item.source.contains("Benzinga"))
        #expect(StockSageCatalystNarrator.sourceDate(.init(news: item)) == original.published)
        let context = StockSageChat.addingResearch(to: .init(at: now, facts: [], context: "fixture"),
            symbol: "AAPL", observation: .init(attempts: [attempt]), leads: nil, webAllowed: true)
        #expect(context.facts.isEmpty && context.sources?.count == 2)
    }

    @Test("Benzinga exact publication and identity boundaries never fabricate empty coverage")
    func benzingaPublicationBounds() {
        let page = benzingaPage(records: [
            benzingaRecord("valid", published: "2026-09-01T02:59:59.123456+03:00"),
            benzingaRecord("boundary", published: "2026-08-25T00:00:00Z"),
            benzingaRecord("future", published: "2026-09-01T00:00:00.000000001Z"),
            benzingaRecord("old", published: "2026-08-24T23:59:59Z"),
            benzingaRecord("bad", published: "not a date"),
            benzingaRecord("wrong-symbol", symbol: "MSFT")])
        let attempt = N.benzingaAttempt(page, symbol: "AAPL", now: now)
        #expect(attempt.items.count == 2 && attempt.status == .partial)
        #expect(attempt.excluded.future == 1 && attempt.excluded.stale == 1)
        #expect(attempt.excluded.missingDate == 1 && attempt.excluded.invalid == 1)
        #expect(N.benzingaAttempt(benzingaPage(symbol: "MSFT"), symbol: "AAPL", now: now).status == .unavailable(.malformed))
    }

    @Test("Dedicated failure categories and generic HTTP failures remain distinct")
    func benzingaFailureCategories() async {
        let cases: [(B.Failure, N.Failure)] = [
            (.unauthorized, .unauthorized), (.entitlement, .entitlement), (.throttled, .throttled),
            (.transport, .transport), (.timedOut, .timedOut), (.malformed, .malformed),
            (.oversized, .oversized), (.obsoleteCredential, .obsoleteCredential)]
        for (failure, expected) in cases {
            #expect(N.benzingaAttempt(benzingaPage(.unavailable(failure)), symbol: "AAPL", now: now).status == .unavailable(expected))
        }
        #expect(N.benzingaAttempt(benzingaPage(), symbol: "AAPL", now: now).status == .answered)
        for (code, expected) in [(401, N.Failure.unauthorized), (402, .entitlement),
                                 (403, .entitlement), (429, .throttled), (503, .http)] {
            let result = await N.observe(for: "AAPL", now: now, benzingaPage: benzingaPage(),
                isCurrent: { $0 == "opaque-fixture" }, allowed: { true }, clock: { now },
                request: request,
                transport: { req in response(req, code, Data("private server body".utf8)) })
            #expect(result.attempts.count == 2 && result.attempts[1].status == .unavailable(expected))
            #expect(!result.summary.contains("private server body"))
        }
    }

    @Test("Opaque generation change across either await withholds late news and aborts fallback")
    func benzingaGenerationRevoked() async throws {
        for duringDedicated in [true, false] {
            var current = "opaque-fixture", calls = 0
            let result = await N.observe(for: "AAPL", now: now,
                loadBenzinga: {
                    calls += 1; await Task.yield()
                    if duringDedicated { current = "replacement-epoch" }
                    return benzingaPage(records: duringDedicated ? [benzingaRecord()] : [])
                }, isCurrent: { $0 == current }, allowed: { true }, clock: { now }, request: request,
                transport: { req in
                    calls += 1; await Task.yield(); current = "replacement-epoch"
                    return response(req, 200, try data(["results": [row()]]))
                })
            #expect(calls == (duringDedicated ? 1 : 2) && result.items.isEmpty)
            #expect(result.attempts.last?.status == .unavailable(.obsoleteCredential))
        }
    }

    @Test("Captured obsolete generation and denied access never dispatch or refetch")
    func benzingaBeforeDispatch() async {
        for permitted in [false, true] {
            var calls = 0
            let result = await N.observe(for: "AAPL", now: now,
                benzingaPage: benzingaPage(records: [benzingaRecord()]),
                loadBenzinga: { calls += 1; return benzingaPage() }, isCurrent: { _ in false },
                allowed: { permitted }, clock: { now }, request: { _ in calls += 1; return nil },
                transport: { _ in calls += 1; throw URLError(.badURL) })
            #expect(calls == 0 && result.items.isEmpty)
            #expect(result.attempts.first?.status == .notChecked(permitted ? .obsoleteCredential : .policyDenied))
        }
    }

    @Test("Cancellation during dedicated acquisition never admits generic transport")
    func benzingaCancellation() async {
        let result = await Task {
            await N.observe(for: "AAPL", now: now, loadBenzinga: {
                withUnsafeCurrentTask { $0?.cancel() }; await Task.yield()
                return benzingaPage(records: [benzingaRecord()])
            }, isCurrent: { _ in true }, allowed: { true }, clock: { now },
            request: { _ in Issue.record("unexpected fallback"); return nil },
            transport: { _ in Issue.record("unexpected transport"); throw URLError(.badURL) })
        }.value
        #expect(result.attempts.count == 1 && result.items.isEmpty)
        #expect(result.attempts.first?.status == .unavailable(.cancelled))
    }

    @Test("Typed generic transport failures retain provider status")
    func benzingaTypedGenericTransportFailures() async {
        let cases: [(B.Failure, N.Failure)] = [
            (.unauthorized, .unauthorized), (.throttled, .throttled),
            (.timedOut, .timedOut), (.obsoleteCredential, .obsoleteCredential),
            (.policyDenied, .policyDenied)]
        for (failure, expected) in cases {
            var requested: [N.Provider] = []
            var transports = 0
            let result = await N.observe(for: "AAPL", now: now, benzingaPage: benzingaPage(),
                isCurrent: { _ in true }, allowed: { true }, clock: { now }, request: { provider in
                    requested.append(provider)
                    return request(provider)
                }, transport: { _ in
                    transports += 1
                    throw failure
                })
            #expect(transports == 1 && result.items.isEmpty)
            #expect(requested == [.massive])
            #expect(result.attempts.map(\.provider) == [.benzinga, .massive])
            #expect(result.attempts[0].status == .answered)
            #expect(result.attempts[1].status == .unavailable(expected))
            #expect(result.summary.contains("Massive: unavailable (\(expected.rawValue))"))
        }
    }

    @Test("Shared news cutoff retains the seven-day boundary despite a later provider check")
    func benzingaSharedCutoffRetainsBoundaryWithoutFallback() async throws {
        let newsAt = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        let published = "2026-09-03T12:00:00Z"
        var clock = newsAt, dedicatedCalls = 0
        let client = StockSageBenzingaClient(key: { "synthetic" }, revision: { nil },
            allowed: { true }, now: { clock }, transport: { req in
                var rows: [[String: Any]] = []
                if req.url?.path == "/benzinga/v2/news" {
                    dedicatedCalls += 1
                    clock = newsAt.addingTimeInterval(1)
                    rows = [["benzinga_id": 1, "tickers": ["AAPL"], "title": "Boundary headline",
                             "author": "Fixture", "published": published, "last_updated": published,
                             "url": "https://example.invalid/fixture"]]
                }
                return self.response(req, 200, try self.data(["status": "OK", "results": rows]))
            })
        let snapshot = await client.snapshot(for: "AAPL", now: newsAt)
        let page = try #require(snapshot.pages.first { $0.query.product == .news })
        #expect(page.records.count == 1 && page.checkedAt > newsAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let captured = try encoder.encode(snapshot)
        var refetches = 0, fallbackRequests = 0, fallbackTransports = 0
        let observation = await N.observe(for: "AAPL", limit: 3, now: newsAt, benzingaPage: page,
            loadBenzinga: { refetches += 1; return page }, isCurrent: { client.isCurrent($0) },
            allowed: { true }, clock: { clock }, request: { provider in
                fallbackRequests += 1
                return provider == .massive ? N.massiveRequest(symbol: "AAPL", key: "synthetic", now: newsAt) : nil
            }, transport: { req in
                fallbackTransports += 1
                return response(req, 200, Data(#"{"status":"OK","results":[]}"#.utf8))
            })
        #expect(dedicatedCalls == 1 && refetches == 0 && fallbackRequests == 0 && fallbackTransports == 0)
        #expect(observation.attempts.map(\.provider) == [.benzinga] && observation.items.count == 1)
        #expect(observation.attempts.first?.status == .answered && observation.attempts.first?.checkedAt == page.checkedAt)
        #expect(observation.items.first?.publicationTime == published && observation.items.first?.updatedTime == published)
        #expect(try encoder.encode(snapshot) == captured)
    }
}
