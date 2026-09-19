import Foundation
import Synchronization
import Testing
@testable import StockSage

struct StockSageYahooCooldownTests {
    typealias Q = StockSageQuoteService

    @Test @MainActor func earningsRequestsShareQuoteCooldown() async throws {
        let gate = Q.YahooCooldown()
        let url = try #require(URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/VRA?modules=calendarEvents"))
        gate.observe(try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "90"])))
        var calls = 0
        let value = await StockSageEarnings.get(URLRequest(url: url), allowed: { true }, transport: { _ in
            calls += 1
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }, cooldown: gate)
        #expect(calls == 0 && value == nil)
    }

    @Test(arguments: ["valid", "redirect", "body", "length"])
    @MainActor func earningsResponseBoundaryControlsSharedCooldown(kind: String) async throws {
        let gate = Q.YahooCooldown()
        let url = try #require(URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/VRA?modules=calendarEvents"))
        let other = try #require(URL(string: "https://example.invalid/redirect"))
        var calls = 0, sleeps = 0
        let value = await StockSageEarnings.get(URLRequest(url: url), allowed: { true }, transport: { _ in
            calls += 1
            let body = kind == "body" ? Data(count: Q.maximumYahooBytes + 1) : Data()
            return (body, try #require(HTTPURLResponse(url: kind == "redirect" ? other : url,
                statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "90",
                    "Content-Length": String(kind == "length" ? Q.maximumYahooBytes + 1 : body.count)])))
        }, sleep: { _ in sleeps += 1 }, cooldown: gate)
        #expect(value == nil && calls == 1 && sleeps == 0)
        #expect(gate.permits() == (kind != "valid"))
    }

    @Test func aThrottleBlocksAnotherSweepAndHistoryUntilTheDeadline() async throws {
        let gate = Q.YahooCooldown()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let request = URLRequest(url: try #require(URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/VRA")))
        let calls = Mutex(0)
        let send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let n = calls.withLock { $0 += 1; return $0 }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: n == 1 ? 429 : 200,
                httpVersion: nil, headerFields: ["Retry-After": "90"])!)
        }
        let first = await Q.yahooResponse(for: request, allowed: { true }, transport: send,
            retryThrottles: false, cooldown: gate, now: { at })
        guard case .throttled = first else { Issue.record("First response must report throttling"); return }
        let second = await Q.yahooResponse(for: request, allowed: { true }, transport: send,
            cooldown: gate, now: { at.addingTimeInterval(89) })
        guard case .throttled = second else { Issue.record("History/another sweep must share the deadline"); return }
        #expect(calls.withLock { $0 } == 1)
        let after = await Q.yahooResponse(for: request, allowed: { true }, transport: send,
            cooldown: gate, now: { at.addingTimeInterval(90) })
        guard case .data = after else { Issue.record("Requests resume at expiry"); return }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test(arguments: ["600", "Wed, 23 Sep 2026 10:10:00 GMT", "garbage"])
    func cooldownPersistsAndShorterResponsesNeverShortenIt(header: String) throws {
        let name = "stocksage-yahoo-cooldown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let at = try #require(ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z"))
        let url = try #require(URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/VRA"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
            headerFields: ["Retry-After": header]))
        let gate = Q.YahooCooldown(defaults: defaults)
        gate.observe(response, now: at)
        let interval: TimeInterval = header == "garbage" ? 30 : 600
        #expect(!gate.permits(at: at.addingTimeInterval(interval - 1)))
        let restarted = Q.YahooCooldown(defaults: defaults)
        #expect(!restarted.permits(at: at.addingTimeInterval(interval - 1)))
        restarted.observe(try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "1"])), now: at)
        #expect(!restarted.permits(at: at.addingTimeInterval(interval - 1)))
        #expect(restarted.permits(at: at.addingTimeInterval(interval)))
    }
}
