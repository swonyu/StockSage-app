import Foundation
import CryptoKit
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageSP500ConstituentsTests {
    typealias C = StockSageSP500Constituents
    private let now = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
    private let header = "Symbol,Security,GICS Sector,GICS Sub-Industry,Headquarters Location,Date added,CIK,Founded"
    private func row(_ symbol: String, date: String = "2010-01-04") -> String {
        "\(symbol),\"Company, \"\"quoted\"\"\",Technology,Software,\"City\nState\",\(date),12345,1900"
    }
    private func csv(count: Int = 503, first: String? = nil) -> String {
        ([header, first ?? row("BRK.B")] + (1..<count).map { row(String(format: "S%03d", $0)) }).joined(separator: "\r\n") + "\r\n"
    }
    private func response(_ request: URLRequest, data: Data, status: Int = 200) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test func reported503RowsPreserveQuotedFieldsShareClassesAndSourceBytes() throws {
        let data = Data(csv().utf8)
        let snapshot = try C.parse(data, retrievedAt: now)
        let expected = Set(["BRK.B"] + (1..<503).map { String(format: "S%03d", $0) })
        #expect(snapshot.symbols == expected && snapshot.provenance.reportedCount == 503)
        #expect(snapshot.provenance.sourceURL == C.sourceURL && snapshot.provenance.retrievedAt == now)
        #expect(snapshot.provenance.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let member = try #require(snapshot.membership(for: "BRK.B"))
        #expect(member.valid(for: "BRK.B", through: now) && !member.valid(for: "BRK-B", through: now))
        #expect(snapshot.membership(for: "BRK-B") == nil)
        #expect(!member.valid(for: "BRK.B", through: now.addingTimeInterval(-1)))
        #expect(!member.valid(for: "BRK.B", through: Date(timeIntervalSince1970: .infinity)))
        #expect(try JSONDecoder().decode(C.Membership.self, from: JSONEncoder().encode(member)) == member)
        let forged = C.Membership(symbol: "BRK.B", provenance: .init(sourceURL: "https://example.com/other.csv",
            sha256: snapshot.provenance.sha256, retrievedAt: now, reportedCount: 503))
        #expect(!forged.valid(for: "BRK.B", through: now))
        let malformedHash = C.Provenance(sourceURL: C.sourceURL, sha256: "not-a-sha256", retrievedAt: now, reportedCount: 503)
        let invalidCount = C.Provenance(sourceURL: C.sourceURL, sha256: snapshot.provenance.sha256, retrievedAt: now, reportedCount: 449)
        #expect(!malformedHash.valid(through: now) && !invalidCount.valid(through: now))
    }

    @Test func malformedIncompleteDuplicateOrUnexpectedCSVIsRejected() throws {
        let original = csv()
        for bad in [original.replacingOccurrences(of: "Symbol,", with: "Ticker,"),
                    original.replacingOccurrences(of: "S001,", with: "BRK.B,"),
                    csv(first: row("brk.b")), csv(first: row("BAD/TICKER")),
                    csv(first: "BRK.B,Only two columns"), csv(first: row("BRK.B") + ",extra"),
                    original + "\"unterminated", original + "PARTIAL,Company\r\n",
                    csv(count: 449), csv(count: 551)] {
            #expect(throws: (any Error).self) { try C.parse(Data(bad.utf8), retrievedAt: now) }
        }
        #expect(throws: (any Error).self) { try C.parse(Data(repeating: 65, count: C.maximumBytes + 1), retrievedAt: now) }
        #expect(throws: (any Error).self) { try C.parse(Data([0xFF]), retrievedAt: now) }
        for count in [450, 550] { #expect(try C.parse(Data(csv(count: count).utf8), retrievedAt: now).symbols.count == count) }
    }

    @Test func dateAddedRejectsFutureAndInvalidDatesButAllowsMissing() throws {
        for date in ["2026-09-21", "2026-02-30", "2026-9-01", "not-a-date"] {
            #expect(throws: (any Error).self) { try C.parse(Data(csv(first: row("BRK.B", date: date)).utf8), retrievedAt: now) }
        }
        for date in ["", "2026-09-20"] {
            #expect(try C.parse(Data(csv(first: row("BF.B", date: date)).utf8), retrievedAt: now).symbols.contains("BF.B"))
        }
        #expect(throws: (any Error).self) { try C.parse(Data(csv().utf8), retrievedAt: Date(timeIntervalSince1970: .nan)) }
    }

    @Test func fetchHasNoAuthorizationAndRecordsTimeAfterResponse() async throws {
        var replied = false, clockCalls = 0
        let snapshot = try await C.fetch(allowed: { true }, clock: {
            #expect(replied); clockCalls += 1; return now
        }, transport: { request in
            #expect(request.url?.absoluteString == C.sourceURL && request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            replied = true
            return response(request, data: Data(csv().utf8))
        })
        #expect(clockCalls == 1 && snapshot.provenance.retrievedAt == now && snapshot.symbols.count == 503)
    }

    @Test func fetchRejectsPolicyRevocationCancellationAndNonSuccessResponses() async {
        for mode in ["denied", "revoked", "cancelled", "redirect", "server-error", "non-http"] {
            var permitted = mode != "denied", calls = 0
            let operation = Task { @MainActor in
                try await C.fetch(allowed: { permitted }, clock: { now }, transport: { request in
                    calls += 1
                    if mode == "revoked" { permitted = false }
                    if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                    if mode == "non-http" {
                        return (Data(csv().utf8), URLResponse(url: request.url!, mimeType: "text/csv", expectedContentLength: -1, textEncodingName: "utf-8"))
                    }
                    return response(request, data: Data(csv().utf8), status: mode == "redirect" ? 302 : mode == "server-error" ? 503 : 200)
                })
            }
            do { _ = try await operation.value; Issue.record("Accepted failed constituent fetch: \(mode)") }
            catch {
                if ["denied", "revoked", "cancelled"].contains(mode) { #expect(error is CancellationError) }
                else { #expect((error as? URLError)?.code == .badServerResponse) }
            }
            #expect(calls == (mode == "denied" ? 0 : 1))
        }
    }
}
