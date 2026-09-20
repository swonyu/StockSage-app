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
    func prospectiveEvaluationRequiresCostAndFitsPhone(accessibility: Bool) async throws {
        let suite = "stocksage.ios.evaluation.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let history = StockSageResearchHistory(storageURL: nil, defaults: defaults)
        let evaluation = StockSageResearchEvaluation(defaults: defaults)
        let config = StockSageLocalModelServer.Config(baseURL: URL(string: "http://127.0.0.1:18080")!,
            model: StockSageLocalModelServer.gemmaModel)
        let view = StockSageResearchEvaluationView(store: store, history: history, evaluation: evaluation,
            configuration: { config }).defaultAppStorage(defaults)
        try await capture(view, name: "prospective-evaluation", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { host, window in
            let initial = try await reveal(in: window, identifier: "research.evaluation.start")
            #expect(initial.accessibilityTraits.contains(.notEnabled))
            #expect(evaluation.studies.isEmpty && !evaluation.isChecking)
            _ = try await reveal(in: window, identifier: "research.evaluation.cost")
            try await editField("Required, e.g. 25", value: "25", host: host, window: window)
            let start = try await reveal(in: window, identifier: "research.evaluation.start")
            try #require(!start.accessibilityTraits.contains(.notEnabled))
            try #require(start.accessibilityActivate(), "Use the real Start action; rendering must never freeze a study")
            try await waitUntil("The explicit Start action must freeze exactly one study") { evaluation.studies.count == 1 }
            let study = try #require(evaluation.studies.first)
            #expect(study.contract.roundTripCostBPS == 25 && study.contract.model == config.model)
            let readiness = try await reveal(in: window, identifier: "research.evaluation.readiness.7")
            #expect(readiness.accessibilityLabel?.contains("Not enough evidence") == true,
                    "A newly started study must not imply measured skill or manufacture performance")
            let check = try await reveal(in: window, identifier: "research.evaluation.check")
            #expect(check.accessibilityTraits.contains(.notEnabled), "Offline fixtures cannot start provider requests")
            #expect(!evaluation.isChecking && !store.isRefreshing && history.runs.isEmpty)
            try await saveViewport(window, name: "prospective-evaluation-study", accessibility: accessibility)
        }
    }

    @Test(arguments: [false, true])
    func prospectiveEvaluationCoverageCannotHideMissingWindows(accessibility: Bool) async throws {
        var summary = StockSageResearchEvaluation.HorizonSummary(horizon: .fortnight)
        summary.selectedWindows = 25; summary.measuredWindows = 2
        summary.waitingWindows = 5; summary.uncheckedWindows = 10; summary.unavailableWindows = 8
        summary.expectedPredictions = 125; summary.measuredPredictions = 10
        summary.eligibleRuns = 29; summary.excludedRuns = 7; summary.sameDateRuns = 1; summary.overlappingRuns = 3
        summary.meanNetReturn = 0.025; summary.meanBenchmarkNetReturn = 0.015; summary.meanExcessReturn = 0.01
        try await capture(StockSageResearchEvaluationView.HorizonSummaryCard(summary: summary),
                          name: "prospective-evaluation-coverage", accessibility: accessibility) { _, window in
            let texts = nativeElements(window).compactMap(\.accessibilityLabel).joined(separator: "\n")
            #expect(texts.contains("2 of 25 selected windows measured"))
            #expect(texts.contains("10 of 125 selected picks measured"))
            #expect(texts.contains("Waiting: 5") && texts.contains("Not checked: 10") && texts.contains("Data unavailable: 8"))
            #expect(texts.contains("+2.50%") && texts.contains("+1.50%") && texts.contains("+1.00%"))
            #expect(texts.contains("Not enough evidence"), "Positive partial results cannot hide the sample warning")
        }
    }

    @Test(arguments: [false, true])
    func holdingsKeepValuesSourcesAndRemovalAccessibleOnPhone(accessibility: Bool) async throws {
        let suite = "stocksage.ios.holdings.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        try #require(portfolio.add(symbol: "AAPL", shares: 1234.5, costBasis: 100))
        try #require(portfolio.add(symbol: "LLOY.L", shares: 250, costBasis: 500))
        let original = portfolio.positions
        let store = StockSageStore(defaults: defaults, heldSymbols: { portfolio.positions.map(\.symbol) })
        let at = Date().addingTimeInterval(-60)
        store.applyPolledQuotes([
            "AAPL": .init(symbol: "AAPL", price: 120, previousClose: 119, marketTime: at, priceSource: .massiveSIP),
            "LLOY.L": .init(symbol: "LLOY.L", price: 520, previousClose: 519, marketTime: at, priceSource: .yahoo)
        ])
        try #require(store.latestPrice("AAPL") == 120 && store.latestPrice("LLOY.L") == 520)
        let draft = StockSagePortfolioHoldingsView.EntryDraft()
        let view = ScrollView { StockSagePortfolioHoldingsView(store: store, portfolio: portfolio, draft: draft) }
        try await capture(view.defaultAppStorage(defaults), name: "holding-values-actions", accessibility: accessibility,
                          viewportHeight: 812) { host, window in
            let identity = try await reveal(in: window, identifier: "portfolio.identity.AAPL")
            #expect(identity.accessibilityLabel?.contains("1234.50 shares") == true)
            #expect(identity.accessibilityLabel?.contains("Massive") == true,
                    "VoiceOver must expose the holding's quote attribution with its identity")
            for (symbol, value, profit) in [("AAPL", "148140.00 USD", "+24690.00 USD"),
                                           ("LLOY.L", "1300.00 GBP", "+50.00 GBP")] {
                let mark = try await reveal(in: window, identifier: "portfolio.value.\(symbol)")
                #expect(mark.accessibilityLabel == "\(symbol) holding value" && mark.accessibilityValue == value)
                let result = try await reveal(in: window, identifier: "portfolio.profit.\(symbol)")
                #expect(result.accessibilityLabel == "\(symbol) profit or loss" && result.accessibilityValue == profit,
                        "Spoken values must distinguish valuation, profit/loss and the local currency")
                for element in [mark, result] {
                    let frame = window.convert(element.accessibilityFrame, from: nil)
                    #expect(frame.width > 0 && frame.minX >= -1 && frame.maxX <= window.bounds.width + 1)
                }
            }
            let remove = try await reveal(in: window, identifier: "portfolio.remove.AAPL")
            #expect(remove.accessibilityLabel == "Remove AAPL" && remove.accessibilityTraits.contains(.button))
            #expect(remove.accessibilityFrame.width >= 44 && remove.accessibilityFrame.height >= 44)
            try #require(remove.accessibilityActivate(), "The actual accessible Remove action must open confirmation")
            let confirmation = try await element(in: window, identifier: "portfolio.confirmRemove")
            #expect(confirmation.accessibilityLabel == "Remove AAPL" && confirmation.accessibilityTraits.contains(.button))
            #expect(portfolio.positions == original)
            if let cancel = nativeElements(window).first(where: { $0.accessibilityLabel == "Cancel" }) {
                if !cancel.accessibilityActivate() {
                    let control = try #require(cancel as? UIControl)
                    try #require(control.isEnabled)
                    control.sendActions(for: .touchUpInside)
                }
            } else {
                // Native popovers omit Cancel: VoiceOver dismisses through the backdrop
                // or escape action. Exercise that installed action, never set SwiftUI state.
                let dismiss = try await element(in: window, identifier: "PopoverDismissRegion")
                var presenter: UIViewController = host
                while let presented = presenter.presentedViewController { presenter = presented }
                print("HOLDING_CONFIRMATION presenter=\(type(of: presenter)) horizontalSizeClass=\(presenter.traitCollection.horizontalSizeClass.rawValue) dismiss=\(nativeDescription(dismiss))")
                let dismissed = dismiss.accessibilityActivate() || dismiss.accessibilityPerformEscape()
                    || presenter.accessibilityPerformEscape() || presenter.view.accessibilityPerformEscape()
                try #require(dismissed, "Cancel through the actual native popover accessibility action")
            }
            try await waitUntil("Cancel must dismiss the actual holding confirmation") {
                !nativeElements(window).contains { nativeIdentifier($0) == "portfolio.confirmRemove" }
            }
        }
        let saved = try portfolio.backupRecords()
        #expect(portfolio.positions == original && saved == original)
        #expect(draft.symbol.isEmpty && draft.shares.isEmpty && draft.cost.isEmpty && !store.isRefreshing)
    }

    @Test(arguments: [false, true])
    func sameDayLevelsAndDatedWarningRemainReadableOnPhone(accessibility: Bool) async throws {
        let suite = "stocksage.ios.same-day.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let fixture = StockSageSameDayResearchTests()
        let research = StockSageSameDayResearch()
        let check = try fixture.check("AAPL")
        await research.run(selection: .init([fixture.listing("AAPL")]), capacity: { 1 },
            allowed: { true }, clock: { fixture.now }, analyze: { _, _, _ in check },
            refreshQuote: { _ in fixture.quote() })
        let original = try #require(research.receipt)
        try #require(original.selectedSymbol == "AAPL")
        let panel = StockSageSameDayResearchPanel(store: store, research: research)
        try await capture(panel.defaultAppStorage(defaults), name: "same-day-dated-levels",
                          accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, identifier: "research.sameDay.dated")
            for label in ["Buy entry (ceiling)", "Stop-loss reference", "Target reference"] {
                let level = try await reveal(in: window, labelContaining: label)
                let bounds = window.convert(level.accessibilityFrame, from: nil)
                #expect(bounds.minX >= 0 && bounds.maxX <= window.bounds.width && bounds.height > 0)
                #expect(level.accessibilityLabel?.contains("$") == true,
                        "Each price must remain paired with its role for VoiceOver")
            }
            try await saveViewport(window, name: "same-day-levels-visible", accessibility: accessibility)
            // The unprefixed risk also appears in the selected-pick card. Only the raw
            // check's prefixed case/risk prove that All checks actually expanded.
            let captured = try #require(original.checks.first)
            let rawCase = "Case: " + (try #require(captured.reason))
            let rawRisk = "Risk: " + (try #require(captured.risk))
            #expect(!nativeElements(window).contains { $0.accessibilityLabel == rawCase })
            let evidence = try await reveal(in: window, labelContaining: "checks and captured evidence")
            try #require(evidence.accessibilityActivate())
            let detail = try await reveal(in: window, labelContaining: rawCase)
            #expect(detail.accessibilityLabel == rawCase)
            try await saveViewport(window, name: "same-day-expanded-check-case", accessibility: accessibility,
                afterDisclosureSettles: { _ = try await reveal(in: window, labelContaining: rawCase) })
            let risk = try await reveal(in: window, labelContaining: rawRisk)
            #expect(risk.accessibilityLabel == rawRisk)
            try await saveViewport(window, name: "same-day-expanded-evidence", accessibility: accessibility)
            let collapse = try await reveal(in: window, labelContaining: "checks and captured evidence")
            try #require(collapse.accessibilityActivate())
            try await waitUntil("Closing All checks must remove its raw check body") {
                !nativeElements(window).contains { $0.accessibilityLabel == rawCase }
            }
        }
        #expect(research.receipt == original && !research.isRunning)
        #expect(!store.isRefreshing && store.userSymbols.isEmpty)
    }

    @Test(arguments: [DynamicTypeSize.accessibility3, .accessibility5])
    func chatSavingWarningIsReachableWithoutLosingTheDraft(size: DynamicTypeSize) async throws {
        let suite = "stocksage.ios.chat-warnings.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("off", forKey: StockSageLocalModelServer.backendKey)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Synthetic storage failure".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let chat = StockSageChatSession(historyURL: blocker.appendingPathComponent("history.json"))
        let id = try #require(chat.begin(question: "What remains uncertain?",
            snapshot: .init(at: now, facts: [], context: "Synthetic local context"), model: "fixture"))
        chat.cancel(id: id)
        let warning = try #require(chat.storageError)
        chat.draft = "Keep this unsent question about AAPL"
        let draft = chat.draft
        let view = StockSageChatSection(store: store, openModelSettings: {}, chat: chat)
            .defaultAppStorage(defaults).environment(\.dynamicTypeSize, size)
        try await capture(view, name: "chat-saving-warning-\(size)", accessibility: true,
                          dynamicTypeSize: size, viewportHeight: 812, shellPadding: 0) { _, window in
            let review = try await reveal(in: window, identifier: "chat.reviewIssues")
            let frame = window.convert(review.accessibilityFrame, from: nil)
            #expect(frame.height >= 44 && window.bounds.contains(frame),
                    "The full large-text warning action must be reachable without compression")
            try await saveViewport(window, name: "chat-saving-warning-composer-\(size)", accessibility: true)
            try #require(review.accessibilityActivate())
            let message = try await element(in: window, identifier: "chat.warning.0")
            #expect(message.accessibilityLabel == warning, "Keep the complete actual save/recovery failure")
            let bounds = window.convert(message.accessibilityFrame, from: nil)
            #expect(bounds.minX >= 0 && bounds.maxX <= window.bounds.width && bounds.height > 0)
            #expect(bounds.intersects(window.bounds), "The warning action must reveal its scrollable recovery text")
            try await saveViewport(window, name: "chat-saving-warning-revealed-\(size)", accessibility: true)
        }
        #expect(chat.draft == draft && chat.storageError == warning && chat.pending == nil)
    }

    @Test(arguments: [false, true])
    func providerSettingsAndExecutionMetricsScaleOnPhone(accessibility: Bool) async throws {
        try await capture(ScrollView { StockSageMassiveKeyField().padding(16) },
                          name: "provider-settings", accessibility: accessibility, viewportHeight: 812) { _, window in
            let save = try await reveal(in: window, identifier: "settings.massive.save")
            #expect(save.accessibilityTraits.contains(.notEnabled))
            let test = try await reveal(in: window, identifier: "settings.massive.test")
            #expect(test.accessibilityFrame.height >= 44)
        }
        let trades = (0..<3).map { index in
            TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 95, target: 110, shares: 10,
                openedAt: now.addingTimeInterval(-86400), exitPrice: 105, closedAt: now,
                note: "Synthetic measured fill \(index)", plannedEntry: 100, entryFill: 100.1,
                plannedExit: 105, exitFill: 104.9)
        }
        try await capture(ExecutionQualityPanel(trades: trades), name: "execution-metrics", accessibility: accessibility)
    }

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
    func deterministicFiveLeadThePhoneResearchPage(accessibility: Bool, horizon: StockSageHorizonResearch.Horizon) async throws {
        let suite = "stocksage.ios.five.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let research = try await StockSageLayoutFixtures.populatedResearch(horizon: horizon)
        let scan = try #require(research.scans[horizon])
        let ranked = try #require(scan.rankedTopFive(horizon: horizon, now: Date()))
        let model = PhoneResearchPresentationModel(horizon: horizon)
        let view = PhoneResearchPresentationFixture(model: model, store: store, research: research)
            .defaultAppStorage(defaults)
        let name = "deterministic-five-\(horizon == .week ? "week" : "fortnight")"
        try await capture(view, name: name, accessibility: accessibility, viewportHeight: 812) { _, window in
            for row in ranked.ranked {
                let button = try await reveal(in: window, identifier: "research.topfive.open.\(row.symbol)")
                #expect(button.accessibilityLabel?.contains(row.action) == true)
                #expect(button.accessibilityLabel?.contains(row.status == .qualified ? "Qualified" : "Not qualified") == true)
                try await saveViewport(window, name: name + "-rank\(row.rank)", accessibility: accessibility)
            }
            let last = try #require(ranked.ranked.last)
            let rowID = "research.topfive.row.\(last.symbol)"
            _ = try await reveal(in: window, labelContaining: "Counterevidence", within: rowID)
            try await saveViewport(window, name: name + "-rank5-tail", accessibility: accessibility)
            let signal = try #require(last.insiderSignals.first)
            let insiderLabel = "\(signal.direction == .purchase ? "Purchase" : "Sale") · \(signal.ownerName)"
            let row = try #require(nativeElements(window).first { nativeIdentifier($0) == rowID })
            #expect(!nativeElements(row).contains { $0.accessibilityLabel == insiderLabel })
            let insider = try await reveal(in: window, labelContaining: "Insider evidence", within: rowID)
            try #require(insider.accessibilityActivate())
            let owner = try await reveal(in: window, labelContaining: insiderLabel, within: rowID)
            #expect(owner.accessibilityLabel == insiderLabel)
            try await saveViewport(window, name: name + "-rank5-insider-owner", accessibility: accessibility,
                afterDisclosureSettles: {
                    _ = try await reveal(in: window, labelContaining: insiderLabel, within: rowID)
                })
            _ = try await reveal(in: window, labelContaining: "old when scored · contribution", within: rowID)
            try await saveViewport(window, name: name + "-rank5-insider-age", accessibility: accessibility)

            try #require(last.status == .notQualified)
            let distinctGate = try #require(last.failedGates.first { !last.hardPenaltyReasons.contains($0) })
            let expandedRow = try #require(nativeElements(window).first { nativeIdentifier($0) == rowID })
            #expect(!nativeElements(expandedRow).contains { $0.accessibilityLabel == distinctGate })
            let gates = try await reveal(in: window, labelContaining: "Failed gates", within: rowID)
            try #require(gates.accessibilityActivate())
            for (index, reason) in last.failedGates.enumerated() {
                let gate = try await reveal(in: window, labelContaining: reason, within: rowID)
                #expect(gate.accessibilityLabel == reason)
                try await saveViewport(window, name: name + "-rank5-gate\(index + 1)", accessibility: accessibility,
                    afterDisclosureSettles: {
                        _ = try await reveal(in: window, labelContaining: reason, within: rowID)
                    })
            }
            let button = try await reveal(in: window, identifier: "research.topfive.open.\(last.symbol)")
            try #require(button.accessibilityActivate())
            try await waitUntil { model.presentation.selected == last.symbol }
            let close = try await element(in: window, label: "Close details")
            if !close.accessibilityActivate() {
                let control = try #require(close as? UIControl)
                try #require(control.isEnabled && control.window === window)
                control.sendActions(for: .touchUpInside)
            }
            try await waitUntil { model.presentation.selected == nil }
            #expect(model.presentation.filter == .all)
        }
        #expect(research.running == nil && research.scans[horizon]?.rankingScoredAt == scan.rankingScoredAt)
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
                // Intrinsic full-content PNGs can compress SwiftUI labels differently.
                // Capture these long controls/headings inside the actual phone viewport.
                _ = try await reveal(in: window, identifier: "research.retryIncomplete")
                try await saveViewport(window, name: "research-retry-viewport", accessibility: accessibility)
                _ = try await reveal(in: window, labelContaining: "5 shown · select a stock")
                try await saveViewport(window, name: "research-strict-heading-viewport", accessibility: accessibility)
                if accessibility {
                    let selection = try await reveal(in: window, identifier: "research.filter.selection")
                    let title = StockSageResearchModesPanel.ResultFilter.topBuys.rawValue
                    #expect(selection.accessibilityLabel == title)
                    let frame = window.convert(selection.accessibilityFrame, from: nil)
                    let font = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: window.traitCollection)
                    let required = (title as NSString).boundingRect(
                        with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                        options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height
                    #expect(frame.height + 1 >= ceil(required),
                            "The whole selected filter must fit at the actual native Dynamic Type size")
                    try await saveViewport(window, name: "research-filter-selection-viewport", accessibility: accessibility)
                }
                for filter in [StockSageResearchModesPanel.ResultFilter.all, .incomplete] {
                    let picker = try await reveal(in: window, identifier: "research.filter")
                    if accessibility { #expect(picker.accessibilityValue == model.presentation.filter.rawValue) }
                    try #require(picker.accessibilityActivate(), "The native research filter must open")
                    // SwiftUI Menu exposes an AX node separate from its backing UIButton.
                    // Match the mounted menu button to the rendered filter's exact bounds.
                    let pickerFrame = window.convert(picker.accessibilityFrame, from: nil)
                    let candidates = nativeElements(window).compactMap { $0 as? UIButton }.filter { button in
                        guard button.window === window, button.isEnabled, button.menu != nil else { return false }
                        let frame = button.convert(button.bounds, to: window)
                        return abs(frame.minX - pickerFrame.minX) < 1 && abs(frame.minY - pickerFrame.minY) < 1
                            && abs(frame.width - pickerFrame.width) < 1 && abs(frame.height - pickerFrame.height) < 1
                    }
                    let owner = try #require((picker as? UIButton) ?? (candidates.count == 1 ? candidates.first : nil),
                                             "The visible research filter must own one mounted native menu button")
                    defer { owner.contextMenuInteraction?.dismissMenu() }
                    let choice = try await element(in: window, label: filter.rawValue, button: true)
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
            _ = try await reveal(in: window, labelContaining: "Observed outcome price")
            try await saveViewport(window, name: "research-terminal-stop-price", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Adjusted scenario")
            try await saveViewport(window, name: "research-terminal-stop-scenario", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "the conservative stop-first rule was applied")
            _ = try await reveal(in: window, labelContaining: "Synthetic adjusted daily prices")
            try await saveViewport(window, name: "research-terminal-stop-detail", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: hit.id) },
            name: "research-terminal-target", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Target hit")
            _ = try await reveal(in: window, labelContaining: "Observed outcome price")
            try await saveViewport(window, name: "research-terminal-target-price", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Adjusted scenario")
            try await saveViewport(window, name: "research-terminal-target-scenario", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Daily bars cannot establish high/low ordering")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("stop-first rule") == true })
            try await saveViewport(window, name: "research-terminal-target-detail", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: quiet.id) },
            name: "research-terminal-horizon", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Horizon close")
            _ = try await reveal(in: window, labelContaining: "Observed outcome price")
            try await saveViewport(window, name: "research-terminal-horizon-detail", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Adjusted scenario")
            try await saveViewport(window, name: "research-terminal-horizon-scenario", accessibility: accessibility)
        }
        try await capture(NavigationStack { StockSageResearchHistoryDetail(history: history, runID: active.id) },
            name: "research-terminal-active", accessibility: accessibility, viewportHeight: 812, shellPadding: 0) { _, window in
            _ = try await reveal(in: window, labelContaining: "Active")
            _ = try await reveal(in: window, labelContaining: "Scheduled horizon session:")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Target hit") == true })
            try await saveViewport(window, name: "research-terminal-active-detail", accessibility: accessibility)
        }
        // The aggregate counts live on Home, reported as three separate kinds and never as a rate.
        try await captureWorkspace(section: .briefing, name: "home-terminal-outcome-counts",
            accessibility: accessibility, researchHistory: history, inspect: { _, window in
            let counts = try await reveal(in: window, identifier: "home.research.outcomes")
            let label = try #require(counts.accessibilityLabel)
            #expect(label.contains("1 target hit") && label.contains("1 stop hit")
                    && label.contains("1 horizon close") && label.contains("3 outcomes recorded"), "\(label)")
            #expect(!label.lowercased().contains("win rate"))
            _ = try await reveal(in: window, labelContaining: "Separate counts, not a win rate.")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.contains("Earlier endpoint-only checks") == true },
                    "No legacy endpoint receipts exist in this fixture, so that line stays absent")
            try await saveViewport(window, name: "home-terminal-outcome-counts", accessibility: accessibility)
        })
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
        let note = "Synthetic journal rationale with a long explanation of the original setup, its uncertainty, and the planned invalidation. Keep the full note readable after closure. Final note sentence."
        let trade = TradeRecord(symbol: "RKLB", side: short ? .short : .long,
            entry: 100, stop: short ? 110 : 90, target: short ? 80 : 120,
            shares: 2, openedAt: Date(), note: note)
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
            let openNote = try await reveal(in: window, identifier: "journal.notes.\(trade.id.uuidString)")
            try #require(openNote.accessibilityActivate())
            _ = try await element(in: window, label: note)
            try await saveViewport(window, name: "journal-open-note-\(short)", accessibility: accessibility)
            let collapseNote = try await element(in: window, identifier: "journal.notes.\(trade.id.uuidString)", button: true)
            try #require(collapseNote.accessibilityActivate())
            let toggle = try await reveal(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            #expect(toggle.accessibilityFrame.width >= 44 && toggle.accessibilityFrame.height >= 44, "Close must expose its full touch target: \(nativeDescription(toggle))")
            try #require(toggle.accessibilityActivate())
            try await waitUntil("Close must expose the actual exit-price field") {
                nativeElements(window).contains { nativeIdentifier($0) == "journal.field.Exit px" }
            }
            let cancel = try await element(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            try #require(cancel.accessibilityActivate())
            try await waitUntil("Cancel must remove the exit-price field without saving") {
                !nativeElements(window).contains { nativeIdentifier($0) == "journal.field.Exit px" }
            }
            #expect(journal.trades == [trade], "Cancel must leave fixture accounting untouched")
            let reopen = try await element(in: window, identifier: "journal.close.\(trade.id.uuidString)")
            try #require(reopen.accessibilityActivate())
            try await waitUntil("Reopening Close must restore the exit-price field") {
                nativeElements(window).contains { nativeIdentifier($0) == "journal.field.Exit px" }
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
            #expect(closed.note == note)
            let closedNote = try await reveal(in: window, identifier: "journal.notes.\(trade.id.uuidString)")
            try #require(closedNote.accessibilityActivate())
            _ = try await element(in: window, label: note)
            try await saveViewport(window, name: "journal-closed-note-\(short)", accessibility: accessibility)
            #expect(StockSageJournalStore(defaults: defaults).trades == [closed], "Read back only the leased fixture suite")
            #expect(!live.isStreaming && live.subscribed.isEmpty && !monitor.isRunning && ai.activeSymbol == nil)
            #expect(paper.trades.isEmpty && portfolio.positions.isEmpty && velocity.series.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func portfolioSecondaryPagesKeepRecordsAndDrafts(accessibility: Bool) async throws {
        let closed: [TradeRecord] = (0..<12).map { index in
            let exit = index.isMultiple(of: 3) ? 95.0 : 112.0
            let date = now.addingTimeInterval(-Double(index + 1) * 7 * 86_400)
            return TradeRecord(symbol: index == 0 ? "RKLB" : "AAPL", side: .long,
                entry: 100, stop: 90, target: 120, shares: 2.5,
                openedAt: date.addingTimeInterval(-2 * 86_400), exitPrice: exit, closedAt: date,
                note: "Synthetic retained journal evidence. Original plan and uncertainty stay readable after changing Portfolio pages.",
                plannedEntry: 99, entryFill: 100, plannedExit: exit - 0.25, exitFill: exit)
        }
        let retainedPaper = TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 90,
            target: 120, shares: 2, openedAt: now.addingTimeInterval(-10 * 86_400),
            note: "Synthetic retained legacy paper record; never submitted to a broker.")
        let draftNote = "Unsaved synthetic draft stays intact across Journal, Forward record and Analytics."
        try await captureWorkspace(section: .portfolio, name: "portfolio-secondary", accessibility: accessibility,
            configureRecords: { portfolio, journal, paper in
                try #require(portfolio.add(symbol: "AAPL", shares: 12.5, costBasis: 100))
                for trade in closed { try #require(journal.add(trade)) }
                paper.add(retainedPaper)
                try #require(paper.trades == [retainedPaper])
            }) { host, window in
            @MainActor func choose(_ title: String) async throws {
                let picker = try await reveal(in: window, identifier: "phone.portfolio.tabs")
                let owner = try #require(picker as? UIButton)
                try #require(owner.accessibilityActivate())
                let choice = try await element(in: window, label: title)
                try await activateMenuChoice(title, rendered: choice, owner: owner)
                try await waitUntil("The actual Portfolio menu must select \(title)") {
                    nativeElements(window).contains {
                        nativeIdentifier($0) == "phone.portfolio.tabs"
                            && $0.accessibilityLabel?.contains(title) == true
                    }
                }
            }
            try await choose("Journal")
            _ = try await reveal(in: window, labelContaining: "Trade journal")
            try await saveViewport(window, name: "portfolio-journal-top", accessibility: accessibility)
            try await scanToBottom(in: window, name: "portfolio-journal", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "R-multiple distribution")
            _ = try await reveal(in: window, labelContaining: "By month")
            let remove = try await reveal(in: window, labelContaining: "Delete RKLB from journal")
            try #require(remove.accessibilityActivate(), "Open the real confirmation without deleting the fixture record")
            _ = try await element(in: window, label: "Delete RKLB")
            try await saveViewport(window, name: "portfolio-journal-delete-confirmation", accessibility: accessibility)
            if let cancel = nativeElements(window).first(where: { $0.accessibilityLabel == "Cancel" }) {
                if !cancel.accessibilityActivate() {
                    let control = try #require(cancel as? UIControl)
                    try #require(control.isEnabled)
                    control.sendActions(for: .touchUpInside)
                }
            } else {
                // Same native popover cancellation used by the Holdings fixture.
                let dismiss = try await element(in: window, identifier: "PopoverDismissRegion")
                var presenter: UIViewController = host
                while let presented = presenter.presentedViewController { presenter = presented }
                let dismissed = dismiss.accessibilityActivate() || dismiss.accessibilityPerformEscape()
                    || presenter.accessibilityPerformEscape() || presenter.view.accessibilityPerformEscape()
                try #require(dismissed)
            }
            try await waitUntil("Cancel must remove the real journal deletion confirmation") {
                !nativeElements(window).contains { $0.accessibilityLabel == "Delete RKLB" }
            }
            let log = try await reveal(in: window, labelContaining: "Log trade")
            try #require(log.accessibilityActivate())
            _ = try await reveal(in: window, identifier: "journal.field.Symbol")
            try await editField("Symbol", value: "MSFT", host: host, window: window)
            _ = try await reveal(in: window, identifier: "journal.field.Note (optional)")
            try await editField("Note (optional)", value: draftNote, host: host, window: window)

            try await choose("Forward record")
            _ = try await reveal(in: window, labelContaining: "Forward scoreboard")
            _ = try await reveal(in: window, labelContaining: "1 simulated position recorded open")
            _ = try await reveal(in: window, labelContaining: "Automatic entries, marking and exits have stopped.")
            try await saveViewport(window, name: "portfolio-forward-record", accessibility: accessibility)
            try await scanToBottom(in: window, name: "portfolio-forward-record", accessibility: accessibility)

            try await choose("Analytics")
            _ = try await reveal(in: window, labelContaining: "Allocation")
            try await saveViewport(window, name: "portfolio-analytics-top", accessibility: accessibility)
            try await scanToBottom(in: window, name: "portfolio-analytics", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Risk-parity weights")
            _ = try await reveal(in: window, labelContaining: "Risk analytics")
            _ = try await reveal(in: window, labelContaining: "Position sizer (Kelly)")
            let win = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                .first { $0.accessibilityLabel == "Win %" })
            win.text = "invalid"
            win.sendActions(for: .editingChanged)
            _ = try await reveal(in: window, labelContaining: "Enter a valid Win %, Payoff R, and Account $ to see a Kelly suggestion.")
            try await saveViewport(window, name: "portfolio-kelly-invalid", accessibility: accessibility)
            let validWin = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                .first { $0.accessibilityLabel == "Win %" })
            try #require(validWin.window === window)
            validWin.text = "55"
            validWin.sendActions(for: .editingChanged)
            _ = try await reveal(in: window, labelContaining: "Full Kelly")
            try await saveViewport(window, name: "portfolio-kelly-valid", accessibility: accessibility)

            try await choose("Journal")
            _ = try await reveal(in: window, identifier: "journal.field.Symbol")
            let symbol = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                .first { nativeIdentifier($0) == "journal.field.Symbol" })
            #expect(symbol.text == "MSFT", "Changing Portfolio pages must retain the unsaved Journal draft")
            _ = try await reveal(in: window, identifier: "journal.field.Note (optional)")
            let note = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                .first { nativeIdentifier($0) == "journal.field.Note (optional)" })
            #expect(note.text == draftNote)
            try await saveViewport(window, name: "portfolio-journal-draft-retained", accessibility: accessibility)
            try await choose("Holdings")
            _ = try await reveal(in: window, identifier: "portfolio.identity.AAPL")
        }
    }

    @Test(arguments: [false, true])
    func rulesPlanningAndBacktestDisclosuresExpandWithoutRequests(accessibility: Bool) async throws {
        let planningTitle = "Planning tools · allocation, fast lane and today's actions"
        let diagnosticsTitle = "Backtests and strategy diagnostics"
        let alertsExplanation = "Flags when an idea turns bullish/bearish or its price crosses the advised stop or target — between refreshes."
        try await captureWorkspace(section: .ideas, name: "rules-secondary", accessibility: accessibility, inspect: { _, window in
            let planning = try await reveal(in: window, labelContaining: planningTitle)
            try #require(planning.accessibilityActivate())
            try await saveViewport(window, name: "rules-planning-expanded", accessibility: accessibility)
            try await scanToBottom(in: window, name: "rules-planning", accessibility: accessibility)
            _ = try await reveal(in: window, labelContaining: "Fast lane — fastest compounding")
            _ = try await reveal(in: window, labelContaining: "Today's plan — executable equities first")
            _ = try await reveal(in: window, labelContaining: "Signal alerts")
            let explanation = try #require(nativeElements(window).first { $0.accessibilityHint == alertsExplanation })
            try #require(explanation.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: alertsExplanation)
            try await saveViewport(window, name: "rules-alerts-explanation", accessibility: accessibility)
            let collapsePlanning = try await reveal(in: window, labelContaining: planningTitle)
            try #require(collapsePlanning.accessibilityActivate())
            try await waitUntil("Collapsing Planning tools must remove its child controls") {
                !nativeElements(window).contains { $0.accessibilityLabel == "Signal alerts" }
            }

            let diagnostics = try await reveal(in: window, labelContaining: diagnosticsTitle)
            try #require(diagnostics.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: "Strategy backtest")
            let strategyExplanation = try #require(nativeElements(window).first {
                $0.accessibilityHint?.contains("The advisor's rules across the sample") == true
            })
            try #require(strategyExplanation.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: "The advisor's rules across the sample")
            try await saveViewport(window, name: "rules-backtest-explanation", accessibility: accessibility)
            try await scanToBottom(in: window, name: "rules-backtests", accessibility: accessibility)
            let collapseDiagnostics = try await reveal(in: window, labelContaining: diagnosticsTitle)
            try #require(collapseDiagnostics.accessibilityActivate())
            try await waitUntil("Collapsing diagnostics must remove its Run surface") {
                !nativeElements(window).contains { $0.accessibilityLabel == "Strategy backtest" }
            }
            let reopen = try await reveal(in: window, labelContaining: planningTitle)
            try #require(reopen.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: "Signal alerts")
            try await saveViewport(window, name: "rules-planning-reopened", accessibility: accessibility)
        })
    }

    @Test(arguments: [false, true])
    func settingsSheetScrollsPersistsAllocationAndDismisses(accessibility: Bool) async throws {
        try #require(StockSageStore.isRunningTests)
        let suite = "stocksage.ios.settings.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "stocksage.liveStream")
        defaults.set(false, forKey: "stocksage.autoRefresh")
        defaults.set(false, forKey: "stocksage.monitor.iosEnabled")
        defaults.set(false, forKey: AppSettings.Keys.webAccess)
        defaults.set(true, forKey: AppSettings.Keys.offlineOnly)
        defaults.set("greedyKnapsack", forKey: "stocksage.allocStrategy")
        let settings = AppSettings(defaults: defaults)
        let content = PhoneSheetPresentationFixture {
            StockSageIOSSettingsSheet(settings: settings).defaultAppStorage(defaults)
        }
        try await capture(content, name: "settings-sheet", accessibility: accessibility,
                          viewportHeight: 812, shellPadding: 0) { _, window in
            let open = try await element(in: window, identifier: "fixture.openSheet")
            try #require(open.accessibilityActivate())
            _ = try await element(in: window, identifier: "settings.ios.done")
            try await scanToBottom(in: window, name: "settings-sheet", accessibility: accessibility)
            _ = try await reveal(in: window, identifier: "settings.massive.disclosure")
            try await saveViewport(window, name: "settings-source-disclosure", accessibility: accessibility)
            let allocation = try await reveal(in: window, identifier: "settings.ios.allocation")
            if accessibility {
                try #require(allocation.accessibilityActivate(), "The large-text native allocation menu must open")
                let owner = try #require(allocation as? UIButton)
                let balanced = try await element(in: window, label: "Balanced")
                try await activateMenuChoice("Balanced", rendered: balanced, owner: owner)
            } else {
                let segmented = try #require(nativeElements(window).compactMap { $0 as? UISegmentedControl }
                    .first { control in
                        (0..<control.numberOfSegments).contains { control.titleForSegment(at: $0) == "Balanced" }
                    })
                let index = try #require((0..<segmented.numberOfSegments).first {
                    segmented.titleForSegment(at: $0) == "Balanced"
                })
                try #require(segmented.isEnabled && segmented.window === window)
                segmented.selectedSegmentIndex = index
                segmented.sendActions(for: .valueChanged)
            }
            try await waitUntil("The native allocation picker must persist Balanced in the fixture suite") {
                defaults.string(forKey: "stocksage.allocStrategy") == "uniformScale"
            }
            _ = try await reveal(in: window, identifier: "settings.ios.priceAlerts")
            _ = try await reveal(in: window, labelContaining: "Disabled price alerts stay armed")
            try await saveViewport(window, name: "settings-notifications-bottom", accessibility: accessibility)
            try await dismissSavedSheet(in: window)
            let reopen = try await element(in: window, identifier: "fixture.openSheet")
            try #require(reopen.accessibilityActivate())
            let persistedAllocation = try await reveal(in: window, identifier: "settings.ios.allocation")
            if accessibility {
                #expect(persistedAllocation.accessibilityValue?.contains("Balanced") == true
                        || persistedAllocation.accessibilityLabel?.contains("Balanced") == true
                        || (persistedAllocation as? UIButton)?.currentTitle == "Balanced",
                        "Reopening must display the persisted Balanced menu selection")
            } else {
                let segmented = try #require(nativeElements(window).compactMap { $0 as? UISegmentedControl }
                    .first { control in
                        (0..<control.numberOfSegments).contains { control.titleForSegment(at: $0) == "Balanced" }
                    })
                #expect(segmented.titleForSegment(at: segmented.selectedSegmentIndex) == "Balanced")
            }
            try await saveViewport(window, name: "settings-allocation-persisted", accessibility: accessibility)
            try await dismissSavedSheet(in: window)
        }
        #expect(defaults.string(forKey: "stocksage.allocStrategy") == "uniformScale")
        #expect(!settings.webAccess && settings.offlineOnly && AppSettings.policyRevision(defaults: defaults) == nil)
        #expect(!defaults.bool(forKey: "stocksage.liveStream") && !defaults.bool(forKey: "stocksage.autoRefresh")
                && !defaults.bool(forKey: "stocksage.monitor.iosEnabled"),
                "Reading Settings and changing allocation must leave fixture network and monitoring preferences intact")
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility3, .accessibility5])
    func browseSheetSearchClearNoMatchAndDone(size: DynamicTypeSize) async throws {
        let accessibility = size.isAccessibilitySize
        try #require(StockSageStore.isRunningTests)
        let suite = "stocksage.ios.browse.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "stocksage.liveStream")
        defaults.set(false, forKey: "stocksage.autoRefresh")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let originalSymbols = store.userSymbols
        let symbol = try #require(StockSageUniverse.catalog.first { $0.symbol == "2222.SR" }).symbol
        let content = PhoneSheetPresentationFixture { BrowseMarketsView(store: store).defaultAppStorage(defaults) }
        try await capture(content, name: "browse-sheet-\(size)", accessibility: accessibility,
                          dynamicTypeSize: size, viewportHeight: 812, shellPadding: 0) { _, window in
            let open = try await element(in: window, identifier: "fixture.openSheet")
            try #require(open.accessibilityActivate())
            _ = try await element(in: window, identifier: "browse.done")
            try await saveViewport(window, name: "browse-presented-\(size)", accessibility: accessibility)
            let field = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                .first { nativeIdentifier($0) == "browse.search" })
            try #require(field.window === window)
            field.text = symbol
            field.sendActions(for: .editingChanged)
            _ = try await reveal(in: window, identifier: "browse.identity.\(symbol)")
            try await saveViewport(window, name: "browse-bilingual-search-\(size)", accessibility: accessibility)
            field.text = "NO-MATCH-SYNTHETIC-ZZZ"
            field.sendActions(for: .editingChanged)
            _ = try await reveal(in: window, identifier: "browse.empty")
            _ = try await element(in: window, label: "No matching markets")
            try await saveViewport(window, name: "browse-no-match-\(size)", accessibility: accessibility)
            let clear = try await reveal(in: window, identifier: "browse.clear")
            try #require(clear.accessibilityActivate(), "The real Clear search action must restore the catalog")
            try await waitUntil("Clear must empty the native search field and remove the empty state") {
                field.text == "" && !nativeElements(window).contains { nativeIdentifier($0) == "browse.empty" }
            }
            try await saveViewport(window, name: "browse-cleared-\(size)", accessibility: accessibility)
            try await dismissSavedSheet(in: window)
        }
        #expect(store.userSymbols == originalSymbols && store.addSymbolError == nil,
                "Browsing and searching must not add names or start an add-symbol request")
    }

    // Capture each viewport through the bottom of every production route. Menus,
    // disclosures and sheets still have their own explicit interaction fixtures.
    @Test(arguments: [false, true], ["sameDay", "week", "fortnight", "library", "home", "markets", "watchlist", "portfolio", "alerts", "catalysts", "research", "chat", "ideas", "heatmap", "paper"])
    func wholePhonePagesRenderFirstViewport(accessibility: Bool, page: String) async throws {
        try #require(StockSageStore.isRunningTests)
        let sections: [String: MarketSection] = ["home": .briefing, "markets": .all,
            "watchlist": .watchlist, "portfolio": .portfolio, "alerts": .alerts,
            "catalysts": .catalysts, "research": .research, "chat": .chat,
            "ideas": .ideas, "heatmap": .heatmap, "paper": .paper,
            "sameDay": .sameDay, "week": .weekResearch, "fortnight": .fortnightResearch, "library": .library]
        let section = try #require(sections[page])
        try await captureWorkspace(section: section, name: "page-\(page)-first-viewport", accessibility: accessibility, inspect: { _, window in
            try await scanToBottom(in: window, name: "page-\(page)", accessibility: accessibility)
            if page == "alerts" {
                for (title, value) in [("≤", "At or below"), ("≥", "At or above")] {
                    let picker = try await reveal(in: window, labelContaining: "Alert direction")
                    let owner = try #require(picker as? UIButton)
                    try #require(owner.window === window && owner.isEnabled)
                    // Cancel the native menu if a rendered choice/action is unavailable.
                    defer { owner.contextMenuInteraction?.dismissMenu() }
                    try #require(owner.accessibilityActivate(), "The actual alert-direction menu must open")
                    let choice = try await element(in: window, label: title, button: true)
                    try await activateMenuChoice(title, rendered: choice, owner: owner)
                    try await waitUntil("The selected alert direction must update its accessibility value") {
                        nativeElements(window).contains {
                            $0.accessibilityLabel?.contains("Alert direction") == true
                                && $0.accessibilityValue == value
                        }
                    }
                }
                _ = try await reveal(in: window, labelContaining: "Add", button: true)
                let picker = try #require(nativeElements(window).first {
                    $0.accessibilityLabel?.contains("Alert direction") == true
                        && $0.accessibilityTraits.contains(.button)
                })
                let price = try #require(nativeElements(window).compactMap { $0 as? UITextField }
                    .first { nativeIdentifier($0) == "journal.field.Price" })
                let add = try await element(in: window, label: "Add", button: true)
                let pickerFrame = window.convert(picker.accessibilityFrame, from: nil)
                let priceFrame = window.convert(price.accessibilityFrame, from: nil)
                let addFrame = window.convert(add.accessibilityFrame, from: nil)
                for frame in [pickerFrame, priceFrame, addFrame] {
                    try #require(!frame.isEmpty && window.bounds.contains(frame),
                                 "Measure the current visible alert controls, not detached or offscreen nodes")
                }
                #expect(!pickerFrame.intersects(priceFrame), "Alert direction must not overlap the Price field")
                #expect(addFrame.height >= 44, "Add must retain a 44-point minimum height")
                #expect(price.text?.isEmpty != false, "Changing direction must leave the unsubmitted price draft empty")
                try await saveViewport(window, name: "alerts-direction-checked", accessibility: accessibility)
            }
        })
    }

    @Test(arguments: [false, true])
    func tradingTabsAndLibraryOpenWithoutStartingResearch(accessibility: Bool) async throws {
        let originalReceipt = StockSageSameDayResearch.shared.receipt
        try await captureWorkspace(section: .sameDay, name: "trading-navigation", accessibility: accessibility, inspect: { _, window in
            _ = try await reveal(in: window, identifier: "research.sameDay.run")
            @MainActor func activate(_ label: String) async throws {
                let item = try await element(in: window, label: label, button: true)
                if nativeIdentifier(item) == "BackButton" {
                    try activateNativeBack(in: window)
                    return
                }
                if !item.accessibilityActivate() {
                    let control = try #require(item as? UIControl)
                    try #require(control.isEnabled)
                    control.sendActions(for: .touchUpInside)
                }
            }
            for horizon in StockSageHorizonResearch.Horizon.allCases {
                try await activate(horizon.rawValue)
                _ = try await reveal(in: window, labelContaining: "Run \(horizon.rawValue) research scan")
                #expect(!nativeElements(window).contains { nativeIdentifier($0) == "research.mode" },
                    "Each research tab must own exactly its titled horizon")
            }
            try await activate("Library")
            let chat = try await reveal(in: window, identifier: "library.open.chat")
            try #require(chat.accessibilityActivate())
            _ = try await reveal(in: window, labelContaining: "Model settings")
            try await activate("Library")
            _ = try await reveal(in: window, identifier: "library.open.briefing")
            try await activate("Same-day pick")
            _ = try await reveal(in: window, identifier: "research.sameDay.run")
            #expect(!StockSageSameDayResearch.shared.isRunning
                    && StockSageSameDayResearch.shared.receipt == originalReceipt)
        })
    }

    @Test(arguments: [false, true])
    func ideasCardDetailKeepsHeaderControlsVisibleAndCaveatReachable(accessibility: Bool) async throws {
        try await captureWorkspace(section: .ideas, name: "ideas-detail-route", accessibility: accessibility, inspect: { _, window in
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
        })
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
            researchHistory: history, inspect: { _, window in
            _ = try await reveal(in: window, labelContaining: "Saved research")
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
            _ = try await reveal(in: window, labelContaining: "Run 7–14 trading days research scan")
            _ = try await element(in: window, label: "Run \(StockSageHorizonResearch.Horizon.fortnight.rawValue) research scan")
            #expect(!nativeElements(window).contains {
                $0.accessibilityLabel == "Run \(StockSageHorizonResearch.Horizon.week.rawValue) research scan"
            }, "The visible Research controls must use the requested fortnight horizon")
            try await saveViewport(window, name: "home-opened-fortnight-research", accessibility: accessibility)
        })
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
                let back = try await element(in: window, identifier: "BackButton")
                try #require(back.accessibilityLabel == "Library")
                try activateNativeBack(in: window)
                _ = try await reveal(in: window, identifier: "library.open.ideas")
            }
            if route == "home" || route == "analytics" {
                let ideas = route == "analytics"
                    ? try await reveal(in: window, identifier: "library.open.ideas")
                    : try await reveal(in: window, labelContaining: "Rules screener, Supporting market context")
                try #require(ideas.accessibilityActivate(), "The supporting link must open the rules screener without running a scan")
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
        let view = StockSageTapeView(symbol: "RKLB", access: .init(key: { "fixture" }, credentialRevision: { nil }, policyRevision: { nil }, allowed: { true }), loadExchanges: { reference }, loadTape: { symbol, _, _ in
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
        let unverified = state == .unverified
        return .init(version: StockSageAIAssessment.QualityReport.version, state: state,
              findings: unverified ? [.uncitedInsiderRecord] : [],
              citedCount: unavailable ? 0 : 1, offeredCount: unavailable ? 0 : (unverified ? 2 : 1),
              classCounts: unavailable ? [:] : (unverified ? ["technical": 1, "insider": 1] : ["technical": 1]),
              insiderPurchases: 0, insiderSales: unverified ? 1 : 0,
              uncitedInsiderIDs: unverified ? ["F2"] : [],
              acceptedAction: "Buy", rejectionReason: nil)
    }

    private func savedPrediction(_ symbol: String, insider: StockSageMassiveEvents.Observation?,
                                 coverageState: String?, at: Date,
                                 quality: StockSageAIAssessment.QualityReport?) -> StockSageResearchHistory.Prediction {
        // A saved prediction is a shortlist entry: the validator accepts only Buy / Strong Buy.
        var value = StockSageResearchHistory.Prediction(symbol: symbol, name: "\(symbol) synthetic company",
            action: "Buy", reason: "Synthetic saved opinion.", risk: "Synthetic risk.", evidence: ["F1"],
            facts: ["F1 synthetic evidence; no live recommendation."]
                + (quality?.uncitedInsiderIDs.isEmpty == false ? ["F2 synthetic insider sale; no motive inferred."] : []), model: "fixture-model",
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
            // Preserve the existing exact-state checks and save the viewport at each one;
            // a single initial PNG only contains the run's introduction.
            let states = [
                ("purchase", "P. Buyer"),
                ("uncited-warning", "An offered insider record was not mentioned in the answer."),
                ("uncited-source", "Insider records offered but not cited: F2"),
                ("sale", "S. Seller"),
                // Supplied plan disclosure, without interpreting the owner's intent.
                ("plan", "Rule 10b5-1"),
                // Missing data, never-assessed quality and unavailable evidence stay distinct.
                ("not-recorded", "Insider activity was not recorded for this saved research"),
                ("not-assessed", "Quality not assessed"),
                ("unavailable", "Evidence unavailable")
            ]
            for (name, label) in states {
                if name == "not-recorded" {
                    // The header also speaks this headline after "Insider activity.".
                    // Capture the separately rendered paragraph, not that summary header.
                    let paragraph = try await reveal(in: window, label: label)
                    #expect(paragraph.accessibilityLabel == label)
                } else {
                    _ = try await reveal(in: window, labelContaining: label)
                }
                try await saveViewport(window, name: "insider-quality-" + name, accessibility: accessibility)
            }
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
            let filters = try await reveal(in: window, identifier: "research.history.filters")
            #expect(!nativeElements(window).contains { $0.accessibilityLabel?.hasPrefix("Evidence checks") == true })
            try #require(filters.accessibilityActivate())
            for (name, label) in [("horizon", "Horizon"), ("action", "Action"),
                                  ("evidence", "Evidence checks"), ("insider", "Insider activity"),
                                  ("outcome", "Outcome")] {
                _ = try await reveal(in: window, labelContaining: label, button: true)
                try await saveViewport(window, name: "saved-research-filter-" + name, accessibility: accessibility)
            }
            // This original run has no terminal receipt: selecting Settled must hide it,
            // state that filters excluded existing history, and offer the native clear action.
            let outcome = try await reveal(in: window, labelContaining: "Outcome", button: true)
            try #require(outcome.accessibilityActivate())
            let owner = try #require(outcome as? UIButton)
            let settled = try await element(in: window, label: "Settled")
            try await activateMenuChoice("Settled", rendered: settled, owner: owner)
            _ = try await reveal(in: window, labelContaining: "No saved research matches this search or these filters.")
            try await saveViewport(window, name: "saved-research-filtered-empty", accessibility: accessibility)
            #expect(!nativeElements(window).contains { nativeIdentifier($0) == "research.history.run.\(run.id)" })
            let clear = try await reveal(in: window, labelContaining: "Clear filters")
            try #require(clear.accessibilityActivate())
            _ = try await reveal(in: window, identifier: "research.history.run.\(run.id)")
            try await saveViewport(window, name: "saved-research-filter-cleared", accessibility: accessibility)
            #expect(history.runs.count == 1 && history.runs.first?.id == run.id && !history.isChecking)
        }
    }

    private func captureWorkspace(section: MarketSection, name: String, accessibility: Bool,
                                  researchHistory: StockSageResearchHistory? = nil,
                                  configureRecords: (@MainActor (StockSagePortfolio, StockSageJournalStore, StockSagePaperTradeStore) throws -> Void)? = nil,
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
        try configureRecords?(portfolio, journal, paper)
        let originalTrades = journal.trades
        let originalPositions = portfolio.positions
        let originalPaper = paper.trades
        let originalIdeaSymbols = store.ideas.map(\.symbol)
        let originalIdeasUpdated = store.ideasUpdated
        let originalRuns = history.runs
        let view = MarketsView(chatSession: chat, qaSection: section,
            store: store, aiAssessments: ai, portfolio: portfolio, journal: journal,
            paperStore: paper, live: live, velocityHistory: velocity, monitor: monitor, researchHistory: history)
        try await capture(view.defaultAppStorage(defaults), name: name,
                          accessibility: accessibility, viewportHeight: 812, shellPadding: 0, inspect: inspect)
        #expect(store.isSampleData && store.userSymbols == ["AAPL", "MSFT", "RKLB"])
        #expect(!live.isStreaming && live.subscribed.isEmpty && !monitor.isRunning && ai.activeSymbol == nil)
        #expect(journal.trades == originalTrades && portfolio.positions == originalPositions
                && paper.trades == originalPaper && velocity.series.isEmpty,
                "Navigation, disclosures and canceled dialogs must retain every fixture record")
        let savedJournal = try journal.backupRecords()
        let savedPortfolio = try portfolio.backupRecords()
        let savedPaper = StockSagePaperTradeStore(defaults: defaults)
        #expect(savedJournal == originalTrades && savedPortfolio == originalPositions)
        #expect(savedPaper.hasLoadedRecords && savedPaper.lastError == nil && savedPaper.trades == originalPaper)
        #expect(!store.isRefreshing && !store.isLoadingIdeas && !store.isLoadingStrategy
                && !store.isBacktesting && !store.isComputingParity && !store.isLoadingAnalytics)
        #expect(store.ideas.map(\.symbol) == originalIdeaSymbols && store.ideasUpdated == originalIdeasUpdated,
                "Opening supporting panels must not replace the seeded Rules results")
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
        try await waitUntil("Done must dismiss the actual presented sheet") {
            func presented(_ controller: UIViewController) -> Bool {
                controller.presentedViewController != nil || controller.children.contains(where: presented)
            }
            return window.rootViewController.map { !presented($0) } ?? false
        }
    }

    private func saveViewport(_ window: UIWindow, name: String, accessibility: Bool,
                              afterDisclosureSettles: (@MainActor () async throws -> Void)? = nil) async throws {
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
        func renderedPNG() throws -> Data {
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(rendered, "The navigated native research viewport must draw completely")
            return try #require(image.pngData())
        }
        if let afterDisclosureSettles {
            // SwiftUI exposes final AX frames before DisclosureGroup finishes painting.
            // These few disclosure captures require a quiet rendered viewport, not just
            // a nil navigation coordinator or repeatedly identical logical AX bounds.
            let paintDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            var previous = try renderedPNG()
            var identicalFrames = 0
            while identicalFrames < 5, ContinuousClock.now < paintDeadline {
                try await Task.sleep(for: .milliseconds(50))
                let current = try renderedPNG()
                identicalFrames = current == previous ? identicalFrames + 1 : 0
                previous = current
            }
            try #require(identicalFrames == 5, "Disclosure paint did not settle within three seconds")
            // The logical child may have moved while its parent expanded. Scroll to
            // its current frame after settling, then capture the actual final viewport.
            try await afterDisclosureSettles()
        }
        let png = try renderedPNG()
        let size = accessibility ? "accessibility3" : "default"
        try png.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-ios-\(name)-375-\(size).png"), options: .atomic)
    }

    private func scanToBottom(in window: UIWindow, name: String, accessibility: Bool) async throws {
        func visibleScrolls() -> [UIScrollView] {
            guard let root = visibleContentView(in: window) else { return [] }
            return descendants(root).compactMap { $0 as? UIScrollView }.filter { scroll in
                guard !(scroll is UITextView), scroll.isScrollEnabled, scroll.window === window,
                      scroll.bounds.height > 1,
                      scroll.convert(scroll.bounds, to: window).intersects(window.bounds) else { return false }
                var ancestor: UIView? = scroll
                while let node = ancestor {
                    if node.isHidden || node.alpha <= 0.01 { return false }
                    ancestor = node.superview
                }
                return scroll.contentSize.height + scroll.adjustedContentInset.top
                    + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1
            }
        }
        var reachedBottom = false
        for step in 0..<60 {
            window.layoutIfNeeded()
            let scrolls = visibleScrolls()
            let pending = scrolls.filter { scroll in
                scroll.contentOffset.y < scroll.contentSize.height + scroll.adjustedContentInset.bottom
                    - scroll.bounds.height - 1
            }
            if pending.isEmpty {
                // Lazy lists can revise their extent after a layout pass. Require a
                // second settled observation before declaring the page complete.
                if reachedBottom {
                    try await saveViewport(window, name: "\(name)-bottom", accessibility: accessibility)
                    return
                }
                reachedBottom = true
            } else {
                reachedBottom = false
                for scroll in pending {
                    let bottom = max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                        y: min(bottom, scroll.contentOffset.y + scroll.bounds.height * 0.7)), animated: false)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            try await saveViewport(window, name: "\(name)-scroll-\(step + 1)", accessibility: accessibility)
        }
        Issue.record("The \(name) fixture did not reach the bottom of its visible native scroll views in 60 viewports")
    }

    private func capture(_ view: some View, name: String, accessibility: Bool,
                         dynamicTypeSize: DynamicTypeSize? = nil,
                         viewportHeight: CGFloat? = nil,
                         shellPadding: CGFloat = 16,
                         inspect: (@MainActor (UIHostingController<AnyView>, UIWindow) async throws -> Void)? = nil) async throws {
        let width: CGFloat = 375
        let textSize = dynamicTypeSize ?? (accessibility ? .accessibility3 : .large)
        try #require([DynamicTypeSize.large, .accessibility3, .accessibility5].contains(textSize))
        var appeared = false
        // Erase the fixture wrapper to avoid the documented iOS 27 deep generic metadata issue.
        let host = UIHostingController(rootView: AnyView(view.padding(shellPadding)
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, textSize)
            .tint(DS.Palette.accent)
            // Intrinsic component captures measure full content; real phone viewports
            // retain the device's safe areas and keyboard avoidance.
            .ignoresSafeArea(.container, edges: viewportHeight == nil ? .all : [])
            .onAppear { appeared = true }))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        window.overrideUserInterfaceStyle = .dark
        // Presented UIKit/SwiftUI sheets inherit native traits from their window.
        window.traitOverrides.preferredContentSizeCategory = textSize == .accessibility5
            ? .accessibilityExtraExtraExtraLarge : (textSize == .accessibility3 ? .accessibilityExtraLarge : .large)
        window.rootViewController = host
        host.view.backgroundColor = UIColor(DS.Palette.bgTop)
        let previousKeyWindow = scene.keyWindow
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
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
            try? await saveViewport(window, name: name + "-failure", accessibility: accessibility)
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

    private func element(in window: UIWindow, identifier: String? = nil, label: String? = nil, button: Bool = false,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws -> NSObject {
        var match: NSObject?
        try await waitUntil("Native element missing: \(identifier ?? label ?? "unspecified")", sourceLocation: sourceLocation) {
            // A native menu may be presented in another window of this fixture's test scene.
            let roots = window.windowScene?.windows.filter { !$0.isHidden } ?? [window]
            match = roots.flatMap { nativeElements($0) }.first { object in
                guard !button || object.accessibilityTraits.contains(.button) else { return false }
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

    private func activateNativeBack(in window: UIWindow) throws {
        // SwiftUI's system back accessibility element is not a UIControl. Exercise
        // UIKit's actual back navigation and verify the resulting SwiftUI route.
        func controllers(_ root: UIViewController) -> [UIViewController] {
            [root] + root.children.flatMap(controllers)
        }
        let root = try #require(window.rootViewController)
        let candidates = controllers(root).compactMap { $0 as? UINavigationController }.filter {
            $0.isViewLoaded && $0.view.window === window && !$0.view.isHidden
                && $0.viewControllers.count > 1 && $0.navigationBar.backItem != nil
        }
        try #require(candidates.count == 1, "The visible Library stack must own one native back route")
        try #require(candidates[0].popViewController(animated: false) != nil)
    }

    private func reveal(in window: UIWindow, identifier: String? = nil, label: String? = nil,
                        labelContaining: String? = nil, within containerIdentifier: String? = nil,
                        button: Bool = false) async throws -> NSObject {
        let description = identifier ?? label ?? labelContaining ?? "unspecified"
        // Identical disclosure labels appear in all five rows. Resolve the current
        // container each time because scrolling can replace its native AX subtree.
        func candidates() -> [NSObject] {
            let elements = nativeElements(window)
            guard let containerIdentifier else { return elements }
            guard let container = elements.first(where: { nativeIdentifier($0) == containerIdentifier }) else { return [] }
            return nativeElements(container)
        }
        for attempt in 0..<30 {
            if let match = candidates().first(where: { object in
                guard !button || object.accessibilityTraits.contains(.button) else { return false }
                if let identifier { return nativeIdentifier(object) == identifier }
                if let label { return object.accessibilityLabel == label }
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
                // Scrolling a SwiftUI subtree can replace the original native node.
                // Activate its current visible counterpart, not a detached menu owner.
                let current = candidates().first { object in
                    guard !button || object.accessibilityTraits.contains(.button) else { return false }
                    if let identifier { return nativeIdentifier(object) == identifier }
                    if let label { return object.accessibilityLabel == label }
                    return labelContaining.map { object.accessibilityLabel?.contains($0) == true } ?? false
                }
                if let current, !current.accessibilityFrame.isEmpty,
                   current.accessibilityFrame.minX.isFinite, current.accessibilityFrame.minY.isFinite {
                    let frame = window.convert(current.accessibilityFrame, from: nil)
                    let visible = visibleContentView(in: window).map {
                        window.convert($0.bounds, from: $0).intersection(window.bounds)
                    } ?? window.bounds
                    if visible.intersects(frame), frame.minX >= window.bounds.minX - 1,
                       frame.maxX <= window.bounds.maxX + 1 {
                        print("Native reveal matched: \(nativeDescription(current))")
                        return current
                    }
                }
                continue
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
        // AX can expose an offscreen SwiftUI field before its native view is mounted.
        // Resolve its label, reveal it, then reacquire the current mounted field.
        // The close editor is last; its label distinguishes the duplicate entry-fill ID.
        let match = try #require(nativeElements(window).compactMap { $0 as? UITextField }
            .last { nativeIdentifier($0) == "journal.field.\(placeholder)" || $0.placeholder == placeholder })
        let label = try #require(match.accessibilityLabel)
        _ = try await reveal(in: window, label: label)
        func mountedField() -> UITextField? {
            guard let root = visibleContentView(in: window) else { return nil }
            return descendants(root).compactMap { $0 as? UITextField }.last {
                $0.window === window && !$0.isHidden && $0.alpha >= 0.01 && !$0.bounds.isEmpty
                    && $0.accessibilityLabel == label
                    && (nativeIdentifier($0) == "journal.field.\(placeholder)" || $0.placeholder == placeholder)
            }
        }
        try await waitUntil("Revealed field must mount in the fixture window: \(label)") {
            host.view.layoutIfNeeded()
            return mountedField() != nil
        }
        let field = try #require(mountedField())
        try #require(field.window === window && field.isEnabled)
        let frame = field.convert(field.bounds, to: window)
        let root = try #require(visibleContentView(in: window))
        let viewport = window.convert(root.bounds, from: root).intersection(window.bounds)
        try #require(viewport.intersects(frame), "Type into the revealed native field: \(label)")
        field.text = value
        field.sendActions(for: .editingChanged)
        host.view.layoutIfNeeded()
        try await waitUntil("The current mounted field must retain the entered text: \(label)") {
            mountedField()?.text == value
        }
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

@MainActor private struct PhoneSheetPresentationFixture<Content: View>: View {
    @State private var isPresented = false
    let content: () -> Content

    var body: some View {
        Button("Open fixture sheet") { isPresented = true }
            .accessibilityIdentifier("fixture.openSheet")
            .sheet(isPresented: $isPresented, content: content)
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
            StockSageTapeView(symbol: symbol, access: .init(key: { "fixture" }, credentialRevision: { nil }, policyRevision: { nil }, allowed: { true }), loadExchanges: loadExchanges, loadTape: loadTape)
        }
    }
}
#endif
