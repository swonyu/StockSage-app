import Foundation
import Testing
import Synchronization
@testable import StockSage

@Suite(.serialized) struct StockSageFundamentalsTests: Sendable {
    typealias F = StockSageFundamentals
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
    private var access: StockSageMassive.Access {
        .init(key: { "fixture-key" }, credentialRevision: { "fixture" }, policyRevision: { "fixture" }, allowed: { true })
    }
    nonisolated private func ratio() -> [String: Any] {
        ["ticker": "TEST", "date": "2026-09-18", "price": 12.0,
         "price_to_earnings": 6.0, "earnings_per_share": 2.0,
         "price_to_sales": 1.2, "price_to_book": 1.5,
         "return_on_assets": 0.08, "return_on_equity": 0.16, "debt_to_equity": 0.5]
    }
    nonisolated private func statement(_ kind: F.Endpoint, end: String = "2026-06-30") -> [String: Any] {
        var row: [String: Any] = ["tickers": ["TEST"], "period_end": end, "filing_date": "2026-08-01",
                                 "fiscal_year": 2026, "fiscal_quarter": 2,
                                 "timeframe": kind == .balance ? "quarterly" : "trailing_twelve_months"]
        switch kind {
        case .income:
            row.merge(["revenue": 1_000.0, "operating_income": 100.0, "income_before_income_taxes": 80.0,
                       "income_taxes": 20.0, "consolidated_net_income_loss": 60.0,
                       "extraordinary_items": 0.0]) { _, b in b }
        case .balance:
            row.merge(["total_assets": 800.0, "total_current_liabilities": 200.0, "total_equity": 400.0,
                       "debt_current": 50.0, "long_term_debt_and_capital_lease_obligations": 150.0,
                       "cash_and_equivalents": 100.0]) { _, b in b }
        case .cash:
            row.merge(["net_cash_from_operating_activities": -10.0,
                       "purchase_of_property_plant_and_equipment": -20.0]) { _, b in b }
        case .ratios: break
        }
        return row
    }
    nonisolated private func payload(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows], options: .sortedKeys)
    }
    private func metric(_ metrics: [F.Metric], _ key: String) throws -> F.Metric {
        try #require(metrics.first { $0.key == key })
    }

    @Test func ratioFractionsAndMultiplesRetainProviderAttributionAndMissingReasons() throws {
        let result = try F.parseRatio(ratio(), symbol: "TEST", asOf: now)
        #expect(result.count == 6)
        #expect(try metric(result, "return_on_equity").value == 0.16)
        #expect(try metric(result, "return_on_equity").displayValue == "16.00%")
        #expect(try metric(result, "price_to_earnings").value == 6)
        #expect(result.allSatisfy { $0.origin == "Massive provider ratio" && $0.period.contains("2026-09-18") })
        var missing = ratio(); missing.removeValue(forKey: "price_to_sales")
        let absent = try metric(F.parseRatio(missing, symbol: "TEST", asOf: now), "price_to_sales")
        #expect(absent.value == nil && !absent.note.isEmpty)
        var loss = ratio(); loss["earnings_per_share"] = -2.0
        #expect(try metric(F.parseRatio(loss, symbol: "TEST", asOf: now), "price_to_earnings").value == nil)
        for key in ["price_to_earnings", "price_to_sales", "price_to_book"] {
            var invalid = ratio(); invalid[key] = 0.0
            #expect(try metric(F.parseRatio(invalid, symbol: "TEST", asOf: now), key).value == nil)
        }
    }

    @Test func wrongIssuerFutureDateInvalidDatesAndBooleanNumbersAreRejected() throws {
        for (key, value) in [("ticker", "OTHER"), ("date", "2026-09-21"), ("date", "2026-02-30")] {
            var row = ratio(); row[key] = value
            #expect(throws: (any Error).self) { try F.parseRatio(row, symbol: "TEST", asOf: now) }
        }
        let malformedNumbers: [Any] = [true, "12.3", Double.infinity, Double.nan]
        for bad in malformedNumbers {
            var row = ratio(); row["return_on_assets"] = bad
            #expect(throws: (any Error).self) { try F.parseRatio(row, symbol: "TEST", asOf: now) }
        }
        #expect(throws: (any Error).self) {
            try F.parseRatio(ratio(), symbol: "TEST", asOf: Date(timeIntervalSince1970: .nan))
        }
    }

    @Test func statementsPinIssuerTTMPeriodDisclosureDateAndRetainUnknownUnits() throws {
        let data = try payload([statement(.income)])
        let parsed = try F.parse(data, endpoint: .income, symbol: "TEST", asOf: now)
        let row = try #require(parsed.statements.first)
        #expect(row.timeframe == "trailing_twelve_months" && row.periodEnd == "2026-06-30")
        #expect(row.filingDate == "2026-08-01" && row.amounts["operating_income"] == 100)
        #expect(row.unit == F.statementUnit && !row.unit.contains("USD"))
        let defects: [(String, Any)] = [("tickers", ["OTHER"]), ("filing_date", "2026-09-21"),
                                      ("period_end", "2026-09-21"), ("timeframe", "annual"),
                                      ("fiscal_quarter", true), ("operating_income", false)]
        for (key, value) in defects {
            var bad = statement(.income); bad[key] = value
            #expect(throws: (any Error).self) { try F.parse(payload([bad]), endpoint: .income, symbol: "TEST", asOf: now) }
        }
        var leap = statement(.balance, end: "2024-02-29"); leap["fiscal_year"] = 2024
        #expect(try F.parse(payload([leap]), endpoint: .balance, symbol: "TEST", asOf: now).statements.count == 1)
        leap["period_end"] = "2023-02-29"
        #expect(throws: (any Error).self) { try F.parse(payload([leap]), endpoint: .balance, symbol: "TEST", asOf: now) }
        #expect(throws: (any Error).self) { try F.parse(payload([statement(.income), statement(.income)]), endpoint: .income, symbol: "TEST", asOf: now) }
    }

    @Test func exactDuplicateStatementsAreDeduplicatedButConflictingAmountsAreRejected() throws {
        var row = statement(.balance)
        row["tickers"] = ["TEST", "TEST"] // Observed real v1 shape; duplicate issuer aliases are not duplicate facts.
        let valid = try F.parse(payload([row, row]), endpoint: .balance, symbol: "TEST", asOf: now)
        #expect(valid.statements.count == 1 && valid.source.recordCount == 2)
        #expect(valid.source.note.contains("1 duplicate") && valid.source.note.contains("1 distinct"))
        var conflicting = row; conflicting["total_assets"] = 999.0
        #expect(throws: (any Error).self) {
            try F.parse(payload([row, conflicting]), endpoint: .balance, symbol: "TEST", asOf: now)
        }
    }

    @Test func collectUsesFourBoundedAuthenticatedV1RequestsAndPreservesPartialFailures() async throws {
        let calls = Mutex<[String: Int]>([:])
        let snapshot = await F.collect(symbol: "TEST", asOf: now, access: access, transport: { request in
            #expect(request.httpMethod == "GET" && request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let url = try #require(request.url)
            #expect(url.host == "api.massive.com" && !url.absoluteString.contains("fixture-key"))
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            let endpoint = try #require(F.Endpoint.allCases.first { url.path.hasSuffix($0.rawValue) })
            calls.withLock { $0[endpoint.rawValue, default: 0] += 1 }
            if endpoint == .ratios {
                #expect(query["ticker"] == "TEST" && query["tickers"] == nil && query["sort"] == nil)
                #expect(query["date"] == nil && query["limit"] == "1")
            } else {
                #expect(query["tickers"] == "TEST" && query["ticker"] == nil)
                #expect(query["filing_date.lte"] == "2026-09-20" && query["period_end.lte"] == "2026-09-20")
                #expect(query["sort"] == "period_end.desc")
                #expect(query["timeframe"] == (endpoint == .balance ? nil : "trailing_twelve_months"))
            }
            let bytes = try endpoint == .ratios ? payload([ratio()]) : payload([statement(endpoint)])
            return (bytes, HTTPURLResponse(url: url, statusCode: endpoint == .balance ? 403 : 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now })
        #expect(calls.withLock { $0.count == 4 && $0.values.allSatisfy { $0 == 1 } })
        #expect(snapshot.sources.count == 5) // Four Massive endpoints + explicit unavailable SEC identity.
        #expect(snapshot.sources.contains { $0.name == "Massive balance sheets" && $0.status == "http403" })
        #expect(snapshot.providerRatios.count == 6 && snapshot.providerRatios.allSatisfy { $0.value != nil })
        #expect(snapshot.statements.count == 2)
        #expect(snapshot.flags.contains { $0.contains("negative operating cash flow") })
        #expect(!snapshot.flags.contains { $0.contains("no one-off") })
        #expect(snapshot.calculated.count == 2 && snapshot.calculated.allSatisfy { $0.value == nil && !$0.note.isEmpty })
        #expect(snapshot.facts.first?.required == true && snapshot.facts.first?.text.contains("not adjusted") == true)
        #expect(snapshot.facts.first?.factClass == .coverageGap)
        #expect(snapshot.facts.first?.text.contains("6/8 ratio slots available") == true)
        #expect(snapshot.facts.first?.text.contains("6.00×") == true)
        #expect(snapshot.facts.first?.text.contains("sector-peer comparisons are unavailable") == true)
        #expect(snapshot.notes.contains { $0.contains("insider ownership is not calculated") })
        #expect(snapshot.facts.count <= 12)
        #expect(try JSONDecoder().decode(F.Snapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func returnedCIKBindsTaggedSECAnnualCalculationWithoutLeakingProviderAuthorization() async throws {
        func secRow(_ value: Double, end: String, start: String? = nil) -> [String: Any] {
            var row: [String: Any] = ["val": value, "end": end, "filed": "2026-03-01",
                                     "accn": "0000000123-26-000001", "form": "10-K", "fy": 2025, "fp": "FY"]
            if let start { row["start"] = start }
            return row
        }
        let gaap: [String: Any] = [
            "OperatingIncomeLoss": ["units": ["USD": [secRow(20, end: "2025-12-31", start: "2025-01-01")]]],
            "Assets": ["units": ["USD": [secRow(100, end: "2024-12-31"), secRow(100, end: "2025-12-31")]]],
            "LiabilitiesCurrent": ["units": ["USD": [secRow(20, end: "2024-12-31"), secRow(20, end: "2025-12-31")]]]
        ]
        let sec = try JSONSerialization.data(withJSONObject: ["cik": 123, "facts": ["us-gaap": gaap]])
        let secCalls = Mutex(0)
        let result = await F.collect(symbol: "TEST", asOf: now, access: access, transport: { request in
            let endpoint = try #require(F.Endpoint.allCases.first { request.url!.path.hasSuffix($0.rawValue) })
            var row = endpoint == .ratios ? ratio() : statement(endpoint)
            row["cik"] = "0000000123"
            return (try payload([row]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, secTransport: { request in
            secCalls.withLock { $0 += 1 }
            #expect(request.url?.absoluteString == "https://data.sec.gov/api/xbrl/companyfacts/CIK0000000123.json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (sec, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { now })
        #expect(secCalls.withLock { $0 } == 1)
        #expect(try metric(result.calculated, "roce").value == 0.25)
        #expect(try metric(result.calculated, "roce").inputs.allSatisfy { $0.unit == "USD" })
        #expect(result.metrics.count == 8 && result.sources.count == 5)
    }

    @Test func mismatchedIssuerCIKsRevocationRedirectAndOversizeCannotPublishRatios() async throws {
        for mode in ["cik-mismatch", "revoked", "redirect", "oversize"] {
            let permitted = Mutex(true)
            let input = StockSageMassive.Access(key: { "fixture-key" }, credentialRevision: { nil },
                policyRevision: { nil }, allowed: { permitted.withLock { $0 } })
            let result = await F.collect(symbol: "TEST", asOf: now, access: input, transport: { request in
                let endpoint = try #require(F.Endpoint.allCases.first { request.url!.path.hasSuffix($0.rawValue) })
                var row = endpoint == .ratios ? ratio() : statement(endpoint)
                if mode == "cik-mismatch" { row["cik"] = endpoint == .ratios ? "123" : "456" }
                if mode == "revoked" { permitted.withLock { $0 = false } }
                let bytes = mode == "oversize" ? Data(repeating: 32, count: F.maximumBytes + 1) : try payload([row])
                let url = mode == "redirect" ? URL(string: "https://other.example/redirect")! : request.url!
                return (bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, secTransport: { _ in Issue.record("Invalid v1 evidence must not reach SEC"); throw URLError(.cancelled) }, clock: { now })
            #expect(result.metrics.allSatisfy { $0.value == nil }, "\(mode)")
            #expect(result.statements.isEmpty, "\(mode)")
        }
    }

    @Test func noKeyDeniedAccessAndCancellationDoNotIssueProviderRequests() async {
        for mode in ["no-key", "denied", "cancelled"] {
            let operation = Task {
                if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                return await F.collect(symbol: "TEST", asOf: now,
                    access: .init(key: { mode == "no-key" ? "" : "fixture-key" },
                                  credentialRevision: { nil }, policyRevision: { nil }, allowed: { mode != "denied" }),
                    transport: { _ in Issue.record("Unexpected provider request: \(mode)"); throw URLError(.cancelled) }, clock: { now })
            }
            let result = await operation.value
            #expect(result.metrics.allSatisfy { $0.value == nil })
            #expect(result.sources.allSatisfy { $0.status != "available" })
        }
    }
}
