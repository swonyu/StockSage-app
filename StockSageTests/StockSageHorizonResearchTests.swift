import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageHorizonResearchTests {
    typealias R = StockSageHorizonResearch
    let now = ISO8601DateFormatter().date(from: "2026-09-09T15:00:00Z")!
    func listing(_ symbol: String = "AAPL") -> R.Listing {
        .init(ticker: symbol, name: symbol, market: "stocks", locale: "us", active: true,
              type: "CS", currency_name: "usd", primary_exchange: "XNAS")
    }
    func history() -> StockSagePriceHistory {
        let dates = (0..<35).map { now.addingTimeInterval(Double($0 - 35) * 86400) }
        return .init(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 35),
            highs: Array(repeating: 102, count: 35), lows: Array(repeating: 98, count: 35),
            closes: Array(repeating: 100, count: 35), volumes: Array(repeating: 1000, count: 35), priceSource: .massiveDaily)
    }
    @Test func requestBindsHostPathAndHeaderWithoutLeakingKey() throws {
        let r = try #require(R.referenceRequest(key: "synthetic-test-only"))
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-only")
        #expect(!r.url!.absoluteString.contains("synthetic-test-only"))
        #expect(r.url!.absoluteString.contains("limit=1000"))
        #expect(R.referenceRequest(key: "x", next: "https://api.massive.com/v3/reference/tickers?cursor=next") != nil)
        for bad in ["http://api.massive.com/v3/reference/tickers", "https://evil.test/v3/reference/tickers",
                    "https://api.massive.com.evil.test/v3/reference/tickers", "https://user@api.massive.com/v3/reference/tickers",
                    "https://api.massive.com:444/v3/reference/tickers", "https://api.massive.com/v3/other",
                    "https://api.massive.com/v3/reference/tickers#fragment"] {
            #expect(R.referenceRequest(key: "x", next: bad) == nil)
        }
    }
    @Test func badPagesNeverBecomeCompleteCensuses() throws {
        let good = Data(#"{"status":"OK","results":[{"ticker":"BRK.B","name":"Berkshire","market":"stocks","locale":"us","active":true,"type":"CS","currency_name":"usd"}]}"#.utf8)
        #expect(try R.parsePage(good).results.first?.ticker == "BRK.B")
        for bad in [#"{"status":"ERROR","results":[]}"#, #"{"status":"OK"}"#,
                    #"{"status":"OK","results":[{"ticker":"../../secret"}]}"#] {
            #expect(throws: (any Error).self) { _ = try R.parsePage(Data(bad.utf8)) }
        }
    }
    @Test func paginationVisitsAllPagesAndRejectsUnsafeOrRepeatedContinuation() async throws {
        func payload(_ symbol: String, next: String?) throws -> Data {
            var page: [String: Any] = ["status": "OK", "count": 1, "results": [["ticker": symbol, "name": symbol,
                "market": "stocks", "locale": "us", "active": true, "type": "ETF"]]]
            if let next { page["next_url"] = next }
            return try JSONSerialization.data(withJSONObject: page)
        }
        let continuation = "https://api.massive.com/v3/reference/tickers?cursor=second"
        var calls = 0
        let all = try await R.fetchUniverse(key: "synthetic-test-only", allowed: { true }, transport: { request in
            calls += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-only")
            let data = try payload(calls == 1 ? "BRK.B" : "ETF-X", next: calls == 1 ? continuation : nil)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(calls == 2 && all.map(\.ticker) == ["BRK.B", "ETF-X"])
        #expect(all.allSatisfy { $0.currency_name == nil }) // retained, not silently removed or assumed USD
        for next in ["https://evil.test/v3/reference/tickers", continuation] {
            calls = 0
            do {
                _ = try await R.fetchUniverse(key: "synthetic-test-only", allowed: { true }, transport: { request in
                    calls += 1
                    return (try payload("AAPL", next: next), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
                Issue.record("Incomplete census accepted")
            } catch { #expect(calls <= 2) }
        }
        #expect(R.referenceRequest(key: "x", next: continuation + "&apiKey=not-for-urls") == nil)
    }
    @Test func closedBarsAndLevelsAreRealBoundedAndUseExistingRules() throws {
        let h = history()
        let closed = try #require(R.completedHistory(h, at: now))
        #expect(closed == h)
        let extended = StockSagePriceHistory(symbol: h.symbol, dates: h.dates + [now, now.addingTimeInterval(86400)],
            opens: h.opens + [999,999], highs: h.highs + [999,999], lows: h.lows + [999,999],
            closes: h.closes + [999,999], volumes: h.volumes + [1,1], priceSource: .massiveDaily)
        #expect(R.completedHistory(extended, at: now) == h)
        let expected = StockSageAdvisor.stopTarget(action: .buy, price: 100, atr: 4,
            realizedVol: StockSageIndicators.annualizedVolatility(h.closes))
        for action in [TradeAdvice.Action.buy, .strongBuy] {
            let p = try #require(R.levels(history: h, action: action, at: now))
            #expect(p.entry == 100 && p.stop == expected.stop && p.target == expected.target)
            #expect(p.stop < p.entry && p.target > p.entry && p.at == h.dates.last)
        }
        #expect(R.levels(history: h, action: .hold, at: now) == nil)
        #expect(R.completedHistory(h, at: now.addingTimeInterval(5 * 86400)) == nil)
        let broken = StockSagePriceHistory(symbol: h.symbol, dates: h.dates, opens: h.opens,
            highs: [0], lows: h.lows, closes: h.closes, volumes: h.volumes, priceSource: .massiveDaily)
        #expect(R.completedHistory(broken, at: now) == nil)
    }
    @Test func promptsDifferByRequestedHorizonNotTradingPolicy() {
        #expect(R.Horizon.week.instructions.contains("1–7 trading days"))
        #expect(R.Horizon.fortnight.instructions.contains("7–14 trading days"))
        #expect(R.Horizon.week.instructions != R.Horizon.fortnight.instructions)
        #expect(R.Horizon.week.instructions.contains("research only"))
        #expect(!R.Horizon.fortnight.instructions.contains("next trading week"))
    }
    #if os(macOS)
    @Test func emptyResearchPresentationSeparatesWaitingFailureAndFilters() {
        typealias Panel = StockSageResearchModesPanel
        var scan = R.Scan()
        #expect(Panel.emptyState(for: scan, isRunning: false).title == "Your research starts here")
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        scan.at = now
        scan.status = "Scan incomplete: listing directory could not be verified."
        #expect(Panel.emptyState(for: scan, isRunning: false).title == "No results collected")
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        scan.status = "Stopping scan…"
        #expect(Panel.emptyState(for: scan, isRunning: true).title == "Waiting for scan results")
        #expect(Panel.emptyState(for: scan, isRunning: true).detail == "The current status is shown above.")
        #expect(scan.status == "Stopping scan…")
        scan.status = "Scan incomplete: listing directory could not be verified."
        scan.listings = [listing()]
        for running in [true, false] {
            #expect(Panel.emptyState(for: scan, isRunning: running).title == "No matching stocks")
        }
        #expect(scan.status == "Scan incomplete: listing directory could not be verified.")
    }
    #endif
    @Test func confirmedUSShareClassPricesAreNeitherForeignCurrenciesNorMinorUnits() {
        for symbol in ["BRK.B", "TEST.L"] {
            let idea = StockSageIdea(symbol: symbol, market: "US", price: 100,
                advice: StockSageAdvisor.advise(history: history()), spark: [], generatedAt: now,
                priceAsOf: now, priceSource: .massiveDaily)
            let facts = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: [:], at: now, quotedInUSD: true).facts
            #expect(facts[1].contains("Observed quote: \(StockSageCurrency.adaptivePrice(100)) USD."))
        }
    }
    @Test func historyMustConfirmIdentityAdjustmentAndCompleteParsing() throws {
        let bar: [String: Any] = ["t": now.timeIntervalSince1970 * 1000, "o": 100, "h": 102, "l": 98, "c": 100, "v": 10]
        var earlier = bar; earlier["t"] = now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000
        let base: [String: Any] = ["status": "OK", "ticker": "AAPL", "adjusted": true, "resultsCount": 2, "results": [earlier, bar]]
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: base), symbol: "AAPL")?.count == 2)
        for (key, value) in [("ticker", "MSFT" as Any), ("adjusted", false as Any), ("adjusted", 1 as Any),
                             ("resultsCount", 3 as Any), ("next_url", "https://api.massive.com/next" as Any)] {
            var altered = base; altered[key] = value
            #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: altered), symbol: "AAPL") == nil)
        }
        var absent = base; absent.removeValue(forKey: "adjusted")
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: absent), symbol: "AAPL") == nil)
        var noVolume = bar; noVolume.removeValue(forKey: "v")
        var incomplete = base; incomplete["results"] = [earlier, noVolume]
        #expect(R.parseResearchHistory(try JSONSerialization.data(withJSONObject: incomplete), symbol: "AAPL") == nil)
    }
    @Test func dailyBoundaryUsesNewYorkAcrossDSTAndWeekend() throws {
        for stamp in ["2026-03-09T04:30:00Z", "2026-11-02T05:30:00Z", "2026-09-12T15:00:00Z"] {
            let at = try #require(ISO8601DateFormatter().date(from: stamp))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let today = calendar.startOfDay(for: at)
            let dates = (0..<36).map { calendar.date(byAdding: .day, value: $0 - 35, to: today)! }
            let h = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 36),
                highs: Array(repeating: 102, count: 36), lows: Array(repeating: 98, count: 36),
                closes: Array(repeating: 100, count: 36), volumes: Array(repeating: 1000, count: 36), priceSource: .massiveDaily)
            let filtered = try #require(R.completedHistory(h, at: at))
            #expect(filtered.count == 35 && filtered.dates.last == dates[34])
            #expect(filtered.dates.allSatisfy { $0 < today })
        }
    }
    @Test func manualRunVisitsEveryListingExactlyOnceAndCannotOverlap() async throws {
        let r = R()
        let names = (0..<150).map { listing("S\($0)") }
        var seen: [String] = []
        let started = r.start(.week, allowed: { true }, universe: { .init(names) }, analyze: { value in
            seen.append(value.ticker); return .init(note: "Synthetic research only")
        })
        #expect(started)
        let overlapped = r.start(.fortnight, allowed: { true }, universe: { .init([]) }, analyze: { _ in .init(note: "must not run") })
        #expect(!overlapped)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(r.running == nil && seen == names.map(\.ticker))
        #expect(r.scans[.week]?.results.count == 150 && r.scans[.fortnight] == nil)
        let count = seen.count
        try await Task.sleep(for: .milliseconds(10))
        #expect(seen.count == count) // no timer or automatic repeat
    }
    @Test(arguments: ["unreachable", "invalid", "cancel", "settings"])
    func failedPreflightRetryRetainsCompletedResearch(outcome: String) async throws {
        let r = R()
        let levels = R.Levels(entry: 100, stop: 90, target: 120, at: now, basis: "Synthetic fixture")
        let receipt = StockSageResearchUniverse.Receipt(session: "2026-09-08", requestedAt: now,
            returnedCount: 1, eligibleCount: 1, directoryCount: 1, partialSession: false, dollarVolume: ["AAPL": 100])
        let first = r.start(.week, allowed: { true }, universe: { .init([listing()], receipt: receipt) },
            analyze: { _ in .init(levels: levels, facts: ["Synthetic retained evidence"],
                note: "Earlier result", at: now, model: "synthetic-model") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let previous = try #require(r.scans[.week])
        try #require(previous.results["AAPL"]?.note == "Earlier result")
        var analyzed = false
        var permitted = true
        var resume: CheckedContinuation<Void, Never>?
        let retry = r.start(.week, allowed: { permitted }, universe: {
            if outcome == "cancel" || outcome == "settings" {
                await withCheckedContinuation { resume = $0 }
                return .init([listing("NEW")])
            }
            if outcome == "invalid" { return .init([listing(), listing()]) }
            throw URLError(.cannotConnectToHost)
        }, analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(retry)
        if outcome == "cancel" || outcome == "settings" {
            for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
            let continuation = try #require(resume)
            if outcome == "cancel" { r.stop() } else { permitted = false }
            continuation.resume()
        }
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let retained = try #require(r.scans[.week])
        #expect(!analyzed)
        #expect(retained.listings == previous.listings)
        #expect(retained.at == previous.at)
        #expect(retained.selection == receipt && retained.selection == previous.selection)
        #expect(retained.results["AAPL"]?.note == "Earlier result")
        #expect(retained.results["AAPL"]?.facts == ["Synthetic retained evidence"])
        #expect(retained.results["AAPL"]?.at == now)
        #expect(retained.results["AAPL"]?.levels == levels && retained.results["AAPL"]?.model == "synthetic-model")
        #expect(retained.status.contains("Earlier scan data retained; no new listings checked."))
        #expect(retained.status.contains(outcome == "cancel" || outcome == "settings" ? "Scan stopped" : "could not be verified"))
    }

    @Test func firstPreflightFailureDoesNotInventPreviousResults() async throws {
        let r = R()
        var analyzed = false
        let started = r.start(.week, allowed: { true }, universe: { throw URLError(.cannotConnectToHost) },
            analyze: { _ in analyzed = true; return .init(note: "Must not run") })
        #expect(started)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let scan = try #require(r.scans[.week])
        #expect(scan.at != nil && scan.listings.isEmpty && scan.results.isEmpty && !analyzed)
        #expect(scan.status == "Scan incomplete: US directory or dated market activity could not be verified. Check Massive settings and retry.")
    }

    @Test(arguments: [false, true])
    func acceptedDirectoryReplacesPreviousScan(empty: Bool) async throws {
        let r = R()
        let first = r.start(.week, allowed: { true }, universe: { .init([listing("OLD")]) },
            analyze: { _ in .init(note: "Earlier") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.scans[.week]?.results["OLD"] != nil)
        let requestedAfter = Date()
        let names = empty ? [] : [listing("NEW")]
        let second = r.start(.week, allowed: { true }, universe: { .init(names) },
            analyze: { _ in .init(note: "New") })
        #expect(second)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil)
        let scan = try #require(r.scans[.week])
        let requested = try #require(scan.at)
        #expect(requested >= requestedAfter && scan.listings == names)
        #expect(scan.results["OLD"] == nil && scan.results.count == names.count)
        #expect(scan.status.contains("Scan finished") && !scan.status.contains("Earlier"))
    }

    @Test(arguments: [true, false], [true, false])
    func stoppedAcceptedRetryKeepsNewPartialResultsNotOldScan(cancel: Bool, completedFirst: Bool) async throws {
        let r = R()
        let first = r.start(.week, allowed: { true }, universe: { .init([listing("OLD")]) },
            analyze: { _ in .init(note: "Earlier") })
        #expect(first)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.scans[.week]?.results["OLD"] != nil)
        var permitted = true
        var resume: CheckedContinuation<Void, Never>?
        let names = completedFirst ? [listing("NEW"), listing("LATE")] : [listing("LATE")]
        let retry = r.start(.week, allowed: { permitted }, universe: { .init(names) }, analyze: { item in
            if item.ticker == "LATE" { await withCheckedContinuation { resume = $0 } }
            return .init(note: item.ticker)
        })
        #expect(retry)
        for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try #require(resume)
        #expect(r.scans[.week]?.results["NEW"]?.note == (completedFirst ? "NEW" : nil))
        if cancel { r.stop() } else { permitted = false }
        continuation.resume()
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(r.running == nil && r.activeSymbol == nil)
        let scan = try #require(r.scans[.week])
        #expect(scan.listings == names && Set(scan.results.keys) == (completedFirst ? ["NEW"] : []))
        #expect(scan.status.contains("Scan stopped") && !scan.status.contains("Earlier"))
    }
    @Test(arguments: R.Horizon.allCases)
    func manualRunCapsDirectoryAt500BeforeResearch(_ horizon: R.Horizon) async throws {
        let r = R()
        let names = (0..<13_000).map { listing(String(format: "S%05d", $0)) }
        var seen: [String] = []
        let started = r.start(horizon, allowed: { true }, universe: { .init(names) }, analyze: { item in
            seen.append(item.ticker)
            return .init(note: "Synthetic research only")
        })
        #expect(started)
        for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(r.running == nil)
        #expect(seen.count == 500 && Set(seen).count == 500)
        #expect(Array(seen.prefix(500)) == names.prefix(500).map(\.ticker))
        #expect(r.scans[horizon]?.listings.count == 500)
        #expect(r.scans[horizon]?.results.count == 500)
        #expect(r.scans[horizon]?.status.contains("500 listings checked once") == true)
    }

    @Test func cancellationOrSettingsChangeCannotPublishLateResult() async throws {
        for cancel in [true, false] {
            let r = R()
            var permitted = true
            var resume: CheckedContinuation<Void, Never>?
            defer { r.stop(); resume?.resume() }
            var analyzed: [String] = []
            let started = r.start(.week, allowed: { permitted }, universe: { .init([listing(), listing("MSFT")]) }, analyze: { item in
                analyzed.append(item.ticker)
                if item.ticker == "AAPL" { await withCheckedContinuation { resume = $0 } }
                return .init(note: "late")
            })
            #expect(started)
            for _ in 0..<100 where resume == nil { try await Task.sleep(for: .milliseconds(5)) }
            let continuation = try #require(resume)
            #expect(r.activeSymbol == "AAPL")
            #if os(macOS)
            let scan = try #require(r.scans[.week])
            #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: r, scan: scan, horizon: .week) == "Checking…")
            #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .week) == "Queued")
            #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .fortnight) == "Not checked")
            #endif
            if cancel { r.stop() } else { permitted = false }
            #expect(r.running == .week, "The first request still owns the scan until it unwinds")
            let overlap = r.start(.fortnight, allowed: { true }, universe: { .init([]) },
                analyze: { _ in .init(note: "must not run") })
            #expect(!overlap && r.running == .week && r.scans[.fortnight] == nil)
            #if os(macOS)
            if cancel {
                #expect(r.activeSymbol == nil)
                #expect(StockSageResearchModesPanel.resultLabel("AAPL", research: r, scan: scan, horizon: .week) == "Not checked")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .week) == "Not checked")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: scan, horizon: .fortnight) == "Not checked")
                var completed = scan
                completed.results["MSFT"] = .init(note: "Synthetic completed check")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: completed, horizon: .week) == "Incomplete")
                #expect(StockSageResearchModesPanel.resultLabel("MSFT", research: r, scan: completed, horizon: .fortnight) == "Incomplete")
            }
            #endif
            resume = nil
            continuation.resume()
            for _ in 0..<100 where r.running != nil { try await Task.sleep(for: .milliseconds(5)) }
            #expect(r.running == nil && r.activeSymbol == nil && r.scans[.week]?.results.isEmpty == true)
            #expect(analyzed == ["AAPL"], "Neither stop nor revoked settings may start the second listing")
        }
    }
}
