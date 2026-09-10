import Foundation
import Testing
@testable import StockSage
#if os(macOS)
import Darwin
#endif

@Suite("Qwen paper automation") @MainActor
struct StockSagePaperAutomationTests {
    typealias A = StockSagePaperAutomation
    private let now = Date(timeIntervalSince1970: 1_788_886_800) // 2026-09-08, US regular session.
    #if os(macOS)
    @Test func paperResearchTimingUsesActualDuePredicate() throws {
        let start = try Date("2026-09-09T15:00:00Z", strategy: .iso8601)
        var book = A.Book(); book.lastResearch = start
        let due = "Research due; waiting for monitor and eligible data."
        #expect(A.researchDue(book: book, at: start))
        #expect(StockSagePaperAutomationPanel.researchTiming(book: book, at: start, running: true, researching: false) == due)
        book.note(action: "Market scan", reason: "Synthetic scan", at: start)
        for offset in [900.0, 1200] {
            #expect(StockSagePaperAutomationPanel.researchTiming(book: book, at: start.addingTimeInterval(offset), running: true, researching: false) == due)
        }
    }

    @Test func paperLatestActivityIncludesGlobalFailure() throws {
        var book = A.Book()
        book.note(symbol: "AAPL", action: "Buy", reason: "Synthetic opinion", at: now)
        book.note(action: "Unavailable", reason: "Synthetic Qwen failure", at: now.addingTimeInterval(1))
        let original = try JSONEncoder().encode(book)
        #expect(StockSagePaperAutomationPanel.latestActivity(in: book.decisions) == book.decisions.last)
        #expect(StockSagePaperAutomationPanel.latestActivity(in: []) == nil)
        #expect(try JSONDecoder().decode(A.Book.self, from: original).decisions == book.decisions)
    }

    @Test func panelModeDescribesEnabledStateNotContinuousActivity() {
        #expect(StockSagePaperAutomationPanel.modeLabel(running: true) == "Day trading enabled · simulation only")
        #expect(StockSagePaperAutomationPanel.modeLabel(running: false) == "Day trading paused · simulation only")
    }
    #endif

    private func quote(_ symbol: String = "AAPL", price: Double = 100, at: Date,
                       source: StockSagePriceSource = .massiveSIP) -> StockSageQuoteService.LiveQuote {
        .init(symbol: symbol, price: price, previousClose: 100, marketTime: at, priceSource: source,
              paperTradeQualified: true) // Explicit synthetic qualified-tape fixture.
    }

