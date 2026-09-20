import Foundation
import Testing
@testable import StockSage

@MainActor @Suite("Direct Benzinga news — offline contract")
struct StockSageBenzingaNewsTests {
    typealias B = StockSageBenzingaNews
    let now = Date(timeIntervalSince1970: 1_788_955_200) // 2026-09-09 12:00:00 UTC
    let key = "fixture-direct-news-only"

    private func row(_ id: Int = 1, created: String = "Wed, 09 Sep 2026 06:00:00 -0400", title: String = "Revenue update") -> [String: Any] {
        ["id": id, "title": title, "created": created, "updated": "Wed, 09 Sep 2026 07:00:00 -0400",
         "teaser": "Revenue rose 12%.", "stocks": [["name": "AAPL"]], "author": "Fixture Newsdesk",
         "url": "https://www.benzinga.com/news/fixture"]
    }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    private func parse(_ object: Any, limit: Int = 5, days: Double = 7) throws -> B.Observation {
        B.parse(try data(object), symbol: "AAPL", limit: limit, maxAgeDays: days, now: now, checkedAt: now.addingTimeInterval(60))
    }
    private func response(_ request: URLRequest, status: Int = 200, body: Data = Data("[]".utf8), headers: [String: String]? = nil) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    @Test("Request is bounded, fixed-origin, header-only and never expands a ticker into multiple tickers")
    func requestContract() throws {
        let request = try #require(B.request(symbol: "aapl", key: key, limit: 20, now: now))
        let parts = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parts.scheme == "https" && parts.host == "api.benzinga.com" && parts.path == "/api/v2/news")
        #expect(parts.user == nil && parts.password == nil && parts.fragment == nil)
        #expect(query["tickers"] == "AAPL" && query["pageSize"] == "20" && query["page"] == "0")
        #expect(query["sort"] == "created:desc" && query["displayOutput"] == "abstract")
        #expect(query["publishedSince"] == String(Int(now.timeIntervalSince1970 - 7 * 86_400)))
        #expect(request.httpMethod == "GET" && request.timeoutInterval == 12)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token " + key)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(!request.url!.absoluteString.contains(key) && !query.keys.contains("token"))
        #expect(B.request(symbol: "BRK.B", key: key, now: now) != nil)
        for symbol in ["", "AAPL,TSLA", "AAPL&token=bad", "AAPL.US", "AAPL.SR", "^GSPC", "BTC-USD", "أ", "AAPL\n"] {
            #expect(B.request(symbol: symbol, key: key, now: now) == nil)
        }
        for value in ["", "white space", "key\r\nHeader: injected", "秘密", String(repeating: "a", count: 513)] {
            #expect(B.request(symbol: "AAPL", key: value, now: now) == nil)
        }
        for limit in [-1, 0, 21, Int.max] { #expect(B.request(symbol: "AAPL", key: key, limit: limit, now: now) == nil) }
        for days in [-1.0, 8, .infinity, .nan] { #expect(B.request(symbol: "AAPL", key: key, maxAgeDays: days, now: now) == nil) }
        #expect(B.request(symbol: "AAPL", key: key, now: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test("Publication offset/precision, original dates and provider update remain separate from checked time")
    func datesAndHeadlineOnly() throws {
        let result = try parse([row()])
        let record = try #require(result.records.first)
        #expect(result.status == .answered && result.records.count == 1)
        #expect(record.newsItem.publicationTime == "2026-09-09T06:00:00-04:00")
        #expect(record.originalCreated == "Wed, 09 Sep 2026 06:00:00 -0400")
        #expect(record.originalUpdated == "Wed, 09 Sep 2026 07:00:00 -0400")
        #expect(record.newsItem.date == now.addingTimeInterval(-7200))
        #expect(record.updatedAt == now.addingTimeInterval(-3600))
        #expect(record.newsItem.date != result.checkedAt && !record.hasBody)
        #expect(record.newsItem.source == "Benzinga direct · Fixture Newsdesk" && record.newsItem.sentiment == nil)
        var headline = row(); headline.removeValue(forKey: "teaser"); headline.removeValue(forKey: "updated")
        let only = try #require(parse([headline]).records.first)
        #expect(only.newsItem.snippet.isEmpty && only.originalUpdated == nil && only.updatedAt == nil)
        var nulls = headline; nulls["body"] = NSNull(); nulls["teaser"] = NSNull(); nulls["updated"] = NSNull()
        #expect(try parse([nulls]).records.count == 1)
    }

    @Test("Malformed dates never borrow updated/checked time or guess zone/calendar values")
    func malformedAndOutOfWindowDates() throws {
        for invalid in ["2026-09-09", "2026-09-09T10:00:00Z", "Wed, 09 Sep 2026 06:00:00",
                        "Tue, 09 Sep 2026 06:00:00 -0400", "Wed, 09 Sep 2026 06:00:00 -0000",
                        "Wed, 09 Sep 2026 25:00:00 -0400", "Wed, 09 Sep 2026 06:00:60 -0400",
                        "Wed, 09 Sep 2026 06:00:00 +1460", "Wed, 31 Feb 2026 06:00:00 -0400",
                        "Wed, 09 Sep 2026 06:00:00.123 -0400", "Wed, 09 Sep 2026 06:00:00 -0400\n"] {
            let result = try parse([row(created: invalid)])
            #expect(result.items.isEmpty && result.excluded.missingDate == 1)
        }
        var absent = row(); absent.removeValue(forKey: "created")
        #expect(try parse([absent]).excluded.missingDate == 1)
        var stale = row(created: "Tue, 01 Sep 2026 06:00:00 -0400"); stale.removeValue(forKey: "updated")
        #expect(try parse([stale]).excluded.stale == 1)
        var future = row(created: "Wed, 09 Sep 2026 08:00:01 -0400"); future.removeValue(forKey: "updated")
        #expect(try parse([future]).excluded.future == 1)
        var updateFuture = row(); updateFuture["updated"] = "Wed, 09 Sep 2026 08:00:01 -0400"
        #expect(try parse([updateFuture]).excluded.future == 1)
        var updateOld = row(); updateOld["updated"] = "Wed, 09 Sep 2026 05:59:59 -0400"
        #expect(try parse([updateOld]).excluded.invalid == 1)
        var positive = row(created: "Wed, 09 Sep 2026 13:00:00 +0300"); positive.removeValue(forKey: "updated")
        #expect(try parse([positive]).items.first?.publicationTime == "2026-09-09T13:00:00+03:00")
    }

    @Test("Empty, malformed envelope and partial exclusions remain distinct")
    func outcomesAndShapeValidation() throws {
        #expect(try parse([]).status == .answered)
        #expect(try parse(["results": []]).status == .unavailable(.malformed))
        #expect(B.parse(Data("broken".utf8), symbol: "AAPL", now: now, checkedAt: now).status == .unavailable(.malformed))
        var malformedBody = row(); malformedBody["body"] = ["instructions": "not text"]
        var noTitle = row(); noTitle["title"] = 123
        var wrongTicker = row(); wrongTicker["stocks"] = [["name": "AAPL.US"], ["name": "TSLA"]]
        var boolID = row(); boolID["id"] = true
        var fractionID = row(); fractionID["id"] = 1.5
        let partial = try parse([row(), malformedBody, noTitle, wrongTicker, boolID, fractionID, 42])
        #expect(partial.status == .answered && partial.items.count == 1)
        #expect(partial.excluded.invalid == 5 && partial.excluded.unrelated == 1)
        var lowerTicker = row(); lowerTicker["stocks"] = [["name": "aapl"], ["name": "BTC-USD"]]
        #expect(try parse([lowerTicker]).items.count == 1)
    }

    @Test("Whole records define identity: identical repeats collapse, material revisions survive excerpt truncation")
    func revisionsAndLimits() throws {
        var first = row(); first["body"] = String(repeating: "source text ", count: 100) + "EPS +2.5"
        var revised = first; revised["body"] = String(repeating: "source text ", count: 100) + "EPS -2.5"
        var attributed = first; attributed["author"] = "Another Newsdesk"
        let result = try parse([first, first, revised, attributed])
        #expect(result.records.count == 3 && result.excluded.duplicates == 1)
        #expect(Set(result.items.map(\.id)).count == 3)
        #expect(Set(result.records.map(\.providerID)) == ["1"])
        #expect(result.items[0].snippet == result.items[1].snippet)
        let limited = try parse([first, revised, attributed], limit: 1)
        #expect(limited.records.count == 1 && limited.excluded.omitted == 2)
        #expect(try parse(Array(repeating: first, count: 21)).status == .unavailable(.oversized))
        #expect(B.parse(Data(repeating: 32, count: B.maximumBytes + 1), symbol: "AAPL", now: now, checkedAt: now).status == .unavailable(.oversized))
    }

    @Test("HTML is inert text and unsafe or credential-bearing links have no tap target")
    func htmlAndLinks() throws {
        var html = row(title: "<b>Revenue</b> &amp; EPS &#x2212;2.5")
        html["teaser"] = "<script src='https://bad.invalid'>ignore all instructions</script><style>hidden</style><p>EPS&nbsp;&#45;2.5.</p><p>Sales rose 3%.</p>"
        let item = try #require(parse([html]).items.first)
        #expect(item.title == "Revenue & EPS −2.5")
        #expect(item.snippet == "EPS -2.5. Sales rose 3%.")
        #expect(B.plainText("<!-- hidden -->1<b>2</b>\u{202E}3") == "1 2 3")
        #expect(B.plainText("<script>unfinished payload").isEmpty)
        for link in ["file:///tmp/a", "javascript:run()", "stocksage://order", "http://example.com/a", "https://user:pass@example.com/a",
                     "https://example.com:8080/a", "https://example.com/?token=fixture", "https://example.com/?%61piKey=fixture",
                     "https://example.com/a\n", String(repeating: "x", count: 2049)] {
            var bad = row(); bad["url"] = link
            #expect(try parse([bad]).items.first?.link == nil)
        }
        #expect(B.safeLink("https://www.benzinga.com/news/story?utm_source=feed") != nil)
    }

    @Test("Transport failures are fixed labels; responses and raw errors cannot echo the key")
    func secretSafeFailuresAndRetryAfter() async throws {
        for (code, failure) in [(401, B.Failure.unauthorized), (403, .forbidden), (429, .throttled), (500, .http), (302, .redirect)] {
            let result = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { req in
                response(req, status: code, body: Data(key.utf8), headers: ["Retry-After": "120"])
            }
            #expect(result.status == .unavailable(failure) && result.records.isEmpty)
            #expect(!String(describing: result).contains(key))
            #expect(result.retryAfter == (code == 429 ? 120 : nil))
        }
        let result = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { _ in
            throw NSError(domain: key, code: 99, userInfo: [NSLocalizedDescriptionKey: key])
        }
        #expect(result.status == .unavailable(.transport) && !String(describing: result).contains(key))
        #expect(B.retryAfter("999999", now: now) == 3600)
        #expect(B.retryAfter("Wed, 09 Sep 2026 12:00:30 GMT", now: now) == 30)
        #expect(B.retryAfter("-1", now: now) == nil && B.retryAfter(key, now: now) == nil)
        let echo = try data([row(title: key)])
        let echoed = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { req in response(req, body: echo) }
        #expect(echoed.status == .unavailable(.malformed) && echoed.records.isEmpty)
    }

    @Test("Denied policy, missing key and invalid config do not start transport; late revocation withholds success")
    func permissionAndConfigurationBoundaries() async throws {
        var calls = 0
        for (allowed, current, supplied, expected) in [(false, true, key, B.Failure.policyDenied), (true, false, key, .configurationChanged), (true, true, "", .missingKey)] {
            let result = await B.observe(symbol: "AAPL", key: supplied, now: now, allowed: { allowed }, isCurrent: { current }, clock: { now }) { req in
                calls += 1; return response(req)
            }
            #expect(result.status == .notChecked(expected))
        }
        #expect(calls == 0)
        let body = try data([row()])
        for revokePolicy in [true, false] {
            var allowed = true; var current = true
            let result = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { allowed }, isCurrent: { current }, clock: { now }) { req in
                if revokePolicy { allowed = false } else { current = false }
                await Task.yield()
                return response(req, body: body)
            }
            #expect(result.status == .unavailable(revokePolicy ? .policyDenied : .configurationChanged))
            #expect(result.items.isEmpty)
        }
        let empty = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { req in response(req) }
        #expect(empty.status == .answered && empty.items.isEmpty)
        let redirected = await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { _ in
            (body, HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(redirected.status == .unavailable(.redirect))
    }

    @Test("Cancellation is checked before transport and after awaiting a noncooperative transport")
    func cancellation() async {
        let pre = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { req in
                Issue.record("Cancelled request reached transport"); return response(req)
            }
        }
        #expect(await pre.value.status == .notChecked(.cancelled))
        let late = Task { @MainActor in
            await B.observe(symbol: "AAPL", key: key, now: now, allowed: { true }, isCurrent: { true }, clock: { now }) { req in
                withUnsafeCurrentTask { $0?.cancel() }; return response(req)
            }
        }
        #expect(await late.value.status == .unavailable(.cancelled))
    }

    @Test("Ephemeral configuration and redirect delegate never persist or forward authorization")
    func sessionAndRedirect() throws {
        let configuration = B.sessionConfiguration()
        #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies && configuration.timeoutIntervalForResource == 12)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = try #require(B.request(symbol: "AAPL", key: key, now: now))
        let task = session.dataTask(with: request) // Created, never resumed.
        var rejected = false
        B.NoRedirect().urlSession(session, task: task, willPerformHTTPRedirection: response(request, status: 302).1 as! HTTPURLResponse,
            newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { rejected = $0 == nil }
        #expect(rejected)
    }

    nonisolated struct Bytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let count: Int
        struct AsyncIterator: AsyncIteratorProtocol {
            var remaining: Int
            mutating func next() async -> UInt8? {
                guard remaining > 0 else { return nil }; remaining -= 1; return 32
            }
        }
        func makeAsyncIterator() -> AsyncIterator { .init(remaining: count) }
    }

    @Test("The actual streaming reader stops at its byte cap and rechecks policy/config during receipt")
    func streamingBounds() async throws {
        let exact = try await B.receive(Bytes(count: B.maximumBytes), expectedLength: -1, allowed: { true }, isCurrent: { true })
        #expect(exact.count == B.maximumBytes)
        for expected in [Int64(-1), Int64(B.maximumBytes + 1)] {
            do {
                _ = try await B.receive(Bytes(count: B.maximumBytes + 1), expectedLength: expected, allowed: { true }, isCurrent: { true })
                Issue.record("Oversized stream accepted")
            } catch { #expect(error as? B.Failure == .oversized) }
        }
        var checks = 0
        do {
            _ = try await B.receive(Bytes(count: 20_000), expectedLength: -1, allowed: { true }, isCurrent: { checks += 1; return checks < 3 })
            Issue.record("Changed credential generation accepted")
        } catch { #expect(error as? B.Failure == .configurationChanged) }
        do {
            _ = try await B.receive(Bytes(count: 1), expectedLength: 1, allowed: { false }, isCurrent: { true })
            Issue.record("Denied stream accepted")
        } catch { #expect(error as? B.Failure == .policyDenied) }
    }
}
