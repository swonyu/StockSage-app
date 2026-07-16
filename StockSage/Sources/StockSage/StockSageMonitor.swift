import Foundation
import UserNotifications

// MARK: - StockSageMonitor
//
// Reworked from the package's `AutonomousMarketAgent`. Kept the genuinely real
// parts — the cancellable monitoring loop and real `UNUserNotificationCenter`
// strong-signal alerts. Changes from the package:
//   * Namespaced (no collision with Chat A's agent backbone).
//   * Throttle decision uses the app's real `MemoryManager` instead of the
//     package's `testingHooks.shouldThrottleForThermal` shim.
//   * **Dropped the fabricated swarm-spawn / device-migration calls** — the
//     package "spawned" agents into a dictionary and printed fake migration
//     success. Shipping nothing that lies.
//   * Reads symbols from `StockSageStore` (in-memory; sample data until Chat A's
//     live feed replaces it).
@MainActor
final class StockSageMonitor {
    static let shared = StockSageMonitor()
    private init() {}

    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    /// When this UserDefaults flag is set AND the user has a non-empty watchlist, the loop
    /// scans ONLY the watchlist (fetching just those quotes) instead of pulling the whole
    /// ~210-name core every cycle (StockSageUniverse.core, post equity-2000 promotion —
    /// was described as ~250 pre-promotion; corrected 2026-07-08). Shared with the Markets
    /// toggle's @AppStorage key.
    static let watchlistOnlyKey = "marketsWatchlistOnly"
    /// The last strong recommendation fired per symbol, so we don't re-spam the
    /// SAME alert every cycle (only a NEW or CHANGED strong signal notifies).
    private var lastAlerted: [String: StockSageRecommendation] = [:]
    /// The last live price seen per TRACKED IDEA symbol, so `checkIdeaAlerts` can detect a
    /// stop/target CROSSING (this cycle's price vs the prior one) instead of a standing
    /// condition — mirrors `lastAlerted`'s role for the strong-signal path. A symbol seen for
    /// the first time seeds this as its own baseline (no prior to compare), so it can't claim a
    /// crossing that may not be real.
    private var lastIdeaPrice: [String: Double] = [:]

