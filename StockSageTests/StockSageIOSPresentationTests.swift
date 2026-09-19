#if os(iOS)
import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import StockSage

@Suite("iPhone Chat and Research presentation", .serialized)
@MainActor
struct StockSageIOSPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_739_200)

    @Test(arguments: [false, true])
    func chatReceiptAndEvidenceFitThePhone(accessibility: Bool) async throws {
        let receipt = StockSageChatSession.Turn(id: UUID(), question: "add rklb to watchlist",
            snapshot: .init(at: now, facts: [], context: "Local watchlist action."), model: "StockSage",
            answer: "Added RKLB to your watchlist.", evidence: [], notice: "Local watchlist action completed.",
            isWatchlistAction: true)
        var edits = 0
        try await capture(StockSageChatSection.turnContent(receipt, pending: false, editQuestion: { edits += 1 }),
                          name: "chat-watchlist", accessibility: accessibility)

        let symbol = StockSageSymbol(symbol: "ORCL", market: "US", quotes: [
            .init(price: 159.70, previousPrice: 158, marketTime: now, priceSource: .massiveSIP)
        ])
        var snapshot = StockSageChat.snapshot(symbols: [symbol], ideas: [], earnings: [:], sample: false, now: now)
        let fact = try #require(snapshot.facts.first)
        let source = StockSageChat.Source(id: "fixture.news", subject: "ORCL",
            attribution: "Fixture market bulletin with a deliberately long attribution", date: now,
            excerpt: "Synthetic source excerpt · تحقق من المصدر والتاريخ.",
            warning: "Attributed report, not a verified forecast or an executable quote.",
            link: URL(string: "https://example.invalid/research"))
        snapshot.sources = [source]
        let turn = StockSageChatSession.Turn(id: UUID(),
            question: "What does this dated observation tell me, and what remains unknown?",
            snapshot: snapshot, model: "fixture",
            answer: "Synthetic answer: a recorded observation is not a prediction. Check the captured source and its timestamp below.",
            evidence: [fact.id, source.id], notice: "Unverified draft · fixture")
        try await capture(StockSageChatSection.turnContent(turn, pending: false, editQuestion: { edits += 1 }),
                          name: "chat-evidence", accessibility: accessibility)
        #expect(edits == 0, "Rendering cannot edit or send a question")
        #expect(turn.snapshot == snapshot && turn.evidence == [fact.id, source.id])
    }

    @Test(arguments: [false, true], StockSageHorizonResearch.Horizon.allCases)
    func populatedResearchAndDetailFitThePhone(accessibility: Bool, horizon: StockSageHorizonResearch.Horizon) async throws {
        typealias R = StockSageHorizonResearch
        let suite = "stocksage.ios.presentation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let research = R()
        let listings = ["AAPL", "MSFT", "NVDA", "AMD", "META", "RKLB", "ORCL", "FAIL"].map { symbol in
            R.Listing(ticker: symbol, name: "\(symbol) synthetic company with a longer display name",
                market: "stocks", locale: "us", active: true, type: "CS", currency_name: "usd",
                primary_exchange: "XNAS")
        }
        let receipt = StockSageResearchUniverse.Receipt(session: "2026-09-11", requestedAt: now,
            returnedCount: listings.count, eligibleCount: listings.count, directoryCount: listings.count, partialSession: true,
            dollarVolume: Dictionary(uniqueKeysWithValues: listings.enumerated().map { ($0.element.ticker, Double(900 - $0.offset * 100)) }))
        let result = R.Result(
            verdict: .init(action: .buy, reason: "Synthetic interpretation, not a verified trading edge.",
                           risk: "Future news and overnight gaps remain unknown.", evidence: ["F1"]),
            levels: .init(entry: 159.70, stop: 150, target: 179.10, at: now,
                basis: "Synthetic daily ATR reference plan. These are scenarios, not forecasts."),
            facts: ["Synthetic fixture only; no live quote or order."], note: "Synthetic research only.",
            at: now, model: "fixture", referenceClose: (value: 159.70, at: now))
        var analyses = 0
        // Use the same injected offline seam as the existing Mac presentation tests.
        let started = research.start(horizon, allowed: { true }, universe: { .init(listings, receipt: receipt) },
            rank: { scan, horizon in
                .success(.fixture(scan: scan, symbols: ["RKLB", "AAPL", "MSFT", "NVDA", "AMD"], horizon: horizon))
            },
            analyze: { item in
                analyses += 1
                if item.ticker == "FAIL" {
                    return .init(note: "No verified opinion. Synthetic incomplete result.\nserver=timeout status=unavailable", at: now)
                }
                var opinion = result
                if item.ticker == "RKLB" || item.ticker == "ORCL" {
                    opinion.verdict = .init(action: item.ticker == "RKLB" ? .strongBuy : .sell,
                        reason: "Synthetic interpretation, not a verified trading edge.", risk: "Synthetic risk.", evidence: ["F1"])
                }
                return opinion
            })
        try #require(started)
        defer { research.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while research.running != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(research.running == nil && analyses == listings.count)
        let captured = try #require(research.scans[horizon])
        try #require(captured.ranking != nil && captured.rankingFailure == nil)
        var presentation = StockSageResearchModesPanel.Presentation(horizon: horizon)
        var presentationChanges = 0
        let panel = StockSageResearchModesPanel(store: store, research: research,
            presentation: Binding(get: { presentation }, set: { presentation = $0; presentationChanges += 1 }))
        let suffix = horizon == .week ? "" : "-fortnight"
        try await capture(panel.defaultAppStorage(defaults), name: "research-results\(suffix)", accessibility: accessibility) { _, window in
            #expect(nativeElements(window).contains {
                nativeIdentifier($0) == "research.filter" && $0.accessibilityTraits.contains(.button)
                    && $0.accessibilityLabel?.contains("Research result filter") == true
            },
                    "iPhone must offer the existing All checks, opinion and incomplete filters")
            let rows = nativeElements(window).compactMap(nativeIdentifier).filter { $0.hasPrefix("research.result.") }
            #expect(Set(rows) == Set(["RKLB", "AAPL", "MSFT", "NVDA", "AMD"].map { "research.result.\($0)" }),
                    "The native main list must show only the top five, excluding the sixth Buy, Sell and incomplete check")
            #expect(nativeElements(window).contains { $0.accessibilityLabel?.contains("1 incomplete") == true },
                    "Incomplete coverage must remain visible above the shortlist")
        }
        try await capture(StockSageResearchModesPanel.resultDetail(listings[0], result: captured.results["AAPL"]),
                          name: "research-detail\(suffix)", accessibility: accessibility)
        #expect(presentationChanges == 0 && presentation.selected == nil && presentation.search.isEmpty
                && presentation.horizon == horizon)
        if horizon == .week {
            let model = PhoneResearchPresentationModel(horizon: horizon)
            let interactive = PhoneResearchPresentationFixture(model: model, store: store, research: research)
                .defaultAppStorage(defaults)
            try await capture(interactive, name: "research-filter-actions", accessibility: accessibility,
                              viewportHeight: 812) { _, window in
                for filter in [StockSageResearchModesPanel.ResultFilter.all, .incomplete] {
                    let picker = try await reveal(in: window, identifier: "research.filter")
                    try #require(picker.accessibilityActivate(), "The native research filter must open")
                    let owner = try #require(picker as? UIButton)
                    let choice = try await element(in: window, label: filter.rawValue)
                    try await activateMenuChoice(filter.rawValue, rendered: choice, owner: owner)
                    try await waitUntil("The selected research filter must update") { model.presentation.filter == filter }
                    if filter == .all {
                        _ = try await reveal(in: window, identifier: "research.result.ORCL")
                        #expect(model.presentation.selected == nil,
                                "Showing All checks must expose the original Sell without opening or changing it")
                    }
                }
                let incomplete = try await reveal(in: window, identifier: "research.result.FAIL")
                let rows = nativeElements(window).compactMap(nativeIdentifier).filter { $0.hasPrefix("research.result.") }
                #expect(Set(rows) == ["research.result.FAIL"], "Incomplete must exclude the completed opinions")
                try #require(incomplete.accessibilityActivate(), "The incomplete row must open its captured explanation")
                try await waitUntil("The native row must select the incomplete check") { model.presentation.selected == "FAIL" }
                _ = try await reveal(in: window, labelContaining: "No verified opinion. Synthetic incomplete result.")
                let close = try await element(in: window, label: "Close details")
                if !close.accessibilityActivate() {
                    let control = try #require(close as? UIControl, "Close details must expose the rendered native toolbar control")
                    try #require(control.isEnabled && control.window === window)
                    control.sendActions(for: .touchUpInside)
                }
                try await waitUntil("Closing evidence must dismiss the sheet and return to the same incomplete filter") {
                    func presented(_ controller: UIViewController) -> Bool {
                        controller.presentedViewController != nil || controller.children.contains(where: presented)
                    }
                    return model.presentation.selected == nil
                        && (window.rootViewController.map { !presented($0) } ?? false)
                }
                #expect(model.presentation.filter == .incomplete && model.presentation.search.isEmpty)
            }
        }
        #expect(research.running == nil && analyses == listings.count && research.scans[horizon]?.at == captured.at)
        #expect(research.scans[horizon]?.selection == receipt && research.scans[horizon]?.results.count == listings.count)
        #expect(store.userSymbols.isEmpty, "Rendering cannot change the isolated watchlist")
    }

    @Test(arguments: [false, true])
    func savedResearchRendersEveryTerminalOutcomeAtAccessibilitySizes(accessibility: Bool) async throws {
        typealias H = StockSageResearchHistory
        let suite = "stocksage.ios.terminal-outcomes.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let history = H(storageURL: nil, defaults: defaults)
        func stamp(_ value: String) throws -> Date { try Date(value, strategy: .iso8601) }
        let reference = try stamp("2026-09-11T04:00:00Z")

        // The captured reference and levels always precede completion, as a real snapshot does.
        func dailyRun(_ symbol: String, completed: String, capturedAt: Date? = nil) throws -> H.Run {
            let captured = capturedAt ?? reference
            return .init(id: UUID(), startedAt: try stamp(completed).addingTimeInterval(-60),
                completedAt: try stamp(completed), horizon: .week,
                predictions: [.init(symbol: symbol, name: "\(symbol) synthetic company", action: "Strong Buy",
                    reason: "Original \(symbol) research opinion, captured before any outcome.",
                    risk: "Synthetic risk: demand and prices can change.", evidence: ["F1"],
                    facts: ["Original synthetic evidence captured before review."], model: "fixture-model",
                    note: "Synthetic unvalidated research only.", referencePrice: 100, referenceDate: captured,
                    levels: .init(entry: 100, stop: 90, target: 120, at: captured,
                        basis: "Synthetic original daily-price scenario, not a forecast."))],
                coverage: .init(requested: 2, checked: 2, incomplete: 1, buyCount: 1, selection: nil),
                measurementPolicy: .nextTradingDateSessions, outcomePolicy: .dailyBarFirstHit)
        }
        func observation(_ symbol: String, sessions: [String], highs: [Double], lows: [Double],
                         closes: [Double]) throws -> H.Observation {
            var dates = [reference], opens = [100.0], high = [100.0], low = [100.0], close = [100.0]
            for (index, session) in sessions.enumerated() {
                dates.append(try stamp(session)); opens.append(100)
                high.append(highs[index]); low.append(lows[index]); close.append(closes[index])
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let settled = calendar.date(byAdding: .day, value: 1,
                to: calendar.startOfDay(for: try stamp(sessions[sessions.count - 1])))!
            return .init(history: .init(symbol: symbol, dates: dates, opens: opens, highs: high, lows: low,
                closes: close, volumes: Array(repeating: 100, count: dates.count), priceSource: .massiveDaily),
                splitAdjusted: true, provider: "Synthetic adjusted daily prices", fetchedAt: settled)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func settledNow(_ session: String) throws -> Date {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: try stamp(session)))!
                .addingTimeInterval(60)
        }

        // One bar reaching both levels: the conservative stop-first rule applies.
        let stopped = try dailyRun("STOP", completed: "2026-09-14T21:00:00Z")
        let stopReceipt = H.evaluate(stopped.predictions[0], in: stopped,
            observation: try observation("STOP", sessions: ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z"],
                highs: [105, 121], lows: [98, 89], closes: [100, 100]),
            now: try settledNow("2026-09-16T04:00:00Z"))
        try #require(stopReceipt.terminalKind == .stopHit && stopReceipt.sameBarStopFirst == true)

        let hit = try dailyRun("TGET", completed: "2026-09-14T21:00:00Z")
        let hitReceipt = H.evaluate(hit.predictions[0], in: hit,
            observation: try observation("TGET", sessions: ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z"],
                highs: [105, 121], lows: [98, 95], closes: [100, 118]),
            now: try settledNow("2026-09-16T04:00:00Z"))
        try #require(hitReceipt.terminalKind == .targetHit)

        let quiet = try dailyRun("HRZN", completed: "2026-09-14T21:00:00Z")
        let sessions = ["2026-09-15T04:00:00Z", "2026-09-16T04:00:00Z", "2026-09-17T04:00:00Z",
                        "2026-09-18T04:00:00Z", "2026-09-21T04:00:00Z", "2026-09-22T04:00:00Z",
                        "2026-09-23T04:00:00Z"]
        let quietReceipt = H.evaluate(quiet.predictions[0], in: quiet,
            observation: try observation("HRZN", sessions: sessions,
                highs: Array(repeating: 105, count: 7), lows: Array(repeating: 95, count: 7),
                closes: Array(repeating: 97, count: 7)),
            now: try settledNow("2026-09-23T04:00:00Z"))
        try #require(quietReceipt.terminalKind == .horizonClose)

        // Completed long enough ago that it is always past its first monitoring session.
        let active = try dailyRun("ACTV", completed: "2026-01-02T21:00:00Z",
            capturedAt: try stamp("2026-01-02T14:30:00Z"))

        for (run, receipt) in [(stopped, stopReceipt), (hit, hitReceipt), (quiet, quietReceipt)] {
            try #require(history.record(run))
            try #require(history.recordEvaluation(receipt, runID: run.id, symbol: run.predictions[0].symbol))
        }
        try #require(history.record(active))
        let originalRuns = history.runs

        try await capture(StockSageResearchHistoryView(store: store, history: history).defaultAppStorage(defaults),
            name: "research-terminal-outcomes", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            let check = try await reveal(in: window, identifier: "research.history.check")
            #expect(check.accessibilityLabel?.contains("Check active results") == true)
            #expect(check.accessibilityTraits.contains(.notEnabled), "Native fixture outcome checks stay disabled")
            let link = try await reveal(in: window, identifier: "research.history.run.\(stopped.id)")
            try #require(link.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: "Stop hit")
            _ = try await reveal(in: window, labelContaining: "Adjusted scenario")
            _ = try await reveal(in: window, labelContaining: "Observed outcome price")
            _ = try await reveal(in: window, labelContaining: "the conservative stop-first rule was applied")
            _ = try await reveal(in: window, labelContaining: "Synthetic adjusted daily prices")
            try await saveViewport(window, name: "research-terminal-stop-detail", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: hit.id) },
            name: "research-terminal-target", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Target hit")
            _ = try await reveal(in: window, labelContaining: "Daily bars cannot establish intraday order")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("stop-first rule") == true })
            try await saveViewport(window, name: "research-terminal-target-detail", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: quiet.id) },
            name: "research-terminal-horizon", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Horizon close")
            try await saveViewport(window, name: "research-terminal-horizon-detail", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: active.id) },
            name: "research-terminal-active", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Active")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Target hit") == true })
            try await saveViewport(window, name: "research-terminal-active-detail", accessibility: accessibility)
        }
        // The aggregate counts live on Home, reported as three separate kinds and never as a rate.
        try await captureWorkspace(section: .briefing, name: "home-terminal-outcome-counts",
            accessibility: accessibility, researchHistory: history) { _, window in
            let counts = try await reveal(in: window, identifier: "home.research.outcomes")
            let label = try #require(counts.accessibilityLabel)
            #expect(label.contains("1 target hit") && label.contains("1 stop hit")
                    && label.contains("1 horizon close") && label.contains("3 outcomes recorded"), "\(label)")
            #expect(!label.lowercased().contains("win rate"))
            _ = try await reveal(in: window, labelContaining: "Separate counts, not a win rate.")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Earlier endpoint-only checks") == true },
                    "No legacy endpoint receipts exist in this fixture, so that line stays absent")
            try await saveViewport(window, name: "home-terminal-outcome-counts", accessibility: accessibility)
        }
        #expect(history.runs == originalRuns && history.lastError == nil && !history.isChecking,
                "Rendering terminal outcomes must not rewrite original research or recorded receipts")
    }

    @Test(arguments: [false, true])
    func savedResearchHistoryShowsOriginalEvidenceAndLaterOutcomes(accessibility: Bool) async throws {
        typealias H = StockSageResearchHistory
        let suite = "stocksage.ios.saved-research.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let history = H(storageURL: nil, defaults: defaults)
        let reference = try Date("2026-08-31T04:00:00Z", strategy: .iso8601)
        func run(_ symbol: String, horizon: H.Horizon, completed: Date) -> H.Run {
            .init(id: UUID(), startedAt: completed.addingTimeInterval(-60), completedAt: completed,
                horizon: horizon, predictions: [.init(symbol: symbol, name: "\(symbol) synthetic company",
                    action: "Strong Buy", reason: "Original \(symbol) research opinion, captured before review.",
                    risk: "Synthetic risk: demand and prices can change.", evidence: ["F1"],
                    facts: ["Original synthetic evidence captured before review."], model: "fixture-model",
                    note: "Synthetic unvalidated research only.", referencePrice: 200, referenceDate: reference,
                    levels: .init(entry: 200, stop: 190, target: 220, at: reference,
                        basis: "Synthetic original daily-price scenario, not a forecast."))],
                coverage: .init(requested: 2, checked: 2, incomplete: 1, buyCount: 1, selection: nil))
        }
        let completed = run("ACME", horizon: .week,
            completed: try Date("2026-09-01T21:00:00Z", strategy: .iso8601))
        let pending = run("FUTR", horizon: .fortnight,
            completed: try Date("2026-09-14T21:00:00Z", strategy: .iso8601))
        try #require(history.record(completed) && history.record(pending))
        let benchmark = try #require(H.benchmarkDay(after: completed.completedAt))
        #expect(benchmark > completed.completedAt && benchmark != reference)
        let target = try #require(H.targetClose(after: completed.completedAt, horizon: .week))
        let reviewAvailable = try #require(H.reviewAvailableAt(for: completed))
        let observation = H.Observation(history: .init(symbol: "ACME", dates: [benchmark, target],
            opens: [100, 110], highs: [105, 110], lows: [100, 110], closes: [105, 110],
            volumes: [100, 100], priceSource: .massiveDaily), splitAdjusted: true,
            provider: "Synthetic adjusted daily prices", fetchedAt: reviewAvailable.addingTimeInterval(60))
        let evaluation = H.evaluate(completed.predictions[0], in: completed, observation: observation,
            now: reviewAvailable.addingTimeInterval(120))
        try #require(evaluation.state == .evaluated && evaluation.direction == .rose)
        #expect(evaluation.comparisonReferenceDate == benchmark && evaluation.comparisonReferencePrice == 100,
                "The return starts at the first trading day's open after completion, never the original reference or that day's close")
        let change = try #require(evaluation.priceReturn)
        #expect(abs(change - 0.10) < 0.000000001)
        try #require(history.recordEvaluation(evaluation, runID: completed.id, symbol: "ACME"))
        let notDue = H.availability(for: pending, now: pending.completedAt.addingTimeInterval(60))
        try #require(notDue.state == .notDue)
        try #require(history.recordEvaluation(notDue, runID: pending.id, symbol: "FUTR"))
        let originalRuns = history.runs
        try await capture(StockSageResearchHistoryView(store: store, history: history).defaultAppStorage(defaults),
            name: "research-history", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            let check = try await reveal(in: window, identifier: "research.history.check")
            #expect(check.accessibilityTraits.contains(.notEnabled), "Native fixture outcome checks must be disabled")
            let link = try await reveal(in: window, identifier: "research.history.run.\(completed.id)")
            try #require(link.accessibilityActivate(), "Open the saved run through its actual native NavigationLink")
            _ = try await reveal(in: window, labelContaining: "Original ACME research opinion")
            let originalPrice = try await reveal(in: window, labelContaining: "Original reference:")
            #expect(originalPrice.accessibilityLabel?.contains(200.formatted(.currency(code: "USD"))) == true)
            _ = try await reveal(in: window, labelContaining: "Rose ·")
            _ = try await reveal(in: window, labelContaining: "Buy direction supported")
            let comparable = try await reveal(in: window, labelContaining: "Benchmark open → review close:")
            #expect(comparable.accessibilityLabel?.contains(100.formatted(.currency(code: "USD"))) == true)
            #expect(comparable.accessibilityLabel?.contains(110.formatted(.currency(code: "USD"))) == true)
            try await saveViewport(window, name: "research-history-reviewed-detail", accessibility: accessibility)
            let evidence = try await reveal(in: window, labelContaining: "Original evidence and model")
            try #require(evidence.accessibilityActivate(), "Open the actual original-evidence disclosure")
            _ = try await reveal(in: window, labelContaining: "Original synthetic evidence captured before review.")
            _ = try await reveal(in: window, labelContaining: "Original scenario")
            try await saveViewport(window, name: "research-history-original-evidence", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: pending.id) },
            name: "research-history-not-due", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Original FUTR research opinion")
            _ = try await reveal(in: window, labelContaining: "Not due yet")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Buy direction supported") == true })
            try await saveViewport(window, name: "research-history-not-due-detail", accessibility: accessibility)
        }
        let emptyHistory = H(storageURL: nil, defaults: defaults)
        try await capture(StockSageResearchHistoryView(store: store, history: emptyHistory).defaultAppStorage(defaults),
            name: "research-history-empty", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "No saved research yet")
            let check = try await reveal(in: window, identifier: "research.history.check")
            #expect(check.accessibilityTraits.contains(.notEnabled))
        }
        try await capture(StockSageResearchHistoryButton(store: store, history: history).defaultAppStorage(defaults),
            name: "research-history-button", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            let button = try await element(in: window, identifier: "research.saved")
            try #require(button.accessibilityActivate(), "Use the real Saved research button to open its sheet")
            _ = try await element(in: window, label: "Saved research")
            try await saveViewport(window, name: "research-history-opened-sheet", accessibility: accessibility)
        }
        #expect(history.runs == originalRuns && history.lastError == nil && !history.isChecking,
                "Native history/detail navigation must not rewrite original research or recorded outcomes")
        let retained = history.runs.first { $0.id == completed.id }
        #expect(retained?.predictions == completed.predictions)
        #expect(emptyHistory.runs.isEmpty && store.userSymbols.isEmpty)
    }

    @Test(arguments: [false, true])
    func onboardingScrollsAndCompletesInThePhoneViewport(accessibility: Bool) async throws {
        let suite = "stocksage.ios.onboarding.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var presented = true
        let binding = Binding(get: { presented }, set: { presented = $0 })
        try await capture(OnboardingSheet(isPresented: binding).defaultAppStorage(defaults),
                          name: "onboarding", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { host, window in
            defer {
                print("Onboarding state: presented=\(presented), scopedDone=\(defaults.bool(forKey: "stocksage.onboarding.done")), hostDone=\(UserDefaults.standard.bool(forKey: "stocksage.onboarding.done"))")
            }
            let button = try await element(in: window, identifier: "onboarding.getStarted")
            let frame = button.accessibilityFrame
            #expect(frame.minY >= window.frame.minY && frame.maxY <= window.frame.maxY,
                    "Get started must remain inside the phone viewport at large text sizes")
            let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }
                .first { $0.contentSize.height > $0.bounds.height + 1 })
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(scroll.contentOffset.y > 0, "The actual welcome content must scroll to its final instructions")
            try #require(button.accessibilityActivate(), "The native Get started action must activate")
            try await waitUntil("Get started must dismiss the binding and save to scoped defaults") {
                !presented && defaults.bool(forKey: "stocksage.onboarding.done")
            }
            #expect(!presented && defaults.bool(forKey: "stocksage.onboarding.done"))
        }
    }

    @Test(arguments: [false, true], ["fresh", "draft", "busy", "sample-and-busy"])
    func assessmentControlsExplainAndPerformOnlyAvailableActions(accessibility: Bool, state: String) async throws {
        var requests = 0
        let controls = StockSageAIAssessmentPanel.RequestControls(
            hasRecord: false, hasDraft: state != "fresh",
            activeSymbol: state.contains("busy") ? "QCOM" : nil,
            isSampleData: state == "sample-and-busy", request: { requests += 1 })
        try await capture(controls, name: "assessment-\(state)", accessibility: accessibility) { _, window in
            let elements = nativeElements(window)
            if let reason = controls.disabledReason {
                #expect(elements.contains { $0.accessibilityLabel?.contains(reason) == true },
                        "The disabled reason must be available in the rendered accessibility tree")
                #expect(requests == 0)
            } else {
                let action = try await element(in: window, label: controls.title)
                try #require(action.accessibilityActivate(), "Activate the real assessment control, not its stored closure")
                try await waitUntil { requests == 1 }
                #expect(requests == 1)
            }
        }
    }

    @Test(arguments: [false, true])
    func tapeDistinguishesMissingReferenceAndClearsItOnReload(accessibility: Bool) async throws {
        let suite = "stocksage.ios.tape.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "stocksage.ticks.nasdaqOnly")
        var referenceCalls = 0
        var tapeSymbols: [String] = []
        let reference = [Int64(12): StockSageMassiveTicks.Exchange(id: 12, mic: "XNAS", acronym: "NASDAQ")]
        let fixture = PhoneTapeReloadFixture(loadExchanges: {
            referenceCalls += 1
            if referenceCalls == 1 { throw StockSageMassiveTicks.Failure.unavailable }
            return reference
        }, loadTape: { symbol, _, _ in
            tapeSymbols.append(symbol)
            return .init(trades: [.init(price: 25.25, size: 10, exchange: 12, timestamp: now, sequence: 7)],
                         quotes: [.init(symbol: symbol, bid: 25, ask: 25.5, bidSize: 10, askSize: 20,
                                        bidExchange: 12, askExchange: 12, timestamp: now, sequence: 8)])
        })
        try await capture(fixture.defaultAppStorage(defaults), name: "tape-reference", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            defer { print("Tape state: referenceCalls=\(referenceCalls), symbols=\(tapeSymbols), nasdaqOnly=\(defaults.bool(forKey: "stocksage.ticks.nasdaqOnly"))") }
            try await waitUntil("First reference and RKLB tape loaders must run") { referenceCalls == 1 && tapeSymbols == ["RKLB"] }
            _ = try await reveal(in: window, labelContaining: "Nasdaq attribution unavailable")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("No matching trades") == true })
            let reload = try await element(in: window, identifier: "tape.fixture.reload")
            try #require(reload.accessibilityActivate())
            try await waitUntil("Native Reload must start MSFT loaders") { referenceCalls == 2 && tapeSymbols == ["RKLB", "MSFT"] }
            _ = try await reveal(in: window, labelContaining: "NASDAQ")
            try await waitUntil("Reload must render NASDAQ and clear old reference notices") {
                let labels = nativeElements(window).compactMap(\.accessibilityLabel)
                return labels.contains(where: { $0.contains("NASDAQ") })
                    && !labels.contains(where: { $0.contains("Exchange reference unavailable") || $0.contains("Nasdaq attribution unavailable") })
            }
            #expect(defaults.bool(forKey: "stocksage.ticks.nasdaqOnly"), "Reload must not silently disable the filter")
        }
    }

    @Test(arguments: [false, true])
    func calendarRowsRetainNegativeAndDatedEvidence(accessibility: Bool) async throws {
        let checked = StockSageCatalystWatch.brief(for: SageFix.idea("CHKD", conviction: 0.5),
            inputs: .init(earningsCheckedAt: now, now: now, catalystSourcesAsked: ["Fixture calendar"]))
        let real = StockSageCatalystWatch.brief(for: SageFix.idea("REAL", conviction: 0.5),
            inputs: .init(earningsDate: now.addingTimeInterval(86_400), earningsCheckedAt: now, now: now,
                          catalystSourcesAsked: ["Fixture calendar"]))
        let entries = StockSageCatalystWatch.calendar([checked, real], now: now)
        let negativeEntry = entries.first { $0.isNegativeRecord }
        let negative = try #require(negativeEntry)
        let dated = try #require(entries.first { !$0.isNegativeRecord && $0.item.date != nil })
        var selected: [String] = []
        let rows = VStack(alignment: .leading, spacing: 18) {
            CatalystsSection.CalendarRow(entry: negative, now: now, onSelect: { selected.append($0.symbol) })
                .accessibilityIdentifier("catalyst.fixture.checked")
            CatalystsSection.CalendarRow(entry: dated, now: now, onSelect: { selected.append($0.symbol) })
                .accessibilityIdentifier("catalyst.fixture.dated")
        }
        .padding(18).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.card))
        try await capture(rows, name: "calendar-rows", accessibility: accessibility) { _, window in
            defer { print("Calendar selection: \(selected)") }
            #expect(selected.isEmpty, "Rendering dated or negative evidence must not open a stock")
            let row = try await element(in: window, identifier: "catalyst.fixture.dated")
            try #require(row.accessibilityActivate(), "The native calendar row must open its captured stock")
            try await waitUntil("Native calendar activation must select \(dated.idea.symbol)") { selected == [dated.idea.symbol] }
            #expect(selected == [dated.idea.symbol])
        }
    }

    @Test(arguments: [false, true])
    func productionSegmentConfigurationsFitAndChangeSelection(accessibility: Bool) async throws {
        var changes: [String: String] = [:]
        let assetOption = try #require(BrowseMarketsView.availableFilters.last { $0 != .all }).rawValue
        let content = PhoneSegmentFixtures { changes[$0] = $1 }
        try await capture(content, name: "segments", accessibility: accessibility, viewportHeight: 812) { _, window in
            defer { print("Segment changes: \(changes)") }
            for (identifier, option) in [("segments.catalyst", "Calendar"),
                                          ("segments.asset", assetOption),
                                          ("segments.direction", "≤"),
                                          ("segments.side", "Short"),
                                          ("segments.fastLane", "Equities")] {
                var menuButton: UIButton?
                if !nativeElements(window).contains(where: { $0.accessibilityLabel == option && $0.accessibilityTraits.contains(.button) }) {
                    let picker = try await element(in: window, identifier: identifier)
                    try #require(picker.accessibilityActivate(), "The native menu must open")
                    menuButton = picker as? UIButton
                }
                let choice = try await element(in: window, label: option)
                if let menuButton {
                    try await activateMenuChoice(option, rendered: choice, owner: menuButton)
                } else {
                    try #require(choice.accessibilityActivate(), "The real segment must activate")
                }
                try await waitUntil("Native \(identifier) choice must change selection to \(option)") { changes[identifier] == option }
                #expect(changes[identifier] == option)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func logTradeOpensJournalAndCloseUsesTypedFixturePrices(accessibility: Bool, short: Bool) async throws {
        try #require(StockSageStore.isRunningTests)
        let suite = "stocksage.ios.journal.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "stocksage.liveStream")
        defaults.set(false, forKey: "stocksage.autoRefresh")
        defaults.set("off", forKey: StockSageLocalModelServer.backendKey)
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { journal.trades })
        await store.seedQAIdeas(previousScanEntries: [:])
        let best = try #require(StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime,
            earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality,
            calibration: store.convictionCalibration)?.idea)
        let trade = TradeRecord(symbol: "RKLB", side: short ? .short : .long,
            entry: 100, stop: short ? 110 : 90, target: short ? 80 : 120,
            shares: 2, openedAt: Date(), note: "Isolated native UI fixture")
        try #require(journal.add(trade))
        let live = StockSageLiveStream()
        let ai = StockSageAIAssessments()
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let monitor = StockSageMonitor(defaults: defaults)
        let velocity = StockSageVelocityHistoryStore(defaults: defaults)
        let view = MarketsView(chatSession: StockSageChatSession(historyURL: nil), qaSection: .ideas,
            store: store, aiAssessments: ai, portfolio: portfolio, journal: journal,
            paperStore: paper, live: live, velocityHistory: velocity, monitor: monitor)
        try await capture(view.defaultAppStorage(defaults), name: "journal-\(short ? "short" : "long")",
                          accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { host, window in
            let log = try await reveal(in: window, identifier: "journal.log.bestOpportunity")
            try #require(log.accessibilityActivate(), "The real Ideas Log trade control must activate")
            try await waitUntil {
                descendants(host.view).compactMap { $0 as? UITextField }
                    .contains { $0.placeholder == "Symbol" && $0.text == best.symbol }
            }
            #expect(journal.trades == [trade], "Opening the Journal draft must not save a trade")
            let symbol = try #require(descendants(host.view).compactMap { $0 as? UITextField }
                .first { $0.placeholder == "Symbol" })
            #expect(symbol.text == best.symbol, "The shared Portfolio route must show the actual prefilled Journal form")
            let toggle = try await reveal(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            #expect(toggle.accessibilityFrame.width >= 44 && toggle.accessibilityFrame.height >= 44, "Close must expose its full touch target: \(nativeDescription(toggle))")
            try #require(toggle.accessibilityActivate())
            try await waitUntil("Close must expose the actual exit-price field") {
                descendants(host.view).contains { ($0 as? UITextField)?.placeholder == "Exit px" }
            }
            let cancel = try await element(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            try #require(cancel.accessibilityActivate())
            try await waitUntil("Cancel must remove the exit-price field without saving") {
                !descendants(host.view).contains { ($0 as? UITextField)?.placeholder == "Exit px" }
            }
            #expect(journal.trades == [trade], "Cancel must leave fixture accounting untouched")
            let reopen = try await element(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            try #require(reopen.accessibilityActivate())
            try await waitUntil("Reopening Close must restore the exit-price field") {
                descendants(host.view).contains { ($0 as? UITextField)?.placeholder == "Exit px" }
            }
            try await editField("Exit px", value: "invalid", host: host, window: window)
            let invalidConfirm = try await reveal(in: window, identifier: "journal.confirmClose")
            #expect(invalidConfirm.accessibilityTraits.contains(.notEnabled))
            #expect(journal.trades == [trade])
            try await editField("Exit px", value: "105.25", host: host, window: window)
            try await editField("Plan px (opt)", value: "104.50", host: host, window: window)
            try await editField("Fill px (opt)", value: "105.10", host: host, window: window)
            let confirm = try await reveal(in: window, identifier: "journal.confirmClose")
            try #require(!confirm.accessibilityTraits.contains(.notEnabled))
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            var rendered = false
            let closeImage = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try #require(rendered, "The filled close form must render before its save action")
            let closePNG = try #require(closeImage.pngData())
            let suffix = accessibility ? "accessibility3" : "default"
            try closePNG.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
                "journal-close-\(short ? "short" : "long")-375-\(suffix).png"), options: .atomic)
            try #require(confirm.accessibilityActivate(), "The actual Confirm close action must save the typed values")
            try await waitUntil { journal.trades.first?.closedAt != nil }
            let closed = try #require(journal.trades.first)
            #expect(closed.exitPrice == 105.25 && closed.plannedExit == 104.50 && closed.exitFill == 105.10)
            #expect(closed.side == trade.side && closed.shares == trade.shares && closed.entry == trade.entry)
            #expect(StockSageJournalStore(defaults: defaults).trades == [closed], "Read back only the leased fixture suite")
            #expect(!live.isStreaming && live.subscribed.isEmpty && !monitor.isRunning && ai.activeSymbol == nil)
            #expect(paper.trades.isEmpty && portfolio.positions.isEmpty && velocity.series.isEmpty)
        }
    }

    // Actual phone navigation and the first viewport only. Content below the fold and
    // keyboard/menu presentation require their separate interaction fixtures.
    @Test(arguments: [false, true], ["home", "markets", "watchlist", "portfolio", "alerts", "catalysts", "research", "chat", "ideas", "heatmap"])
    func wholePhonePagesRenderFirstViewport(accessibility: Bool, page: String) async throws {
        try #require(StockSageStore.isRunningTests)
        let sections: [String: MarketSection] = ["home": .briefing, "markets": .all,
            "watchlist": .watchlist, "portfolio": .portfolio, "alerts": .alerts,
            "catalysts": .catalysts, "research": .research, "chat": .chat,
            "ideas": .ideas, "heatmap": .heatmap]
        let section = try #require(sections[page])
        try await captureWorkspace(section: section, name: "page-\(page)-first-viewport", accessibility: accessibility)
    }

    @Test(arguments: [false, true])
    func ideasCardDetailKeepsHeaderControlsVisibleAndCaveatReachable(accessibility: Bool) async throws {
        try await captureWorkspace(section: .ideas, name: "ideas-detail-route", accessibility: accessibility) { _, window in
            let card = try await reveal(in: window, identifier: "ideas.result.AAPL")
            try await saveViewport(window, name: "ideas-card", accessibility: accessibility)
            try #require(card.accessibilityActivate(), "Open the actual idea card's detail sheet")
            let close = try await element(in: window, identifier: "idea.detail.close")
            let identity = try await element(in: window, identifier: "idea.detail.identity")
            let position = try await element(in: window, identifier: "idea.detail.position")
            try await saveViewport(window, name: "idea-detail-first-viewport", accessibility: accessibility)
            let viewport = window.convert(window.bounds, to: nil)
            for control in [close, identity, position] {
                let frame = control.accessibilityFrame
                #expect(!frame.isEmpty && viewport.contains(frame),
                        "The initial sheet viewport must contain its identity, board position and Close control: \(nativeDescription(control))")
            }
            #expect(identity.accessibilityLabel?.contains("AAPL") == true)
            let caveat = try await reveal(in: window, identifier: "idea.detail.caveat")
            #expect(caveat.accessibilityLabel == StockSageAdvisor.caveat, "The complete existing caveat must remain reachable")
            #expect(viewport.intersects(caveat.accessibilityFrame), "Scrolling must bring the caveat into the visible sheet")
            try await saveViewport(window, name: "idea-detail-caveat", accessibility: accessibility)
            let visibleClose = try await reveal(in: window, identifier: "idea.detail.close")
            try #require(visibleClose.accessibilityActivate(), "Close must dismiss the actual idea sheet")
            try await waitUntil("Close must dismiss the actual idea detail sheet") {
                !nativeElements(window).contains { nativeIdentifier($0) == "idea.detail.close" }
            }
        }
    }

    @Test(arguments: [false, true])
    func homeSummaryOpensSavedPredictionsAndTheRequestedResearchHorizon(accessibility: Bool) async throws {
        typealias H = StockSageResearchHistory
        let suite = "stocksage.ios.home-history.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = H(storageURL: nil, defaults: defaults)
        let reference = try Date("2026-07-14T04:00:00Z", strategy: .iso8601)
        func run(_ symbol: String, horizon: H.Horizon, completed: Date) -> H.Run {
            .init(id: UUID(), startedAt: completed.addingTimeInterval(-60), completedAt: completed,
                horizon: horizon, predictions: [.init(symbol: symbol, name: "\(symbol) synthetic company",
                    action: "Strong Buy", reason: "Original \(symbol) opinion saved before its review date.",
                    risk: "Synthetic risk: future prices may fall.", evidence: ["F1"],
                    facts: ["Original synthetic evidence; no live recommendation."], model: "fixture-model",
                    note: "Synthetic unvalidated research only.", referencePrice: 100, referenceDate: reference,
                    levels: nil)],
                coverage: .init(requested: 2, checked: 2, incomplete: 1, buyCount: 1, selection: nil))
        }
        let week = run("ACME", horizon: .week,
            completed: try Date("2026-07-14T20:30:00Z", strategy: .iso8601))
        let fortnight = run("FORT", horizon: .fortnight,
            completed: try Date("2026-08-14T20:30:00Z", strategy: .iso8601))
        try #require(history.record(week) && history.record(fortnight))
        let benchmark = try #require(H.benchmarkDay(after: fortnight.completedAt))
        let target = try #require(H.targetClose(after: fortnight.completedAt, horizon: fortnight.horizon))
        let available = try #require(H.reviewAvailableAt(for: fortnight))
        let observation = H.Observation(history: .init(symbol: "FORT", dates: [benchmark, target],
            opens: [100, 110], highs: [105, 110], lows: [100, 110], closes: [105, 110],
            volumes: [100, 100], priceSource: .massiveDaily), splitAdjusted: true,
            provider: "Synthetic adjusted daily prices", fetchedAt: available.addingTimeInterval(60))
        let evaluation = H.evaluate(fortnight.predictions[0], in: fortnight, observation: observation,
            now: available.addingTimeInterval(120))
        try #require(evaluation.state == .evaluated)
        try #require(history.recordEvaluation(evaluation, runID: fortnight.id, symbol: "FORT"))
        let originalRuns = history.runs
        try #require(H.availability(for: week, now: Date()).state == .due)

        try await captureWorkspace(section: .briefing, name: "home-research-summary", accessibility: accessibility,
            researchHistory: history) { _, window in
            _ = try await reveal(in: window, labelContaining: "Your research today")
            _ = try await reveal(in: window, labelContaining: "Ready for review")
            _ = try await reveal(in: window, labelContaining: "1 saved prediction is ready to check.")
            let ready = try await reveal(in: window, identifier: "home.review.\(week.id)")
            try #require(ready.accessibilityActivate(), "Home's ready row must open the actual saved run")
            _ = try await reveal(in: window, labelContaining: "Original ACME opinion saved before its review date.")
            _ = try await reveal(in: window, labelContaining: "Ready to check")
            try await saveViewport(window, name: "home-ready-prediction", accessibility: accessibility)
            try await dismissSavedSheet(in: window)

            _ = try await reveal(in: window, labelContaining: "Latest completed research")
            for run in [week, fortnight] {
                let pick = try await reveal(in: window, identifier: "home.pick.\(run.id).\(run.predictions[0].symbol)")
                #expect(pick.accessibilityLabel?.contains(run.predictions[0].symbol) == true)
                #expect(pick.accessibilityLabel?.contains("Strong Buy") == true)
                _ = try await reveal(in: window,
                    labelContaining: "Completed \(run.completedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            try await saveViewport(window, name: "home-latest-completed-picks", accessibility: accessibility)
            let saved = try await reveal(in: window, identifier: "research.saved")
            try #require(saved.accessibilityActivate(), "Home's actual Saved research button must open its sheet")
            _ = try await element(in: window, label: "Saved research")
            let check = try await reveal(in: window, identifier: "research.history.check")
            #expect(check.accessibilityTraits.contains(.notEnabled), "Fixture navigation cannot start provider checks")
            try await saveViewport(window, name: "home-saved-research-sheet", accessibility: accessibility)
            try await dismissSavedSheet(in: window)

            let openResearch = try await reveal(in: window, identifier: "home.research.14")
            try #require(openResearch.accessibilityActivate(), "The actual Home action must navigate to Research")
            _ = try await reveal(in: window, labelContaining: "Market research")
            _ = try await element(in: window, label: "Run \(StockSageHorizonResearch.Horizon.fortnight.rawValue) research scan")
            #expect(!nativeElements(window).contains {
                $0.accessibilityLabel == "Run \(StockSageHorizonResearch.Horizon.week.rawValue) research scan"
            }, "The visible Research controls must use the requested fortnight horizon")
            try await saveViewport(window, name: "home-opened-fortnight-research", accessibility: accessibility)
        }
        #expect(history.runs == originalRuns && history.lastError == nil && !history.isChecking,
                "Home navigation must preserve every original prediction and outcome")
    }

    @Test(arguments: [false, true], ["home", "analytics", "detail", "today"])
    func nativeLogEntryPointsOpenAnUnsavedJournalDraft(accessibility: Bool, route: String) async throws {
        try #require(StockSageStore.isRunningTests)
        let suite = "stocksage.ios.log-route.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "stocksage.liveStream")
        defaults.set(false, forKey: "stocksage.autoRefresh")
        defaults.set("off", forKey: StockSageLocalModelServer.backendKey)
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { journal.trades })
        await store.seedQAIdeas(previousScanEntries: [:])
        let live = StockSageLiveStream()
        let ai = StockSageAIAssessments()
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let monitor = StockSageMonitor(defaults: defaults)
        let velocity = StockSageVelocityHistoryStore(defaults: defaults)
        let best = try #require(StockSageExpectedValue.bestOpportunity(store.ideas, regime: store.regime,
            earnings: store.earnings, liquidity: store.liquidity, seasonality: store.seasonality,
            calibration: store.convictionCalibration)?.idea)
        var expected = best
        if route == "today" {
            let plans = StockSageTodayPlan.rankedActions(store.ideas, account: nil, riskFraction: nil,
                calibration: store.convictionCalibration, marketRegime: store.regime,
                earnings: store.earnings, liquidity: store.liquidity, mode: .equityExecutableFirst)
            try #require(plans.count >= 2, "The actual Today's actions card needs at least two ranked plans")
            let plan = try #require(plans.first { plan in
                store.ideas.contains { $0.symbol == plan.symbol && [.strongBuy, .buy, .sell, .reduce].contains($0.advice.action) }
            })
            expected = try #require(store.ideas.first { $0.symbol == plan.symbol })
        }
        let initial: MarketSection = route == "analytics" ? .portfolio : route == "home" ? .briefing : .ideas
        let view = MarketsView(chatSession: StockSageChatSession(historyURL: nil), qaSection: initial,
            store: store, aiAssessments: ai, portfolio: portfolio, journal: journal,
            paperStore: paper, live: live, velocityHistory: velocity, monitor: monitor)
        try await capture(view.defaultAppStorage(defaults), name: "log-route-\(route)", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { host, window in
            if route == "analytics" {
                let picker = try await element(in: window, identifier: "phone.portfolio.tabs")
                let button = try #require(picker as? UIButton)
                try #require(button.accessibilityActivate())
                let option = try await element(in: window, label: "Analytics")
                try await activateMenuChoice("Analytics", rendered: option, owner: button)
                try await waitUntil("The actual Portfolio picker must select Analytics") {
                    nativeElements(window).contains { nativeIdentifier($0) == "phone.portfolio.tabs" && $0.accessibilityLabel?.contains("Analytics") == true }
                }
                let home = try await element(in: window, label: "Home")
                if !home.accessibilityActivate() {
                    let control = try #require(home as? UIControl, "The rendered Home tab must expose a native control")
                    try #require(control.isEnabled)
                    control.sendActions(for: .touchUpInside)
                }
                try await waitUntil("The native Home tab must show the Home page") {
                    nativeElements(window).contains { $0.accessibilityLabel == "Your research today" }
                }
            }
            if route == "home" || route == "analytics" {
                let ideas = try await reveal(in: window, labelContaining: "Find ideas, Compare evidence and risk")
                try #require(ideas.accessibilityActivate(), "Home's link must open Ideas without running a scan")
            }
            let log: NSObject
            if route == "detail" {
                let detail = try await reveal(in: window, labelContaining: "Best rules-ranked opportunity: \(expected.symbol),")
                try #require(detail.accessibilityActivate(), "Open the actual idea detail sheet")
                log = try await reveal(in: window, identifier: "journal.log.ideaDetail")
            } else if route == "today" {
                let planning = try await reveal(in: window, labelContaining: "Planning tools · allocation, fast lane and today's actions")
                try #require(planning.accessibilityActivate())
                log = try await reveal(in: window, labelContaining: "Log trade for \(expected.symbol) — prefills the journal form")
            } else {
                log = try await reveal(in: window, identifier: "journal.log.bestOpportunity")
            }
            try #require(log.accessibilityActivate(), "Use the rendered Log action for this route")
            try await waitUntil("Every Log entry point must show the prefilled Journal form") {
                descendants(host.view).compactMap { $0 as? UITextField }
                    .contains { $0.placeholder == "Symbol" && $0.text == expected.symbol }
            }
            #expect(journal.trades.isEmpty, "A Log action opens an unsaved draft and cannot create a trade")
            #expect(!live.isStreaming && live.subscribed.isEmpty && !monitor.isRunning && ai.activeSymbol == nil)
            #expect(paper.trades.isEmpty && portfolio.positions.isEmpty && velocity.series.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func tapeKnownNonNasdaqRowsBecomeVisibleWhenFilterIsTurnedOff(accessibility: Bool) async throws {
        let suite = "stocksage.ios.tape-filter.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "stocksage.ticks.nasdaqOnly")
        var calls = 0
        let reference = [Int64(24): StockSageMassiveTicks.Exchange(id: 24, mic: "XNYS", acronym: "NYSE")]
        let view = StockSageTapeView(symbol: "RKLB", loadExchanges: { reference }, loadTape: { symbol, _, _ in
            calls += 1
            return .init(trades: [.init(price: 25.25, size: 10, exchange: 24, timestamp: now, sequence: 901)],
                         quotes: [.init(symbol: symbol, bid: 25, ask: 25.5, bidSize: 10, askSize: 20,
                                        bidExchange: 24, askExchange: 24, timestamp: now, sequence: 902)])
        })
        try await capture(view.defaultAppStorage(defaults), name: "tape-checked-empty", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            try await waitUntil { calls == 1 }
            _ = try await reveal(in: window, labelContaining: "No matching trades in the returned window.")
            _ = try await reveal(in: window, labelContaining: "No matching quotes in the returned window.")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("attribution unavailable") == true })
            let filter = try await reveal(in: window, labelContaining: "Nasdaq only")
            try #require(filter.accessibilityActivate(), "Turn off the actual Nasdaq-only switch")
            try await waitUntil { !defaults.bool(forKey: "stocksage.ticks.nasdaqOnly") }
            _ = try await reveal(in: window, labelContaining: "Sequence 901")
            _ = try await reveal(in: window, labelContaining: "Sequence 902")
            #expect(calls == 1, "A display filter must not refetch the tape")
        }
    }

    @Test(arguments: ["reference-success", "reference-error", "tape"])
    func lateCanceledTapeLoadsCannotReplaceTheCurrentSymbol(stage: String) async throws {
        typealias Exchanges = [Int64: StockSageMassiveTicks.Exchange]
        let suite = "stocksage.ios.tape-cancel.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "stocksage.ticks.nasdaqOnly")
        let reference: Exchanges = [12: .init(id: 12, mic: "XNAS", acronym: "NASDAQ")]
        let oldReference: Exchanges = [24: .init(id: 24, mic: "XNYS", acronym: "NYSE")]
        let currentTape = StockSageMassiveTicks.Tape(trades: [
            .init(price: 22.22, size: 10, exchange: 12, timestamp: now, sequence: 222)
        ])
        let staleTape = StockSageMassiveTicks.Tape(trades: [
            .init(price: 11.11, size: 10, exchange: 12, timestamp: now, sequence: 111)
        ])
        var waitingReference: CheckedContinuation<Exchanges, any Error>?
        var waitingTape: CheckedContinuation<StockSageMassiveTicks.Tape, Never>?
        var oldReturned = false
        var referenceCalls = 0
        var tapeSymbols: [String] = []
        // Always release suspended synthetic work, including when an earlier assertion throws.
        defer {
            waitingReference?.resume(throwing: StockSageMassiveTicks.Failure.unavailable)
            waitingTape?.resume(returning: staleTape)
        }
        let view = PhoneTapeReloadFixture(loadExchanges: {
            referenceCalls += 1
            if referenceCalls == 1 && stage != "tape" {
                defer { oldReturned = true }
                return try await withCheckedThrowingContinuation { waitingReference = $0 }
            }
            return reference
        }, loadTape: { symbol, _, _ in
            tapeSymbols.append(symbol)
            if symbol == "RKLB" && stage == "tape" {
                defer { oldReturned = true }
                return await withCheckedContinuation { waitingTape = $0 }
            }
            return currentTape
        })
        try await capture(view.defaultAppStorage(defaults), name: "tape-cancel-\(stage)", accessibility: false,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            try await waitUntil("The first synthetic request must suspend before reload") {
                waitingReference != nil || waitingTape != nil
            }
            let reload = try await element(in: window, identifier: "tape.fixture.reload")
            try #require(reload.accessibilityActivate())
            try await waitUntil { referenceCalls == 2 && tapeSymbols.contains("MSFT") }
            _ = try await reveal(in: window, labelContaining: "Sequence 222")
            if let continuation = waitingReference {
                waitingReference = nil
                if stage == "reference-error" { continuation.resume(throwing: StockSageMassiveTicks.Failure.unavailable) }
                else { continuation.resume(returning: oldReference) }
            }
            if let continuation = waitingTape {
                waitingTape = nil
                continuation.resume(returning: staleTape)
            }
            try await waitUntil("The old suspended task must actually resume before checking its cancellation") { oldReturned }
            await Task.yield()
            _ = try await reveal(in: window, labelContaining: "Sequence 222")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Sequence 111") == true })
            #expect(tapeSymbols == (stage == "tape" ? ["RKLB", "MSFT"] : ["MSFT"]))
            _ = try await reveal(in: window, labelContaining: "Nasdaq only")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Exchange reference unavailable") == true },
                    "A canceled reference error must not replace the current symbol's successful status")
            #expect(defaults.bool(forKey: "stocksage.ticks.nasdaqOnly"))
        }
    }

    // MARK: Task 6 bullet 5 — insider purchase, insider sale, missing data, rejected output.
    // The unit tests pin the state machine; this pins that each state actually reaches the screen
    // and lays out on a phone at normal AND large text.
    private func insiderTransaction(_ direction: StockSageMassiveEvents.InsiderTransaction.Direction,
                                    owner: String, role: String?, at: Date,
                                    plan: Bool? = nil) -> StockSageMassiveEvents.InsiderTransaction {
        .init(direction: direction, transactionDate: at.addingTimeInterval(-86_400), filingDate: at,
              ownerName: owner, role: role, shares: 12_500, pricePerShare: 31.75,
              planReported: plan, amendment: false)
    }

    private func insiderObservation(_ transactions: [StockSageMassiveEvents.InsiderTransaction],
                                    symbol: String, at: Date) -> StockSageMassiveEvents.Observation {
        let events = transactions.enumerated().map { index, row -> StockSageMassiveEvents.Event in
            var event = StockSageMassiveEvents.Event(id: "\(symbol)-form4-\(index)", symbol: symbol,
                feed: .insider, date: at, headline: "Form 4 filed",
                details: ["Synthetic fixture filing."], link: nil)
            event.insider = row
            return event
        }
        var value = StockSageMassiveEvents.Observation(symbol: symbol, feed: .insider, checkedAt: at,
                                                      outcome: .answered, event: events.first)
        value.insiderEvents = events
        value.insiderOmittedRecordCount = 0
        return value
    }

    // `.modelRejected` cannot be fixtured on a saved Prediction and its absence here is the point:
    // QualityReport.valid requires `action == nil` for that state, while a saved prediction's action
    // is non-optional and must be Buy or Strong Buy — because a refused answer never becomes a
    // published prediction. That state lives on the intermediate CompletedCheck; the badge copy for
    // it is covered by the unit tests instead.
    //
    // The other three carry the counts the validator actually demands: verified needs
    // offeredCount == factCount with no findings, unverified needs at least one finding, and
    // dataUnavailable needs offeredCount == 0 (hence no citations at all).
    private func qualityFixture(_ state: StockSageAIAssessment.QualityReport.State) -> StockSageAIAssessment.QualityReport {
        let unavailable = state == .dataUnavailable
        return .init(version: StockSageAIAssessment.QualityReport.version, state: state,
              findings: state == .unverified ? [.uncitedInsiderRecord] : [],
              citedCount: unavailable ? 0 : 1, offeredCount: unavailable ? 0 : 1,
              classCounts: unavailable ? [:] : ["technical": 1],
              insiderPurchases: 0, insiderSales: 0, uncitedInsiderIDs: [],
              acceptedAction: "Buy", rejectionReason: nil)
    }

    private func savedPrediction(_ symbol: String, insider: StockSageMassiveEvents.Observation?,
                                 coverageState: String?, at: Date,
                                 quality: StockSageAIAssessment.QualityReport?) -> StockSageResearchHistory.Prediction {
        // A saved prediction is a shortlist entry: the validator accepts only Buy / Strong Buy.
        var value = StockSageResearchHistory.Prediction(symbol: symbol, name: "\(symbol) synthetic company",
            action: "Buy", reason: "Synthetic saved opinion.", risk: "Synthetic risk.", evidence: ["F1"],
            facts: ["F1 synthetic evidence; no live recommendation."], model: "fixture-model",
            note: "Synthetic unvalidated research only.", referencePrice: 100, referenceDate: at, levels: nil)
        value.insiderEvidence = insider
        value.insiderCoverage = coverageState.map {
            .init(source: StockSageMassiveEvents.Feed.insider.source, state: $0, checkedAt: at)
        }
        value.qualityReport = quality
        return value
    }

    @Test(arguments: [false, true])
    func everyInsiderAndQualityStateRendersOnThePhone(accessibility: Bool) async throws {
        let suite = "stocksage.ios.insider.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = StockSageResearchHistory(storageURL: nil, defaults: defaults)
        let completed = now.addingTimeInterval(-3_600)
        // Every recorded clock must precede the run's completion: validInsiderEvidence requires
        // checkedAt <= through, and coverage.checkedAt == evidence.checkedAt exactly.
        let observed = completed.addingTimeInterval(-120)
        let run = StockSageResearchHistory.Run(id: UUID(), startedAt: completed.addingTimeInterval(-60),
            completedAt: completed, horizon: .week, predictions: [
                savedPrediction("BUYR", insider: insiderObservation([insiderTransaction(.purchase, owner: "P. Buyer", role: "Director", at: observed)], symbol: "BUYR", at: observed),
                                coverageState: "answered", at: observed, quality: qualityFixture(.verified)),
                savedPrediction("SELR", insider: insiderObservation([insiderTransaction(.sale, owner: "S. Seller", role: "CFO", at: observed, plan: true)], symbol: "SELR", at: observed),
                                coverageState: "answered", at: observed, quality: qualityFixture(.unverified)),
                savedPrediction("GAPS", insider: nil, coverageState: nil, at: observed, quality: nil),
                {
                    // dataUnavailable requires offeredCount == 0, so this row cites nothing.
                    var value = StockSageResearchHistory.Prediction(symbol: "UNAV", name: "UNAV synthetic company",
                        action: "Buy", reason: "Synthetic saved opinion.", risk: "Synthetic risk.",
                        evidence: [], facts: [], model: "fixture-model",
                        note: "Synthetic unvalidated research only.", referencePrice: 100,
                        referenceDate: observed, levels: nil)
                    value.insiderCoverage = .init(source: StockSageMassiveEvents.Feed.insider.source,
                                                  state: "unavailable", checkedAt: observed)
                    value.qualityReport = qualityFixture(.dataUnavailable)
                    return value
                }(),
            ],
            // With no ranking the validator requires predictions.count == min(5, buyCount).
            coverage: .init(requested: 4, checked: 4, incomplete: 0, buyCount: 4, selection: nil))
        try #require(history.record(run))

        // A bare List has no intrinsic height; give it the same phone viewport captureWorkspace uses.
        try await capture(StockSageResearchHistoryDetail(history: history, runID: run.id),
                          name: "insider-quality-states", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "P. Buyer")
            _ = try await reveal(in: window, labelContaining: "S. Seller")
            // A plan disclosure is displayed as supplied and never interpreted.
            _ = try await reveal(in: window, labelContaining: "Rule 10b5-1")
            // Missing data reads as not recorded, never as an absence of insider activity.
            _ = try await reveal(in: window, labelContaining: "Insider activity was not recorded")
            _ = try await reveal(in: window, labelContaining: "Quality not assessed")
            // Unavailable evidence is its own state, distinct from never-assessed, and its copy
            // describes the EVIDENCE rather than warning about the company.
            _ = try await reveal(in: window, labelContaining: "Evidence unavailable")
        }
    }

    // Task 23: the saved-research list renders its filter controls and its runs on a phone.
    // A fresh simulator has no saved research, so this is the only place the filtered list can be
    // seen at all — including the explicit "nothing matches" copy, which must never degrade into a
    // bare empty list that reads as "no saved research".
    @Test(arguments: [false, true])
    func savedResearchListShowsFiltersAndRuns(accessibility: Bool) async throws {
        let suite = "stocksage.ios.filters.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = StockSageResearchHistory(storageURL: nil, defaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let completed = now.addingTimeInterval(-3_600)
        let observed = completed.addingTimeInterval(-120)
        let run = StockSageResearchHistory.Run(id: UUID(), startedAt: completed.addingTimeInterval(-60),
            completedAt: completed, horizon: .week, predictions: [
                savedPrediction("BUYR", insider: insiderObservation([insiderTransaction(.purchase, owner: "P. Buyer", role: "Director", at: observed)], symbol: "BUYR", at: observed),
                                coverageState: "answered", at: observed, quality: qualityFixture(.verified)),
            ],
            coverage: .init(requested: 1, checked: 1, incomplete: 0, buyCount: 1, selection: nil))
        try #require(history.record(run))

        try await capture(StockSageResearchHistoryView(store: store, history: history),
                          name: "saved-research-filters", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, identifier: "research.history.filters")
            _ = try await reveal(in: window, identifier: "research.history.run.\(run.id)")
        }
    }

    private func captureWorkspace(section: MarketSection, name: String, accessibility: Bool,
                                  researchHistory: StockSageResearchHistory? = nil,
                                  inspect: (@MainActor (UIHostingController<AnyView>, UIWindow) async throws -> Void)? = nil) async throws {
        try #require(StockSageStore.isRunningTests)
        let suite = "stocksage.ios.page.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "stocksage.liveStream")
        defaults.set(false, forKey: "stocksage.autoRefresh")
        defaults.set("off", forKey: StockSageLocalModelServer.backendKey)
        defaults.set(["AAPL", "MSFT", "RKLB"], forKey: "stocksage_user_symbols")
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { journal.trades })
        await store.seedQAIdeas(previousScanEntries: [:])
        let live = StockSageLiveStream()
        let ai = StockSageAIAssessments()
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let monitor = StockSageMonitor(defaults: defaults)
        let velocity = StockSageVelocityHistoryStore(defaults: defaults)
        let chat = StockSageChatSession(historyURL: nil)
        // The production Research child keeps only process-local state and performs no
        // automatic scan. Require its untouched state; never stop or reset a shared scan.
        try #require(StockSageHorizonResearch.shared.running == nil && StockSageHorizonResearch.shared.scans.isEmpty)
        let history = researchHistory ?? StockSageResearchHistory(storageURL: nil, defaults: defaults)
        let originalRuns = history.runs
        let view = MarketsView(chatSession: chat, qaSection: section,
            store: store, aiAssessments: ai, portfolio: portfolio, journal: journal,
            paperStore: paper, live: live, velocityHistory: velocity, monitor: monitor, researchHistory: history)
        try await capture(view.defaultAppStorage(defaults), name: name,
                          accessibility: accessibility, viewportHeight: 812, shellPadding: 0, inspect: inspect)
        #expect(store.isSampleData && store.userSymbols == ["AAPL", "MSFT", "RKLB"])
        #expect(!live.isStreaming && live.subscribed.isEmpty && !monitor.isRunning && ai.activeSymbol == nil)
        #expect(journal.trades.isEmpty && portfolio.positions.isEmpty && paper.trades.isEmpty && velocity.series.isEmpty)
        #expect(chat.turns.isEmpty && chat.draft.isEmpty)
        #expect(StockSageHorizonResearch.shared.running == nil && StockSageHorizonResearch.shared.scans.isEmpty)
        #expect(history.runs == originalRuns && history.lastError == nil && !history.isChecking,
                "Opening or navigating Home must not check or rewrite saved research")
    }

    private func dismissSavedSheet(in window: UIWindow) async throws {
        let done = try await element(in: window, label: "Done")
        if !done.accessibilityActivate() {
            let control = try #require(done as? UIControl, "The visible Done action must expose a native control")
            try #require(control.isEnabled)
            control.sendActions(for: .touchUpInside)
        }
        try await waitUntil("Done must dismiss the actual saved-research sheet") {
            func presented(_ controller: UIViewController) -> Bool {
                controller.presentedViewController != nil || controller.children.contains(where: presented)
            }
            return window.rootViewController.map { !presented($0) } ?? false
        }
    }

    private func saveViewport(_ window: UIWindow, name: String, accessibility: Bool) async throws {
        func settled(_ controller: UIViewController) -> Bool {
            controller.transitionCoordinator == nil && controller.children.allSatisfy(settled)
                && (controller.presentedViewController.map(settled) ?? true)
        }
        let root = try #require(window.rootViewController)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !settled(root), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(settled(root), "Capture the completed native navigation, not an animation frame")
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(rendered, "The navigated native research viewport must draw completely")
        let png = try #require(image.pngData())
        let size = accessibility ? "accessibility3" : "default"
        try png.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-ios-\(name)-375-\(size).png"), options: .atomic)
    }

    private func capture(_ view: some View, name: String, accessibility: Bool,
                         viewportHeight: CGFloat? = nil,
                         shellPadding: CGFloat = 16,
                         inspect: (@MainActor (UIHostingController<AnyView>, UIWindow) async throws -> Void)? = nil) async throws {
        let width: CGFloat = 375
        var appeared = false
        // Erase the fixture wrapper to avoid the documented iOS 27 deep generic metadata issue.
        let host = UIHostingController(rootView: AnyView(view.padding(shellPadding)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
            .tint(DS.Palette.accent)
            // This is a component capture; device safe areas must not shrink its measured height.
            .ignoresSafeArea()
            .onAppear { appeared = true }))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        host.view.backgroundColor = UIColor(DS.Palette.bgTop)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(appeared)
        host.view.layoutIfNeeded()
        let fitting = viewportHeight.map { CGSize(width: width, height: $0) }
            ?? host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        try #require(fitting.width.isFinite && fitting.height.isFinite && fitting.height > 0 && fitting.height < 10_000)
        #expect(fitting.width <= width + 1, "The component must fit a 375-point phone without horizontal overflow")
        // Capture the entire component at phone width so evidence and every synthetic row are inspectable.
        window.frame.size = CGSize(width: width, height: ceil(fitting.height))
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.view.layoutIfNeeded()
        func checkBounds(_ current: UIView) {
            guard !current.isHidden, current.alpha > 0.01 else { return }
            if current is UIControl || current is UILabel || current is UITextView {
                let bounds = current.convert(current.bounds, to: host.view)
                // Horizontal filter strips intentionally place later controls outside the
                // viewport. Their scroll container owns that overflow. A vertical page or
                // an ordinary clipped parent must still pass the original width check.
                var ancestor = current.superview
                var insideHorizontalScrollContent = false
                while let node = ancestor, node !== host.view {
                    if let scroll = node as? UIScrollView,
                       scroll.contentSize.width > scroll.bounds.width + 1,
                       scroll.contentSize.height <= scroll.bounds.height + 1 {
                        insideHorizontalScrollContent = true
                        break
                    }
                    ancestor = node.superview
                }
                if !bounds.isEmpty && !insideHorizontalScrollContent {
                    #expect(bounds.minX >= -1 && bounds.maxX <= width + 1,
                            "Native text and controls must stay within the phone's horizontal bounds: \(nativeDescription(current)); host bounds=\(bounds)")
                }
            }
            for child in current.subviews { checkBounds(child) }
        }
        checkBounds(host.view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Native hierarchy drawing preserves the glass/material of a real phone viewport.
        // Tall intrinsic leaf captures can exceed the render server's snapshot limit, so
        // those retain the bounded 1x layer-rendering path used by accessibility Research.
        var hierarchyRendered = false
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { context in
            if viewportHeight != nil {
                hierarchyRendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            } else {
                host.view.layer.render(in: context.cgContext)
            }
        }
        if viewportHeight != nil { try #require(hierarchyRendered, "The native phone hierarchy must render completely") }
        let png = try #require(image.pngData())
        #expect(image.size.width == width && image.size.height > 0 && png.count > 1_000)
        let pixels = try #require(image.cgImage?.dataProvider?.data) as Data
        #expect(Set(pixels).count > 16, "The native render must contain drawn content, not a blank canvas")
        let suffix = accessibility ? "accessibility3" : "default"
        try png.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-ios-\(name)-375-\(suffix).png"), options: .atomic)
        try writeNativeDiagnostics(window, name: "\(name)-\(suffix)-initial")
        do { try await inspect?(host, window) }
        catch {
            try writeNativeDiagnostics(window, name: "\(name)-\(suffix)-failure")
            throw error
        }
    }

    private func descendants(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants($0) }
    }

    private func nativeElements(_ root: NSObject) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        var elements: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            elements.append(object)
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { visit(child) }
            } else {
                let count = object.accessibilityElementCount()
                if count > 0 && count < 2_000 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
            if let view = object as? UIView { for child in view.subviews { visit(child) } }
        }
        visit(root)
        return elements
    }

    private func element(in window: UIWindow, identifier: String? = nil, label: String? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws -> NSObject {
        var match: NSObject?
        try await waitUntil("Native element missing: \(identifier ?? label ?? "unspecified")", sourceLocation: sourceLocation) {
            // A native menu may be presented in another window of this fixture's test scene.
            let roots = window.windowScene?.windows.filter { !$0.isHidden } ?? [window]
            match = roots.flatMap { nativeElements($0) }.first { object in
                if let identifier {
                    return nativeIdentifier(object) == identifier
                }
                return object.accessibilityLabel == label
            }
            return match != nil
        }
        if let match { print("Native lookup matched: \(nativeDescription(match))") }
        return try #require(match, "Native element missing: \(identifier ?? label ?? "unspecified")")
    }

    private func visibleContentView(in window: UIWindow) -> UIView? {
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller?.view
    }

    private func reveal(in window: UIWindow, identifier: String? = nil, labelContaining: String? = nil) async throws -> NSObject {
        let description = identifier ?? labelContaining ?? "unspecified"
        for attempt in 0..<30 {
            if let match = nativeElements(window).first(where: { object in
                if let identifier { return nativeIdentifier(object) == identifier }
                return labelContaining.map { text in object.accessibilityLabel?.contains(text) == true } ?? false
            }) {
                if let root = visibleContentView(in: window) {
                    for scroll in descendants(root).compactMap({ $0 as? UIScrollView })
                    where scroll.contentSize.height + scroll.adjustedContentInset.top
                        + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1 {
                        let frame = scroll.convert(window.convert(match.accessibilityFrame, from: nil), from: window)
                        scroll.scrollRectToVisible(frame.insetBy(dx: 0, dy: -8), animated: false)
                    }
                    root.layoutIfNeeded()
                }
                try await Task.sleep(for: .milliseconds(50))
                print("Native reveal matched: \(nativeDescription(match))")
                return match
            }
            if let root = visibleContentView(in: window) {
                for scroll in descendants(root).compactMap({ $0 as? UIScrollView })
                where scroll.contentSize.height + scroll.adjustedContentInset.top
                        + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1 {
                    let bottom = max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                    let next = attempt == 0 ? -scroll.adjustedContentInset.top
                        : min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.7)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
                }
                root.layoutIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("Native reveal exhausted for \(description)")
        for scroll in descendants(window).compactMap({ $0 as? UIScrollView }) {
            print("Scroll: \(nativeDescription(scroll)); content=\(scroll.contentSize); offset=\(scroll.contentOffset)")
        }
        throw NSError(domain: "StockSage.NativeFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not reveal native control \(description)"])
    }

    private func editField(_ placeholder: String, value: String, host: UIHostingController<AnyView>, window: UIWindow) async throws {
        // The unsaved entry draft above the open trades has the same optional plan/fill
        // placeholders. The close editor is last in this actual view hierarchy.
        let field = try #require(descendants(host.view).compactMap { $0 as? UITextField }
            .last { $0.placeholder == placeholder })
        try #require(field.window === window)
        var ancestor = field.superview
        while let node = ancestor {
            if let scroll = node as? UIScrollView {
                scroll.scrollRectToVisible(field.convert(field.bounds, to: scroll).insetBy(dx: 0, dy: -8), animated: false)
            }
            ancestor = node.superview
        }
        host.view.layoutIfNeeded()
        field.text = value
        field.sendActions(for: .editingChanged)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(field.text == value)
    }

    private func activateMenuChoice(_ title: String, rendered choice: NSObject, owner: UIButton) async throws {
        try #require(choice.accessibilityTraits.contains(.button) && !choice.accessibilityTraits.contains(.notEnabled))
        if choice.accessibilityActivate() { return }
        // UIKit's rendered context-menu cell is not directly AX-activatable in this host.
        // Dispatch its installed, visible UIAction through the owning native control's
        // public event dispatcher; never extract a SwiftUI closure or call a delegate.
        func findAction(_ element: UIMenuElement) -> UIAction? {
            if let action = element as? UIAction, action.title == title { return action }
            if let menu = element as? UIMenu {
                for child in menu.children { if let action = findAction(child) { return action } }
            }
            return nil
        }
        let menu = try #require(owner.menu)
        let action = try #require(findAction(menu), "The rendered choice must belong to this native menu")
        try #require(!action.attributes.contains(.disabled) && !action.attributes.contains(.hidden))
        print("Dispatching installed native menu action: \(action.title)")
        owner.sendAction(action)
        owner.contextMenuInteraction?.dismissMenu()
        if let menuView = choice as? UIView {
            try await waitUntil("The native menu must dismiss after its action") {
                menuView.window == nil || menuView.window?.isHidden == true
            }
        }
    }

    private func nativeIdentifier(_ object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        // SwiftUI AccessibilityNode advertises UIKit's public identifier getter without
        // declaring that protocol. Read only the getter it explicitly responds to.
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }

    private func nativeDescription(_ object: NSObject) -> String {
        let identifier = nativeIdentifier(object) ?? ""
        var ancestors: [String] = []
        if let view = object as? UIView {
            var current: UIView? = view
            while let node = current {
                ancestors.append("\(type(of: node))(hidden:\(node.isHidden),alpha:\(node.alpha),frame:\(node.frame),clips:\(node.clipsToBounds))")
                current = node.superview
            }
        }
        return "\(type(of: object)); id=\(identifier); label=\(object.accessibilityLabel ?? ""); value=\(object.accessibilityValue ?? ""); isElement=\(object.isAccessibilityElement); traits=\(object.accessibilityTraits.rawValue); frame=\(object.accessibilityFrame); ancestors=\(ancestors.joined(separator: " > "))"
    }

    private func writeNativeDiagnostics(_ window: UIWindow, name: String) throws {
        let lines = ["Fixture window key=\(window.isKeyWindow), frame=\(window.frame)"]
            + nativeElements(window).map { nativeDescription($0) }
        try lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-ios-\(name)-native.txt"), atomically: true, encoding: .utf8)
    }

    private func waitUntil(_ message: String = "Native fixture state did not reach the expected value",
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), Comment(rawValue: message), sourceLocation: sourceLocation)
    }
}

