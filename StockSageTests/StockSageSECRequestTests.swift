import Foundation
import Synchronization
import Testing
@testable import StockSage

struct StockSageSECRequestTests {
    typealias D = StockSageDisclosureService
    nonisolated private static let tickers = Data(#"{"0":{"ticker":"TEST","cik_str":123}}"#.utf8)
    nonisolated private static let filings = Data(#"{"filings":{"recent":{"form":["8-K"],"accessionNumber":["0000000123-26-000001"],"filingDate":["2026-09-08"]}}}"#.utf8)
    nonisolated private static func response(_ request: URLRequest, _ body: Data, status: Int = 200) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }


    @Test(arguments: ["P", "S"], ["A", "D", "X", "", "missing"])
    func insiderDirectionMustAgreeThroughActualSECRequests(code: String, flag: String) async throws {
        func row(_ code: String, _ flag: String, shares: Int) -> String {
            let side = flag == "missing" ? "" : "<transactionAcquiredDisposedCode><value>\(flag)</value></transactionAcquiredDisposedCode>"
            return """
            <nonDerivativeTransaction>
              <transactionDate><value>2026-09-08</value></transactionDate>
              <transactionCoding><transactionCode>\(code)</transactionCode></transactionCoding>
              <transactionAmounts><transactionShares><value>\(shares)</value></transactionShares>
                <transactionPricePerShare><value>10</value></transactionPricePerShare>\(side)
              </transactionAmounts>
            </nonDerivativeTransaction>
            """
        }
        // A valid row precedes the disputed row: rejection must not publish a partial net.
        let xml = """
        <ownershipDocument><issuerTradingSymbol>TEST</issuerTradingSymbol><rptOwnerName>Fixture</rptOwnerName>
          <nonDerivativeTable>\(row("P", "A", shares: 100))\(row(code, flag, shares: 25))</nonDerivativeTable>
        </ownershipDocument>
        """
        let replies = [
            Data(#"{"filings":{"recent":{"form":["4"],"accessionNumber":["0000000123-26-000001"]}}}"#.utf8),
            Data(#"{"directory":{"item":[{"name":"doc4.xml"}]}}"#.utf8), Data(xml.utf8)
        ]
        let calls = Mutex(0)
        let result = await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in "0000000123" },
            transport: { req in
                let index = calls.withLock { $0 += 1; return $0 - 1 }
                guard replies.indices.contains(index) else { throw URLError(.badServerResponse) }
                return Self.response(req, replies[index])
            }, allowed: { true })
        #expect(calls.withLock { $0 } == 3)
        let compatible = flag == "missing" || (code == "P" && flag == "A") || (code == "S" && flag == "D")
        if compatible {
            let summary = try #require(result)
            #expect(summary.symbol == "TEST" && summary.discretionary.count == 2)
            #expect(summary.discretionary.last?.acquired == (code == "P"))
            #expect(summary.netBuyValue == (code == "P" ? 1_250 : 750))
        } else {
            #expect(StockSageInsider.parseForm4(xml) == nil)
            #expect(result == nil, "Do not publish a contradictory transaction or a partial directional net")
        }
    }

    @Test func failedLookupRetriesInsteadOfPoisoningTheSession() async {
        let calls = Mutex(0)
        let map = D.CIKMap { req in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { throw URLError(.timedOut) }
            return Self.response(req, Self.tickers)
        }
        #expect(await map.cik(for: "TEST", allowed: { true }) == nil)
        #expect(await map.cik(for: "TEST", allowed: { true }) == "0000000123")
        #expect(await map.cik(for: "TEST", allowed: { true }) == "0000000123")
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func failedHTTPAndEmptyMapsAreNotAuthoritative() async {
        for status in [200, 403, 429] {
            let calls = Mutex(0)
            let map = D.CIKMap { req in
                let n = calls.withLock { $0 += 1; return $0 }
                return Self.response(req, n == 1 && status == 200 ? Data("{}".utf8) : Self.tickers,
                                     status: n == 1 ? status : 200)
            }
            #expect(await map.cik(for: "TEST", allowed: { true }) == nil)
            #expect(await map.cik(for: "TEST", allowed: { true }) == "0000000123")
            #expect(calls.withLock { $0 } == 2)
        }
    }

    @Test func lookupCannotPublishOrCacheAfterPolicyIsRevoked() async {
        let permitted = Mutex(true), calls = Mutex(0)
        let map = D.CIKMap { req in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { permitted.withLock { $0 = false } }
            return Self.response(req, Self.tickers)
        }
        let allowed: @Sendable () -> Bool = { permitted.withLock { $0 } }
        #expect(await map.cik(for: "TEST", allowed: allowed) == nil)
        permitted.withLock { $0 = true }
        #expect(await map.cik(for: "TEST", allowed: allowed) == "0000000123")
        #expect(calls.withLock { $0 } == 2)
        permitted.withLock { $0 = false }
        #expect(await map.cik(for: "TEST", allowed: allowed) == nil)
    }

    @Test @MainActor func filingsStopAtEachRequestBoundary() async {
        for revokeAt in 1...2 {
            let permitted = Mutex(true), calls = Mutex(0)
            let wire: D.Transport = { req in
                let n = calls.withLock { $0 += 1; return $0 }
                if n == revokeAt { permitted.withLock { $0 = false } }
                return Self.response(req, n == 1 ? Self.tickers : Self.filings)
            }
            let result = await D.recentFilings(for: "TEST", map: D.CIKMap(transport: wire),
                transport: wire, allowed: { permitted.withLock { $0 } })
            #expect(result.isEmpty)
            #expect(calls.withLock { $0 } == revokeAt)
        }
    }

    @Test @MainActor func filingsRejectErrorBodiesAndNonpositiveLimits() async {
        for status in [403, 429] {
            let map = D.CIKMap { Self.response($0, Self.tickers) }
            let result = await D.recentFilings(for: "TEST", map: map,
                transport: { Self.response($0, Self.filings, status: status) }, allowed: { true })
            #expect(result.isEmpty)
        }
        let root = try! JSONSerialization.jsonObject(with: Self.filings) as! [String: Any]
        for limit in [-1, 0] { #expect(D.parseFilings(root, cik: "0000000123", limit: limit).isEmpty) }
    }

    @Test func insiderStopsAfterLookupAndEachSECHop() async {
        for revokeAt in 0...3 {
            let permitted = Mutex(true), calls = Mutex(0)
            let result = await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in
                if revokeAt == 0 { permitted.withLock { $0 = false } }
                return "0000000123"
            }, transport: { req in
                let n = calls.withLock { $0 += 1; return $0 }
                if n == revokeAt { permitted.withLock { $0 = false } }
                let body = n == 1 ? #"{"filings":{"recent":{"form":["4"],"accessionNumber":["0000000123-26-000001"]}}}"#
                    : n == 2 ? #"{"directory":{"item":[{"name":"doc4.xml"}]}}"#
                    : "<ownershipDocument><issuerTradingSymbol>TEST</issuerTradingSymbol></ownershipDocument>"
                return Self.response(req, Data(body.utf8))
            }, allowed: { permitted.withLock { $0 } })
            #expect(result == nil)
            #expect(calls.withLock { $0 } == revokeAt)
        }
    }

    @Test @MainActor func cancelledCallerMakesNoRequests() async {
        let calls = Mutex(0)
        let wire: D.Transport = { req in calls.withLock { $0 += 1 }; return Self.response(req, Self.tickers) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(await D.CIKMap(transport: wire).cik(for: "TEST", allowed: { true }) == nil)
            #expect(await D.recentFilings(for: "TEST", map: D.CIKMap(transport: wire), transport: wire, allowed: { true }).isEmpty)
            #expect(await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in "0000000123" }, transport: wire, allowed: { true }) == nil)
        }
        await task.value
        #expect(calls.withLock { $0 } == 0)
    }

    @Test @MainActor func oversizedMapAndFilingsAreRejected() async {
        let padding = Data(repeating: 32, count: 4 * 1_024 * 1_024)
        let map = D.CIKMap { Self.response($0, Self.tickers + padding) }
        #expect(await map.cik(for: "TEST", allowed: { true }) == nil)
        let validMap = D.CIKMap { Self.response($0, Self.tickers) }
        #expect(await D.recentFilings(for: "TEST", map: validMap,
            transport: { Self.response($0, Self.filings + padding) }, allowed: { true }).isEmpty)
    }

    @Test func aDifferentIssuersForm4CannotBecomeThisSymbolsActivity() async {
        let calls = Mutex(0)
        let result = await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in "0000000123" }, transport: { req in
            let n = calls.withLock { $0 += 1; return $0 }
            let body = n == 1 ? #"{"filings":{"recent":{"form":["4"],"accessionNumber":["0000000123-26-000001"]}}}"#
                : n == 2 ? #"{"directory":{"item":[{"name":"doc4.xml"}]}}"#
                : "<ownershipDocument><issuerTradingSymbol>OTHER</issuerTradingSymbol></ownershipDocument>"
            return Self.response(req, Data(body.utf8))
        }, allowed: { true })
        #expect(result == nil)
    }

    @Test @MainActor func bothConsumersUseTheSameSuccessfulMapWithoutChangingValidResults() async {
        let paths = Mutex<[String]>([])
        let wire: D.Transport = { req in
            let path = req.url!.path
            paths.withLock { $0.append(path) }
            #expect(req.value(forHTTPHeaderField: "User-Agent") == D.ua)
            #expect(req.timeoutInterval == 15)
            let body: Data
            if path.hasSuffix("company_tickers.json") { body = Self.tickers }
            else if path.contains("submissions") {
                body = Data(#"{"filings":{"recent":{"form":["8-K","4"],"accessionNumber":["0000000123-26-000001","0000000123-26-000002"],"filingDate":["2026-09-08","2026-09-08"]}}}"#.utf8)
            } else if path.hasSuffix("index.json") { body = Data(#"{"directory":{"item":[{"name":"doc4.xml"}]}}"#.utf8) }
            else { body = Data("<ownershipDocument><issuerTradingSymbol>TEST</issuerTradingSymbol></ownershipDocument>".utf8) }
            return Self.response(req, body)
        }
        let map = D.CIKMap(transport: wire)
        let filings = await D.recentFilings(for: "TEST", map: map, transport: wire, allowed: { true })
        #expect(filings.count == 1)
        #expect(filings.first?.accessionNumber == "0000000123-26-000001")
        let insider = await StockSageInsider.recentActivity(for: "TEST",
            lookup: { await map.cik(for: $0, allowed: { true }) }, transport: wire, allowed: { true })
        #expect(insider?.symbol == "TEST")
        #expect(insider?.isEmpty == true)
        #expect(paths.withLock { $0.filter { $0.hasSuffix("company_tickers.json") }.count } == 1)
        #expect(paths.withLock { $0.count } == 5)
    }

    @Test func incompleteForm4WindowCannotReportASuccessfulEmptySummary() async {
        let calls = Mutex(0)
        let result = await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in "0000000123" }, transport: { req in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 4 { throw URLError(.timedOut) }
            let body = n == 1 ? #"{"filings":{"recent":{"form":["4","4"],"accessionNumber":["0000000123-26-000001","0000000123-26-000002"]}}}"#
                : n == 2 ? #"{"directory":{"item":[{"name":"doc4.xml"}]}}"#
                : "<ownershipDocument><issuerTradingSymbol>TEST</issuerTradingSymbol></ownershipDocument>"
            return Self.response(req, Data(body.utf8))
        }, allowed: { true })
        #expect(result == nil)
    }

    @Test func raggedForm4ColumnsCannotClaimNoFilings() async {
        #expect(await StockSageInsider.recentActivity(for: "TEST", lookup: { _ in "0000000123" },
            transport: { Self.response($0, Data(#"{"filings":{"recent":{"form":["4"],"accessionNumber":[]}}}"#.utf8)) },
            allowed: { true }) == nil)
    }

    @Test func tenDigitCIKIsNotTruncatedToThirtyTwoBits() async {
        let map = D.CIKMap { Self.response($0, Data(#"{"0":{"ticker":"TEST","cik_str":9999999999}}"#.utf8)) }
        #expect(await map.cik(for: "TEST", allowed: { true }) == "9999999999")
    }

    @Test func invalidCIKValuesDoNotPoisonLaterLookups() async {
        for value in ["true", "0", "-1", "1.5", "10000000000"] {
            let calls = Mutex(0)
            let map = D.CIKMap { req in
                let n = calls.withLock { $0 += 1; return $0 }
                return Self.response(req, n == 1 ? Data("{\"0\":{\"ticker\":\"TEST\",\"cik_str\":\(value)}}".utf8) : Self.tickers)
            }
            #expect(await map.cik(for: "TEST", allowed: { true }) == nil)
            #expect(await map.cik(for: "TEST", allowed: { true }) == "0000000123")
        }
    }

    @Test func SECURLsAndResponseHostsAreRestricted() async {
        let calls = Mutex(0)
        let wire: D.Transport = { req in
            calls.withLock { $0 += 1 }
            return Self.response(req, Self.tickers)
        }
        for text in ["http://www.sec.gov/a", "https://example.com/a", "https://www.sec.gov:9000/a",
                     "https://user@www.sec.gov/a", "https://www.sec.gov/a?q=1", "https://www.sec.gov/a#b"] {
            #expect(await D.get(URL(string: text)!, transport: wire, allowed: { true }) == nil)
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(await D.get(URL(string: "https://www.sec.gov/a")!, transport: { _ in
            Self.response(URLRequest(url: URL(string: "https://example.com/a")!), Self.tickers)
        }, allowed: { true }) == nil)
        #expect(await D.get(URL(string: "https://data.sec.gov/submissions/CIK0000000123.json")!, transport: { _ in
            Self.response(URLRequest(url: URL(string: "https://data.sec.gov/submissions/CIK0000000456.json")!), Self.filings)
        }, allowed: { true }) == nil)
    }

    @Test func actualSECSessionRefusesRedirects() throws {
        let session = D.session
        let delegate = try #require(session.delegate as? URLSessionTaskDelegate)
        let original = URL(string: "https://www.sec.gov/files/company_tickers.json")!
        let task = session.dataTask(with: original) // Never resumed; no network.
        defer { task.cancel() }
        let returned = Mutex((called: false, refused: false))
        delegate.urlSession?(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://example.com/redirect")!),
            completionHandler: { value in returned.withLock { $0 = (true, value == nil) } })
        #expect(returned.withLock { $0.called && $0.refused })
    }
}
