import Foundation
import Combine
import UserNotifications

// MARK: - StockSageMonitor
//
// Reworked from the package's `AutonomousMarketAgent`. Kept the genuinely real
// parts — the cancellable monitoring loop and real `UNUserNotificationCenter`
// strong-signal alerts. Changes from the package:
//   * Namespaced (no collision with Chat A's agent backbone).
//   * Throttle decision uses a real machine-stress read instead of the package's
//     `testingHooks.shouldThrottleForThermal` shim (standalone: ProcessInfo thermal
//     state — see the STANDALONE DEVIATION in start()).
//   * **Dropped the fabricated swarm-spawn / device-migration calls** — the
//     package "spawned" agents into a dictionary and printed fake migration
//     success. Shipping nothing that lies.
//   * Reads symbols from `StockSageStore` (in-memory; sample data until Chat A's
//     live feed replaces it).
@MainActor
final class StockSageMonitor: ObservableObject {
    static let shared = StockSageMonitor()
    init(defaults: UserDefaults = .standard,
         strongSignalSender: (@MainActor (StockSageSignal, String) async -> Bool)? = nil,
         priceAlertCheck: (@MainActor () async -> Void)? = nil) {
        self.defaults = defaults
        self.strongSignalSender = strongSignalSender
        self.priceAlertCheck = priceAlertCheck
        budget = StockSageNotificationBudget(loadingFrom: defaults)
    }

    private let defaults: UserDefaults
    private let strongSignalSender: (@MainActor (StockSageSignal, String) async -> Bool)?

    private let priceAlertCheck: (@MainActor () async -> Void)?

    private var task: Task<Void, Never>?
    @Published private(set) var isRunning = false
    /// iOS foreground polling remains enabled until explicitly opted out. This is not
    /// the Mac's separate launch opt-in, and a transient background stop must not edit it.
    private static let foregroundMonitoringKey = "stocksage.monitor.iosEnabled"
    var foregroundMonitoringEnabled: Bool {
        get { defaults.object(forKey: Self.foregroundMonitoringKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.foregroundMonitoringKey) }
    }

    /// The iOS lifecycle entry point. A supplied starter tests resume decisions without
    /// launching timers, requesting notification permission or touching the shared board.
    func resumeForegroundMonitoring(start: (@MainActor () -> Void)? = nil) {
        guard foregroundMonitoringEnabled else { return }
        if let start { start() } else { try? self.start() }
    }

    /// Rate control for every outbound push (owner report 2026-07-28: "it sends so much").
    /// Loaded from disk, not fresh — see StockSageNotificationBudget's persistence note: an
    /// in-memory-only budget is wiped by every OS app kill, which is exactly when the cold-start
    /// alert burst happens.
    private var budget: StockSageNotificationBudget
    /// Distinct (symbol x reason) pushes the budget withheld since the last delivered one —
    /// rendered in the Signal-alerts panel so suppression is visible rather than silent.
    /// STORED, not computed: `budget` is not `@Published`, so a computed property over it would
    /// never fire `objectWillChange` and the panel would paint once and never update again.
    @Published private(set) var suppressedAlertCount = 0

    /// The ONLY permitted way to ask the budget for permission — it keeps the published count in
    /// step with every refusal, and returns the REASON so callers can apply D1's baseline rule.
    /// Calling `budget.allow`/`budget.refuse` directly reintroduces the silent drop.
    private func budgetRefusal(symbol: String, price: Double) -> StockSageNotificationBudget.Refusal? {
        let refusal = budget.refuse(symbol: symbol, price: price)
        publishSuppressionCount()
        return refusal
    }

    /// The ONLY permitted way to record a DELIVERED push: persists the brakes and clears the
    /// published held-back count in one place.
    private func budgetRecord(symbol: String, price: Double) {
        budget.record(symbol: symbol, price: price)
        budget.save(to: defaults)
        publishSuppressionCount()
    }

    private func publishSuppressionCount() {
        let n = budget.distinctSuppressedCount
        // Write only on change: `@Published` fires objectWillChange on every assignment and
        // MarketsView observes this object, so an unconditional write would re-render the whole
        // Markets tab on every 180s cycle for no visible reason.
        if suppressedAlertCount != n { suppressedAlertCount = n }
    }
    /// Rolling-hour timestamps, so the price-alert path can honour the GLOBAL cap while staying
    /// exempt from the per-symbol hysteresis/cooldown a one-shot alert should not face.
    private var budgetRecentAlerts: [Date] { budget.recentAlerts }
    /// Unread-alert badge (iOS): bumped per ACCEPTED push, cleared when the app foregrounds.
    private var pendingBadge = 0