@MainActor private final class PhoneResearchPresentationModel: ObservableObject {
    @Published var presentation: StockSageResearchModesPanel.Presentation
    init(horizon: StockSageHorizonResearch.Horizon) { presentation = .init(horizon: horizon) }
}

@MainActor private struct PhoneResearchPresentationFixture: View {
    @ObservedObject var model: PhoneResearchPresentationModel
    let store: StockSageStore
    let research: StockSageHorizonResearch
    var body: some View {
        ScrollView {
            StockSageResearchModesPanel(store: store, research: research, presentation: $model.presentation)
        }
    }
}

@MainActor private struct PhoneSegmentFixtures: View {
    let changed: (String, String) -> Void
    @State private var catalyst = CatalystsSection.Mode.cards
    @State private var asset = BrowseMarketsView.AssetFilter.all
    @State private var direction = PriceAlert.Direction.above
    @State private var side = TradeRecord.Side.long
    @State private var fastLane = MarketsView.FastLaneBoard.both

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Production segment configurations").font(.headline)
            DSSegmentPicker(cases: CatalystsSection.Mode.allCases, selection: $catalyst) { $0.title }
                .frame(maxWidth: 260).accessibilityLabel("Catalyst view")
                .accessibilityIdentifier("segments.catalyst")
                .onChange(of: catalyst) { _, value in changed("segments.catalyst", value.title) }
            DSSegmentPicker(cases: BrowseMarketsView.availableFilters, selection: $asset) { $0.rawValue }
                .accessibilityLabel("Asset class").accessibilityIdentifier("segments.asset")
                .onChange(of: asset) { _, value in changed("segments.asset", value.rawValue) }
            DSSegmentPicker(cases: [PriceAlert.Direction.above, .below], selection: $direction) { $0 == .above ? "≥" : "≤" }
                .frame(width: 74).accessibilityLabel("Alert direction").accessibilityIdentifier("segments.direction")
                .onChange(of: direction) { _, value in changed("segments.direction", value == .above ? "≥" : "≤") }
            DSSegmentPicker(cases: Array(TradeRecord.Side.allCases), selection: $side) { $0.rawValue }
                .frame(width: 130).accessibilityLabel("Trade side").accessibilityIdentifier("segments.side")
                .onChange(of: side) { _, value in changed("segments.side", value.rawValue) }
            DSSegmentPicker(cases: Array(MarketsView.FastLaneBoard.allCases), selection: $fastLane) { $0.rawValue }
                .frame(maxWidth: 340).accessibilityLabel("Fast-lane board filter").accessibilityIdentifier("segments.fastLane")
                .onChange(of: fastLane) { _, value in changed("segments.fastLane", value.rawValue) }
        }
    }
}

@MainActor private struct PhoneTapeReloadFixture: View {
    let loadExchanges: @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange]
    let loadTape: @MainActor (String, Date, Date) async -> StockSageMassiveTicks.Tape
    @State private var symbol = "RKLB"

    var body: some View {
        VStack(spacing: 0) {
            Button("Reload synthetic tape") { symbol = "MSFT" }
                .accessibilityIdentifier("tape.fixture.reload")
            StockSageTapeView(symbol: symbol, loadExchanges: loadExchanges, loadTape: loadTape)
        }
    }
}
#endif
