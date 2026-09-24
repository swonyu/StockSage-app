import Foundation
import Testing
@testable import StockSage

@Suite("Massive short interest and short volume (shadow evidence)")
struct StockSageMassiveShortInterestTests {
    private typealias S = StockSageMassiveShortInterest
    private let now = Date(timeIntervalSince1970: 1_788_696_000) // 2026-09-06 12:00 UTC

    private func body(_ rows: String, status: String = "OK") -> Data {
        Data("{\"status\":\"\(status)\",\"request_id\":\"r\",\"results\":[\(rows)],\"next_url\":\"https://api.massive.com/next\"}".utf8)
    }

    @Test(arguments: S.Feed.allCases)
    func requestUsesBearerHeaderPinnedHostAndNewestFirstSort(feed: S.Feed) throws {
        let request = try #require(S.request(feed, symbol: "aapl", key: "fixture-only"))
        let url = try #require(request.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        #expect(url.scheme == "https" && url.host == "api.massive.com" && url.path == feed.path)
        #expect(!url.absoluteString.contains("fixture-only"))
        #expect(!items.contains { $0.name.lowercased() == "apikey" })
        #expect(items.first { $0.name == "sort" }?.value == feed.dateField + ".desc")
        #expect(items.first { $0.name == "limit" }?.value == "1")
        #expect(items.first { $0.name == "ticker" }?.value == "AAPL")
        #expect(S.request(feed, symbol: "2222.SR", key: "fixture-only") == nil)
        #expect(S.request(feed, symbol: "AAPL", key: "") == nil)
    }