    #if os(macOS)
    @Test func paperResearchTimingBoundaryAndStatePrecedence() throws {
        let start = try Date("2026-09-09T11:00:00-04:00", strategy: .iso8601)
        var book = A.Book(); book.lastResearch = start
        book.note(action: "Market scan", reason: "Synthetic scan", at: start)
        for offset in [899.0, 899.999] {
            let text = try #require(StockSagePaperAutomationPanel.researchTiming(book: book,
                at: start.addingTimeInterval(offset), running: true, researching: false))
            #expect(text.hasPrefix("Earliest next cycle: ") && text.hasSuffix(" · while awake, connected and in session"))
        }
        var never = book; never.lastResearch = nil
        #expect(StockSagePaperAutomationPanel.researchTiming(book: never, at: start, running: true, researching: false)
            == "Research due; waiting for monitor and eligible data.")
        for (running, researching) in [(false, false), (true, true), (false, true)] {
            #expect(StockSagePaperAutomationPanel.researchTiming(book: book, at: start.addingTimeInterval(-1),
                running: running, researching: researching) == nil)
        }
        let closed = try Date("2026-09-09T20:00:00-04:00", strategy: .iso8601)
        #expect(StockSagePaperAutomationPanel.researchTiming(book: book, at: closed, running: true, researching: false) == nil)
        book.lastResearch = closed.addingTimeInterval(1)
        let warning = try #require(StockSagePaperAutomationPanel.researchTiming(book: book, at: closed, running: true, researching: false))
        #expect(warning.localizedCaseInsensitiveContains("clock") && !warning.hasPrefix("Earliest next cycle: "))
    }

    @Test func paperSummaryMarksAgeWithoutRefreshingQuotesOrSettlementHistory() throws {
        let at = try Date("2026-09-09T11:00:00-04:00", strategy: .iso8601)
        let held = A.Book(trades: [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98,
            target: 104, shares: 1, openedAt: at.addingTimeInterval(-60))])
        let sold = A.Book(trades: [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98,
            target: 104, shares: 1, openedAt: at.addingTimeInterval(-60), exitPrice: 110, closedAt: at)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode([held, sold]), q = quote(at: at)
        #expect(held.equity(quotes: ["AAPL": q], at: at.addingTimeInterval(10)) == 9999.9)
        #expect(held.equity(quotes: ["AAPL": q], at: at.addingTimeInterval(10.001)) == nil)
        #expect(held.equity(quotes: [:], at: at) == nil && A.Book().equity(quotes: [:], at: at) == 10_000)
        let due = try #require(A.settlementDate(forSaleAt: at))
        #expect(sold.buyingCash(at: due.addingTimeInterval(-1)) == 9900 && sold.unsettledProceeds(at: due.addingTimeInterval(-1)) == 110)
        #expect(sold.buyingCash(at: due) == 10_010 && sold.unsettledProceeds(at: due) == 0)
        #expect(sold.equity(quotes: [:], at: due.addingTimeInterval(-1)) == sold.equity(quotes: [:], at: due))
        #expect(try encoder.encode([held, sold]) == before && q.marketTime == at)
    }

    @Test(arguments: ["2026-09-09T19:55:00-04:00", "2026-11-27T16:55:00-05:00"])
    func paperCloseOutWarningTracksCutoffsAndRetainedHoldings(_ iso: String) throws {
        let at = try Date(iso, strategy: .iso8601)
        let book = A.Book(trades: [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98,
            target: 104, shares: 1, openedAt: at.addingTimeInterval(-3600))])
        #expect(StockSagePaperAutomationPanel.closeOutWarning(book: book, at: at.addingTimeInterval(-1), running: true) == nil)
        #expect(StockSagePaperAutomationPanel.closeOutWarning(book: book, at: at, running: true) != nil)
        #expect(StockSagePaperAutomationPanel.closeOutWarning(book: book, at: at, running: false)?.localizedCaseInsensitiveContains("exit checks are paused") == true)
        #expect(StockSagePaperAutomationPanel.closeOutWarning(book: book, at: at.addingTimeInterval(23 * 3600), running: true) != nil)
    }

    @Test func paperActivityCommitOrderAndExactNoFillActions() throws {
        let at = try Date("2026-09-09T10:00:00-04:00", strategy: .iso8601)
        let actions = ["Unavailable", "Skipped", "Expired", "Cancelled", "Buy", "Strong Buy", "Paper Buy",
                       "Paper Sell", "Exit requested", "Market scan unavailable", "unavailable", "Unavailable "]
        let records = actions.enumerated().map { index, action in
            A.Decision(id: UUID(), at: at.addingTimeInterval(-Double(index)), symbol: index == 0 ? "" : "AAPL", action: action,
                reason: "Saved reason \(index)", risk: "", facts: ["Saved evidence"], evidence: [], model: "")
        }
        #expect(StockSagePaperAutomationPanel.latestActivity(in: records) == records.last)
        for end in 1...records.count {
            #expect(StockSagePaperAutomationPanel.latestNoFillEvidence(in: Array(records.prefix(end))) == records[min(end, 4) - 1])
        }
        #expect(StockSagePaperAutomationPanel.latestNoFillEvidence(in: Array(records.dropFirst(4))) == nil)
        #expect(StockSagePaperAutomationPanel.latestNoFillEvidence(in: []) == nil)
    }

    @Test func paperPendingStatusPrecedenceAndAttemptBoundaries() throws {
        let at = try Date("2026-09-09T10:00:00-04:00", strategy: .iso8601)
        let cutoff = try Date("2026-09-09T19:55:00-04:00", strategy: .iso8601)
        let closed = try Date("2026-09-09T20:00:00-04:00", strategy: .iso8601)
        let unsupported = try Date("2027-09-09T10:00:00-04:00", strategy: .iso8601)
        let paused = "Monitoring paused; no attempts run."
        let entry = "Entry window closed; awaiting monitor processing."
        let future = "Current clock precedes the saved attempt; awaiting monitor processing."
        let elapsed = "Attempt window elapsed; awaiting monitor processing."
        let session = "No fills outside a supported paper session."
        let waiting = "Awaiting a later eligible observation; detailed cause not recorded."
        let cases: [(Date, Double, Bool, Bool, String)] = [
            (at, -0.001, false, true, future), (at, 0, false, true, waiting), (at, 0, true, true, waiting),
            (at, 119.999, false, true, waiting), (at, 120, false, true, elapsed),
            (cutoff, -1, true, false, paused), (at, 120, false, false, paused),
            (cutoff, -1, true, true, entry), (cutoff, 120, true, true, entry),
            (cutoff, 0, false, true, waiting), (closed, 0, false, true, session),
            (closed, 120, false, true, elapsed), (closed, -1, false, true, future),
            (unsupported, 0, false, true, session)
        ]
        for (now, age, buy, running, expected) in cases {
            let request = A.Pending(id: UUID(), symbol: "AAPL", buy: buy, at: now.addingTimeInterval(-age))
            #expect(StockSagePaperAutomationPanel.pendingStatus(request, running: running, at: now) == expected)
        }
        var protective = A.Pending(id: UUID(), symbol: "AAPL", buy: false,
            at: closed.addingTimeInterval(-120), protectiveTradeID: UUID())
        #expect(StockSagePaperAutomationPanel.pendingStatus(protective, running: false, at: closed) == paused)
        protective.at = closed.addingTimeInterval(1)
        #expect(StockSagePaperAutomationPanel.pendingStatus(protective, running: true, at: closed) == future)
        #expect(StockSagePaperAutomationPanel.pendingStatus(protective, running: false, at: closed) == paused)
    }
    #endif

    @Test func tenSecondPriceBoundaryControlsActualPaperFills() {
        for age in [0.0, 10, 10.001, -0.001] {
            let executionAt = now.addingTimeInterval(30)
            let q = quote(at: executionAt.addingTimeInterval(-age))
            #expect(A.fresh(q, at: executionAt) == (age >= 0 && age <= 10))
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: ["AAPL": q], at: executionAt)
            #expect(book.open.count == (age >= 0 && age <= 10 ? 1 : 0))
        }
        #expect(!A.fresh(.init(symbol: "AAPL", price: 100, previousClose: 99, marketTime: nil,
                              priceSource: .massiveSIP), at: now))
        #expect(!A.fresh(quote(at: now, source: .yahoo), at: now))
    }

    @Test func researchAllowsOneMinuteObservationsButExecutionStaysAtTen() async throws {
        let decisionAt = now.addingTimeInterval(90)
        let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Momentum", risk: "Reversal", evidence: ["F1"])
        for age in [0.0, 10, 10.001, 20, 20.001, 59.999, 60, 60.001, -0.001] {
            let observation = quote(at: decisionAt.addingTimeInterval(-age))
            let researchEligible = (0...60).contains(age)
            for fromSnapshot in [false, true] {
                let quotes = await A.fetchPaperQuotes(for: ["AAPL"], at: decisionAt, maximumAge: A.researchMaximumAge,
                    externalAllowed: { true }, snapshots: { _ in fromSnapshot ? ["AAPL": observation] : [:] },
                    tick: { _, _ in fromSnapshot ? nil : observation })
                #expect((quotes["AAPL"] != nil) == researchEligible)
            }
            let market = StockSageMassive.MarketSnapshot(returnedCount: 1, rows: [
                .init(quote: observation, dollarVolume: 1000)
            ])
            #expect(!A.researchTargets(market: market, book: A.Book(), at: decisionAt).isEmpty == researchEligible)
            let researched = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: ["Dated observation"],
                model: "test", researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: decisionAt,
                allowed: { true }, contextFresh: { _ in true }, currentBook: { A.Book() }, fetch: { _, _ in observation }))
            #expect(!researched.pending.isEmpty == researchEligible)
            var filling = A.Book()
            filling.propose(symbol: "AAPL", action: .buy, at: now)
            filling.settle(quotes: ["AAPL": observation], at: decisionAt)
            #expect(!filling.open.isEmpty == (0...10).contains(age))
            #expect(StockSageLiveStream.isLiveObservation(observation.marketTime, at: decisionAt) == (0...10).contains(age))
        }
    }

    @Test func buyOpinionsKeepDatedEntryStopTargetPreviewWithoutRewritingOlderRows() async throws {
        for action in [TradeAdvice.Action.buy, .strongBuy, .hold] {
            let verdict = StockSageAIAssessment.Verdict(action: action, reason: "Case", risk: "Risk", evidence: ["F1"])
            let b = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: ["Observed"],
                model: "test", researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: now.addingTimeInterval(1),
                allowed: { true }, contextFresh: { _ in true }, currentBook: { A.Book() }, fetch: { _, _ in nil }))
            let decision = try #require(b.decisions.first)
            if action == .hold { #expect(decision.plan == nil); continue }
            let p = try #require(decision.plan)
            #expect(p.at == now && p.entry == 100 * (1 + A.costRate))
            #expect(p.stop == p.entry * 0.98 && p.target == p.entry * 1.04)
            #expect(b.pending.isEmpty && b.trades.isEmpty) // preview is not an executable order
            let encoded = try JSONEncoder().encode(decision)
            #expect(try JSONDecoder().decode(A.Decision.self, from: encoded) == decision)
            var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "plan")
            let old = try JSONDecoder().decode(A.Decision.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(old.plan == nil && old.facts == ["Observed"])
        }
    }

    @Test func failedResearchRetainsSourceEvidenceWithoutAnOpinionOrOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "failed-research-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let facts = ["Synthetic completed Massive minute at \(now.ISO8601Format()): close 100 USD."]
        try #require(state.acquire())
        state.recordFailure("No verified model opinion; source evidence retained.", symbol: "AAPL", at: now, facts: facts)
        let decision = try #require(state.book.decisions.last)
        #expect(decision.action == "Unavailable" && decision.facts == facts && decision.at == now)
        #expect(decision.model.isEmpty && decision.evidence.isEmpty && state.book.pending.isEmpty && state.book.trades.isEmpty)
        let saved = try JSONDecoder().decode(A.Book.self, from: Data(contentsOf: url))
        #expect(saved.decisions == state.book.decisions && saved.valid)
    }

    @Test func mixedPaperCandidatesCannotBorrowPeerFreshness() async {
        let fillAt = now.addingTimeInterval(30)
        let candidates = ["AAPL": quote("AAPL", at: fillAt.addingTimeInterval(-11)),
                          "MSFT": quote("MSFT", at: fillAt)]
        var requested: [String] = []
        let selected = await A.fetchPaperQuotes(for: ["AAPL", "MSFT"], after: [:], at: fillAt,
            externalAllowed: { true }, snapshots: { _ in candidates },
            tick: { symbol, _ in requested.append(symbol); return nil })
        #expect(requested == ["AAPL"] && Set(selected.keys) == ["MSFT"])
        var book = A.Book()
        for symbol in ["AAPL", "MSFT"] { book.propose(symbol: symbol, action: .buy, at: now) }
        book.settle(quotes: candidates, at: fillAt)
        #expect(book.open.map(\.symbol) == ["MSFT"])
        #expect(book.pending.map(\.symbol) == ["AAPL"])
    }

    @Test func readyExitDoesNotWaitForSlowPeerQuote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "monitor-arrival-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        try #require(state.acquire())
        var seeded = A.Book()
        seeded.propose(symbol: "AAPL", action: .buy, at: now)
        seeded.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(1))
        seeded.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(2))
        seeded.propose(symbol: "MSFT", action: .buy, at: now.addingTimeInterval(2))
        try #require(state.save(seeded))
        let originalID = try #require(seeded.open.first?.id)
        let observedAt = now.addingTimeInterval(4)
        var suspended: CheckedContinuation<Void, Never>?
        var fastReturned = false
        let work = Task { @MainActor in
            let completed = await state.pollPositions(allowed: { true }, at: observedAt,
                tick: { symbol, _ in
                    if symbol == "MSFT" { await withCheckedContinuation { suspended = $0 } }
                    else { fastReturned = true }
                    return quote(symbol, price: 101, at: observedAt)
                })
            #expect(completed)
        }
        for _ in 0..<100 {
            if suspended != nil && fastReturned { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(suspended != nil && fastReturned)
        #expect(state.book.trades.first(where: { $0.id == originalID })?.isOpen == false,
                "A ready later exit observation must be saved before the slow sibling returns")
        #expect(!state.book.open.contains(where: { $0.symbol == "MSFT" }))
        suspended?.resume(); suspended = nil
        await work.value
        #expect(state.book.decisions.filter { $0.action == "Paper Sell" && $0.symbol == "AAPL" }.count == 1)
        #expect(state.book.trades.first?.id == originalID)
        let saved = try JSONDecoder().decode(A.Book.self, from: Data(contentsOf: url))
        #expect(saved.trades == state.book.trades && saved.valid)
    }

    @Test(arguments: [false, true])
    func retiredMonitorCannotPublishOrOverwriteInterveningBook(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "retired-monitor-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        try #require(state.acquire())
        var seeded = A.Book()
        seeded.propose(symbol: "AAPL", action: .buy, at: now)
        seeded.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(1))
        seeded.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(2))
        try #require(state.save(seeded))
        var allowed = true
        var suspended: CheckedContinuation<Void, Never>?
        let work = Task { @MainActor in
            await state.pollPositions(allowed: { allowed }, at: now.addingTimeInterval(4), tick: { _, at in
                await withCheckedContinuation { suspended = $0 } // Deliberately ignores cancellation until released.
                return quote(at: at)
            })
        }
        for _ in 0..<100 {
            if suspended != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(suspended != nil)
        if cancel { work.cancel() } else { allowed = false }
        state.recordFailure("Intervening synthetic research record", at: now.addingTimeInterval(3))
        let before = try Data(contentsOf: url)
        suspended?.resume(); suspended = nil
        let completed = await work.value
        #expect(!completed && state.quotes.isEmpty && state.book.open.count == 1)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func laterBasisWarningStopsRemainingWorkWithoutRewritingCompletedExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "monitor-basis-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let state = A(url: root.appendingPathComponent("account.json"), defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        try #require(state.acquire())
        var seeded = A.Book()
        for symbol in ["AAPL", "MSFT"] {
            seeded.propose(symbol: symbol, action: .buy, at: now)
            seeded.settle(quotes: [symbol: quote(symbol, at: now.addingTimeInterval(1))], at: now.addingTimeInterval(1))
        }
        seeded.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(2))
        seeded.propose(symbol: "NVDA", action: .buy, at: now.addingTimeInterval(2))
        try #require(state.save(seeded))
        var suspended: CheckedContinuation<Void, Never>?
        var buyReturned = false
        let work = Task { @MainActor in
            await state.pollPositions(allowed: { true }, at: now.addingTimeInterval(4), tick: { symbol, at in
                if symbol == "MSFT" { await withCheckedContinuation { suspended = $0 } }
                if symbol == "NVDA" { buyReturned = true }
                return quote(symbol, price: symbol == "MSFT" ? 200 : 100, at: at)
            })
        }
        for _ in 0..<100 {
            if suspended != nil && buyReturned && !state.book.open.contains(where: { $0.symbol == "AAPL" }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(suspended != nil && buyReturned)
        #expect(!state.book.open.contains(where: { $0.symbol == "AAPL" }))
        #expect(!state.book.open.contains(where: { $0.symbol == "NVDA" })) // No early buy.
        let exited = state.book.trades.first(where: { $0.symbol == "AAPL" })
        suspended?.resume(); suspended = nil
        let completed = await work.value
        #expect(!completed && state.error?.contains("basis change") == true)
        #expect(state.book.open.map(\.symbol) == ["MSFT"] && state.book.pending.isEmpty)
        #expect(state.book.trades.first(where: { $0.symbol == "AAPL" }) == exited)
        #expect(state.book.decisions.filter { $0.action == "Paper Sell" }.count == 1)
        #expect(state.quotes["MSFT"] == nil)
    }

    @Test func unqualifiedSnapshotCannotBypassTradeChecksOrSettle() async throws {
        // The display snapshot preserves price/time, not condition/event-clock qualification.
        for condition in [NSNull(), [999_999]] as [Any] {
            let raw: [String: Any] = ["status": "OK", "tickers": [["ticker": "AAPL",
                "lastTrade": ["p": 100, "t": (now.timeIntervalSince1970 + 1) * 1_000_000_000,
                              "c": condition, "s": 0], "prevDay": ["c": 99]]]]
            let data = try JSONSerialization.data(withJSONObject: raw)
            let snapshot = try #require(StockSageMassive.parseSnapshot(data, requestedSymbols: ["AAPL"])["AAPL"])
            var ticks = 0
            let selected = await A.fetchPaperQuotes(for: ["AAPL"], after: ["AAPL": now],
                at: now.addingTimeInterval(2), externalAllowed: { true },
                snapshots: { _ in ["AAPL": snapshot] }, tick: { _, _ in ticks += 1; return nil })
            #expect(ticks == 1 && selected.isEmpty)
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: ["AAPL": snapshot], at: now.addingTimeInterval(2))
            #expect(book.open.isEmpty && book.cash == A.initialCash)
        }
    }

    @Test func delayedInferenceRevalidatesWithoutRewritingFactsOrOverwritingConcurrentBook() async throws {
        let decisionAt = now.addingTimeInterval(45)
        let captured = quote(at: now)
        let fresh = quote(at: decisionAt)
        let facts = ["Original observation at \(now.ISO8601Format())"]
        let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Momentum", risk: "Reversal", evidence: ["F1"])
        var current = A.Book()
        var fetches = 0, commits = 0
        let result = await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: facts, model: "test",
            researchQuote: captured, holdingID: nil, citesIntraday: true, at: decisionAt,
            allowed: { true }, contextFresh: { _ in true }, currentBook: { current },
            commit: { current = $0; commits += 1; return true }, fetch: { symbol, after in
                fetches += 1
                #expect(symbol == "AAPL" && after == self.now)
                // Simulate a sibling settlement during the post-model network await.
                await Task.yield()
                current.propose(symbol: "MSFT", action: .buy, at: self.now)
                current.settle(quotes: ["MSFT": self.quote("MSFT", at: decisionAt)], at: decisionAt)
                return fresh
            })
        var book = try #require(result)
        #expect(fetches == 1 && commits == 1 && book.open.map(\.symbol) == ["MSFT"])
        #expect(current.pending.contains { $0.symbol == "AAPL" })
        #expect(book.pending.contains { $0.symbol == "AAPL" })
        #expect(book.decisions.first { $0.action == verdict.action.rawValue }?.facts == facts)
        #expect(book.decisions.contains { $0.action == "Price revalidated" && $0.facts.contains("Market timestamp: \(decisionAt.ISO8601Format())") })
        book.settle(quotes: ["AAPL": fresh], at: decisionAt)
        #expect(!book.open.contains { $0.symbol == "AAPL" }, "Revalidation cannot also be a post-proposal fill")
        book.settle(quotes: ["AAPL": quote(at: decisionAt.addingTimeInterval(1))], at: decisionAt.addingTimeInterval(1))
        #expect(book.open.contains { $0.symbol == "AAPL" })
    }

    @Test func postInferenceFailureCancellationAndHoldingChangeFailClosed() async throws {
        let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Momentum", risk: "Reversal", evidence: ["F1"])
        let at = now.addingTimeInterval(90)
        let observationReason = "No valid qualified observation later than the research observation; no paper order created."
        for response in [nil, quote(at: at.addingTimeInterval(-60.001)), quote(at: now.addingTimeInterval(-1)),
                         quote(at: at.addingTimeInterval(0.001)), quote("MSFT", at: at)] {
            let book = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: ["Original"], model: "test",
                researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: at,
                allowed: { true }, contextFresh: { _ in true }, currentBook: { A.Book() }, fetch: { _, _ in response }))
            #expect(book.pending.isEmpty && book.decisions.contains { $0.action == "Skipped" && $0.reason == observationReason })
        }
        let closedAt = try Date("2026-09-09T00:00:00Z", strategy: .iso8601)
        var closedFetches = 0, closedContextChecks = 0
        let closed = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
            researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: closedAt,
            allowed: { true }, contextFresh: { _ in closedContextChecks += 1; return true },
            currentBook: { A.Book() }, fetch: { _, _ in closedFetches += 1; return self.quote(at: closedAt) }))
        #expect(closedFetches == 0 && closedContextChecks == 1 && closed.pending.isEmpty)
        #expect(closed.decisions.contains {
            $0.action == "Skipped" && $0.reason == "Paper session closed after inference; no paper order created."
        })
        var allowed = true, bookReads = 0
        let denied = await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
            researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: at,
            allowed: { allowed }, contextFresh: { _ in true }, currentBook: { bookReads += 1; return A.Book() },
            fetch: { _, _ in allowed = false; return self.quote(at: at) })
        #expect(denied == nil && bookReads == 0)
        let cancelled = Task { @MainActor in
            await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
                researchQuote: self.quote(at: self.now), holdingID: nil, citesIntraday: true, at: at,
                allowed: { true }, contextFresh: { _ in true }, currentBook: { A.Book() },
                fetch: { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return self.quote(at: at) })
        }
        #expect(await cancelled.value == nil)
        var current = A.Book()
        let changed = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
            researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: at,
            allowed: { true }, contextFresh: { _ in true }, currentBook: { current }, fetch: { _, _ in
                current.propose(symbol: "AAPL", action: .buy, at: self.now)
                current.settle(quotes: ["AAPL": self.quote(at: at)], at: at)
                return self.quote(at: at)
            }))
        #expect(changed.open.count == 1 && changed.pending.isEmpty)
        #expect(changed.decisions.contains {
            $0.action == "Skipped" && $0.reason == "Paper holding changed after inference; no paper order created."
        })
    }

    @Test func revalidationCannotUseOlderResearchPriceOrBypassNewExpiry() async throws {
        let verdict = StockSageAIAssessment.Verdict(action: .buy, reason: "Momentum", risk: "Reversal", evidence: ["F1"])
        var initialFetches = 0, initialContextChecks = 0
        let initiallyExpired = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
            researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: now.addingTimeInterval(1),
            allowed: { true }, contextFresh: { _ in initialContextChecks += 1; return false },
            currentBook: { A.Book() }, fetch: { _, _ in initialFetches += 1; return self.quote(at: self.now.addingTimeInterval(1)) }))
        #expect(initialFetches == 0 && initialContextChecks == 1 && initiallyExpired.pending.isEmpty)
        #expect(initiallyExpired.decisions.contains {
            $0.action == "Skipped" && $0.reason == "Research context expired after inference; no paper order created."
        })
        var contextValid = true
        for changedContext in [false, true] {
            contextValid = true
            var contextChecks = 0
            let book = try #require(await A.decisionBook(symbol: "AAPL", verdict: verdict, facts: [], model: "test",
                researchQuote: quote(at: now), holdingID: nil, citesIntraday: true, at: now.addingTimeInterval(1),
                allowed: { true }, contextFresh: { _ in contextChecks += 1; return contextValid }, currentBook: { A.Book() }, fetch: { _, _ in
                    contextValid = !changedContext
                    return self.quote(at: self.now.addingTimeInterval(changedContext ? 1 : -0.1))
                }))
            let reason = changedContext
                ? "Research context expired after inference; no paper order created."
                : "No valid qualified observation later than the research observation; no paper order created."
            #expect(contextChecks == (changedContext ? 2 : 1) && book.pending.isEmpty)
            #expect(book.decisions.contains { $0.action == "Skipped" && $0.reason == reason })
        }
    }

    @Test func holdAvoidNeedNoPriceRequestAndAreNotSkippedOrders() async throws {
        for action in [TradeAdvice.Action.hold, .avoid] {
            var fetches = 0
            let result = try #require(await A.decisionBook(symbol: "AAPL",
                verdict: .init(action: action, reason: "Wait", risk: "Uncertainty", evidence: ["F1"]),
                facts: ["Dated research"], model: "test", researchQuote: quote(at: now),
                holdingID: nil, citesIntraday: false, at: now.addingTimeInterval(45),
                allowed: { true }, contextFresh: { _ in false }, currentBook: { A.Book() },
                fetch: { _, _ in fetches += 1; return nil }))
            #expect(fetches == 0 && result.pending.isEmpty)
            #expect(result.decisions.count == 1 && result.decisions.first?.action == action.rawValue)
        }
    }

    @Test func sameDayCutoffCancelsBuysAndClosesOnlyOnLaterPrices() throws {
        let cutoff = try Date("2026-09-08T23:55:00Z", strategy: .iso8601)
        var pending = A.Book()
        pending.propose(symbol: "AAPL", action: .buy, at: cutoff.addingTimeInterval(-1))
        pending.settle(quotes: ["AAPL": quote(at: cutoff)], at: cutoff)
        #expect(pending.pending.isEmpty && pending.open.isEmpty, "No new entry at or after the same-day cutoff")
        var held = A.Book()
        held.propose(symbol: "AAPL", action: .buy, at: cutoff.addingTimeInterval(-10))
        held.settle(quotes: ["AAPL": quote(at: cutoff.addingTimeInterval(-9))], at: cutoff.addingTimeInterval(-8))
        try #require(held.open.count == 1)
        held.settle(quotes: ["AAPL": quote(at: cutoff)], at: cutoff)
        #expect(held.open.count == 1 && held.pending.count == 1)
        held.settle(quotes: ["AAPL": quote(at: cutoff.addingTimeInterval(1))], at: cutoff.addingTimeInterval(2))
        #expect(held.open.isEmpty && held.trades.count == 1 && held.valid)
        held.propose(symbol: "MSFT", action: .buy, at: cutoff)
        #expect(held.pending.isEmpty)
        #expect(!A.researchInstructions.contains("next trading week"))
        #expect(A.researchInstructions.contains("Keep reason and risk qualitative"))
    }

    @Test func entryCutoffUsesNewYorkDSTNotDeviceMidnight() throws {
        for (iso, allowed) in [("2026-09-08T23:54:59Z", true), ("2026-09-08T23:55:00Z", false),
                               ("2026-11-03T00:54:59Z", true), ("2026-11-03T00:55:00Z", false),
                               ("2026-09-09T07:59:59Z", false), ("2026-09-09T08:00:00Z", true)] {
            #expect(A.entryWindowOpen(try Date(iso, strategy: .iso8601)) == allowed)
        }
    }

    @Test func sessionClockFactLabelsNewYorkAndDoesNotTreatUTCAsLocalTime() throws {
        for (instant, local, gate) in [
            ("2026-09-08T22:19:00Z", "2026-09-08T18:19:00-04:00", "OPEN"),
            ("2026-09-08T23:55:00Z", "2026-09-08T19:55:00-04:00", "CLOSED"),
            ("2026-11-03T00:54:00Z", "2026-11-02T19:54:00-05:00", "OPEN"),
            ("2026-11-03T00:55:00Z", "2026-11-02T19:55:00-05:00", "CLOSED")
        ] {
            let fact = A.sessionClockFact(at: try Date(instant, strategy: .iso8601))
            #expect(fact.contains(local) && fact.contains("America/New_York"))
            #expect(fact.contains("New entry window: \(gate)"))
        }
    }

    @Test func missingCloseNeverFabricatesFillAndOverdueHoldingBlocksNewBuys() throws {
        let before = try Date("2026-09-08T23:54:00Z", strategy: .iso8601)
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: before)
        book.settle(quotes: ["AAPL": quote(at: before.addingTimeInterval(1))], at: before.addingTimeInterval(2))
        let closed = try Date("2026-09-09T00:01:00Z", strategy: .iso8601)
        book.settle(quotes: [:], at: closed)
        #expect(book.open.count == 1, "No synthetic closing price when the app missed the cutoff")
        let next = try Date("2026-09-09T08:01:00Z", strategy: .iso8601)
        book.propose(symbol: "MSFT", action: .buy, at: next)
        #expect(!book.pending.contains { $0.buy })
        book.settle(quotes: [:], at: next)
        #expect(book.pending.count == 1 && book.pending.first?.buy == false)
        book.settle(quotes: ["AAPL": quote(at: next.addingTimeInterval(1))], at: next.addingTimeInterval(2))
        #expect(book.open.isEmpty && book.valid)
    }

    @Test func staleSnapshotFallsBackForResearchAndLaterPaperFill() async throws {
        var calls: [String] = []
        let stale = quote(at: now.addingTimeInterval(-360))
        let later = quote(price: 101, at: now.addingTimeInterval(1))
        let observed = await A.fetchPaperQuotes(for: ["AAPL"], at: now.addingTimeInterval(2),
            externalAllowed: { true }, snapshots: { _ in ["AAPL": stale] }, tick: { symbol, _ in calls.append(symbol); return later })
        #expect(observed["AAPL"] == later && calls == ["AAPL"])
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: observed, at: now.addingTimeInterval(2))
        #expect(book.open.count == 1 && book.valid)
        calls = []
        let fresh = await A.fetchPaperQuotes(for: ["AAPL"], at: now.addingTimeInterval(2),
            externalAllowed: { true }, snapshots: { _ in ["AAPL": later] }, tick: { symbol, _ in calls.append(symbol); return nil })
        #expect(fresh["AAPL"] == later && calls.isEmpty)
        let missing = await A.fetchPaperQuotes(for: ["AAPL"], at: now,
            externalAllowed: { true }, snapshots: { _ in ["AAPL": stale] }, tick: { _, _ in nil })
        #expect(missing.isEmpty, "A failed tick fallback never relabels a stale snapshot")
        let preDecision = quote(at: now)
        let postDecision = await A.fetchPaperQuotes(for: ["AAPL"], after: ["AAPL": now], at: now.addingTimeInterval(2),
            externalAllowed: { true }, snapshots: { _ in ["AAPL": preDecision] }, tick: { _, _ in later })
        #expect(postDecision["AAPL"] == later, "Fresh but pre-decision snapshots must also use the tick fallback")
        let delayed = await A.fetchPaperQuotes(for: ["AAPL"], after: ["AAPL": now], at: now.addingTimeInterval(2),
            externalAllowed: { true }, snapshots: { _ in ["AAPL": preDecision] }, tick: { _, _ in preDecision })
        #expect(delayed.isEmpty, "A pre-decision trade cannot become a later fill")
    }

    @Test func monitoringStatusDoesNotDependOnResearchAndLabelsClosedSessions() throws {
        let open = try Date("2026-09-09T12:00:00Z", strategy: .iso8601)
        let closed = try Date("2026-09-09T02:00:00Z", strategy: .iso8601)
        #expect(StockSagePaperAutomationPanel.monitoringLabel(running: true, at: open) == "Position and exit monitoring enabled")
        #expect(StockSagePaperAutomationPanel.monitoringLabel(running: true, at: closed) == "Monitoring enabled · waiting for the next supported session")
        #expect(StockSagePaperAutomationPanel.monitoringLabel(running: false, at: open) == "Position monitoring paused")
    }

    @Test func researchHasFourBoundedWorkersAndNoLostCompletions() async {
        var active = 0, peak = 0
        var finished: Set<String> = []
        let symbols = (0..<13).map(String.init)
        await A.forEachResearchTarget(symbols) { symbol in
            active += 1; peak = max(peak, active)
            try? await Task.sleep(for: .milliseconds(5))
            finished.insert(symbol); active -= 1
        }
        #expect(peak == 4 && active == 0 && finished == Set(symbols))
    }

    @Test func changedResearchPolicyStopsQueueReplenishment() async {
        var allowed = true
        var started: [String] = []
        await A.forEachResearchTarget((0..<100).map(String.init), allowed: { allowed }) { symbol in
            started.append(symbol)
            await Task.yield()
            allowed = false
        }
        #expect(started.count <= A.researchConcurrency && !started.isEmpty)
    }

    @Test(arguments: [false, true])
    func slowHoldingLeavesFreeWorkersForDiscovery(legacyBarrier: Bool) async {
        let symbols = ["AAPL", "AMZN", "GOOG", "MSFT", "NVDA", "META"]
        var suspended: CheckedContinuation<Void, Never>?
        var finished: [String] = []
        var active = 0, peak = 0
        let task = Task { @MainActor in
            // Control replays the old caller composition; production now uses one ordered queue.
            let batches = legacyBarrier ? [Array(symbols.prefix(4)), Array(symbols.dropFirst(4))] : [symbols]
            for batch in batches {
                await A.forEachResearchTarget(batch) { symbol in
                    active += 1; peak = max(peak, active)
                    if symbol == "AAPL" { await withCheckedContinuation { suspended = $0 } }
                    else { await Task.yield() }
                    active -= 1
                    finished.append(symbol)
                }
            }
        }
        while suspended == nil { await Task.yield() }
        for _ in 0..<100 {
            if finished.contains("META") { break }
            // Yielding alone can immediately reschedule this test ahead of the worker group.
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished.contains("NVDA") == !legacyBarrier && finished.contains("META") == !legacyBarrier,
                "Only the legacy barrier should block discovery; completed: \(finished)")
        #expect(!finished.contains("AAPL"))
        suspended?.resume(); suspended = nil
        await task.value
        #expect(active == 0 && peak <= A.researchConcurrency)
        #expect(finished.count == symbols.count && Set(finished) == Set(symbols))
    }

    @Test(arguments: [false, true])
    func modelEditCancellationPreservesBookAndClearsResearchOnUnwind(storageFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "research-cancel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let state = A(url: root.appendingPathComponent("account.json"), defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        var resumed: CheckedContinuation<Void, Never>?
        defer { resumed?.resume() }
        var cancelled = false
        let original = try JSONEncoder().encode(state.book)
        state.scheduleResearch {
            await state.withResearchCheck("AAPL") {
                await withCheckedContinuation { resumed = $0 }
            }
            cancelled = Task.isCancelled
        }
        while resumed == nil { await Task.yield() }
        #expect(state.isResearching)
        #expect(state.researchingSymbols == ["AAPL"])
        let progress = try #require(state.researchProgress)
        #expect(progress.totalUnitCount == 0 && progress.isIndeterminate)
        if storageFailure {
            try #require(state.acquire())
            #expect(!state.save(state.book, beforeAccountCommit: { throw CocoaError(.fileWriteUnknown) }))
            #expect(state.status == "Paused after storage failure")
            #expect(state.researchingSymbols.isEmpty, "Paused after storage failure must not keep active bars")
        } else {
            state.cancelResearchForSettingsChange()
        }
        #expect(state.researchProgress == nil, "Cancelled checks must not remain queued on screen")
        #expect(state.researchingSymbols.isEmpty, "Retire loading bars while cancelled requests unwind")
        #expect(state.isResearching, "Do not allow a new cycle before the cancelled cycle unwinds")
        resumed?.resume()
        resumed = nil
        while state.isResearching { await Task.yield() }
        #expect(state.researchProgress == nil)
        #expect(state.researchingSymbols.isEmpty)
        #expect(cancelled && !state.isRunning)
        #expect(try JSONDecoder().decode(A.Book.self, from: original).decisions == state.book.decisions)
        #expect(state.book.trades.isEmpty && state.book.pending.isEmpty && state.book.lastResearch == nil)
        var nextRan = false
        state.scheduleResearch { nextRan = true }
        #expect(state.researchProgress !== progress, "The next research run must not reuse a cancelled run's progress")
        while state.isResearching { await Task.yield() }
        #expect(state.researchProgress == nil)
        #expect(nextRan, "Cancelled research must not strand the next cycle")
    }

    @Test func researchDisplayLabelsPreserveOtherActions() {
        #expect(StockSagePaperAutomationPanel.actionLabel("Unavailable") == "Incomplete research")
        #expect(StockSagePaperAutomationPanel.actionLabel("Market scan unavailable") == "Market scan incomplete")
        for action in ["Paper Buy", "Paper Sell", "Paused", "Hold", "Research complete"] {
            #expect(StockSagePaperAutomationPanel.actionLabel(action) == action)
        }
        let original = "Visited 94/94: 61 verified opinions, 33 unavailable checks."
        #expect(StockSagePaperAutomationPanel.reasonLabel(action: "Research complete", reason: original)
                == "Visited 94/94: 61 verified opinions, 33 incomplete checks.")
        #expect(StockSagePaperAutomationPanel.reasonLabel(action: "Unavailable", reason: original) == original)
        #expect(StockSagePaperAutomationPanel.reasonLabel(action: "Unavailable", reason: "Source unavailable; no paper order.")
                == "Source unavailable; no paper order.")
    }

    @Test func oldResearchUnwindCannotClearRestartedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "research-progress-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let state = A(url: root.appendingPathComponent("account.json"), defaults: defaults)
        var old: CheckedContinuation<Void, Never>?, new: CheckedContinuation<Void, Never>?
        defer {
            old?.resume(); new?.resume(); state.stop()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        var oldFinished = false
        state.scheduleResearch {
            await state.withResearchCheck("AAPL") {
                await withCheckedContinuation { old = $0 }
            }
            oldFinished = true
        }
        while old == nil { await Task.yield() }
        let first = try #require(state.researchProgress)
        state.stop()
        #expect(state.researchProgress == nil)
        #expect(state.researchingSymbols.isEmpty)
        state.scheduleResearch {
            await state.withResearchCheck("AAPL") {
                await withCheckedContinuation { new = $0 }
            }
        }
        while new == nil { await Task.yield() }
        let second = try #require(state.researchProgress)
        #expect(first !== second)
        old?.resume(); old = nil
        while !oldFinished { await Task.yield() }
        #expect(state.isResearching && state.researchProgress === second)
        #expect(state.researchingSymbols == ["AAPL"], "Old completion cannot clear the new check for the same ticker")
        new?.resume(); new = nil
        while state.isResearching { await Task.yield() }
        #expect(state.researchProgress == nil)
        #expect(state.researchingSymbols.isEmpty)
    }

    @Test func perCheckLoadingTracksOnlyRunningWorkersAndRemovesReadyResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "per-check-progress-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let state = A(url: root.appendingPathComponent("account.json"), defaults: defaults)
        let symbols = ["AAPL", "AMZN", "GOOG", "MSFT", "NVDA"]
        var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        defer {
            for continuation in waiting.values { continuation.resume() }
            state.stop(); try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        state.scheduleResearch {
            await A.forEachResearchTarget(symbols) { symbol in
                await state.withResearchCheck(symbol) {
                    await withCheckedContinuation { waiting[symbol] = $0 }
                }
            }
        }
        while waiting.count < 4 { await Task.yield() }
        #expect(state.researchingSymbols == Set(symbols.prefix(4)))
        #expect(!state.researchingSymbols.contains("NVDA"), "Queued work must not pretend it is loading")
        waiting.removeValue(forKey: "AMZN")?.resume()
        while waiting["NVDA"] == nil { await Task.yield() }
        #expect(state.researchingSymbols == ["AAPL", "GOOG", "MSFT", "NVDA"],
                "A slow AAPL keeps its own bar while AMZN finishes and NVDA starts")
        for continuation in waiting.values { continuation.resume() }
        waiting.removeAll()
        while state.isResearching { await Task.yield() }
        #expect(state.researchingSymbols.isEmpty)
        #expect(state.book.decisions.isEmpty && state.book.trades.isEmpty && state.book.pending.isEmpty)
    }

    @Test func positionQuoteFallbackIsBoundedAndConcurrent() async {
        var active = 0, peak = 0
        let names = ["AAPL", "MSFT", "AMZN", "META", "GOOG"]
        let result = await A.fetchPaperQuotes(for: names, at: now, externalAllowed: { true }, snapshots: { _ in [:] }, tick: { symbol, at in
            active += 1; peak = max(peak, active)
            try? await Task.sleep(for: .milliseconds(5))
            active -= 1
            return self.quote(symbol, at: at)
        })
        #expect(peak == 4 && active == 0 && Set(result.keys) == Set(names))
    }

    @Test func revokedQuotePermissionCannotFillOrStartFallback() async {
        for revokeAt in ["before", "snapshot", "emptySnapshot", "fallback", "partialBatch"] {
            var allowed = revokeAt != "before"
            var snapshots = 0, ticks = 0
            let later = quote(at: now.addingTimeInterval(1))
            let names = revokeAt == "partialBatch" ? ["AAPL", "MSFT"] : ["AAPL"]
            let observed = await A.fetchPaperQuotes(for: names, at: now.addingTimeInterval(2),
                externalAllowed: { allowed }, snapshots: { _ in
                    snapshots += 1
                    await Task.yield()
                    if revokeAt == "snapshot" || revokeAt == "emptySnapshot" { allowed = false }
                    return revokeAt == "fallback" || revokeAt == "emptySnapshot" ? [:] : ["AAPL": later]
                }, tick: { symbol, _ in
                    ticks += 1
                    await Task.yield()
                    allowed = false
                    return self.quote(symbol, at: self.now.addingTimeInterval(1))
                })
            #expect(observed.isEmpty, "Discard results when permission is revoked at \(revokeAt)")
            #expect(snapshots == (revokeAt == "before" ? 0 : 1))
            #expect(ticks == (revokeAt == "fallback" || revokeAt == "partialBatch" ? 1 : 0))
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: observed, at: now.addingTimeInterval(2))
            #expect(book.open.isEmpty && book.pending.count == 1 && book.cash == A.Book().cash)
        }
    }

    @Test func sameDayEntryEvidenceCannotBeOnlyDailyBackgroundOrSummary() {
        // Zero-based indices 2 and 3 are actual intraday observations; index 1 is their caveat.
        #expect(!A.hasIntradayEvidence(["F1", "F2"], factIndices: 2..<4))
        #expect(A.hasIntradayEvidence(["F1", "F3"], factIndices: 2..<4))
        #expect(A.hasIntradayEvidence(["F4"], factIndices: 2..<4))
        #expect(!A.hasIntradayEvidence(["F5"], factIndices: 2..<4))
        #expect(!A.hasIntradayEvidence(["F3"], factIndices: 2..<2))
    }

    @Test func policyActivationRetiresOldEntryRequestsOnceWithoutDeletingHoldings() throws {
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        book.propose(symbol: "MSFT", action: .buy, at: now.addingTimeInterval(3))
        book.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(3))
        book.lastResearch = now
        let holding = try #require(book.open.first)
        book.activateSameDay(at: now.addingTimeInterval(4))
        #expect(book.open.first?.id == holding.id && book.pending.count == 1 && book.pending.first?.buy == false)
        #expect(book.lastResearch == nil && book.valid)
        let count = book.decisions.count
        book.lastResearch = now.addingTimeInterval(5)
        book.activateSameDay(at: now.addingTimeInterval(6))
        #expect(book.decisions.count == count && book.lastResearch == now.addingTimeInterval(5))
    }

    @Test func cancellationDoesNotStartTheRestOfTheResearchQueue() async {
        var started = 0
        let task = Task {
            await A.forEachResearchTarget((0..<100).map(String.init)) { _ in
                started += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
        while started < 4 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(started == 4)
    }

    @Test func optedInResponseReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["STOCKSAGE_PAPER_RESPONSE_REPLAY"] else { return }
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let results = try #require(root["results"] as? [[String: Any]])
        for row in results {
            let text = try #require(row["text"] as? String)
            let facts = try #require(row["facts"] as? [String])
            let valid = StockSageAIAssessment.parse(text, facts: facts) != nil
            print("PAPER_RESPONSE \(row["symbol"] ?? "unknown") verified=\(valid) finish=\(row["finish_reason"] ?? "unknown")")
            #expect(valid)
        }
    }

    @Test func optedInLivePaperDiagnostics() async throws {
        // Explicit local diagnostic only; ordinary gates never read credentials or call the network.
        guard let directory = ProcessInfo.processInfo.environment["STOCKSAGE_PAPER_DIAGNOSTICS"] else { return }
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = prior
        temporary[StockSageMassive.keyDefaultsKey] = UserDefaults(suiteName: "SA.StockSage")?.string(forKey: StockSageMassive.keyDefaultsKey)
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        try #require(ToolPolicy.isExternalAllowed && StockSageMassive.isConfigured)
        let names = ["AMGN", "STX", "LRCX", "SNOW", "DELL"]
        let snapshots = await StockSageMassive.fetchSnapshots(for: names)
        var recovered = 0
        for symbol in names {
            let quotes = await A.fetchPaperQuotes(for: [symbol], snapshots: { _ in snapshots })
            let age = snapshots[symbol]?.marketTime.map { Date().timeIntervalSince($0) } ?? -1
            if let q = quotes[symbol] {
                #expect(A.fresh(q, at: Date()))
                if age > 120 { recovered += 1 }
                print("PAPER_LIVE \(symbol) snapshot_age=\(age) selected_age=\(Date().timeIntervalSince(q.marketTime!))")
            } else { print("PAPER_LIVE \(symbol) snapshot_age=\(age) no_eligible_trade") }
            let intradayAt = Date()
            let minute = await StockSageMassiveTicks.intradayFacts(symbol: symbol,
                from: max(intradayAt.addingTimeInterval(-3600), A.sessionTime(intradayAt, hour: 4, minute: 0)), now: intradayAt)
            print("PAPER_INTRADAY \(symbol) fresh=\(minute?.fresh(at: Date()) ?? false) facts=\(minute?.facts.count ?? 0)")
        }
        print("PAPER_LIVE recovered=\(recovered)")
        for name in ["baseline", "optimized", "batched", "batched512"] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name + ".json")
            let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let results = try #require(root["results"] as? [[String: Any]])
            let valid = results.filter { row in
                guard let text = row["text"] as? String, let facts = row["facts"] as? [String] else { return false }
                return StockSageAIAssessment.parse(text, facts: facts) != nil
            }.count
            print("PAPER_BENCHMARK \(name) valid=\(valid)/\(results.count) wall=\(root["wall_seconds"] ?? "unknown")")
        }
    }

    @Test func marketDiscoveryRequestsAllTickersWithoutChangingEmptyListSemantics() throws {
        let request = try #require(StockSageMassive.marketRequest(key: "fixture-key"))
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!query.contains { $0.name == "tickers" })
        #expect(query.contains { $0.name == "include_otc" && $0.value == "false" })
        #expect(!url.absoluteString.contains("fixture-key"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(StockSageMassive.marketRequest(key: "") == nil)
        #expect(StockSageMassive.request(for: [], key: "fixture-key") == nil)
    }

    @Test func marketParserPreservesCoverageAndRejectsErrorOrPartialPayload() throws {
        let ns = Int64(now.timeIntervalSince1970) * 1_000_000_000
        let rows: [[String: Any]] = [
            ["ticker": "IBM", "lastTrade": ["p": 100, "t": ns], "day": ["v": 1000, "vw": 99]],
            ["ticker": "ORCL", "day": ["c": 100]], // No last trade is not a live observation.
            ["ticker": "BRK.B", "lastTrade": ["p": 500, "t": ns]], // Existing router does not support this spelling.
            ["ticker": "BAD/URL", "lastTrade": ["p": 100, "t": ns]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["status": "OK", "count": 4, "tickers": rows])
        let snapshot = try #require(StockSageMassive.parseMarketSnapshot(data))
        #expect(snapshot.returnedCount == 4)
        #expect(snapshot.rows.count == 1 && snapshot.rows.first?.quote.symbol == "IBM")
        #expect(snapshot.rows.first?.dollarVolume == 99_000)
        #expect(snapshot.rows.first?.quote.marketTime == now)
        for root: [String: Any] in [
            ["status": "ERROR", "tickers": rows],
            ["status": "OK", "count": 5, "tickers": rows],
            ["status": "OK", "tickers": "invalid"],
            ["status": "OK", "tickers": ["invalid"]]
        ] {
            #expect(StockSageMassive.parseMarketSnapshot(try JSONSerialization.data(withJSONObject: root)) == nil)
        }
        let empty = try JSONSerialization.data(withJSONObject: ["status": "OK", "count": 0, "tickers": []])
        #expect(StockSageMassive.parseMarketSnapshot(empty)?.returnedCount == 0)
    }

    @Test func discoveryRotatesBeyondWatchlistAndAlwaysReviewsHoldingsFirst() {
        let names = (0..<102).map { "ZX" + String(UnicodeScalar(65 + $0 / 26)!) + String(UnicodeScalar(65 + $0 % 26)!) }
        let rows = names.enumerated().map { index, symbol in
            StockSageMassive.MarketCandidate(quote: quote(symbol, at: now), dollarVolume: Double(1000 - index))
        }
        let market = StockSageMassive.MarketSnapshot(returnedCount: rows.count, rows: rows)
        var book = A.Book()
        let first = A.researchTargets(market: market, book: book, at: now)
        #expect(first == Array(names.prefix(101)), "Owner-selected 101 total checks, not a watchlist cap")
        for symbol in first { book.note(symbol: symbol, action: "Hold", reason: "Fixture", at: now) }
        #expect(A.researchTargets(market: market, book: book, at: now).first == names.last)
        let held = ["MSFT", "NVDA", "ORCL", "TSLA", "V"]
        for symbol in held { book.propose(symbol: symbol, action: .buy, at: now.addingTimeInterval(-2)) }
        book.settle(quotes: Dictionary(uniqueKeysWithValues: held.map { ($0, quote($0, at: now.addingTimeInterval(-1))) }), at: now)
        #expect(Array(A.researchTargets(market: market, book: book, at: now).prefix(5)) == held)
        #expect(A.researchTargets(market: market, book: book, at: now).count == 101,
                "Holdings retain priority inside the owner's 101-check cap")
        #expect(A.researchTargets(market: nil, book: book, at: now) == held,
                "Discovery failure must not suppress held-stock sell reviews")
    }

    @Test func discoveryExcludesBadQuotesPendingAndUnaffordableEntries() {
        let rows = [quote("AAPL", at: now), quote("MSFT", at: now.addingTimeInterval(-121)),
                    quote("NVDA", at: now.addingTimeInterval(1)), quote("ORCL", at: now, source: .yahoo),
                    quote("COST", price: 3000, at: now), quote("AMZN", price: .nan, at: now),
                    quote("2222.SR", at: now), quote("IBM", at: now)]
            .map { StockSageMassive.MarketCandidate(quote: $0, dollarVolume: 1_000_000) }
        var book = A.Book()
        book.propose(symbol: "IBM", action: .buy, at: now)
        #expect(A.researchTargets(market: .init(returnedCount: rows.count, rows: rows), book: book, at: now) == ["AAPL"])
        #expect(!A.mayResearch("ORCL", marketSymbols: ["AAPL"], heldSymbols: []))
        #expect(A.mayResearch("ORCL", marketSymbols: [], heldSymbols: ["ORCL"]))
    }

    @Test func discoveredOffBoardStockCanAutomaticallyBuyThenSell() throws {
        var book = A.Book()
        let market = StockSageMassive.MarketSnapshot(returnedCount: 1, rows: [
            .init(quote: quote("IBM", at: now), dollarVolume: 1_000_000)
        ])
        let symbol = try #require(A.researchTargets(market: market, book: book, at: now).first)
        let permitted = Set([symbol])
        try #require(A.mayResearch(symbol, marketSymbols: permitted, heldSymbols: []))
        book.propose(symbol: symbol, action: .buy, at: now)
        book.settle(quotes: [symbol: quote(symbol, at: now)], at: now.addingTimeInterval(1))
        #expect(book.open.isEmpty, "No decision-time fabricated fill")
        book.settle(quotes: [symbol: quote(symbol, at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        try #require(book.open.count == 1)
        try #require(A.mayResearch(symbol, marketSymbols: [], heldSymbols: Set(book.open.map(\.symbol))))
        book.propose(symbol: symbol, action: .sell, at: now.addingTimeInterval(3))
        book.settle(quotes: [symbol: quote(symbol, price: 105, at: now.addingTimeInterval(4))], at: now.addingTimeInterval(5))
        #expect(book.open.isEmpty && book.trades.count == 1 && book.trades[0].exitPrice != nil)
        #expect(book.cash == 10_091.11 && book.valid)
    }

    @Test func upgradingWatchlistOnlyBookStartsMarketScanImmediatelyThenKeepsCadence() {
        var book = A.Book()
        book.lastResearch = now
        book.note(symbol: "ORCL", action: "Hold", reason: "Legacy watchlist-only cycle", at: now)
        #expect(A.researchDue(book: book, at: now))
        book.note(action: "Market scan unavailable", reason: "Fixture outage", at: now)
        #expect(!A.researchDue(book: book, at: now.addingTimeInterval(899)))
        #expect(A.researchDue(book: book, at: now.addingTimeInterval(900)))
    }

    @Test func scheduledPaperWindowIncludesPreAndAfterHours() throws {
        let cases: [(String, Bool)] = [
            ("2026-09-08T07:59:59Z", false), ("2026-09-08T08:00:00Z", true),
            ("2026-09-08T13:29:59Z", true), ("2026-09-08T13:30:00Z", true),
            ("2026-09-08T19:59:59Z", true), ("2026-09-08T20:00:00Z", true),
            ("2026-09-08T23:59:59Z", true), ("2026-09-09T00:00:00Z", false),
            ("2026-09-12T14:00:00Z", false), ("2026-09-13T21:00:00Z", false),
            // New York is on standard time after November's DST transition.
            ("2026-11-02T08:59:59Z", false), ("2026-11-02T09:00:00Z", true),
            ("2026-11-03T00:59:59Z", true), ("2026-11-03T01:00:00Z", false)
        ]
        for (iso, allowed) in cases {
            let at = try Date(iso, strategy: .iso8601)
            #expect(A.paperSessionOpen(at) == allowed, "Session boundary: \(iso)")
        }
    }

    @Test func announcedUTPOvernightHoursDoNotExpandApprovedPaperSession() throws {
        for iso in ["2026-12-07T02:00:00Z", "2026-12-08T02:30:00Z"] {
            let at = try Date(iso, strategy: .iso8601)
            #expect(!A.paperSessionOpen(at), "SIP or exchange overnight operation is outside the approved paper window: \(iso)")
            #expect(!A.entryWindowOpen(at))
        }
        let approvedPreMarket = try Date("2026-12-07T09:00:00Z", strategy: .iso8601)
        #expect(A.paperSessionOpen(approvedPreMarket))
    }

    @Test(arguments: ["2026-09-08T08:30:00Z", "2026-09-08T21:00:00Z"])
    func extendedHoursUsesLaterQuotesForEntriesAndStopExits(_ iso: String) throws {
        let at = try Date(iso, strategy: .iso8601)
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .hold, at: at)
        book.propose(symbol: "AAPL", action: .avoid, at: at)
        #expect(book.pending.isEmpty, "Extended hours must not force a trade from a neutral opinion")
        book.propose(symbol: "AAPL", action: .buy, at: at)
        book.settle(quotes: ["AAPL": quote(at: at)], at: at.addingTimeInterval(1))
        #expect(book.open.isEmpty, "The decision-time quote cannot become a simulated fill")
        book.settle(quotes: ["AAPL": quote(at: at.addingTimeInterval(1))], at: at.addingTimeInterval(2))
        try #require(book.open.count == 1, "Extended-hours entry needs a later fresh observation")
        #expect(book.cash == 8098.1 && book.valid)
        book.settle(quotes: ["AAPL": quote(price: 96, at: at.addingTimeInterval(3))], at: at.addingTimeInterval(4))
        #expect(book.open.count == 1 && book.pending.count == 1, "A sampled stop requests, but does not immediately fill, an exit")
        book.settle(quotes: ["AAPL": quote(price: 94, at: at.addingTimeInterval(5))], at: at.addingTimeInterval(6))
        #expect(book.open.isEmpty && book.pending.isEmpty && book.valid)
        #expect(abs((book.trades.first?.exitPrice ?? 0) - 93.906) < 0.000001)
    }

    @Test func closedSessionStillExpiresWithoutFilling() throws {
        let at = try Date("2026-09-08T23:59:59Z", strategy: .iso8601)
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        book.propose(symbol: "AAPL", action: .sell, at: at)
        book.settle(quotes: ["AAPL": quote(at: at.addingTimeInterval(1))], at: at.addingTimeInterval(2))
        #expect(book.open.count == 1 && book.pending.count == 1)
        book.settle(quotes: [:], at: at.addingTimeInterval(120))
        #expect(book.open.count == 1 && book.pending.isEmpty && book.decisions.last?.action == "Expired")
    }

    @Test func paperCashCostsAndLaterFillAreReproducible() throws {
        #expect(A.paperSessionOpen(now))
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.propose(symbol: "AAPL", action: .strongBuy, at: now)
        #expect(book.pending.count == 1 && book.cash == 10_000)
        book.settle(quotes: ["AAPL": quote(at: now)], at: now.addingTimeInterval(1))
        #expect(book.open.isEmpty, "A quote from before or at decision time cannot fill the order")
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(book.valid && book.open.count == 1 && book.open[0].shares == 19 && book.cash == 8098.1)
        let persisted = try JSONDecoder().decode(A.Book.self, from: JSONEncoder().encode(book))
        book = persisted
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(book.trades.count == 1, "Restart/repeated observations cannot duplicate a fill")
        book.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(3))
        book.settle(quotes: ["AAPL": quote(price: 105, at: now.addingTimeInterval(4))], at: now.addingTimeInterval(5))
        #expect(book.valid && book.open.isEmpty && book.cash == 10_091.11)
        #expect(book.equity(quotes: [:], at: now.addingTimeInterval(5)) == book.cash)
    }

    @Test(arguments: ["2026-09-08T08:30:00Z", "2026-09-08T15:00:00Z", "2026-09-08T21:00:00Z"])
    func badQuotesAndExpiredDecisionsCannotTrade(_ iso: String) throws {
        let now = try Date(iso, strategy: .iso8601)
        for q in [quote(at: now.addingTimeInterval(-300)), quote(at: now.addingTimeInterval(30)),
                  quote(at: now.addingTimeInterval(1), source: .yahoo),
                  quote("MSFT", at: now.addingTimeInterval(1)), quote(price: .nan, at: now.addingTimeInterval(1))] {
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: ["AAPL": q], at: now.addingTimeInterval(2))
            #expect(book.open.isEmpty && book.cash == 10_000)
            book.settle(quotes: [:], at: now.addingTimeInterval(120))
            #expect(book.pending.isEmpty && book.decisions.last?.action == "Expired")
        }
    }

    @Test func cashAndPositionCapsCannotBeOverriddenByOpinion() {
        var book = A.Book()
        let names = ["AAPL", "MSFT", "ORCL", "NVDA", "GOOG", "META"]
        for symbol in names { book.propose(symbol: symbol, action: .strongBuy, at: now) }
        #expect(book.pending.count == 5)
        let quotes = Dictionary(uniqueKeysWithValues: names.map { ($0, quote($0, at: now.addingTimeInterval(1))) })
        book.settle(quotes: quotes, at: now.addingTimeInterval(2))
        #expect(book.valid && book.open.count == 5 && book.cash >= 0)
        #expect(book.open.allSatisfy { A.Book.money($0.entry * $0.shares) <= 2_000 })
        book.propose(symbol: "META", action: .buy, at: now.addingTimeInterval(3))
        #expect(book.pending.isEmpty)
        #expect(book.equity(quotes: [:], at: now) == nil, "Missing marks cannot become zero-valued holdings")
        #expect(!A.validSymbol("2222.SR") && !A.validSymbol("BTC-USD") && !A.validSymbol("^GSPC"))
    }

    @Test func sameDaySaleCannotFinanceAnotherCashAccountEntry() {
        var book = A.Book()
        let names = ["AAPL", "MSFT", "ORCL", "NVDA", "GOOG"]
        for symbol in names { book.propose(symbol: symbol, action: .buy, at: now) }
        book.settle(quotes: Dictionary(uniqueKeysWithValues: names.map {
            ($0, quote($0, at: now.addingTimeInterval(1)))
        }), at: now.addingTimeInterval(2))
        #expect(book.cash == 490.5 && book.open.count == 5)
        book.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(3))
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(4))], at: now.addingTimeInterval(5))
        #expect(book.cash == 2388.6 && book.open.count == 4)
        book.propose(symbol: "META", action: .buy, at: now.addingTimeInterval(6))
        book.settle(quotes: ["META": quote("META", price: 600, at: now.addingTimeInterval(7))],
                    at: now.addingTimeInterval(8))
        #expect(!book.open.contains { $0.symbol == "META" }, "Only $490.50 remains settled; sale proceeds are not same-day buying power")
        #expect(book.valid)
    }

    @Test func stopUsesSubsequentObservedPriceNotAnInventedStopFill() {
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        book.settle(quotes: ["AAPL": quote(price: 96, at: now.addingTimeInterval(3))], at: now.addingTimeInterval(4))
        #expect(book.open.count == 1 && book.pending.count == 1)
        book.settle(quotes: ["AAPL": quote(price: 94, at: now.addingTimeInterval(5))], at: now.addingTimeInterval(6))
        #expect(book.open.isEmpty && abs((book.trades[0].exitPrice ?? 0) - 93.906) < 0.000001)
        #expect(book.trades[0].exitPrice != book.trades[0].stop)
    }

    @Test func protectiveExitSurvivesExpiryRecoveryAndRestartButModelSellDoesNot() throws {
        for protective in [true, false] {
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
            let trigger = now.addingTimeInterval(4)
            if protective {
                book.settle(quotes: ["AAPL": quote(price: 96, at: trigger)], at: trigger)
            } else { book.propose(symbol: "AAPL", action: .sell, at: trigger) }
            let original = try #require(book.pending.first)
            let retry = trigger.addingTimeInterval(120)
            book.settle(quotes: ["AAPL": quote(price: 100, at: retry)], at: retry)
            #expect(book.open.count == 1, "Expiry/rearm cannot invent an immediate fill")
            #expect(book.pending.count == (protective ? 1 : 0))
            book = try JSONDecoder().decode(A.Book.self, from: JSONEncoder().encode(book))
            if protective {
                #expect(book.pending.first?.id == original.id && book.pending.first?.at == retry)
            }
            book.settle(quotes: ["AAPL": quote(price: 100, at: retry.addingTimeInterval(1))], at: retry.addingTimeInterval(1))
            #expect(book.open.count == (protective ? 0 : 1))
            #expect(book.valid)
        }
    }

    @Test func protectiveExitWaitsThroughClosedSessionsThenRearmsOnce() throws {
        let closures = [
            ("2026-09-08T23:58:00Z", "2026-09-09T08:00:00Z"), // Ordinary night.
            ("2026-09-04T23:58:00Z", "2026-09-08T08:00:00Z"), // Labor Day weekend.
            ("2026-11-27T21:58:00Z", "2026-11-30T09:00:00Z"), // Early close.
            ("2026-10-30T23:58:00Z", "2026-11-02T09:00:00Z")  // Fall DST weekend.
        ]
        for (triggerISO, reopenISO) in closures {
            let trigger = try Date(triggerISO, strategy: .iso8601)
            let reopen = try Date(reopenISO, strategy: .iso8601)
            let holding = TradeRecord(symbol: "AAPL", side: .long, entry: 100,
                stop: 98, target: 104, shares: 1, openedAt: trigger.addingTimeInterval(-3600))
            let order = A.Pending(id: UUID(), symbol: "AAPL", buy: false,
                                  at: trigger, protectiveTradeID: holding.id)
            var book = A.Book(trades: [holding], pending: [order])
            for offset in stride(from: 120.0, to: reopen.timeIntervalSince(trigger), by: 120.0) {
                book.settle(quotes: [:], at: trigger.addingTimeInterval(offset))
            }
            #expect(book.decisions.isEmpty, "Closed sessions must not generate retry audit churn: \(triggerISO)")
            #expect(book.pending.first?.at == trigger)
            #expect(book.open.count == 1 && book.pending.first?.protectiveTradeID == holding.id)
            #if os(macOS)
            let retained = try #require(book.pending.first)
            #expect(StockSagePaperAutomationPanel.pendingStatus(retained, running: true, at: reopen.addingTimeInterval(-120))
                == "Protective intent retained; waiting for the next supported paper session.")
            #endif

            book = try JSONDecoder().decode(A.Book.self, from: JSONEncoder().encode(book))
            let retry = reopen.addingTimeInterval(30)
            book.settle(quotes: ["AAPL": quote(price: 100, at: retry)], at: retry)
            #expect(book.open.count == 1, "Rearming cannot fill from that same observation")
            #expect(book.pending.first?.id == order.id && book.pending.first?.at == retry)
            #expect(book.decisions.filter { $0.action == "Stop exit retry" }.count == 1)
            book.settle(quotes: ["AAPL": quote(price: 100, at: retry.addingTimeInterval(1))],
                        at: retry.addingTimeInterval(1))
            #expect(book.open.isEmpty && book.pending.isEmpty && book.valid)
        }
    }

    @Test func exchangeHolidaysAndEarlyCloseGateActualOrders() throws {
        let cases = [("2026-11-26T16:00:00Z", false, false),
                     ("2026-11-27T21:54:59Z", true, true),
                     ("2026-11-27T21:55:00Z", true, false),
                     ("2026-11-27T22:00:00Z", false, false),
                     ("2026-10-12T15:00:00Z", true, true), // Bank holiday, exchange open.
                     ("2026-11-11T15:00:00Z", true, true)]
        for (iso, session, entry) in cases {
            let at = try Date(iso, strategy: .iso8601)
            #expect(A.paperSessionOpen(at) == session)
            #expect(A.entryWindowOpen(at) == entry)
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: at)
            #expect(book.pending.isEmpty == !entry)
        }
        let at = try Date("2026-11-27T21:55:00Z", strategy: .iso8601)
        var book = A.Book()
        book.trades = [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98, target: 104,
                             shares: 1, openedAt: at.addingTimeInterval(-3600))]
        book.enforceDayLimit(at: at)
        #expect(book.pending.count == 1 && book.pending.first?.buy == false)
        #expect(A.sessionClockFact(at: at).contains("2026-11-27T16:55:00-05:00"))
    }

    @Test func unpublished2027NasdaqCalendarKeepsPaperEligibilityFailClosed() throws {
        for iso in ["2027-01-04T15:00:00Z", "2027-11-26T17:00:00Z", "2027-12-31T17:00:00Z"] {
            let at = try Date(iso, strategy: .iso8601)
            #expect(!A.paperSessionOpen(at), "Unsupported Nasdaq date must not become paper eligible: \(iso)")
            #expect(!A.entryWindowOpen(at))
            #expect(A.entryCutoff(at) == nil)
        }
    }

    @Test func settlementCalendarUsesNewYorkBusinessDatesIncludingBankHolidays() throws {
        let cases = [
            ("2026-09-08T23:59:59Z", "2026-09-09T04:00:00Z"),
            ("2026-09-09T00:00:00Z", "2026-09-09T04:00:00Z"), // Still September 8 in New York.
            ("2026-09-04T19:00:00Z", "2026-09-08T04:00:00Z"), // Weekend + Labor Day.
            ("2026-04-02T19:00:00Z", "2026-04-06T04:00:00Z"), // Good Friday.
            ("2026-07-02T19:00:00Z", "2026-07-06T04:00:00Z"), // Observed Independence Day.
            ("2026-10-09T19:00:00Z", "2026-10-13T04:00:00Z"), // Columbus Day: exchange open, no settlement.
            ("2026-10-12T19:00:00Z", "2026-10-13T04:00:00Z"),
            ("2026-11-10T19:00:00Z", "2026-11-12T05:00:00Z"), // Veterans Day.
            ("2026-11-11T19:00:00Z", "2026-11-12T05:00:00Z"),
            ("2026-03-06T19:00:00Z", "2026-03-09T04:00:00Z"), // Spring DST.
            ("2026-10-30T19:00:00Z", "2026-11-02T05:00:00Z"), // Fall DST.
            ("2026-11-25T19:00:00Z", "2026-11-27T05:00:00Z"), // Early-close day still settles.
            ("2026-12-31T19:00:00Z", "2027-01-04T05:00:00Z"),
            ("2027-01-15T19:00:00Z", "2027-01-19T05:00:00Z")
        ]
        for (sale, expected) in cases {
            #expect(A.settlementDate(forSaleAt: try Date(sale, strategy: .iso8601)) == (try Date(expected, strategy: .iso8601)))
        }
        for unsupported in ["2025-12-31T19:00:00Z", "2027-01-29T19:00:00Z", "2027-02-01T19:00:00Z"] {
            #expect(A.settlementDate(forSaleAt: try Date(unsupported, strategy: .iso8601)) == nil)
        }
        #expect(A.settlementDate(forSaleAt: Date(timeIntervalSince1970: .nan)) == nil)
    }

    @Test func settlementCoverageStopsAtTheExistingJanuary2027Boundary() throws {
        let supportedSale = try Date("2027-01-28T19:00:00Z", strategy: .iso8601)
        let due = try Date("2027-01-29T05:00:00Z", strategy: .iso8601)
        #expect(A.settlementDate(forSaleAt: supportedSale) == due)

        let supportedBook = A.Book(trades: [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98,
            target: 104, shares: 100, openedAt: supportedSale.addingTimeInterval(-60),
            exitPrice: 101, closedAt: supportedSale)])
        #expect(supportedBook.unsettledProceeds(at: due.addingTimeInterval(-1)) == 10_100)
        #expect(supportedBook.buyingCash(at: due.addingTimeInterval(-1)) == 0)
        #expect(supportedBook.unsettledProceeds(at: due) == 0)
        #expect(supportedBook.buyingCash(at: due) == 10_100)

        let unsupportedSale = try Date("2027-01-29T19:00:00Z", strategy: .iso8601)
        #expect(A.settlementDate(forSaleAt: unsupportedSale) == nil)
        let unsupportedBook = A.Book(trades: [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98,
            target: 104, shares: 100, openedAt: unsupportedSale.addingTimeInterval(-60),
            exitPrice: 101, closedAt: unsupportedSale)])
        let later = unsupportedSale.addingTimeInterval(14 * 86_400)
        #expect(unsupportedBook.unsettledProceeds(at: later) == 10_100)
        #expect(unsupportedBook.buyingCash(at: later) == 0)
    }

    @Test func proceedsReleaseAtScheduledDateWithoutChangingEquityOrHistory() throws {
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        book.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(3))
        book.settle(quotes: ["AAPL": quote(price: 105, at: now.addingTimeInterval(4))], at: now.addingTimeInterval(5))
        let due = try #require(A.settlementDate(forSaleAt: now))
        let before = try JSONEncoder().encode(book)
        #expect(book.cash == 10_091.11)
        #expect(book.unsettledProceeds(at: due.addingTimeInterval(-1)) == 1993.01)
        #expect(book.settledCash(at: due.addingTimeInterval(-1)) == 8098.1)
        #expect(book.settledCash(at: due) == book.cash && book.unsettledProceeds(at: due) == 0)
        #expect(book.equity(quotes: [:], at: due.addingTimeInterval(-1)) == book.equity(quotes: [:], at: due))
        let restored = try JSONDecoder().decode(A.Book.self, from: before)
        #expect(restored.trades == book.trades && restored.valid && restored.version == 1)
        #expect(restored.settledCash(at: due.addingTimeInterval(-1)) == 8098.1)
        #expect(restored.settledCash(at: due) == 10_091.11)
    }

    @Test func fundingDeficitBlocksOnlyEntriesAndUnknownDatesKeepProceedsUnavailable() throws {
        var book = A.Book()
        // A historical full-cash round trip plus an already recycled $100 holding.
        book.trades = [
            .init(symbol: "AAPL", side: .long, entry: 100, stop: 98, target: 104, shares: 100,
                  openedAt: now.addingTimeInterval(-10), exitPrice: 100, closedAt: now),
            .init(symbol: "MSFT", side: .long, entry: 100, stop: 98, target: 104, shares: 1, openedAt: now)
        ]
        #expect(book.valid && book.cash == 9900 && book.settledCash(at: now) == -100 && book.buyingCash(at: now) == 0)
        book.propose(symbol: "META", action: .buy, at: now.addingTimeInterval(1))
        #expect(book.pending.isEmpty && book.decisions.last?.reason.contains("settled paper cash") == true)
        let market = StockSageMassive.MarketSnapshot(returnedCount: 1, rows: [.init(quote: quote("META", price: 1, at: now), dollarVolume: 1000)])
        #expect(A.researchTargets(market: market, book: book, at: now) == ["MSFT"], "Zero funds must not suppress held-position research")
        book.propose(symbol: "MSFT", action: .sell, at: now.addingTimeInterval(1))
        book.settle(quotes: ["MSFT": quote("MSFT", at: now.addingTimeInterval(2))], at: now.addingTimeInterval(3))
        #expect(book.open.isEmpty && book.valid && book.settledCash(at: now.addingTimeInterval(3)) == -100)
        let unsupported = try Date("2027-02-01T19:00:00Z", strategy: .iso8601)
        book.trades = [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98, target: 104, shares: 100,
                            openedAt: unsupported, exitPrice: 101, closedAt: unsupported)]
        #expect(book.unsettledProceeds(at: unsupported.addingTimeInterval(14 * 86_400)) == 10_100)
        #expect(book.buyingCash(at: unsupported.addingTimeInterval(14 * 86_400)) == 0 && book.valid)
    }

    @Test func concurrentPendingFillsRecheckSettledCashAndActivationIsIdempotent() throws {
        var book = A.Book()
        book.trades = [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98, target: 104, shares: 95,
                            openedAt: now.addingTimeInterval(-10), exitPrice: 100, closedAt: now)]
        for symbol in ["META", "AMD"] { book.propose(symbol: symbol, action: .buy, at: now) }
        book.lastResearch = now
        let orders = book.pending.map(\.id), trades = book.trades
        book.activateSettlement(at: now)
        book.activateSettlement(at: now.addingTimeInterval(1))
        #expect(book.pending.map(\.id) == orders && book.trades == trades && book.lastResearch == now)
        #expect(book.decisions.filter { $0.action == "T+1 cash policy activated" }.count == 1)
        let quotes = ["META": quote("META", price: 300, at: now.addingTimeInterval(1)),
                      "AMD": quote("AMD", price: 300, at: now.addingTimeInterval(1))]
        book.settle(quotes: quotes, at: now.addingTimeInterval(2))
        #expect(book.open.count == 1 && book.open.first?.shares == 1 && book.pending.isEmpty)
        #expect(book.settledCash(at: now.addingTimeInterval(2)) == 199.7 && book.cash == 9699.7 && book.valid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(book)
        var restored = try JSONDecoder().decode(A.Book.self, from: snapshot)
        restored.settle(quotes: quotes, at: now.addingTimeInterval(2))
        #expect(restored.decisions.map(\.id) == book.decisions.map(\.id) && restored.trades == book.trades)
        #expect(restored.pending.isEmpty && restored.cash == 9699.7)
        #expect(restored.settledCash(at: now.addingTimeInterval(2)) == 199.7 && restored.valid)
        #expect(try encoder.encode(restored) == snapshot)
    }

    #if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STOCKSAGE_PAPER_PROCESS_DEATH"] == "1"))
    func abruptChildDeathAtBeforeAccountCommitReleasesLeaseAndRecoversOneFill() async throws {
        let environment = ProcessInfo.processInfo.environment, files = FileManager.default
        let flag = "STOCKSAGE_PAPER_PROCESS_DEATH", prefix = "stocksage-paper-process-death-"
        let childKey = "\(flag)_CHILD", accountKey = "\(flag)_ACCOUNT"
        let defaultsKey = "\(flag)_DEFAULTS", executableKey = "\(flag)_EXECUTABLE"
        let executable = try #require(Bundle.main.executableURL).resolvingSymlinksInPath()
        try #require(executable.lastPathComponent == "testrunner",
                     "Opt in only with the existing standalone testrunner, never an Xcode app host.")
        let length = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        try #require(length > 1 && length < 4096)
        var buffer = [CChar](repeating: 0, count: length)
        try #require(Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length)
        let temp = URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
        try #require(files.temporaryDirectory.resolvingSymlinksInPath().path == temp.path)
        func ownedRoot(_ root: URL) -> stat? {
            var info = stat()
            guard Darwin.lstat(root.path, &info) == 0, info.st_uid == Darwin.geteuid(),
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_mode & 0o7777 == 0o700 else { return nil }
            return info
        }
        let witnessName = "abandoned-decision.json"
        if environment[childKey] == "1" {
            guard environment[executableKey] == executable.path,
                  let name = environment[defaultsKey], name.hasPrefix(prefix),
                  let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  name == prefix + id.uuidString else { Darwin._exit(80) }
            let root = temp.appendingPathComponent(name), account = root.appendingPathComponent("account.json")
            var info = stat()
            guard environment[accountKey] == account.path, ownedRoot(root) != nil,
                  account.resolvingSymlinksInPath().path == account.path,
                  Darwin.lstat(account.path, &info) == 0, info.st_uid == Darwin.geteuid(),
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                  (try? files.contentsOfDirectory(atPath: root.path)) == ["account.json"],
                  let defaults = UserDefaults(suiteName: name) else { Darwin._exit(80) }
            let state = A(url: account, defaults: defaults)
            guard state.error == nil, state.acquire() else { Darwin._exit(81) }
            var next = state.book
            next.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
            guard next.trades.count == 1, next.pending.isEmpty, next.cash == 8_098.10,
                  next.decisions.count == 40_001, let abandonedID = next.decisions.last?.id else { Darwin._exit(82) }
            _ = state.save(next, beforeAccountCommit: {
                let contender = A(url: account, defaults: defaults)
                guard !contender.acquire(),
                      contender.error == "This paper account is running in another StockSage process." else { Darwin._exit(84) }
                try JSONEncoder().encode(abandonedID).write(to: root.appendingPathComponent(witnessName),
                                                           options: .withoutOverwriting)
                Darwin._exit(86) // No stop(), defer, or error unwinding; account commit has not happened.
            })
            Darwin._exit(83)
        }
        try #require([childKey, accountKey, defaultsKey, executableKey].allSatisfy { environment[$0] == nil })
        let name = prefix + UUID().uuidString, child = Process()
        let root = temp.appendingPathComponent(name), account = root.appendingPathComponent("account.json")
        try #require(Darwin.mkdir(root.path, mode_t(0o700)) == 0) // Exclusive creation; never adopt an existing root.
        let created = try #require(ownedRoot(root))
        var defaults: UserDefaults?, recovery: A?
        var childReaped = true
        defer {
            if childReaped, let current = ownedRoot(root),
               current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                recovery?.stop() // Synthetic cleanup only, after all recovery/replay assertions.
                defaults?.removePersistentDomain(forName: name)
                do { try files.removeItem(at: root) } catch { Issue.record(error) }
            } else {
                Issue.record("Fixture retained: unreaped child or changed root identity at \(root.path)")
            }
        }
        defaults = try #require(UserDefaults(suiteName: name))
        let isolatedDefaults = try #require(defaults)
        var baseline = A.Book()
        for _ in 0..<40_000 { baseline.note(action: "Fixture", reason: "Synthetic audit identity", at: now) }
        baseline.propose(symbol: "AAPL", action: .buy, at: now)
        let pendingID = try #require(baseline.pending.first?.id)
        try #require(baseline.valid && baseline.decisions.count == 40_000 && baseline.pending.count == 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let baselineBytes = try encoder.encode(baseline)
        try baselineBytes.write(to: account, options: .atomic)
        child.executableURL = executable
        child.currentDirectoryURL = root
        child.arguments = ["--filter",
            "abruptChildDeathAtBeforeAccountCommitReleasesLeaseAndRecoversOneFill",
            "--no-parallel"]
        child.environment = [flag: "1", childKey: "1", accountKey: account.path,
                             defaultsKey: name, executableKey: executable.path]
        if let tmp = environment["TMPDIR"] { child.environment?["TMPDIR"] = tmp }
        child.standardInput = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            else { child.waitUntilExit(); childReaped = true }
        }
        childReaped = false
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while child.isRunning && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let timelyExit = !child.isRunning
        if child.isRunning {
            let result = Darwin.kill(child.processIdentifier, SIGKILL)
            if result != 0 && errno != ESRCH { Issue.record("Could not signal owned child: errno \(errno)") }
            let reapDeadline = ProcessInfo.processInfo.systemUptime + 5
            while child.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline {
                try? await Task.sleep(for: .milliseconds(10))
                await Task.yield() // Remain cooperative even if this test task was cancelled.
            }
        }
        try #require(!child.isRunning, "Owned child could not be reaped; fixture retained at \(root.path)")
        child.waitUntilExit(); childReaped = true
        try #require(timelyExit, "Child timed out or test was cancelled before the pre-commit exit.")
        print("[paper-process-death] owned child exit=\(child.terminationStatus)")
        try #require(child.terminationReason == .exit)
        try #require(child.terminationStatus == 86)

        #expect(try Data(contentsOf: account) == baselineBytes)
        let orphanNames = try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("audit-") && $0.hasSuffix(".json") }
        let orphanName = try #require(orphanNames.count == 1 ? orphanNames[0] : nil)
        let orphan = try JSONDecoder().decode([A.Decision].self,
            from: Data(contentsOf: root.appendingPathComponent(orphanName)))
        #expect(orphan == Array(baseline.decisions.prefix(1_000)))
        let abandonedID = try JSONDecoder().decode(UUID.self,
            from: Data(contentsOf: root.appendingPathComponent(witnessName)))
        let restarted = A(url: account, defaults: isolatedDefaults)
        recovery = restarted
        try #require(restarted.error == nil && restarted.acquire())
        #expect(try Data(contentsOf: account) == baselineBytes)
        #expect(try encoder.encode(restarted.book) == baselineBytes)
        #expect(try encoder.encode(restarted.book.pending) == encoder.encode(baseline.pending))
        #expect(restarted.book.decisions == baseline.decisions)
        #expect(restarted.book.cash == 10_000 && restarted.book.trades.isEmpty)
        #expect(restarted.book.pending.map(\.id) == [pendingID] && restarted.book.audit == nil)

        var filled = restarted.book
        filled.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(filled.pending.isEmpty && filled.trades.count == 1)
        #expect(filled.trades.first?.id == pendingID && filled.trades.first?.shares == 19)
        #expect(filled.cash == 8_098.10 && filled.decisions.count == 40_001)
        try #require(restarted.save(filled))
        let reopened = A(url: account, defaults: isolatedDefaults)
        try #require(reopened.error == nil && reopened.hasLoadedBook)
        let audit = try #require(reopened.book.audit)
        var history: [A.Decision] = []
        for archive in audit.archives { history += try archive.read(beside: account) }
        history += reopened.book.decisions
        let identical = history == filled.decisions
        #expect(identical, "Durable recovery retains every complete decision, in commit order.")
        #expect(history.count == 40_001 && Set(history.map(\.id)).count == 40_001)
        #expect(!history.contains { $0.id == abandonedID } && history.last?.action == "Paper Buy")
        #expect(reopened.book.pending.isEmpty && reopened.book.trades.count == 1)
        #expect(reopened.book.trades == filled.trades && reopened.book.cash == 8_098.10)
        let referenced = Set(audit.archives.map { $0.url(beside: account).lastPathComponent })
        let allAudit = Set(try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("audit-") && $0.hasSuffix(".json") })
        #expect(referenced.count == 1 && !referenced.contains(orphanName))
        #expect(allAudit.subtracting(referenced) == Set([orphanName]))
        let committedBytes = try Data(contentsOf: account), replayBefore = try encoder.encode(reopened.book)
        var repeated = reopened.book
        repeated.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(try encoder.encode(repeated) == replayBefore)
        #expect(try Data(contentsOf: account) == committedBytes)
    }
    #endif

    @Test func failedAcquireAfterInitialReadClearsLoadedStateWithoutChangingBook() throws {
        let files = FileManager.default
        let name = "qwen-paper-state-\(UUID().uuidString)"
        let temp = files.temporaryDirectory.resolvingSymlinksInPath()
        let root = temp.appendingPathComponent(name, isDirectory: true)
        try #require(!files.fileExists(atPath: root.path))
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        try #require(root.resolvingSymlinksInPath().path == root.path)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let url = root.appendingPathComponent("account.json")
        var book = A.Book()
        book.note(action: "Fixture research", reason: "Synthetic retained evidence", at: now)
        book.propose(symbol: "AAPL", action: .buy, at: now)
        try #require(book.valid && book.pending.count == 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(book)
        try before.write(to: url, options: .withoutOverwriting) // Ordinary fixture bytes; no save/acquire yet.
        let state = A(url: url, defaults: defaults)
        defer { state.stop() } // Failed read releases its lease; cleanup must not save.
        try #require(state.hasLoadedBook && state.error == nil)
        #expect(try encoder.encode(state.book) == before)

        let corruptBytes = Data("broken".utf8)
        try corruptBytes.write(to: url)
        try #require(!state.acquire())
        let corruptError = "Paper account unavailable or corrupt. Existing data has been preserved."
        #expect(!state.hasLoadedBook)
        #expect(state.error == corruptError)
        #expect(try encoder.encode(state.book) == before)
        #expect(try Data(contentsOf: url) == corruptBytes)

        let second = A(url: url, defaults: defaults)
        defer { second.stop() } // This reader also fails before retaining a lease.
        try #require(!second.acquire())
        #expect(!second.hasLoadedBook && second.error == corruptError,
                "Failed acquisition must release the lease, not block the next corrupt reader.")
        #expect(try Data(contentsOf: url) == corruptBytes)
    }

    @Test func accountLeasePersistenceAndCorruptionProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "qwen-paper-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let url = root.appendingPathComponent("account.json")
        let first = A(url: url, defaults: defaults)
        let second = A(url: url, defaults: defaults)
        #expect(first.acquire() && !second.acquire())
        var book = A.Book()
        book.note(action: "Fixture research", reason: "Synthetic evidence", at: now)
        #expect(first.save(book))
        let before = try Data(contentsOf: url)
        var invalid = book; invalid.version = 999
        #expect(!first.save(invalid))
        #expect(try Data(contentsOf: url) == before)
        first.stop()
        #expect(second.acquire() && second.book.cash == 10_000)
        second.stop()
        try Data("broken".utf8).write(to: url)
        let corrupt = A(url: url, defaults: defaults)
        #expect(!corrupt.acquire() && corrupt.error != nil && !corrupt.hasLoadedBook)
        #expect(try Data(contentsOf: url) == Data("broken".utf8))
    }

    @Test func fullAuditHistoryDoesNotPreventSavingAnEligibleExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "qwen-capacity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        var full = A.Book()
        full.trades = [.init(symbol: "AAPL", side: .long, entry: 100, stop: 98, target: 104, shares: 1, openedAt: now)]
        for _ in 0..<50_000 { full.note(action: "Fixture", reason: "Preserve this audit record", at: now) }
        full.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(1))
        #expect(state.acquire() && state.save(full))
        var next = state.book
        next.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(2))], at: now.addingTimeInterval(2))
        #expect(next.open.isEmpty)
        let saved = state.save(next)
        #expect(saved, "Audit capacity must not reject a valid protective/ordinary exit")
        #expect(state.book.open.isEmpty)
    }
}
