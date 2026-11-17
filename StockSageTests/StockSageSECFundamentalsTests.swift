import Foundation
import Testing
import Synchronization
@testable import StockSage

@MainActor
struct StockSageSECFundamentalsTests {
    typealias S = StockSageSECFundamentals
    private let cik = "0000320193"
    private let accession = "0000320193-25-000079"
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")! }

    // Small Company Facts-shaped fixture using the annual operating-income and
    // balance-sheet values in Apple's actual 2025 10-K, converted from millions
    // of USD. This is NOT a captured Company Facts response or a live API test.
    // https://www.sec.gov/Archives/edgar/data/320193/000032019325000079/aapl-20250927.htm
    private func appleFacts() -> [String: Any] {
        let values: [String: [Double]] = [
            "Assets": [364_980_000_000, 359_241_000_000],
            "LiabilitiesCurrent": [176_392_000_000, 165_631_000_000]
        ]
        var concepts: [String: Any] = [:]
        for (tag, pair) in values {
            concepts[tag] = ["units": ["USD": [
                row(pair[0], end: "2024-09-28"), row(pair[1], end: "2025-09-27")
            ]]]
        }
        concepts["OperatingIncomeLoss"] = ["units": ["USD": [
            row(133_050_000_000, start: "2024-09-29", end: "2025-09-27")
        ]]]
        return ["cik": 320193, "entityName": "Apple Inc.", "facts": ["us-gaap": concepts]]
    }

    private func row(_ value: Any, start: String? = nil, end: String) -> [String: Any] {
        var result: [String: Any] = ["val": value, "end": end, "filed": "2025-10-31",
            "accn": accession, "form": "10-K", "fy": 2025, "fp": "FY"]
        if let start { result["start"] = start }
        return result
    }

    private func replacing(_ data: [String: Any], tag: String, rows: [[String: Any]],
                           unit: String = "USD") -> [String: Any] {
        var result = data
        var facts = result["facts"] as! [String: Any]
        var gaap = facts["us-gaap"] as! [String: Any]
        gaap[tag] = ["units": [unit: rows]]
        facts["us-gaap"] = gaap
        result["facts"] = facts
        return result
    }

    private func parse(_ root: [String: Any]) throws -> S.Snapshot {
        S.parse(try JSONSerialization.data(withJSONObject: root), cik: cik, now: now)
    }

    @Test func annualUSDROCEUsesAverageBeginningAndEndingCapital() throws {
        let output = try parse(appleFacts())
        let metric = try #require(output.calculated.first { $0.key == "roce" })
        let expected = 133_050_000_000.0 / ((364_980_000_000 - 176_392_000_000 + 359_241_000_000 - 165_631_000_000) / 2)
        let value = try #require(metric.value)
        #expect(abs(value - expected) < 1e-12)
        #expect(metric.unit == "fraction")
        #expect(metric.label.contains("Operating-income"))
        #expect(metric.period.contains("2024-09-29") && metric.period.contains("2025-09-27"))
        #expect(metric.inputs.count == 5)
        #expect(metric.inputs.allSatisfy { $0.unit == "USD" && $0.sourceURL.contains("000032019325000079") })
        #expect(output.calculated.first { $0.key == "roic" }?.value == nil)
    }

