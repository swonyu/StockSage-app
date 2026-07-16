import Testing
import Foundation
@testable import StockSage

// MARK: - StockSageMonitor (pure decision helpers)
//
// `runCycle`/`runWatchlistCycle` are @MainActor, side-effecting (real live-network fetch +
// real UNUserNotificationCenter push + StockSageStore.shared singleton state), so the
// notify-or-not DECISION is pulled out into small `nonisolated static` pure functions the
// monitor's loops call inline — the same "thin shell over a tested rule" shape
// `StockSageAlertDecision` already uses. These tests pin that decision logic directly.

struct StockSageMonitorTests {
    typealias Monitor = StockSageMonitor

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
        // Mirrors the PRE-FIX construction (marketTime omitted): "can't judge" ⇒ never stale,
        // no matter how old the feed's own market timestamp actually was.
        let preFix = StockSageSymbol(symbol: "AAPL", market: "★ My watchlist", quotes: [
            StockSageQuote(price: 226, previousPrice: 226, time: now.addingTimeInterval(-86_400)),
            StockSageQuote(price: 227, previousPrice: 226),
        ])
        #expect(preFix.isStale(asOf: now) == false)
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