    @Test func answeredRowsParseAndCarryLagLabels() throws {
        let interest = try #require(try S.parse(body(#"{"ticker":"AAPL","settlement_date":"2026-08-31","short_interest":120000000,"days_to_cover":2.5,"avg_daily_volume":48000000}"#),
                                                feed: .shortInterest, symbol: "AAPL"))
        #expect(interest.shortInterest == 120_000_000 && interest.daysToCover == 2.5 && interest.averageDailyVolume == 48_000_000)
        let volume = try #require(try S.parse(body(#"{"ticker":"AAPL","date":"2026-09-04","short_volume":1000,"total_volume":4000,"short_volume_ratio":25}"#),
                                              feed: .shortVolume, symbol: "AAPL"))
        #expect(volume.shortVolume == 1000 && volume.totalVolume == 4000 && volume.shortVolumeRatio == 25)
        let line = S.Observation(feed: .shortInterest, checkedAt: now, outcome: .answered(interest)).line
        #expect(line.contains("settlement " + StockSageCatalystWatch.dateStr(interest.date)))
        #expect(line.contains("6 days before") && line.contains("120000000 shares short") && line.contains("2.50 days to cover"))
        #expect(line.contains("lags current positioning"))
    }

    @Test(arguments: S.Feed.allCases)
    func missingOptionalFieldsAreToleratedAndAnEmptyAnswerIsNotUnavailable(feed: S.Feed) throws {
        let row = try #require(try S.parse(body("{\"ticker\":\"AAPL\",\"\(feed.dateField)\":\"2026-09-04\"}"), feed: feed, symbol: "AAPL"))
        let day = try #require(StockSageMassiveEvents.day("2026-09-04"))
        #expect(row == S.Row(date: day))
        #expect(S.Observation(feed: feed, checkedAt: now, outcome: .answered(row)).line.contains("values not supplied"))
        let empty = S.observation(.success(body("")), feed: feed, symbol: "AAPL", now: now)
        #expect(empty.outcome == .answered(nil))
        #expect(empty.line.contains("no record returned") && !empty.line.contains("unavailable"))
    }

    @Test func wrongTickerNonOKAndInvalidRowsAreRejected() {
        let cases: [(Data, S.Feed)] = [
            (body(#"{"ticker":"MSFT","settlement_date":"2026-08-31","short_interest":1}"#), .shortInterest),
            (body(#"{"settlement_date":"2026-08-31","short_interest":1}"#), .shortInterest),
            (body(#"{"ticker":"AAPL","settlement_date":"2026-08-31"}"#, status: "ERROR"), .shortInterest),
            (body(#"{"ticker":"AAPL","short_interest":1}"#), .shortInterest),
            (body(#"{"ticker":"AAPL","settlement_date":"2026-08-31","short_interest":-1}"#), .shortInterest),
            (body(#"{"ticker":"AAPL","settlement_date":"2026-08-31","days_to_cover":true}"#), .shortInterest),
            (body(#"{"ticker":"AAPL","date":"2026-09-04","short_volume_ratio":101}"#), .shortVolume),
            (body(#"{"ticker":"AAPL","date":"2026-09-04"},{"ticker":"AAPL","date":"2026-09-03"}"#), .shortVolume),
            (Data("not json".utf8), .shortVolume)]
        for (data, feed) in cases {
            #expect(throws: S.Failure.invalidPayload) { try S.parse(data, feed: feed, symbol: "AAPL") }
            #expect(S.observation(.success(data), feed: feed, symbol: "AAPL", now: now).outcome == .unavailable(.invalidPayload))
        }
        #expect(throws: S.Failure.responseTooLarge) {
            try S.parse(Data(repeating: 32, count: S.maximumBytes + 1), feed: .shortVolume, symbol: "AAPL")
        }
        let failed = S.observation(.failure(.http(500)), feed: .shortVolume, symbol: "AAPL", now: now)
        #expect(failed.outcome == .unavailable(.http(500)) && failed.line.contains("not an empty result"))
    }

    @MainActor @Test func forbiddenRecordsAPerFeedDenialAndLaterRequestsCoolDown() async throws {
        let name = "provider.short-interest.denial.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        func load(_ feed: S.Feed, status: Int) async throws -> Result<Data, S.Failure> {
            let request = try #require(S.request(feed, symbol: "AAPL", key: "fixture-only"))
            return await S.get(feed, request: request, now: Date(), revision: nil, defaults: defaults, allowed: { true },
                               transport: { req in
                requests += 1
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
        }
        #expect(try await load(.shortInterest, status: 403) == .failure(.http(403)))
        #expect(StockSageMassiveCredential.denialUntil(S.gateKey(.shortInterest), defaults: defaults) != nil)
        #expect(try await load(.shortInterest, status: 200) == .failure(.cooldown))
        #expect(requests == 1)
        // The gate is per feed: short volume still asks.
        #expect(try await load(.shortVolume, status: 200) == .success(Data()))
        #expect(requests == 2)
    }

    @MainActor @Test func serverErrorsDoNotRecordADenial() async throws {
        let name = "provider.short-interest.server.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let request = try #require(S.request(.shortVolume, symbol: "AAPL", key: "fixture-only"))
        let result = await S.get(.shortVolume, request: request, now: Date(), revision: nil, defaults: defaults, allowed: { true },
                                 transport: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) })
        #expect(result == .failure(.http(500)))
        #expect(StockSageMassiveCredential.denialUntil(S.gateKey(.shortVolume), defaults: defaults) == nil)
    }

    @MainActor @Test func requestsWithAnAPIKeyQueryOrForeignHostAreNeverSent() async throws {
        let name = "provider.short-interest.boundary.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        for raw in ["https://api.massive.com/stocks/v1/short-volume?ticker=AAPL&apiKey=fixture-only",
                    "https://example.com/stocks/v1/short-volume?ticker=AAPL"] {
            let url = try #require(URL(string: raw))
            let result = await S.get(.shortVolume, request: URLRequest(url: url), now: Date(),
                                     revision: nil, defaults: defaults, allowed: { true },
                                     transport: { req in
                requests += 1
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            #expect(result == .failure(.requestUnavailable))
        }
        let disabled = await S.get(.shortVolume, request: S.request(.shortVolume, symbol: "AAPL", key: "fixture-only"),
                                   now: Date(), revision: nil, defaults: defaults, allowed: { false },
                                   transport: { req in
            requests += 1
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(disabled == .failure(.externalAccessDisabled))
        #expect(requests == 0)
    }
}