    func clearBadge() {
        #if os(iOS)
        pendingBadge = 0
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        #endif
    }

    /// Bump-and-set after an accepted push (iOS only — the .badge permission we request
    /// finally does something; review 2026-07-27).
    private func bumpBadge() async {
        #if os(iOS)
        pendingBadge += 1
        try? await UNUserNotificationCenter.current().setBadgeCount(pendingBadge)
        #endif
    }
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
    /// automatically when `ProcessInfo` reports serious/critical thermal state —
    /// see the STANDALONE DEVIATION below). Throws if already running.
    /// `firstCycleDelay` staggers the monitor's first refresh so it doesn't race
    /// the view's onAppear refresh that fires at the same moment on launch.
    /// Cadence raised 45s -> 180s (owner report 2026-07-28). At 45 seconds the monitor
    /// re-evaluated every alert path ~80 times an hour against a keyless endpoint; combined with
    /// the missing hysteresis that WAS the alert spam. US names stream live now, so the poll's
    /// remaining job is Tadawul coverage between refreshes, where 3 minutes is ample.
    func start(interval: TimeInterval = 180, firstCycleDelay: TimeInterval = 20) throws {
        guard !isRunning else { throw MonitorError.alreadyRunning }
        isRunning = true
        requestNotificationPermission()

        task = Task { [weak self] in
            // Stagger the first cycle: the view's .task fires store.refresh() on appear;
            // without this delay both hit Yahoo simultaneously on every cold launch.
            try? await Task.sleep(for: .seconds(Int(firstCycleDelay)))
            while !Task.isCancelled {
                // Research and model assessment require explicit actions. The timer
                // checks only prices the user deliberately saved as alert levels.
                if let check = self?.priceAlertCheck { await check() }
                else { await self?.checkPriceAlerts() }
                guard !Task.isCancelled else { break }
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
        streamCheckTask?.cancel()
        streamCheckTask = nil
        isRunning = false
    }

    deinit {
        task?.cancel()
        streamCheckTask?.cancel()
    }

    /// One evaluation pass: derive a signal per tracked symbol and fire a
    /// notification for strong buy/sell. Returns the strong signals it found
    /// (also used by the unit tests / tool, which don't want notifications) PLUS
    /// how many symbols were actually examined (had a scoreable quote) — review fix
    /// 2026-07-17: the alerts empty state said "mostly Hold" even when an offline
    /// cycle examined zero names; the count lets the UI tell "scanned N, found
    /// none" apart from "couldn't scan at all".
    @discardableResult
    func runCycle(notify: Bool = true) async -> (signals: [StockSageSignal], examined: Int) {
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
        var examined = 0
        for symbol in store.fetchAllSymbols() {
            // CONCURRENCY #2: stop() cancels the loop task, but a cancelled task keeps executing
            // past its awaits (the sendAlert below) unless it checks — without this, alerts kept
            // firing AFTER monitoring was toggled off, and a quick stop→start overlapped two
            // cycles on the same lastAlerted state (double-fired or suppressed pushes).
            guard !Task.isCancelled else { break }
            guard let signal = StockSageSignalEngine.generateSignal(for: symbol) else { continue }
            examined += 1   // scoreable symbol (any recommendation) — see the return doc
            guard signal.recommendation == .strongBuy || signal.recommendation == .strongSell else { continue }
            strong.append(signal)
            // A quote whose latest MARKET timestamp is stale (a weekend/holiday close) is not
            // actionable until the market reopens — possibly gapped — so it must neither push a
            // notification NOR poison `lastAlerted` (that would silently suppress the legitimate
            // alert once a FRESH quote later confirms the same signal).
            let fresh = !symbol.isStale()
            // Fire only when this symbol's strong signal is NEW or has FLIPPED
            // (Strong Buy ⇄ Strong Sell) AND the quote is fresh — not the same alert on every
            // poll, and never off a stale close.
            var delivered = true
            if liveNotify, StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.strongSignalsKey, defaults: defaults),
               Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                        lastAlerted: lastAlerted[signal.symbol],
                                                        isFresh: fresh) {
                // Budget gate (2026-07-28): hysteresis + per-symbol cooldown + rolling hourly cap.
                let alertPrice = symbol.latest?.price ?? 0
                let refusal = budgetRefusal(symbol: signal.symbol, price: alertPrice)
                if refusal == nil {
                    delivered = await sendAlert(signal: signal, market: symbol.market)
                    if delivered { budgetRecord(symbol: signal.symbol, price: alertPrice) }
                } else if !StockSageNotificationBudget.shouldAdvanceBaseline(after: refusal) {
                    // D1: the global cap is capacity, not a verdict on this symbol. Latching the
                    // dedupe here destroyed the signal permanently — an unflipped Strong Buy never
                    // re-queues — so a crash-day alert was lost, not delayed. The cap still bounds
                    // the rate to 8/hour and the per-symbol brakes below still latch.
                    delivered = false
                }
                // A budget REFUSAL is not a delivery failure: `delivered` stays true so the dedup
                // state still advances. Otherwise the same alert re-queues every cycle and floods
                // the instant the cooldown expires — the exact spam this is meant to stop.
            }
            // Review 2026-07-27: latch the dedup state only when any attempted push was ACCEPTED —
            // a denied/failed push must not consume the one-shot (sendPriceAlert's existing rule).
            if fresh, delivered { nowStrong[signal.symbol] = signal.recommendation }
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
        return (strong, examined)
    }

    /// Watchlist-only evaluation: fetch LIVE quotes for just the watchlist tickers and alert
    /// on strong buy/sell — independently of the board's sample/cache flags, then publishes
    /// the fetched prices. It stays honest (it fires only on quotes it just fetched) and
    /// cheap (no 250-name pull). Same NEW-or-flipped dedup as runCycle via `lastAlerted`.
    /// Same examined-count contract as runCycle (review fix 2026-07-17).
    @discardableResult
    func runWatchlistCycle(_ watch: [String], notify: Bool = true) async -> (signals: [StockSageSignal], examined: Int) {
        let quotes = await StockSageQuoteService.fetchQuotes(for: watch)
        let result = await evaluateWatchlistQuotes(watch, quotes: quotes, notify: notify)
        // Publish the freshly-fetched watchlist prices to the board so it reflects live data
        // for the names the user is focused on (watchlist-only stops the full auto-refresh).
        StockSageStore.shared.mergeLiveQuotes(quotes)
        if notify, !Task.isCancelled {
            await checkPriceAlerts()
            await checkIdeaAlerts(prices: result.freshPrices)
        }
        return (result.signals, result.examined)
    }

    /// The production watchlist loop, after fetching and before board publication. Keeping
    /// delivery and its dedupe commit together makes failed-enqueue retries testable without
    /// a live quote request, shared board mutations or real system notifications.
    func evaluateWatchlistQuotes(_ watch: [String], quotes: [String: StockSageQuoteService.LiveQuote],
                                now: Date = Date(), notify: Bool = true) async
        -> (signals: [StockSageSignal], examined: Int, freshPrices: [String: Double]) {
        var strong: [StockSageSignal] = []
        var nowStrong: [String: StockSageRecommendation] = [:]
        var freshPrices: [String: Double] = [:]
        var examined = 0
        for ticker in watch {
            // CONCURRENCY #2: same cooperative-cancellation bail as runCycle.
            guard !Task.isCancelled else { break }
            guard let q = quotes[ticker.uppercased()], q.price > 0, q.previousClose > 0 else { continue }
            examined += 1   // ticker had a usable quote this cycle
            let sym = StockSageSymbol(symbol: ticker, market: "★ My watchlist", quotes: [
                StockSageQuote(price: q.previousClose, previousPrice: q.previousClose,
                               time: Date(timeIntervalSinceNow: -86_400)),
                // Carry the real MARKET time (was omitted here) so this synthetic symbol's own
                // `isStale()` can flag a days-old weekend/holiday close, same as the board path.
                StockSageQuote(price: q.price, previousPrice: q.previousClose, marketTime: q.marketTime,
                               massiveTradeSequence: q.massiveTradeSequence, priceSource: q.priceSource,
                               previousCloseSource: q.previousCloseSource, previousCloseQuoteTime: q.previousCloseQuoteTime),
            ])
            // Collect the fresh price for the idea stop/target check below regardless of
            // whether THIS ticker's momentum signal is currently strong.
            let fresh = !sym.isStale(asOf: now)
            if fresh { freshPrices[ticker.uppercased()] = q.price }
            guard let signal = StockSageSignalEngine.generateSignal(for: sym) else { continue }
            guard signal.recommendation == .strongBuy || signal.recommendation == .strongSell else { continue }
            strong.append(signal)
            var delivered = true
            // FIX (second review, 2026-07-28): this path checked NEITHER the strong-signals
            // preference NOR the budget, so in watchlist-only mode the Settings switch did
            // nothing and every brake was bypassed. runCycle gated both; this one never did.
            if notify, StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.strongSignalsKey, defaults: defaults),
               Self.shouldPushStrongSignal(recommendation: signal.recommendation,
                                                    lastAlerted: lastAlerted[signal.symbol],
                                                    isFresh: fresh) {
                let px = q.price
                let refusal = budgetRefusal(symbol: signal.symbol, price: px)
                if refusal == nil {
                    delivered = await sendAlert(signal: signal, market: sym.market)
                    if delivered { budgetRecord(symbol: signal.symbol, price: px) }
                } else if !StockSageNotificationBudget.shouldAdvanceBaseline(after: refusal) {
                    delivered = false   // D1, same rule as runCycle
                }
            }
            // Match runCycle: failed enqueue keeps the previous recommendation retryable;
            // deliberate mute/budget suppression still advances dedupe to prevent a burst.
            if fresh, delivered { nowStrong[signal.symbol] = signal.recommendation }
        }
        if notify, !Task.isCancelled { for (s, r) in nowStrong { lastAlerted[s] = r } }
        return (strong, examined, freshPrices)
    }