    @Test(arguments: ["CAD", "missing-beginning", "mismatched-accession", "quarter", "future-filing", "boolean-value", "duplicate-conflict"])
    func refusesUnverifiableAnnualInputs(_ defect: String) throws {
        var facts = appleFacts()
        var income = row(133_050_000_000, start: "2024-09-29", end: "2025-09-27")
        switch defect {
        case "CAD": facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [income], unit: "CAD")
        case "missing-beginning": facts = replacing(facts, tag: "Assets", rows: [row(359_241_000_000, end: "2025-09-27")])
        case "mismatched-accession":
            var end = row(359_241_000_000, end: "2025-09-27"); end["accn"] = "0000320193-25-000001"
            facts = replacing(facts, tag: "Assets", rows: [row(364_980_000_000, end: "2024-09-28"), end])
        case "quarter": income["start"] = "2025-06-29"; facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [income])
        case "future-filing": income["filed"] = "2026-09-21"; facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [income])
        case "boolean-value": income["val"] = true; facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [income])
        default:
            var conflict = income; conflict["val"] = 1
            facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [income, conflict])
        }
        let output = try parse(facts)
        #expect(output.calculated.first { $0.key == "roce" }?.value == nil)
        #expect(!output.sources.isEmpty && !output.notes.isEmpty)
    }

    @Test(arguments: [false, true])
    func rejectsWrongOrBooleanIssuer(_ boolean: Bool) throws {
        var facts = appleFacts()
        if boolean { facts["cik"] = true } else { facts["cik"] = 123 }
        #expect(try parse(facts).calculated.allSatisfy { $0.value == nil })
    }

    @Test func latestNonpositiveCapitalDoesNotFallBackToOlderPositiveYear() throws {
        var facts = appleFacts()
        let oldIncome = row(10, start: "2023-09-30", end: "2024-09-28")
        facts = replacing(facts, tag: "OperatingIncomeLoss", rows: [oldIncome,
            row(133_050_000_000, start: "2024-09-29", end: "2025-09-27")])
        facts = replacing(facts, tag: "Assets", rows: [row(100, end: "2023-09-29"),
            row(364_980_000_000, end: "2024-09-28"), row(1, end: "2025-09-27")])
        facts = replacing(facts, tag: "LiabilitiesCurrent", rows: [row(1, end: "2023-09-29"),
            row(176_392_000_000, end: "2024-09-28"), row(2, end: "2025-09-27")])
        let metric = try #require(parse(facts).calculated.first { $0.key == "roce" })
        #expect(metric.value == nil)
        #expect(metric.period.contains("2025-09-27"))
        #expect(metric.note.contains("positive"))
    }

    private func roicFacts() -> [String: Any] {
        // Synthetic, explicitly reported units/tags; not an Apple ROIC claim.
        var facts = appleFacts()
        for (tag, value) in [("DebtCurrent", 20.0), ("LongTermDebtNoncurrent", 30.0),
                             ("FinanceLeaseLiabilityNoncurrent", 0.0), ("StockholdersEquity", 100.0),
                             ("StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest", 100.0),
                             ("CashAndCashEquivalentsAtCarryingValue", 10.0)] {
            facts = replacing(facts, tag: tag, rows: [row(value, end: "2024-09-28"), row(value, end: "2025-09-27")])
        }
        for (tag, value) in [("OperatingIncomeLoss", 20.0), ("IncomeTaxExpenseBenefit", 5.0),
            ("IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest", 25.0)] {
            facts = replacing(facts, tag: tag, rows: [row(value, start: "2024-09-29", end: "2025-09-27")])
        }
        return facts
    }

    @Test func annualROICRequiresCompleteNonoverlappingDebtAndTaxInputs() throws {
        let facts = roicFacts()
        let metric = try #require(parse(facts).calculated.first { $0.key == "roic" })
        let value = try #require(metric.value)
        #expect(abs(value - (16.0 / 140.0)) < 1e-12)
        let missing = replacing(facts, tag: "DebtCurrent", rows: [])
        #expect(try parse(missing).calculated.first { $0.key == "roic" }?.value == nil)
        let negativeTax = replacing(facts, tag: "IncomeTaxExpenseBenefit", rows: [row(-5.0, start: "2024-09-29", end: "2025-09-27")])
        #expect(try parse(negativeTax).calculated.first { $0.key == "roic" }?.value == nil)
    }

    @Test func consolidatedROICIncludesNoncontrollingEquityWithoutAddingParentAgain() throws {
        // FASB distinguishes equity attributable to parent from total equity:
        // https://xbrl.fasb.org/impdocs/OCI_TIG/othercompincome.htm
        let tag = "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"
        let facts = replacing(roicFacts(), tag: tag,
            rows: [row(120.0, end: "2024-09-28"), row(120.0, end: "2025-09-27")])
        let output = try parse(facts)
        let metric = try #require(output.calculated.first { $0.key == "roic" })
        let value = try #require(metric.value)
        // NOPAT16 / (current debt20 + noncurrent debt30 + consolidated equity120 − cash10).
        // Parent equity100 is present too; using it alone or adding it again is wrong.
        #expect(abs(value - 0.1) < 1e-12)
        #expect(metric.inputs.filter { $0.name == "us-gaap:" + tag }.map(\.value) == [120, 120])
        #expect(!metric.inputs.contains { $0.name == "us-gaap:StockholdersEquity" })
        #expect(metric.note.contains("noncontrolling"))
        #expect(output.calculated.first { $0.key == "roce" }?.value != nil)
    }

    @Test(arguments: ["parent-only", "missing-beginning", "mismatched-filing", "conflicting-total"])
    func ROICRefusesUnverifiedConsolidatedEquity(_ defect: String) throws {
        let tag = "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"
        var rows = [row(120.0, end: "2024-09-28"), row(120.0, end: "2025-09-27")]
        switch defect {
        case "parent-only": rows = []
        case "missing-beginning": rows.removeFirst()
        case "mismatched-filing": rows[0]["accn"] = "0000320193-25-000001"
        default: rows.append(row(130.0, end: "2025-09-27"))
        }
        let output = try parse(replacing(roicFacts(), tag: tag, rows: rows))
        let metric = try #require(output.calculated.first { $0.key == "roic" })
        #expect(metric.value == nil, "Parent-only equity must not fill a missing or ambiguous consolidated capital base")
        #expect(metric.note.contains("consolidated equity"))
        #expect(output.calculated.first { $0.key == "roce" }?.value != nil)
    }

    @Test func disabledAccessMakesNoCIKOrCompanyFactsRequest() async {
        let output = await S.collect(for: "AAPL", expectedCIK: cik, transport: { _ in
            Issue.record("Disabled access must perform zero HTTP requests")
            throw URLError(.cancelled)
        }, allowed: { false }, now: now)
        #expect(output.calculated.allSatisfy { $0.value == nil })
    }

    @Test func oversizedPayloadRemainsExplicitlyUnavailable() {
        let large = Data(repeating: 32, count: StockSageDisclosureService.maximumResponseBytes + 1)
        let parsed = S.parse(large, cik: cik, now: now)
        #expect(parsed.calculated.allSatisfy { $0.value == nil })
        #expect(parsed.sources.first?.status == "unavailable")
    }

    @Test(arguments: ["http403", "http429", "timeout", "size-error", "url-cancelled",
                      "task-cancelled", "transport-error", "oversized-data", "wrong-url",
                      "non-http", "access-revoked"])
    func collectionFailureReportsSpecificSafeReason(_ failure: String) async throws {
        let expectedDetails = [
            "http403": "SEC returned HTTP 403.",
            "http429": "SEC returned HTTP 429.",
            "timeout": "The SEC request timed out.",
            "size-error": "The SEC response exceeded the 4 MiB safety limit.",
            "url-cancelled": "The SEC request was cancelled.",
            "task-cancelled": "The SEC request was cancelled.",
            "transport-error": "The SEC request failed before a usable response was received.",
            "oversized-data": "The SEC response exceeded the 4 MiB safety limit.",
            "wrong-url": "The SEC response did not match the requested URL or HTTP format.",
            "non-http": "The SEC response did not match the requested URL or HTTP format.",
            "access-revoked": "External access was disabled before the SEC request completed."
        ]
        let detail = try #require(expectedDetails[failure])
        let expected = "SEC annual fundamentals unavailable: " + detail
        let sensitive = "fixture_token=DO_NOT_PUBLISH_PRIVATE_RESPONSE"
        var facts = appleFacts()
        facts["sensitive_test_marker"] = sensitive
        let body = try JSONSerialization.data(withJSONObject: facts)
        let permitted = Mutex(true)
        let calls = Mutex(0)
        let response = await S.collect(for: "AAPL", expectedCIK: cik, transport: { request in
            calls.withLock { $0 += 1 }
            switch failure {
            case "timeout": throw URLError(.timedOut)
            case "size-error": throw URLError(.dataLengthExceedsMaximum)
            case "url-cancelled": throw URLError(.cancelled)
            case "task-cancelled": throw CancellationError()
            case "transport-error":
                throw NSError(domain: "FixtureTransport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: sensitive])
            case "access-revoked": permitted.withLock { $0 = false }
            default: break
            }
            if failure == "non-http" {
                return (body, URLResponse(url: request.url!, mimeType: "application/json",
                    expectedContentLength: body.count, textEncodingName: "utf-8"))
            }
            var returned = body
            if failure == "oversized-data" {
                returned.append(Data(repeating: 32,
                    count: StockSageDisclosureService.maximumResponseBytes + 1 - returned.count))
            }
            let url = failure == "wrong-url" ? URL(string: "https://unrelated.example/\(sensitive)")! : request.url!
            let status = failure == "http403" ? 403 : (failure == "http429" ? 429 : 200)
            return (returned, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, allowed: { permitted.withLock { $0 } }, now: now)
        #expect(calls.withLock { $0 } == 1)
        #expect(response.calculated.count == 2)
        #expect(response.calculated.allSatisfy { $0.value == nil })
        #expect(response.calculated.allSatisfy { $0.note == expected })
        #expect(response.sources.count == 1)
        #expect(response.sources.first?.status == "unavailable")
        #expect(response.sources.first?.note == expected)
        #expect(response.notes == [expected])
        let saved = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        #expect(!saved.contains(sensitive))
        #expect(!saved.contains("FixtureTransport"))
        #expect(!saved.contains("unrelated.example"))
    }

    @Test func collectionUsesExpectedCIKAndTheBoundedSECTransport() async throws {
        let body = try JSONSerialization.data(withJSONObject: appleFacts())
        let output = await S.collect(for: "AAPL", expectedCIK: cik, transport: { request in
            #expect(request.url?.absoluteString == "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, allowed: { true }, now: now)
        #expect(output.calculated.first { $0.key == "roce" }?.value != nil)
    }
}
