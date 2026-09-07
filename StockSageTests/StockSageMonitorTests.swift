import Testing
import Foundation
@testable import StockSage

// MARK: - StockSageMonitor (stateful enqueue regression + pure decisions)
//
// Exercise the production post-fetch watchlist loop with per-test preferences/budgets and
// a simulated enqueue result: no live quotes, shared board mutations or system pushes.
// The pure tests below separately pin the shared freshness/stop/target decision rules.

struct StockSageMonitorTests {
    typealias Monitor = StockSageMonitor

    @MainActor @Test func failedWatchlistEnqueueRetriesThenDedupesOnlyAfterAcceptance() async throws {
        let name = "monitor.retry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var attempts = 0
        let monitor = Monitor(defaults: defaults) { signal, _ in
            #expect(signal.recommendation == .strongBuy)
            attempts += 1
            return attempts > 1
        }
        let quotes = ["TEST": StockSageQuoteService.LiveQuote(symbol: "TEST", price: 110,
                                                             previousClose: 100, marketTime: Date())]
        let first = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: quotes)
        #expect(first.signals.count == 1 && first.examined == 1)
        #expect(attempts == 1)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.isEmpty)
        let second = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: quotes)
        #expect(second.signals == first.signals)
        #expect(second.freshPrices["TEST"] == 110)
        #expect(attempts == 2, "a failed enqueue must not consume the signal's next attempt")
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 1)
        _ = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: quotes)
        #expect(attempts == 2, "the accepted retry must not be sent again")
    }

    @MainActor @Test func acceptedWatchlistSignalDoesNotRepeat() async throws {
        let name = "monitor.accepted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var attempts = 0
        let monitor = Monitor(defaults: defaults) { _, _ in attempts += 1; return true }
        let quotes = ["TEST": StockSageQuoteService.LiveQuote(symbol: "TEST", price: 110,
                                                             previousClose: 100, marketTime: Date())]
        for _ in 0..<3 { _ = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: quotes) }
        #expect(attempts == 1)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 1)
        #expect(monitor.suppressedAlertCount == 0) // dedupe, not a repeated budget refusal
    }

    @MainActor @Test func failedSendLeavesBudgetAvailableToANewMonitor() async throws {
        let name = "monitor.failure-probe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let failing = Monitor(defaults: defaults) { _, _ in false }
        let quotes = ["TEST": StockSageQuoteService.LiveQuote(symbol: "TEST", price: 110,
                                                             previousClose: 100, marketTime: Date())]
        _ = await failing.evaluateWatchlistQuotes(["TEST"], quotes: quotes)
        let saved = StockSageNotificationBudget(loadingFrom: defaults)
        #expect(saved.recentAlerts.isEmpty && saved.perSymbol.isEmpty)
        var attempts = 0
        let fresh = Monitor(defaults: defaults) { _, _ in attempts += 1; return true }
        _ = await fresh.evaluateWatchlistQuotes(["TEST"], quotes: quotes)
        #expect(attempts == 1) // same quote and persisted budget, only dedupe instance differs
    }

    @MainActor @Test(arguments: ["stale", "inspect", "muted", "capped"])
    func retryFixPreservesDeliberateSuppression(mode: String) async throws {
        let name = "monitor.suppression.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        if mode == "muted" { defaults.set(false, forKey: StockSageNotifyPrefs.strongSignalsKey) }
        if mode == "capped" {
            var budget = StockSageNotificationBudget(loadingFrom: defaults)
            for i in 0..<StockSageNotificationBudget.hourlyCap {
                budget.record(symbol: "SEED\(i)", price: 100, now: now)
            }
            budget.save(to: defaults)
        }
        var attempts = 0
        let monitor = Monitor(defaults: defaults) { _, _ in attempts += 1; return true }
        let staleTime = now.addingTimeInterval(-72 * 3600)
        let quotes = ["TEST": StockSageQuoteService.LiveQuote(symbol: "TEST", price: 110,
            previousClose: 100, marketTime: mode == "stale" ? staleTime : now)]
        _ = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: quotes, notify: mode != "inspect")
        #expect(attempts == 0)
        defaults.set(true, forKey: StockSageNotifyPrefs.strongSignalsKey)
        let fresh = ["TEST": StockSageQuoteService.LiveQuote(symbol: "TEST", price: 110,
                                                            previousClose: 100, marketTime: now)]
        _ = await monitor.evaluateWatchlistQuotes(["TEST"], quotes: fresh)
        #expect(attempts == ((mode == "stale" || mode == "inspect") ? 1 : 0))
        #expect(monitor.suppressedAlertCount == (mode == "capped" ? 1 : 0))
        // Muting/budget rejection deliberately advance dedupe to avoid a queued alert burst;
        // inspection-only or stale observations never consume a later eligible notification.
    }

    @MainActor @Test func cancelledWatchlistBatchStopsAndItsFailedSendCanRetry() async throws {
        let name = "monitor.cancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var sent: [String] = []
        let monitor = Monitor(defaults: defaults) { signal, _ in
            sent.append(signal.symbol)
            if sent.count == 1 {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
            return true
        }
        let quotes = Dictionary(uniqueKeysWithValues: ["FIRST", "SECOND"].map {
            ($0, StockSageQuoteService.LiveQuote(symbol: $0, price: 110,
                                                previousClose: 100, marketTime: Date()))
        })
        let cancelled = Task { await monitor.evaluateWatchlistQuotes(["FIRST", "SECOND"], quotes: quotes) }
        let result = await cancelled.value
        #expect(result.examined == 1)
        #expect(sent == ["FIRST"])
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.isEmpty)
        _ = await monitor.evaluateWatchlistQuotes(["FIRST", "SECOND"], quotes: quotes)
        #expect(sent == ["FIRST", "FIRST", "SECOND"])
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 2)
    }

    @MainActor @Test func mutingDuringOneSendPreventsTheNextStrongSignal() async throws {
        let name = "monitor.mute.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var sent: [String] = []
        let monitor = Monitor(defaults: defaults) { signal, _ in
            sent.append(signal.symbol)
            defaults.set(false, forKey: StockSageNotifyPrefs.strongSignalsKey)
            await Task.yield()
            return true
        }
        let quotes = Dictionary(uniqueKeysWithValues: ["FIRST", "SECOND"].map {
            ($0, StockSageQuoteService.LiveQuote(symbol: $0, price: 110,
                                                previousClose: 100, marketTime: Date()))
        })
        _ = await monitor.evaluateWatchlistQuotes(["FIRST", "SECOND"], quotes: quotes)
        #expect(sent == ["FIRST"])
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 1)
    }

    // MARK: Finding 1 — strong-signal push must never fire on a STALE quote

    @Test func staleQuoteNeverPushesEvenOnABrandNewStrongSignal() {
        // Before the fix, the gate was dedup-only (`recommendation != lastAlerted`) — a brand
        // new Strong Buy (nothing alerted before) on a STALE weekend/holiday close would have
        // returned true here and fired a push. It must now stay silent until the market reopens.
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongBuy, lastAlerted: nil, isFresh: false) == false)
        // Same for a flip (Strong Sell → Strong Buy) built on a stale close.
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongBuy, lastAlerted: .strongSell, isFresh: false) == false)
    }

    @Test func freshNewOrFlippedSignalStillPushes() {
        // The fresh case must reproduce the exact pre-fix dedup-only behavior byte-for-byte.
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongBuy, lastAlerted: nil, isFresh: true) == true)
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongSell, lastAlerted: .strongBuy, isFresh: true) == true)
    }

    @Test func freshButAlreadyAlertedStaysSilent() {
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongBuy, lastAlerted: .strongBuy, isFresh: true) == false)
    }

    @Test func staleGateDoesNotPoisonFutureFreshAlerts() {
        // A stale cycle must not be treated as "already alerted" — otherwise the LEGITIMATE
        // push once a fresh quote confirms the same signal (market reopens, still Strong Buy)
        // would be silently suppressed. Simulated here: `lastAlerted` stays nil after a stale
        // cycle (the monitor's loop only merges into `lastAlerted` when `isFresh`), so the next,
        // fresh cycle at the SAME recommendation still passes the gate.
        let lastAlertedAfterStaleCycle: StockSageRecommendation? = nil   // never merged — see runCycle
        #expect(Monitor.shouldPushStrongSignal(recommendation: .strongBuy,
                                                lastAlerted: lastAlertedAfterStaleCycle, isFresh: true) == true)
    }

    // MARK: Finding 1 — the watchlist synthetic quote must carry a real market time

    @Test func watchlistSyntheticSymbolNowCarriesMarketTimeForStalenessCheck() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let staleMarketTime = now.addingTimeInterval(-60 * 3600)   // 60h-old equity close → stale
        // Mirrors the FIXED construction in `runWatchlistCycle` (marketTime passed through).
        let fixed = StockSageSymbol(symbol: "AAPL", market: "★ My watchlist", quotes: [
            StockSageQuote(price: 226, previousPrice: 226, time: now.addingTimeInterval(-86_400)),
            StockSageQuote(price: 227, previousPrice: 226, marketTime: staleMarketTime),
        ])
        #expect(fixed.isStale(asOf: now) == true)
        // Mirrors the PRE-FIX construction (marketTime omitted). Under the fail-closed
        // contract (owner-signed 2026-07-27) an unverifiable timestamp is STALE — the very
        // defect this test documents is now caught by the shared rule itself.
        let preFix = StockSageSymbol(symbol: "AAPL", market: "★ My watchlist", quotes: [
            StockSageQuote(price: 226, previousPrice: 226, time: now.addingTimeInterval(-86_400)),
            StockSageQuote(price: 227, previousPrice: 226),
        ])
        #expect(preFix.isStale(asOf: now) == true)
    }

    // MARK: Finding 2 — tracked-idea stop/target pushes via StockSageAlertDecision.evaluate

    @Test func ideaAlertRecommendationMapsShortActionsToStrongSellAndTheRestToStrongBuy() {
        // Mirrors `StockSageAdvisor.stopTarget`'s own short definition (`.sell`/`.reduce`)
        // exactly — those are the only actions with a non-nil stop/target on the short side.
        #expect(Monitor.ideaAlertRecommendation(for: .sell) == .strongSell)
        #expect(Monitor.ideaAlertRecommendation(for: .reduce) == .strongSell)
        #expect(Monitor.ideaAlertRecommendation(for: .buy) == .strongBuy)
        #expect(Monitor.ideaAlertRecommendation(for: .strongBuy) == .strongBuy)
        #expect(Monitor.ideaAlertRecommendation(for: .hold) == .strongBuy)
        #expect(Monitor.ideaAlertRecommendation(for: .avoid) == .strongBuy)
    }

    @Test func isPushableIdeaAlertOnlyAllowsStopBreachAndTargetHit() {
        #expect(Monitor.isPushableIdeaAlert(nil) == false)
        #expect(Monitor.isPushableIdeaAlert(StockSageAlert(symbol: "X", kind: .stopBreach, reason: "")) == true)
        #expect(Monitor.isPushableIdeaAlert(StockSageAlert(symbol: "X", kind: .targetHit, reason: "")) == true)
        // The strong-signal event classes stay owned by the price-momentum signal-engine path
        // elsewhere in the monitor — never double-pushed from the idea path.
        #expect(Monitor.isPushableIdeaAlert(StockSageAlert(symbol: "X", kind: .newStrongBuy, reason: "")) == false)
        #expect(Monitor.isPushableIdeaAlert(StockSageAlert(symbol: "X", kind: .newStrongSell, reason: "")) == false)
        #expect(Monitor.isPushableIdeaAlert(StockSageAlert(symbol: "X", kind: .flip, reason: "")) == false)
    }

    /// End-to-end regression pin for finding 2: chains the exact production functions
    /// `checkIdeaAlerts` uses internally (`ideaAlertRecommendation` → `evaluate` →
    /// `isPushableIdeaAlert`) to prove a tracked LONG idea's target-hit and a tracked SHORT
    /// idea's stop-breach both produce a pushable notification — the documented feature
    /// (StockSageAlertDecision's header) that, before this fix, had zero production callers.
    @Test func trackedIdeaStopAndTargetCrossingsProduceAPushableAlert() {
        func pushableAlert(action: TradeAdvice.Action, price: Double, priorPrice: Double,
                           stop: Double?, target: Double?) -> StockSageAlert? {
            let alert = StockSageAlertDecision.evaluate(
                symbol: "TST", recommendation: Monitor.ideaAlertRecommendation(for: action),
                price: price, priorPrice: priorPrice, stop: stop, target: target,
                lastAlertedRecommendation: nil)
            return Monitor.isPushableIdeaAlert(alert) ? alert : nil
        }

        // LONG idea (.buy), target 120, crosses UP through it (115 → 121): pushable target hit.
        let target = pushableAlert(action: .buy, price: 121, priorPrice: 115, stop: 90, target: 120)
        #expect(target?.kind == .targetHit)

        // SHORT idea (.sell), stop 110 (above, short-side), crosses UP through it (105 → 111):
        // pushable stop breach.
        let stop = pushableAlert(action: .sell, price: 111, priorPrice: 105, stop: 110, target: 80)
        #expect(stop?.kind == .stopBreach)

        // A brand-new Strong Buy idea with NO crossing this update must NOT push from this
        // path — that event class belongs to the separate price-momentum signal path.
        let noCross = pushableAlert(action: .strongBuy, price: 105, priorPrice: 100, stop: 90, target: 120)
        #expect(noCross == nil)
    }
}