    /// Check user-set price alerts against FRESHLY-FETCHED live prices (never the board's
    /// last-good values — a failed in-session refresh can leave those stale while the live/cache
    /// flags don't change), so a one-shot alert can't fire on stale/sample data. Armed alerts are
    /// few (user-set), so re-fetching just those each cycle is cheap. A freshly-fetched quote can
    /// STILL be a days-old close (Yahoo returns the last close over weekends/holidays), so we also
    /// drop any quote whose market timestamp is materially old — a level reached only at a stale
    /// close won't fire a push while the market is shut and the owner can't act.
    private func checkPriceAlerts() async {
        await checkPriceAlerts(
            currentAlerts: { StockSageStore.shared.priceAlertsForMonitoring() },
            fetchQuotes: { await StockSageQuoteService.fetchQuotes(for: $0) },
            enqueue: { await self.sendPriceAlert($0, price: $1) },
            markTriggered: { StockSageStore.shared.markPriceAlertsTriggered($0) },
            fetchDayVolumes: { await Self.fetchDayVolumes(for: $0) })
    }

    /// The actual fetch/check/send path with live state read at call time. Closures keep the
    /// asynchronous boundaries replayable without loading the shared board or sending pushes.
    /// Price alerts read `fetchQuotes`; day-volume alerts read only `fetchDayVolumes` (REST `day.v`).
    /// `now` drives only the quote-staleness filter; the hourly cap stays on the wall clock.
    func checkPriceAlerts(
        currentAlerts: @MainActor () -> [PriceAlert],
        fetchQuotes: @MainActor ([String]) async -> [String: StockSageQuoteService.LiveQuote],
        enqueue: @MainActor (PriceAlert, Double) async -> Bool,
        markTriggered: @MainActor ([UUID]) -> Void,
        fetchDayVolumes: @MainActor ([String]) async -> [String: Double] = { _ in [:] },
        now: @MainActor () -> Date = { Date() }
    ) async {
        // Muted type: check nothing, consume nothing — the user's armed alerts stay armed.
        guard StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.priceAlertsKey, defaults: defaults) else { return }
        // SINGLE-FLIGHT across the 180 s loop and stream-triggered checks. Two overlapping checks
        // could each push the same one-shot alert before either latched it — the double-push
        // described below. A check that finds another in flight skips; the next tick or cycle retries.
        guard !priceAlertCheckInFlight else { return }
        priceAlertCheckInFlight = true
        defer { priceAlertCheckInFlight = false }
        let armed = currentAlerts().filter { $0.isArmed }
        // One process owns both delivery and its persisted one-shot latch. Checking only
        // when saving would let another copy deliver the same alert before its write fails.
        guard (try? StockSageRecordWriter.require(defaults)) != nil, !armed.isEmpty else { return }
        let priceSymbols = Set(armed.filter { $0.resolvedMetric == .price }.map { $0.symbol })
        let volumeSymbols = Set(armed.filter { $0.resolvedMetric == .dayVolume }.map { $0.symbol })
        var q: [String: StockSageQuoteService.LiveQuote] = [:]
        if !priceSymbols.isEmpty { q = await fetchQuotes(Array(priceSymbols)) }
        var volumes: [String: Double] = [:]
        if !volumeSymbols.isEmpty, !Task.isCancelled { volumes = await fetchDayVolumes(Array(volumeSymbols)) }
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
        let checkedAt = now()
        for (k, v) in q where v.price > 0 && !StockSageQuoteFreshness.isStale(symbol: k, marketTime: v.marketTime, asOf: checkedAt) {
            prices[k.uppercased()] = v.price
        }
        var confirmedVolumes: [String: Double] = [:]
        for (k, v) in volumes where v.isFinite && v >= 0 { confirmedVolumes[k.uppercased()] = v }
        let fired = StockSagePriceAlertEngine.newlyTriggered(armed, prices: prices, volumes: confirmedVolumes)
        guard !fired.isEmpty else { return }
        // Review fix 2026-07-17: latch ONLY alerts whose push was ACCEPTED for delivery.
        // The no-guard-between-push-and-latch invariant above still holds (no cancellation
        // check is interposed) — but with notifications denied/blocked, `add` throws, and
        // the old unconditional latch consumed the one-shot on a push that never left:
        // the row read "triggered" while the owner heard nothing. A failed delivery now
        // leaves the alert ARMED; the standing condition re-attempts next cycle, which is
        // correct — the owner has not yet been notified — and delivers the moment
        // permission returns. The latch remains the truthful record of pushes that
        // actually went out.
        for a in fired {
            guard !Task.isCancelled,
                  StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.priceAlertsKey, defaults: defaults) else { break }
            // Fetching and every earlier enqueue can suspend this cycle. Require the same
            // still-armed definition/identity, not just membership in the captured array.
            guard currentAlerts().contains(a) else { continue }
            // A user-set price alert is a ONE-SHOT the owner explicitly armed and it disarms on
            // trigger, so it is exempt from hysteresis and cooldown. It still respects the GLOBAL
            // hourly cap so a market-wide move cannot produce a flood.
            // The same uppercased, metric-specific lookup as StockSagePriceAlertEngine.newlyTriggered.
            // Never fall back to `a.target`: that once PUSHED THE ALERT'S OWN TARGET as the observed
            // price, a fabricated market observation — the worst failure this file can produce.
            guard let px = StockSagePriceAlertEngine.observed(a, prices: prices, volumes: confirmedVolumes) else { continue }
            guard StockSageNotificationBudget.countWithinHour(budget.recentAlerts, now: Date())
                    < StockSageNotificationBudget.hourlyCap else { break }
            if await enqueue(a, px) {
                // A volume is not a price: 0 records the push without seeding price hysteresis.
                budgetRecord(symbol: a.symbol, price: a.resolvedMetric == .price ? px : 0)
                markTriggered([a.id]) // Record accepted delivery before the next suspension.
            }
        }
    }

    // MARK: - Stream-triggered price alerts

    /// At most one stream-triggered alert check per symbol per this many seconds. The 180 s loop
    /// still runs; the stream only shortens latency for armed symbols that are trading.
    nonisolated static let streamCheckInterval: TimeInterval = 5
    /// A stream-nominated day-volume alert costs one REST snapshot to confirm, so each symbol is
    /// confirmed at most this often. Streamed per-minute volume is provisional and never fires.
    nonisolated static let volumeConfirmInterval: TimeInterval = 60
    /// A REST `day.v` confirms only when its `lastTrade.t` is a regular-session print this recent.
    nonisolated static let volumeConfirmMaximumTradeAge: TimeInterval = 15 * 60

    /// Shared by EVERY price-alert check (see the single-flight note in `checkPriceAlerts`).
    private(set) var priceAlertCheckInFlight = false
    private var streamCheckTask: Task<Void, Never>?
    /// Latest alertable trade per ARMED symbol only, so the whole-market feed is never retained.
    private var streamedTicks: [String: StockSageLiveStream.Tick] = [:]
    private var lastStreamCheck: [String: Date] = [:]
    private var lastVolumeConfirm: [String: Date] = [:]

    /// Live-tick hook (`StockSageStore.applyLiveTicks`). Runs only while monitoring is on — the
    /// same switch that owns the 180 s loop — and spawns a check only when an armed symbol ticks.
    func noteStreamedTicks(_ ticks: [String: StockSageLiveStream.Tick], now: Date = Date()) {
        guard isRunning, !ticks.isEmpty else { return }
        let due = nominateStreamedTicks(ticks, armed: StockSageStore.shared.priceAlerts, now: now)
        guard !due.isEmpty, !priceAlertCheckInFlight else { return }
        // A spawned check that has not started yet is superseded; one in flight was excluded above.
        streamCheckTask?.cancel()
        streamCheckTask = Task { [weak self] in await self?.checkStreamedPriceAlerts() }
    }

    /// Record alertable trades for armed symbols and return the symbols whose throttle allows a check.
    func nominateStreamedTicks(_ ticks: [String: StockSageLiveStream.Tick], armed: [PriceAlert],
                               now: Date) -> [String] {
        let symbols = Set(armed.filter { $0.isArmed }.map { $0.symbol.uppercased() })
        streamedTicks = streamedTicks.filter { symbols.contains($0.key) }
        var due: [String] = []
        for symbol in symbols.sorted() {
            guard let tick = ticks[symbol], Self.isAlertableStreamTrade(tick, now: now) else { continue }
            streamedTicks[symbol] = tick
            if let last = lastStreamCheck[symbol], now.timeIntervalSince(last) < Self.streamCheckInterval { continue }
            lastStreamCheck[symbol] = now
            due.append(symbol)
        }
        return due
    }

    /// Regular-session default (owner decision pending): a streamed trade can fire an alert only
    /// when it is a live observation, priced, not Form T (condition 12) and inside the scheduled
    /// NASDAQ regular session. Pre/post-market prints never fire from the stream.
    nonisolated static func isAlertableStreamTrade(_ tick: StockSageLiveStream.Tick, now: Date) -> Bool {
        tick.price > 0 && tick.price.isFinite
            && StockSageLiveStream.isLiveObservation(tick.timestamp, at: now)
            && isRegularSessionPrint(at: tick.timestamp, conditions: tick.conditions)
    }

    nonisolated static func isRegularSessionPrint(at time: Date, conditions: [Int64]?) -> Bool {
        !(conditions ?? []).contains(12)
            && StockSageMarketHours.nasdaqState(at: time, calendar: Calendar(identifier: .gregorian)).phase == .open
    }

    private func checkStreamedPriceAlerts() async {
        await checkStreamedPriceAlerts(
            currentAlerts: { StockSageStore.shared.priceAlertsForMonitoring() },
            confirmDayVolumes: { await Self.fetchDayVolumes(for: $0) },
            enqueue: { await self.sendPriceAlert($0, price: $1) },
            markTriggered: { StockSageStore.shared.markPriceAlertsTriggered($0) })
    }

    /// The stream-triggered check: the same `checkPriceAlerts` rules (single-flight, still-armed
    /// identity, hourly cap, latch only after accepted delivery), with prices from recorded live
    /// trades instead of a REST quote fetch. A day-volume alert is nominated by a live trade and
    /// fires only on a REST-confirmed `day.v`.
    func checkStreamedPriceAlerts(
        currentAlerts: @MainActor () -> [PriceAlert],
        confirmDayVolumes: @MainActor ([String]) async -> [String: Double],
        enqueue: @MainActor (PriceAlert, Double) async -> Bool,
        markTriggered: @MainActor ([UUID]) -> Void,
        now: @MainActor () -> Date = { Date() }
    ) async {
        await checkPriceAlerts(
            currentAlerts: currentAlerts,
            fetchQuotes: { symbols in self.streamedQuotes(for: symbols, now: now()) },
            enqueue: enqueue,
            markTriggered: markTriggered,
            fetchDayVolumes: { symbols in
                let nominated = self.dueVolumeConfirmations(symbols, now: now())
                if nominated.isEmpty { return [:] }
                return await confirmDayVolumes(nominated)
            },
            now: now)
    }

    private func streamedQuotes(for symbols: [String], now: Date) -> [String: StockSageQuoteService.LiveQuote] {
        var quotes: [String: StockSageQuoteService.LiveQuote] = [:]
        for symbol in symbols {
            let key = symbol.uppercased()
            // Re-check at read time: a trade recorded as live may have aged out before this check ran.
            guard let tick = streamedTicks[key], Self.isAlertableStreamTrade(tick, now: now) else { continue }
            quotes[key] = .init(symbol: key, price: tick.price, previousClose: tick.price, marketTime: tick.timestamp,
                                massiveTradeSequence: tick.sequence, priceSource: .massiveSIP)
        }
        return quotes
    }

    private func dueVolumeConfirmations(_ symbols: [String], now: Date) -> [String] {
        var due: [String] = []
        for symbol in symbols {
            let key = symbol.uppercased()
            guard let tick = streamedTicks[key], Self.isAlertableStreamTrade(tick, now: now) else { continue }
            if let last = lastVolumeConfirm[key], now.timeIntervalSince(last) < Self.volumeConfirmInterval { continue }
            lastVolumeConfirm[key] = now
            due.append(key)
        }
        return due
    }

    /// REST `day.v` per requested ticker, parsed by `parseDayVolumes`. Same request as
    /// `StockSageMassive.fetchSnapshots`: pinned host, Bearer header, 2 MB cap, access generation.
    static func fetchDayVolumes(for symbols: [String], access: StockSageMassive.Access = .init(),
                                transport: StockSageMassive.Transport? = nil) async -> [String: Double] {
        let covered = symbols.filter(StockSageMassive.covers)
        guard access.allowed(), !Task.isCancelled, !covered.isEmpty else { return [:] }
        let captured = access.capture()
        guard !captured.key.isEmpty, captured.isCurrent() else { return [:] }
        var out: [String: Double] = [:]
        for chunk in StockSageMassive.chunks(covered) {
            guard let request = StockSageMassive.request(for: chunk, key: captured.key) else { continue }
            let result = try? await StockSageMassive.response(for: request,
                maximumBytes: StockSageMassive.snapshotMaximumBytes, transport: transport)
            guard captured.isCurrent() else { return [:] }
            guard let (data, response) = result, response.statusCode == 200 else { continue }
            out.merge(parseDayVolumes(data, requested: chunk, now: Date())) { _, new in new }
        }
        return captured.isCurrent() ? out : [:]
    }

    /// `day.v` for requested tickers whose `lastTrade.t` is a regular-session print no older than
    /// `volumeConfirmMaximumTradeAge`. Every field is optional; a missing one yields no entry.
    nonisolated static func parseDayVolumes(_ data: Data, requested: [String], now: Date) -> [String: Double] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["tickers"] as? [[String: Any]] else { return [:] }
        let wanted = Set(requested.map { $0.uppercased() })
        var volumes: [String: Double] = [:]
        for row in rows {
            guard let ticker = row["ticker"] as? String, wanted.contains(ticker),
                  let volume = StockSageMassive.finite((row["day"] as? [String: Any])?["v"]), volume >= 0,
                  let ns = StockSageMassive.int64((row["lastTrade"] as? [String: Any])?["t"]) else { continue }
            let traded = StockSageMassive.date(fromNanoseconds: ns)
            guard (0...volumeConfirmMaximumTradeAge).contains(now.timeIntervalSince(traded)),
                  isRegularSessionPrint(at: traded, conditions: nil) else { continue }
            volumes[ticker] = volume
        }
        return volumes
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
        await checkIdeaAlerts(prices: prices, ideas: StockSageStore.shared.ideas,
            holdings: StockSagePortfolio.holdingBySymbol(in: StockSagePortfolio.shared.positions),
            send: { [weak self] alert, held in await self?.sendIdeaAlert(alert, held: held) ?? false })
    }

    /// Inject only source snapshots and notification delivery, retaining the production loop.
    func checkIdeaAlerts(prices: [String: Double], ideas: [StockSageIdea],
                         holdings: [String: AggregatedHolding],
                         send: (StockSageAlert, AggregatedHolding?) async -> Bool) async {
        guard !prices.isEmpty else { return }
        // Same board every other idea-derived surface draws from (the Sharia screen that used
        // to filter this was removed 2026-07-28).
        guard !ideas.isEmpty else { return }
        // ALERT-HELD-1: looked up ONCE per cycle (not per idea) — a stop-breach/target-hit push
        // is the single most decision-relevant alert, so it should say whether the owner actually
        // has a position on. Idea alerts ONLY — sendPriceAlert (user-set price alerts) is untouched.
        for idea in ideas {
            // CONCURRENCY #2 (review 2026-07-27): same cooperative-cancellation guard as the
            // strong-signal and price-alert loops — stop() must halt idea pushes mid-batch too.
            guard !Task.isCancelled else { break }
            guard let price = prices[idea.symbol.uppercased()], price > 0 else { continue }
            // Muted type: keep the crossing baseline advancing (else re-enabling would fire a
            // flood of stale crossings), just never push.
            guard StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.ideaAlertsKey, defaults: defaults) else {
                lastIdeaPrice[idea.symbol] = price; continue
            }
            // First sighting this session: seed the baseline rather than claim a crossing that
            // may not be real (mirrors `lastAlerted`'s "no alert on first appearance" rule).
            let priorPrice = lastIdeaPrice[idea.symbol] ?? price
            guard let alert = StockSageAlertDecision.evaluate(
                symbol: idea.symbol,
                recommendation: Self.ideaAlertRecommendation(for: idea.advice.action),
                price: price, priorPrice: priorPrice,
                stop: idea.advice.stopPrice, target: idea.advice.targetPrice,
                // Thread the REAL dedup state (was hardcoded nil — inert today because
                // isPushableIdeaAlert only passes stop/target alerts, but a latent spam trap
                // if that filter is ever relaxed to strong-signal/flip alerts).
                lastAlertedRecommendation: lastAlerted[idea.symbol]
            ), Self.isPushableIdeaAlert(alert) else { lastIdeaPrice[idea.symbol] = price; continue }
            // Review 2026-07-27: advance the crossing baseline only when the push was ACCEPTED —
            // a failed push keeps the prior baseline so the same crossing re-fires next cycle.
            if let refusal = budgetRefusal(symbol: idea.symbol, price: price) {
                // A PER-SYMBOL brake advances the baseline so this crossing is not re-detected and
                // queued every cycle. D1: a global-cap refusal must NOT — advancing moves
                // `priorPrice` to the far side of the stop, so StockSageAlertDecision.evaluate can
                // never see the breach again and the owner is never told his stop was hit.
                if StockSageNotificationBudget.shouldAdvanceBaseline(after: refusal) {
                    lastIdeaPrice[idea.symbol] = price
                }
                continue
            }
            if await send(alert, holdings[idea.symbol.uppercased()]) {
                lastIdeaPrice[idea.symbol] = price
                budgetRecord(symbol: idea.symbol, price: price)
            }
        }
    }

    private func sendIdeaAlert(_ alert: StockSageAlert, held: AggregatedHolding?) async -> Bool {
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
        content.userInfo = ["symbol": alert.symbol]   // tap deep-link (2026-07-27)
        let delivered = await StockSageNotificationDelivery.enqueue(content,
            event: .forIdea(alert.kind), brief: "\(alert.kind.rawValue) alert for \(alert.symbol). Review the details.")
        if delivered { await bumpBadge() }
        return delivered
    }

    /// Returns whether the push was ACCEPTED for delivery — the caller latches the
    /// one-shot only on true (review fix 2026-07-17: `try?` swallowed the
    /// notifications-denied error and the alert consumed its shot on nothing).
    private func sendPriceAlert(_ alert: PriceAlert, price: Double) async -> Bool {
        let content = UNMutableNotificationContent()
        if alert.resolvedMetric == .dayVolume {
            content.title = "Volume alert: \(alert.symbol) \(alert.levelText)"
            content.userInfo = ["symbol": alert.symbol]
            content.body = "Day volume now \(PriceAlert.volumeText(price)) (Massive snapshot)."
            let delivered = await StockSageNotificationDelivery.enqueue(content, event: .price,
                brief: "Volume alert for \(alert.symbol). Your saved level was reached.")
            if delivered { await bumpBadge() }
            return delivered
        }
        // ALERT-FMT-1 (round-3 honesty hunt): was bare `.formatted()` (locale grouping, dropped
        // trailing zeros, full float precision) — the ONE alert surface ALERT-FMT-1 missed when it
        // unified the idea-alert path onto the shared adaptive formatter. Same
        // `StockSageCurrency.adaptivePrice` every board/card/sheet already renders, so this push's
        // numbers match what the user sees everywhere else in the app.
        content.title = "Price alert: \(alert.symbol) \(alert.direction.symbol) \(StockSageCurrency.adaptivePrice(alert.target))"
        content.userInfo = ["symbol": alert.symbol]   // tap deep-link (2026-07-27)
        content.body = "Now \(StockSageCurrency.adaptivePrice(price))."
        let delivered = await StockSageNotificationDelivery.enqueue(content, event: .price,
            brief: "Price alert for \(alert.symbol). Your saved level was reached.")
        if delivered { await bumpBadge() }
        return delivered
    }

    /// Returns whether the push was ACCEPTED for delivery — runCycle latches dedup only on true.
    private func sendAlert(signal: StockSageSignal, market: String) async -> Bool {
        if let strongSignalSender { return await strongSignalSender(signal, market) }
        let content = UNMutableNotificationContent()
        content.title = "\(signal.recommendation.rawValue): \(signal.symbol) (\(market))"
        content.body = signal.reason
        content.userInfo = ["symbol": signal.symbol]   // tap deep-link (2026-07-27)
        let delivered = await StockSageNotificationDelivery.enqueue(content,
            event: .forRecommendation(signal.recommendation),
            brief: "\(signal.recommendation.rawValue) alert for \(signal.symbol). Research only. No order placed.")
        if delivered { await bumpBadge() }
        return delivered
    }

    private func requestNotificationPermission() {
        // Native loop fixtures must not change or prompt for the test host's OS permission.
        guard !StockSageStore.isRunningTests else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("⚠️ StockSage: Failed to request notification authorization: \(error)")
            } else if !granted {
                print("⚠️ StockSage: Notification permission denied - alerts will not appear")
            }
        }
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


/// Per-type notification switches (owner directive 2026-07-27: "not for everything —
/// control from Settings"). Absent key = ENABLED, so existing installs keep behavior.
/// Keys are shared with IOSSettingsSheet's @AppStorage bindings.
enum StockSageNotifyPrefs {
    static let strongSignalsKey = "stocksage.notify.strongSignals"
    static let ideaAlertsKey = "stocksage.notify.ideaAlerts"
    static let priceAlertsKey = "stocksage.notify.priceAlerts"

    static func enabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
