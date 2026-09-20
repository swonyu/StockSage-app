import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageResearchUniverseTests {
    typealias U = StockSageResearchUniverse
    let now = ISO8601DateFormatter().date(from: "2026-09-12T15:00:00Z")!
    let day = "2026-09-11"
    func listing(_ symbol: String, currency: String = "usd", type: String? = "CS", exchange: String? = "XNAS") -> U.Listing {
        .init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
              type: type, currency_name: currency, primary_exchange: exchange)
    }
    func payload(_ symbols: [String], date: String = "2026-09-11", volumes: [Double]? = nil) throws -> Data {
        let stamp = ISO8601DateFormatter().date(from: date + "T04:00:00Z")!.timeIntervalSince1970 * 1000
        return try JSONSerialization.data(withJSONObject: ["status": "OK", "adjusted": true,
            "resultsCount": symbols.count, "results": symbols.enumerated().map { i, symbol in
                ["T": symbol, "t": stamp, "v": volumes?[i] ?? Double(i + 1), "vw": 100] as [String: Any]
            }])
    }
    @Test func activityNotAlphabetSelectsThe1500AndPreservesShareClasses() throws {
        let names = (0..<1501).map { String(format: "S%05d", $0) }
        let selected = try U.select(directory: names.map { listing($0) }, data: payload(names), session: day, at: now)
        #expect(selected.listings.count == 1500)
        #expect(selected.listings.first?.ticker == "S01500")
        #expect(!selected.listings.contains { $0.ticker == "S00000" })
        let classes = ["AAA", "BRK.B", "ZZZ"]
        let ranked = try U.select(directory: classes.map { listing($0) }, data: payload(classes), session: day, at: now)
        #expect(ranked.listings.map(\.ticker) == ["ZZZ", "BRK.B", "AAA"])
        #expect(ranked.receipt?.dollarVolume["BRK.B"] == 200)
    }

    @Test func nasdaqCommonStockEligibilityPrecedesTheActivityCap() throws {
        let common = (0..<1501).map { listing(String(format: "S%05d", $0)) }
        let excluded = [listing("NYSE", exchange: "XNYS"), listing("ARCA", exchange: "ARCX"),
            listing("UNKNOWN", exchange: nil), listing("ETF", type: "ETF"),
            listing("ADR", type: "ADRC"), listing("PREFERRED", type: "PFD"),
            listing("UNIT", type: "UNIT"), listing("MISSING", type: nil),
            listing("LOWER", type: "cs"), listing("LOWEREX", exchange: "xnas")]
        let directory = common + excluded // Excluded instruments have the highest observed activity.
        let selected = try U.select(directory: directory, data: payload(directory.map(\.ticker)), session: day, at: now)
        #expect(selected.listings.count == 1500)
        #expect(selected.listings.map(\.ticker) == common.dropFirst().reversed().map(\.ticker))
        #expect(selected.receipt?.eligibleCount == 1501)
        #expect(selected.receipt?.returnedCount == directory.count)
        #expect(selected.receipt?.directoryCount == directory.count)
    }

    @Test func combinedPoolDeduplicatesNasdaqAndReportedMembersBeforeThe1500Cap() throws {
        typealias C = StockSageSP500Constituents
        let members = Set(["DUAL", "NYMEM", "BRK.B", "ETF", "UNKNOWN"] + (0..<498).map { "I\($0)" })
        let provenance = C.Provenance(sourceURL: C.sourceURL, sha256: String(repeating: "a", count: 64),
            retrievedAt: now, reportedCount: members.count)
        let snapshot = C.Snapshot(symbols: members, provenance: provenance)
        var forged = listing("NONMEM", exchange: "XNYS")
        forged.sp500Membership = snapshot.membership(for: "NYMEM")
        let directory = (0..<1501).map { listing(String(format: "S%05d", $0)) } + [
            listing("DUAL"), listing("NYMEM", exchange: "XNYS"), listing("BRK.B", exchange: "XNYS"),
            forged, listing("ETF", type: "ETF"), listing("UNKNOWN", exchange: nil)]
        let selected = try U.select(directory: directory, data: payload(directory.map(\.ticker)),
            session: day, at: now, sp500: snapshot)
        #expect(selected.listings.count == 1500 && Set(selected.listings.map(\.ticker)).count == 1500)
        #expect(selected.receipt?.eligibleCount == 1504 && selected.receipt?.sp500 == provenance)
        #expect(Set(["DUAL", "NYMEM", "BRK.B"]).isSubset(of: Set(selected.listings.map(\.ticker))))
        #expect(selected.listings.filter { $0.ticker == "DUAL" }.count == 1)
        #expect(!selected.listings.contains { ["NONMEM", "ETF", "UNKNOWN"].contains($0.ticker) })
        #expect(selected.listings.filter { $0.primary_exchange == "XNYS" }.allSatisfy {
            $0.sp500Membership?.valid(for: $0.ticker, through: now) == true
        })
        #expect(selected.receipt?.summary.contains("No official membership effective date") == true)
        let nasdaqOnly = try U.select(directory: directory, data: payload(directory.map(\.ticker)), session: day, at: now)
        #expect(nasdaqOnly.listings.allSatisfy { $0.primary_exchange == "XNAS" && $0.sp500Membership == nil })
    }

    @Test func reportedMembersRequireASupportedListingVenueAndCommonShares() throws {
        typealias C = StockSageSP500Constituents
        let members = Set(["CBOE"] + (0..<502).map { "I\($0)" })
        let snapshot = C.Snapshot(symbols: members, provenance: .init(sourceURL: C.sourceURL,
            sha256: String(repeating: "a", count: 64), retrievedAt: now, reportedCount: members.count))
        for exchange: String? in ["XNAS", "XNYS", "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX", "OTCM", "XOTC", "unknown", nil] {
            let supported = !["OTCM", "XOTC", "unknown", nil].contains(exchange)
            let selected = try U.select(directory: [listing("CBOE", exchange: exchange)], data: payload(["CBOE"]),
                session: day, at: now, sp500: snapshot)
            #expect(selected.listings.count == (supported ? 1 : 0))
            if supported { #expect(selected.listings.first?.sp500Membership == snapshot.membership(for: "CBOE")) }
        }
        let excluded = try U.select(directory: [listing("CBOE", type: "ETF", exchange: "BATS")],
            data: payload(["CBOE"]), session: day, at: now, sp500: snapshot)
        #expect(excluded.listings.isEmpty)
    }

    @Test(arguments: [false, true]) func combinedFetchCapturesMembershipOrStopsBeforePricing(failed: Bool) async throws {
        typealias C = StockSageSP500Constituents
        let symbols = ["NASDAQ", "NYMEM"]
        let header = "Symbol,Security,GICS Sector,GICS Sub-Industry,Headquarters Location,Date added,CIK,Founded"
        let members = ["NYMEM"] + (0..<502).map { "I\($0)" }
        let csv = ([header] + members.map { "\($0),Company,Tech,Software,US,2020-01-02,123,2000" }).joined(separator: "\n")
        var pricingRequests = 0, membershipRequests = 0
        do {
            let selected = try await U.fetch(key: "synthetic-only", allowed: { true }, at: now,
                includeSP500: true, membershipClock: { now.addingTimeInterval(1) }, transport: { request in
                    if request.url?.absoluteString == C.sourceURL {
                        membershipRequests += 1
                        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                        return response(request, Data(csv.utf8), code: failed ? 503 : 200)
                    }
                    if request.url?.path == "/v3/reference/tickers" {
                        var body = try #require(JSONSerialization.jsonObject(with: directoryPayload(symbols)) as? [String: Any])
                        var rows = try #require(body["results"] as? [[String: Any]])
                        rows[1]["primary_exchange"] = "XNYS"; body["results"] = rows
                        return try response(request, JSONSerialization.data(withJSONObject: body))
                    }
                    pricingRequests += 1
                    return try response(request, payload(symbols))
                })
            #expect(!failed && selected.listings.map(\.ticker) == ["NYMEM", "NASDAQ"])
            #expect(selected.receipt?.sp500?.retrievedAt == now.addingTimeInterval(1))
            #expect(selected.listings.first?.sp500Membership?.symbol == "NYMEM")
        } catch {
            #expect(failed && error as? U.Failure == .sp500Unavailable)
        }
        #expect(membershipRequests == 1 && pricingRequests == (failed ? 0 : 1))
    }

    @Test func sameDaySelectionKeepsItsOriginalFiveHundredCoverageThreshold() async throws {
        let clock = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
        let names = (0..<501).map { String(format: "S%05d", $0) }
        var requests = 0
        let selected = try await U.fetch(key: "synthetic-only", allowed: { true }, at: clock, limit: 500, transport: { request in
            requests += 1
            #expect(request.url?.host == "api.massive.com")
            if request.url?.path == "/v3/reference/tickers" { return try response(request, directoryPayload(names)) }
            #expect(request.url?.lastPathComponent == "2026-09-09")
            return try response(request, payload(Array(names.prefix(500)), date: "2026-09-09"))
        })
        #expect(requests == 2 && selected.listings.count == 500 && selected.receipt?.fallback == false)
        #expect(selected.receipt?.sp500 == nil)
    }

    @Test func selectionSummarySeparatesSelectionFromResearchAndNamesTheActivityBoundary() throws {
        for count in [0, 2, 500, 1500, 1501] {
            let names = (0..<count).map { String(format: "S%05d", $0) }
            let selected = try U.select(directory: names.map { listing($0) }, data: payload(names), session: day, at: now)
            let receipt = try #require(selected.receipt)
            let summary = receipt.summary
            #expect(summary.contains("\(min(count, 1500)) of \(count) eligible selected"))
            #expect(!summary.localizedCaseInsensitiveContains("researched"))
            if count == 0 {
                #expect(!summary.contains("Lowest selected activity:") && !summary.contains("Selection cutoff:"))
            } else if count <= 1500 {
                #expect(summary.contains("Lowest selected activity:"))
                #expect(summary.contains("100") && !summary.contains("Selection cutoff:"))
            } else {
                #expect(summary.contains("Selection cutoff:"))
                #expect(summary.contains("200") && !summary.contains("Lowest selected activity:"))
            }
        }
        var partial = try #require(U.select(directory: [listing("AAA")], data: payload(["AAA"]), session: day,
            at: ISO8601DateFormatter().date(from: "2026-09-11T15:00:00Z")!).receipt)
        #expect(partial.summary.contains("session-to-date") && partial.summary.contains("1 of 1 eligible selected"))
        partial.fallback = true
        #expect(partial.summary.contains("Prior session used") && !partial.summary.contains("researched"))
    }

    @Test func unverifiedCalendarExplainsTheBuildLimitBeforeAnyNetworkRequest() async throws {
        for clock in ["2027-01-04T15:00:00Z", "2026-01-02T08:00:00Z"] {
            var requests = 0
            do {
                _ = try await U.fetch(key: "synthetic-only", allowed: { true },
                    at: ISO8601DateFormatter().date(from: clock)!, transport: { _ in
                        requests += 1
                        throw URLError(.cannotConnectToHost)
                    })
                Issue.record("Unverified calendar accepted")
            } catch {
                #expect(error as? U.Failure == .unverifiedCalendar)
                let message = (error as? LocalizedError)?.errorDescription ?? ""
                #expect(message.contains("calendar") && message.contains("2026"))
                #expect(!message.contains("Massive") && !message.contains("credentials"))
            }
            #expect(requests == 0)
        }
    }

    @Test func sessionChoiceUsesExchangeDatesHolidaysDSTAndSupportedCalendar() throws {
        for (clock, primary, previous) in [
            ("2026-09-12T15:00:00Z", "2026-09-11", nil),
            ("2026-09-07T15:00:00Z", "2026-09-04", nil),
            ("2026-09-08T07:59:00Z", "2026-09-04", nil),
            ("2026-09-08T08:00:00Z", "2026-09-08", "2026-09-04"),
            ("2026-11-02T08:59:00Z", "2026-10-30", nil),
            ("2026-11-02T09:00:00Z", "2026-11-02", "2026-10-30"),
            ("2026-11-27T19:00:00Z", "2026-11-27", "2026-11-25")
        ] as [(String, String, String?)] {
            let dates = try U.sessions(at: ISO8601DateFormatter().date(from: clock)!)
            #expect(dates.primary == primary && dates.previous == previous)
        }
        for clock in ["2027-01-04T15:00:00Z", "2026-01-02T08:00:00Z"] {
            #expect(throws: (any Error).self) { try U.sessions(at: ISO8601DateFormatter().date(from: clock)!) }
        }
        #expect(throws: (any Error).self) { try U.sessions(at: Date(timeIntervalSince1970: .nan)) }
        let request = try #require(U.request(key: "synthetic-only", session: day))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only")
        #expect(request.url?.host == "api.massive.com" && request.url?.query == "adjusted=true&include_otc=false")
        #expect(request.url?.absoluteString.contains("synthetic-only") == false)
        for bad in ["../secret", "2026-09-12", "2026-9-11", "2027-01-04"] { #expect(U.request(key: "x", session: bad) == nil) }
    }

    @Test func malformedEnvelopeAndDuplicateIdentityDoNotBecomeEmptySuccess() throws {
        let base = try #require(JSONSerialization.jsonObject(with: payload(["AAA", "ZZZ"])) as? [String: Any])
        for (key, value) in [("status", "ERROR" as Any), ("adjusted", false as Any), ("adjusted", 1 as Any),
                             ("resultsCount", 3 as Any), ("resultsCount", true as Any), ("next_url", "https://example.test/next" as Any)] {
            var bad = base; bad[key] = value
            #expect(throws: (any Error).self) { try U.select(directory: [listing("AAA"), listing("ZZZ")],
                data: JSONSerialization.data(withJSONObject: bad), session: day, at: now) }
        }
        var duplicate = base
        var rows = base["results"] as! [[String: Any]]
        rows[0]["v"] = 0; rows[1]["T"] = "AAA"; duplicate["results"] = rows
        #expect(throws: (any Error).self) { try U.select(directory: [listing("AAA")],
            data: JSONSerialization.data(withJSONObject: duplicate), session: day, at: now) }
    }

    @Test func onlyVerifiedDatedDollarActivityQualifiesAndTiesAreDeterministic() throws {
        let names = ["AAA", "ZZZ"]
        let base = try #require(JSONSerialization.jsonObject(with: payload(names)) as? [String: Any])
        let duringSession = ISO8601DateFormatter().date(from: "2026-09-11T12:00:00Z")!
        for (key, value) in [("v", 0 as Any), ("v", true as Any), ("vw", "NaN" as Any),
                             ("v", 1e308 as Any), ("t", 1_789_099_200 as Any),
                             ("t", 1_789_099_200_000_000_000 as Any), ("t", 1_789_156_800_000 as Any),
                             ("otc", true as Any), ("otc", 1 as Any)] {
            var bad = base; var rows = base["results"] as! [[String: Any]]
            rows[0][key] = value; bad["results"] = rows
            let result = try U.select(directory: names.map { listing($0) }, data: JSONSerialization.data(withJSONObject: bad), session: day, at: duringSession)
            #expect(result.listings.map(\.ticker) == ["ZZZ"], "Invalid field \(key) must not enter the ranking")
            #expect(result.receipt?.eligibleCount == 1 && result.receipt?.returnedCount == 2)
        }
        let tie = try U.select(directory: [listing("ZZZ"), listing("AAA")], data: payload(names, volumes: [2, 2]), session: day, at: now)
        #expect(tie.listings.map(\.ticker) == names)
        let foreign = try U.select(directory: [listing("AAA", currency: "gbp"), listing("ZZZ")], data: payload(names), session: day, at: now)
        #expect(foreign.listings.map(\.ticker) == ["ZZZ"])
        let empty = try U.select(directory: [], data: payload([]), session: day, at: now)
        #expect(empty.listings.isEmpty && empty.receipt?.eligibleCount == 0)
        for field in ["vw", "v", "t"] {
            var missing = base; var rows = base["results"] as! [[String: Any]]
            rows[0].removeValue(forKey: field); missing["results"] = rows
            let result = try U.select(directory: names.map { listing($0) },
                data: JSONSerialization.data(withJSONObject: missing), session: day, at: now)
            #expect(result.listings.map(\.ticker) == ["ZZZ"])
        }
    }

    func directoryPayload(_ names: [String], next: String? = nil) throws -> Data {
        var body: [String: Any] = ["status": "OK", "count": names.count,
            "results": names.map { ["ticker": $0, "name": $0, "market": "stocks", "locale": "us",
                "active": true, "type": "CS", "currency_name": "usd", "primary_exchange": "XNAS"] as [String: Any] }]
        if let next { body["next_url"] = next }
        return try JSONSerialization.data(withJSONObject: body)
    }
    func response(_ request: URLRequest, _ data: Data, code: Int = 200) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    @Test func currentCoverageFallbackAndTiesUseOneSessionAndCompareBeforeTheCap() async throws {
        let clock = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
        let names = (0..<1501).map { String(format: "S%05d", $0) }
        for (current, prior) in [(1499, 1501), (1500, 1501), (1499, 1499), (0, 1501)] {
            var paths: [String] = []
            let selected = try await U.fetch(key: "synthetic-only", allowed: { true }, at: clock, transport: { request in
                let path = request.url!.path; paths.append(path)
                if path == "/v3/reference/tickers" {
                    let later = request.url?.query?.contains("cursor=second") == true
                    return try response(request, directoryPayload(Array(later ? names.dropFirst(1000) : names.prefix(1000)),
                        next: later ? nil : "https://api.massive.com/v3/reference/tickers?cursor=second"))
                }
                let date = request.url!.lastPathComponent
                return try response(request, payload(Array(names.prefix(date == "2026-09-09" ? current : prior)), date: date))
            })
            let usedPrior = current < 1500 && prior > current
            #expect(selected.receipt?.session == (usedPrior ? "2026-09-08" : "2026-09-09"))
            #expect(selected.receipt?.fallback == usedPrior)
            #expect(selected.receipt?.eligibleCount == (usedPrior ? prior : current))
            #expect(selected.listings.count == min(1500, usedPrior ? prior : current))
            #expect(paths.count == (current < 1500 ? 4 : 3))
        }
    }

    @Test func closedDayNeverWalksFurtherBackAndFailedFallbackRetainsUsableCurrentEvidence() async throws {
        for weekend in [true, false] {
            let clock = weekend ? now : ISO8601DateFormatter().date(from: "2026-09-11T15:00:00Z")!
            var requests = 0
            let selected = try await U.fetch(key: "synthetic-only", allowed: { true }, at: clock, transport: { request in
                requests += 1
                if request.url!.path == "/v3/reference/tickers" { return try response(request, directoryPayload(["AAA", "ZZZ"])) }
                if request.url!.lastPathComponent != "2026-09-11" { return response(request, Data(), code: 503) }
                return try response(request, payload(["AAA", "ZZZ"]))
            })
            #expect(requests == (weekend ? 2 : 3))
            #expect(selected.receipt?.session == "2026-09-11" && selected.receipt?.fallback == false)
            #expect(selected.listings.map(\.ticker) == ["ZZZ", "AAA"])
        }
    }

    @Test(arguments: [false, true]) func cancelledOrRevokedSelectionCannotIssueFallback(cancel: Bool) async throws {
        let control = SelectionControl()
        let operation = Task { @MainActor in
            try await U.fetch(key: "synthetic-only", allowed: { control.allowed },
                at: ISO8601DateFormatter().date(from: "2026-09-11T15:00:00Z")!, transport: { request in
                    control.calls += 1
                    if request.url!.path == "/v3/reference/tickers" { return try response(request, directoryPayload(["AAA"])) }
                    await withCheckedContinuation { control.resume = $0 }
                    return try response(request, payload(["AAA"]))
                })
        }
        for _ in 0..<100 where control.resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        let resume = try #require(control.resume)
        if cancel { operation.cancel() } else { control.allowed = false }
        resume.resume(); control.resume = nil
        do { _ = try await operation.value; Issue.record("Cancelled selection published") }
        catch { #expect(error is CancellationError) }
        #expect(control.calls == 2)
    }

    @Test func invalidOrEmptyPrimaryCannotInventSelectionAndFallbackCancellationPropagates() async throws {
        for mode in ["bad-primary", "empty", "cancel-fallback"] {
            var requests = 0
            do {
                _ = try await U.fetch(key: "synthetic-only", allowed: { true },
                    at: ISO8601DateFormatter().date(from: "2026-09-11T15:00:00Z")!, transport: { request in
                        requests += 1
                        if request.url!.path == "/v3/reference/tickers" { return try response(request, directoryPayload(["AAA"])) }
                        if mode == "bad-primary" { return response(request, Data(), code: 503) }
                        if mode == "cancel-fallback", request.url!.lastPathComponent != day { throw URLError(.cancelled) }
                        return try response(request, payload(mode == "empty" ? [] : ["AAA"], date: request.url!.lastPathComponent))
                    })
                Issue.record("Failed or cancelled selection published in \(mode)")
            } catch {
                if mode == "cancel-fallback" { #expect((error as? URLError)?.code == .cancelled) }
                else { #expect((error as? URLError)?.code == (mode == "empty" ? .zeroByteResource : .badServerResponse)) }
            }
            #expect(requests == (mode == "bad-primary" ? 2 : 3))
        }
    }

    @Test(arguments: StockSageHorizonResearch.Horizon.allCases)
    func bothHorizonsConsumeRankedSelectionAndKeepTheReceipt(_ horizon: StockSageHorizonResearch.Horizon) async throws {
        let selected = try U.select(directory: [listing("AAA"), listing("ZZZ")], data: payload(["AAA", "ZZZ"]), session: day, at: now)
        let research = StockSageHorizonResearch()
        var seen: [String] = []
        let started = research.start(horizon, allowed: { true }, universe: { selected }, analyze: { item in
            seen.append(item.ticker); return .init(note: "Synthetic research only")
        })
        #expect(started)
        for _ in 0..<100 where research.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(research.running == nil && seen == ["ZZZ", "AAA"])
        #expect(research.scans[horizon]?.selection == selected.receipt)
    }
}

@MainActor private final class SelectionControl {
    var allowed = true
    var calls = 0
    var resume: CheckedContinuation<Void, Never>?
}