    enum MonitorError: LocalizedError {
        case alreadyRunning
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "StockSage monitor is already running."
            }
        }
    }

    /// Start the monitoring loop. Re-evaluates every `interval` seconds (doubled
    /// automatically when `MemoryManager` reports the machine is under
    /// memory/thermal pressure). Throws if already running.
    /// `firstCycleDelay` staggers the monitor's first refresh so it doesn't race
    /// the view's onAppear refresh that fires at the same moment on launch.
    func start(interval: TimeInterval = 45, firstCycleDelay: TimeInterval = 20) throws {
        guard !isRunning else { throw MonitorError.alreadyRunning }
        isRunning = true
        requestNotificationPermission()

        task = Task { [weak self] in
            // Stagger the first cycle: the view's .task fires store.refresh() on appear;
            // without this delay both hit Yahoo simultaneously on every cold launch.
            try? await Task.sleep(for: .seconds(Int(firstCycleDelay)))
            while !Task.isCancelled {
                // Watchlist-only mode (opt-in, re-read each cycle so toggling takes effect):
                // fetch + scan ONLY the user's watchlist instead of refreshing the whole core.
                let watch = StockSageStore.shared.userSymbols
                let scoped = UserDefaults.standard.bool(forKey: StockSageMonitor.watchlistOnlyKey) && !watch.isEmpty
                if scoped {
                    await self?.runWatchlistCycle(watch)
                } else {
                    // Evaluate on LIVE quotes: pull a fresh snapshot before each cycle (no-ops
                    // cleanly when offline / web access is off). SCOPED to `.core` (review
                    // round-2 finding 1, orchestrator-flagged; RATIFIED by the owner 2026-07-08 —
                    // core+watchlist scoping, picked via question, see DEVELOPMENT_LOG.md's
                    // Equity-2000 stage 2 ship entry): this is the UNATTENDED background
                    // auto-cycle (~45s, indefinitely, while the app runs) — pulling Stage 2's full
                    // 2,420-name universe on every tick risked a feed cooldown that would take the
                    // whole app down. User-initiated refreshes (manual button, Find-Ideas scan)
                    // are UNCHANGED and still pull the full universe — see
                    // `StockSageStore.refresh(scope:)`'s doc comment.
                    await StockSageStore.shared.refresh(scope: .core)
                    // CONCURRENCY #2: stop() during the refresh await must not start a whole
                    // evaluation cycle for a monitor the user just turned off.
                    guard !Task.isCancelled else { break }
                    await self?.runCycle()
                }
                // Throttle under pressure — back off to 2× the interval when the machine is
                // stressed. STANDALONE DEVIATION (extraction @ fc8f383): the parent folded
                // memory pressure + thermal state via its MemoryManager (part of the LLM stack,
                // not carried over); the standalone keeps the same back-off intent using the
                // system thermal state directly.
                let thermal = ProcessInfo.processInfo.thermalState
                let stressed = thermal == .serious || thermal == .critical
                let delay = stressed ? interval * 2 : interval
                try? await Task.sleep(for: .seconds(Int(delay)))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    deinit { task?.cancel() }

    /// One evaluation pass: derive a signal per tracked symbol and fire a
    /// notification for strong buy/sell. Returns the strong signals it found
    /// (also used by the unit tests / tool, which don't want notifications).
    @discardableResult
    func runCycle(notify: Bool = true) async -> [StockSageSignal] {
        // NEVER fire a notification on seeded SAMPLE data OR on STALE disk-cache prices.
        // seedSampleData() plants two strong movers (2222.SR, NVDA), so a failed first-launch
        // refresh would push a "Strong Buy" built on hardcoded demo prices; loadedFromCache means
        // the board is last-session prices the in-app UI already labels "NOT live" — pushing a
        // notification off either is an honesty-floor violation (a stale push the owner acts on
        // without seeing the on-screen caveat). Still RETURN the signals so the tests/tool exercise
        // the logic without notifications, and don't poison `lastAlerted` with stale state.
        let store = StockSageStore.shared
        let liveNotify = notify && !store.isSampleData && !store.loadedFromCache
        var strong: [StockSageSignal] = []
        var nowStrong: [String: StockSageRecommendation] = [:]
        for symbol in store.fetchAllSymbols() {
            // CONCURRENCY #2: stop() cancels the loop task, but a cancelled task keeps executing
            // past its awaits (the sendAlert below) unless it checks — without this, alerts kept
            // firing AFTER monitoring was toggled off, and a quick stop→start overlapped two
            // cycles on the same lastAlerted state (double-fired or suppressed pushes).
            guard !Task.isCancelled else { break }
            guard let signal = StockSageSignalEngine.generateSignal(for: symbol) else { continue }
            guard signal.recommendation == .strongBuy || signal.recommendation == .strongSell else { continue }
            strong.append(signal)
            // A quote whose latest MARKET timestamp is stale (a weekend/holiday close) is not
            // actionable until the market reopens — possibly gapped — so it must neither push a
            // notification NOR poison `lastAlerted` (that would silently suppress the legitimate
            // alert once a FRESH quote later confirms the same signal).
            let fresh = !symbol.isStale()
            if fresh { nowStrong[signal.symbol] = signal.recommendation }
            // Fire only when this symbol's strong signal is NEW or has FLIPPED
            // (Strong Buy ⇄ Strong Sell) AND the quote is fresh — not the same alert on every
            // poll, and never off a stale close.
            if liveNotify, Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                        lastAlerted: lastAlerted[signal.symbol],
                                                        isFresh: fresh) {
                await sendAlert(signal: signal, market: symbol.market)
            }
        }
        // MERGE rather than replace: update the symbols that are strong now, but KEEP the
        // last-alerted state of symbols that left "strong". Replacing with only the
        // currently-strong set would forget a symbol that went strong→hold, so a
        // strong→hold→strong round-trip would re-fire the identical alert the user already
        // saw. A genuine flip (Strong Buy⇄Strong Sell) still alerts — the rec differs.
        // CONCURRENCY #2: a dying cycle must not write the dedupe map (two overlapping writers).
        if liveNotify, !Task.isCancelled { for (sym, rec) in nowStrong { lastAlerted[sym] = rec } }
        if notify, !Task.isCancelled {
            await checkPriceAlerts()
            // Tracked-idea stop/target pushes: same honesty gate as the strong-signal path
            // above (never off sample/cached-not-live data), and only off quotes THIS cycle
            // actually observed as fresh (reuses the per-symbol staleness already computed by
            // the loop above, one fetchAllSymbols() pass, no extra network calls).
            if liveNotify {
                var freshPrices: [String: Double] = [:]
                for symbol in store.fetchAllSymbols() {
                    guard !symbol.isStale(), let p = symbol.latest?.price, p > 0 else { continue }
                    freshPrices[symbol.symbol.uppercased()] = p
                }
                await checkIdeaAlerts(prices: freshPrices)
            }
        }
        return strong
    }

    /// Watchlist-only evaluation: fetch LIVE quotes for just the watchlist tickers and alert
    /// on strong buy/sell — self-contained (doesn't touch the board `symbols` or its
    /// sample/cache flags), so it stays honest (it fires only on quotes it just fetched) and
    /// cheap (no 250-name pull). Same NEW-or-flipped dedup as runCycle via `lastAlerted`.
    @discardableResult
    func runWatchlistCycle(_ watch: [String], notify: Bool = true) async -> [StockSageSignal] {
        let quotes = await StockSageQuoteService.fetchQuotes(for: watch)
        var strong: [StockSageSignal] = []
        var nowStrong: [String: StockSageRecommendation] = [:]
        var freshPrices: [String: Double] = [:]
        for ticker in watch {
            // CONCURRENCY #2: same cooperative-cancellation bail as runCycle.
            guard !Task.isCancelled else { break }
            guard let q = quotes[ticker.uppercased()], q.price > 0, q.previousClose > 0 else { continue }
            let sym = StockSageSymbol(symbol: ticker, market: "★ My watchlist", quotes: [
                StockSageQuote(price: q.previousClose, previousPrice: q.previousClose,
                               time: Date(timeIntervalSinceNow: -86_400)),
                // Carry the real MARKET time (was omitted here) so this synthetic symbol's own
                // `isStale()` can flag a days-old weekend/holiday close, same as the board path.
                StockSageQuote(price: q.price, previousPrice: q.previousClose, marketTime: q.marketTime),
            ])
            // Collect the fresh price for the idea stop/target check below regardless of
            // whether THIS ticker's momentum signal is currently strong.
            let fresh = !sym.isStale()
            if fresh { freshPrices[ticker.uppercased()] = q.price }
            guard let signal = StockSageSignalEngine.generateSignal(for: sym) else { continue }
            guard signal.recommendation == .strongBuy || signal.recommendation == .strongSell else { continue }
            strong.append(signal)
            if fresh { nowStrong[signal.symbol] = signal.recommendation }
            if notify, Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                    lastAlerted: lastAlerted[signal.symbol],
                                                    isFresh: fresh) {
                await sendAlert(signal: signal, market: sym.market)
            }
        }
        if notify, !Task.isCancelled { for (s, r) in nowStrong { lastAlerted[s] = r } }
        // Publish the freshly-fetched watchlist prices to the board so it reflects live data
        // for the names the user is focused on (watchlist-only stops the full auto-refresh).
        StockSageStore.shared.mergeLiveQuotes(quotes)
        if notify, !Task.isCancelled {
            await checkPriceAlerts()
            await checkIdeaAlerts(prices: freshPrices)
        }
        return strong
    }

    /// Check user-set price alerts against FRESHLY-FETCHED live prices (never the board's
    /// last-good values — a failed in-session refresh can leave those stale while the live/cache
    /// flags don't change), so a one-shot alert can't fire on stale/sample data. Armed alerts are
    /// few (user-set), so re-fetching just those each cycle is cheap. A freshly-fetched quote can
    /// STILL be a days-old close (Yahoo returns the last close over weekends/holidays), so we also
    /// drop any quote whose market timestamp is materially old — a level reached only at a stale
    /// close won't fire a push while the market is shut and the owner can't act.
    private func checkPriceAlerts() async {
        let store = StockSageStore.shared
        let armed = store.priceAlerts.filter { $0.isArmed }
        guard !armed.isEmpty else { return }
        let q = await StockSageQuoteService.fetchQuotes(for: Array(Set(armed.map { $0.symbol })))
        // CONCURRENCY #2 (L3-09): a stop() during the fetch await above must not let this cycle
        // push a one-shot price alert — same idiom as runCycle's post-await guards. Without this,
        // a stop()→start() overlap could double-push the SAME alert: the cancelled cycle's fetch
        // completes after cancellation, fires the push and (being one-shot) latches `triggeredAt`,
        // while a concurrent fresh cycle from the new task can independently do the same. Once
        // `sendPriceAlert` dispatch begins below, the pushes are unstoppable — UNUserNotificationCenter.add
        // is completion-bridged, not cancellation-aware — so there must be NO guard between the push
        // loop and `markPriceAlertsTriggered`: the latch is the truthful record of pushes that went
        // out, and skipping it would leave the alert ARMED while `newlyTriggered` fires on a STANDING
        // condition (isMet, not a crossing), re-pushing the same one-shot alert on the next cycle
        // after restart. `markPriceAlertsTriggered` is UserDefaults-persisted, so unlike the in-memory
        // `lastAlerted`/`lastIdeaPrice` dedup maps, a wrongful fire here doesn't self-heal — the
        // user would need to manually re-arm the alert.
        guard !Task.isCancelled else { return }
        var prices: [String: Double] = [:]
        for (k, v) in q where v.price > 0 && !StockSageQuoteFreshness.isStale(symbol: k, marketTime: v.marketTime) {
            prices[k.uppercased()] = v.price
        }
        let fired = StockSagePriceAlertEngine.newlyTriggered(armed, prices: prices)
        guard !fired.isEmpty else { return }
        for a in fired { await sendPriceAlert(a, price: prices[a.symbol] ?? a.target) }
        store.markPriceAlertsTriggered(fired.map(\.id))
    }

    /// Drive stop-breach/target-hit pushes for TRACKED IDEAS via the tested
    /// `StockSageAlertDecision.evaluate` rule — completes the feature its own header describes
    /// (the monitor as "a thin shell over a tested rule"); before this, `evaluate` had zero
    /// production callers and those events only reached the passive in-app
    /// `StockSageAlerts.detect` list (silent unless the user opens the app). Runs against
    /// `StockSageStore.shared.ideas` (the advisor's last-computed stop/target per symbol) — a
    /// no-op until the user has opened the Ideas board at least once. `prices` is keyed by
    /// UPPERCASED ticker → this cycle's live price, already staleness-filtered by the caller, so
    /// this never fires off a price it didn't just observe fresh.
    private func checkIdeaAlerts(prices: [String: Double]) async {
        guard !prices.isEmpty else { return }
        let ideas = StockSageStore.shared.ideas
        guard !ideas.isEmpty else { return }
        // ALERT-HELD-1: looked up ONCE per cycle (not per idea) — a stop-breach/target-hit push
        // is the single most decision-relevant alert, so it should say whether the owner actually
        // has a position on. Idea alerts ONLY — sendPriceAlert (user-set price alerts) is untouched.
        let holdingBySymbol = StockSagePortfolio.holdingBySymbol(in: StockSagePortfolio.shared.positions)
        for idea in ideas {
            guard let price = prices[idea.symbol.uppercased()], price > 0 else { continue }
            // First sighting this session: seed the baseline rather than claim a crossing that
            // may not be real (mirrors `lastAlerted`'s "no alert on first appearance" rule).
            let priorPrice = lastIdeaPrice[idea.symbol] ?? price
            lastIdeaPrice[idea.symbol] = price
            guard let alert = StockSageAlertDecision.evaluate(
                symbol: idea.symbol,
                recommendation: Self.ideaAlertRecommendation(for: idea.advice.action),
                price: price, priorPrice: priorPrice,
                stop: idea.advice.stopPrice, target: idea.advice.targetPrice,
                lastAlertedRecommendation: nil
            ), Self.isPushableIdeaAlert(alert) else { continue }
            await sendIdeaAlert(alert, held: holdingBySymbol[idea.symbol.uppercased()])
        }
    }

    private func sendIdeaAlert(_ alert: StockSageAlert, held: AggregatedHolding?) async {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.kind.rawValue): \(alert.symbol)"
        // ALERT-HELD-1: display-text only — held context makes the single most decision-relevant
        // push (stop breach / target hit) actionable at a glance without opening the app.
        if let held, held.shares > 0 {
            // Whole shares → %.0f; fractional → adaptive so a tiny crypto lot (0.001 BTC)
            // never renders as "0.00 sh"; em-dash append (reasons end with a period).
            let shares = held.shares == held.shares.rounded() ? String(format: "%.0f", held.shares)
                : (held.shares >= 0.01 ? String(format: "%.2f", held.shares) : String(format: "%.4f", held.shares))
            content.body = "\(alert.reason) — you hold \(shares) sh"
        } else {
            content.body = alert.reason
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func sendPriceAlert(_ alert: PriceAlert, price: Double) async {
        let content = UNMutableNotificationContent()
        // ALERT-FMT-1 (round-3 honesty hunt): was bare `.formatted()` (locale grouping, dropped
        // trailing zeros, full float precision) — the ONE alert surface ALERT-FMT-1 missed when it
        // unified the idea-alert path onto the shared adaptive formatter. Same
        // `StockSageCurrency.adaptivePrice` every board/card/sheet already renders, so this push's
        // numbers match what the user sees everywhere else in the app.
        content.title = "Price alert: \(alert.symbol) \(alert.direction.symbol) \(StockSageCurrency.adaptivePrice(alert.target))"
        content.body = "Now \(StockSageCurrency.adaptivePrice(price))."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func sendAlert(signal: StockSageSignal, market: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(signal.recommendation.rawValue): \(signal.symbol) (\(market))"
        content.body = signal.reason
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Pure decision helpers (testable without the async I/O / @MainActor state above)

    /// Whether a strong-buy/sell push should fire: the recommendation must be NEW or FLIPPED vs
    /// the last one alerted on for this symbol, AND the quote behind it must be fresh — a stale
    /// weekend/holiday close is not actionable until the market reopens (possibly gapped), so it
    /// must never notify. `isFresh: true` reproduces the exact pre-fix dedup-only check.
    nonisolated static func shouldPushStrongSignal(recommendation: StockSageRecommendation,
                                                    lastAlerted: StockSageRecommendation?,
                                                    isFresh: Bool) -> Bool {
        isFresh && recommendation != lastAlerted
    }

    /// Map a tracked idea's advisor action to the long/short side `StockSageAlertDecision.evaluate`
    /// needs to pick the correct stop/target crossing direction — mirrors
    /// `StockSageAdvisor.stopTarget`'s own short definition (`.sell`/`.reduce`) exactly. Only
    /// `evaluate`'s STOP/TARGET branches are consumed from this path (see
    /// `isPushableIdeaAlert`) — the "new strong signal" branch is owned elsewhere in this file
    /// (the price-momentum `StockSageSignalEngine`, a different rule) — so this only needs to
    /// reproduce the correct side, not a faithful `TradeAdvice.Action → StockSageRecommendation`
    /// mapping (`.hold`/`.avoid` have no stop/target anyway — `stopTarget` returns nil for both).
    nonisolated static func ideaAlertRecommendation(for action: TradeAdvice.Action) -> StockSageRecommendation {
        (action == .sell || action == .reduce) ? .strongSell : .strongBuy
    }

    /// Restrict `checkIdeaAlerts` to the events it owns: a stop breach or target hit. A "new
    /// strong signal" / "flip" alert can still fall out of `evaluate` here (this path always
    /// passes `lastAlertedRecommendation: nil`), but that event class belongs to the
    /// price-momentum strong-signal path above — never double-push it from here.
    nonisolated static func isPushableIdeaAlert(_ alert: StockSageAlert?) -> Bool {
        alert?.kind == .stopBreach || alert?.kind == .targetHit
    }
}
