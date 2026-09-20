import Foundation
import Combine
import Synchronization

/// One ranked trade idea: a symbol joined with the advisor's verdict on its real
/// candle history. What the "Ideas" board renders.
struct StockSageIdea: Sendable, Equatable, Identifiable {
    let symbol: String
    let market: String
    let price: Double
    let advice: TradeAdvice
    /// Downsampled recent closes for the inline sparkline (newest last).
    let spark: [Double]
    /// Typical TRUE one-day move (avg |Δ| of the raw daily closes), if known. The `spark` is
    /// down-sampled (~2 calendar days/point), so deriving a daily move from it doubles velocity;
    /// this carries the un-downsampled value for the velocity/hold estimate. nil ⇒ fall back to spark.
    let dailyMove: Double?
    /// Annualized realized volatility from the RAW daily closes (not the down-sampled spark, which
    /// would overstate it). Lets the allocator vol-target like the advisor does. nil ⇒ no shrink.
    let realizedVol: Double?
    var id: String { symbol }

    /// Per-symbol vol regime computed from the raw close history. nil when history is too short
    /// (<273 bars). The `sizingMultiplier` is applied by StockSageCapitalAllocator after Kelly sizing.
    let volRegime: VolRegime?

    /// When this idea's advice was computed against a live quote — nil for ideas built without
    /// one (tests, older persisted state). Stop/target are fixed numbers against THAT quote;
    /// viewing the idea later, the market has moved and R:R has silently drifted. nil ⇒ no
    /// "computed at" note is shown (HONESTY_FLOOR: only claim a timestamp we actually have).
    let generatedAt: Date?

    /// 0–1 read on whether SHORT-HORIZON momentum is genuinely hot right now, as computed by
    /// `StockSageExpectedValue.momentumQuality(for:closes:)` from the RAW daily close history.
    /// nil ⇒ history was too short for ANY of the three internal signals (the spark is down-sampled
    /// and cannot substitute here). NEVER defaults to a number — nil means unknown, not neutral.
    let momentumQuality: Double?

    /// Whether the LATEST close sits at the running high/low of the RAW (un-downsampled) recent
    /// window — the "At N-day high/low" chip's honesty fix (L1, 2026-07-07): the chip used to
    /// call `SparkSeries.extreme(spark)` on the DOWNSAMPLED spark array (≤32 of up to 63 points),
    /// so a true high/low on a day the downsample skipped could be missed, silently making the
    /// claim false vs the actual last-63-day window. Computed here from the RAW closes so the
    /// displayed chip is genuinely honest about the full window it claims. nil means
    /// not computed (default init); buildIdeas always sets a value — `.neither` when the
    /// window has fewer than 2 closes.
    let recentExtreme: SparkSeries.Extreme?
    /// The actual window length `recentExtreme` was computed over — `min(closes.count, 63)`.
    /// Carried alongside `recentExtreme` so the chip can label "At N-day high/low" with the
    /// TRUE N (days, not downsampled bars) rather than assuming a fixed 63.
    let recentExtremeSpan: Int?

    /// The price history's OWN last-bar date (`history.dates.last`) — distinct from `generatedAt`,
    /// which is `Date()` (build wall-clock time) EVEN when the price came from `cachedHistories`
    /// (same-UTC-day cache reuse — `partitionByCacheFreshness`/`isCacheFreshForToday`, a deliberate
    /// 429-avoidance POLICY, untouched here). On a weekend/offline that cache's last bar can be days
    /// old while `generatedAt` still reads "just now", so a cache-served idea rendered as a fresh
    /// live quote (honesty-floor gap). nil ⇒ unknown (older/test-built ideas with no history) —
    /// never flagged stale off missing data (HONESTY_FLOOR: unknown renders nothing). Purely a
    /// freshness LABEL — does not change the cache-reuse policy or any stop/target/RR format.
    let priceAsOf: Date?
    /// Massive trade sequence attached to priceAsOf, never to the independent NBBO clock.
    let massiveTradeSequence: Int64?
    let priceSource: StockSagePriceSource?
    /// Ephemeral authenticated cost input, never persisted as historical market evidence.
    private(set) var nbbo: StockSageNBBO? = nil

    nonisolated func withNBBO(_ quote: StockSageNBBO?) -> Self {
        var copy = self
        copy.nbbo = quote?.matches(symbol) == true ? quote : nil
        return copy
    }

    nonisolated init(symbol: String, market: String, price: Double, advice: TradeAdvice,
                     spark: [Double], dailyMove: Double? = nil, realizedVol: Double? = nil,
                     volRegime: VolRegime? = nil, generatedAt: Date? = nil,
                     momentumQuality: Double? = nil, recentExtreme: SparkSeries.Extreme? = nil,
                     recentExtremeSpan: Int? = nil, priceAsOf: Date? = nil, massiveTradeSequence: Int64? = nil,
                     priceSource: StockSagePriceSource? = nil) {
        self.symbol = symbol; self.market = market; self.price = price
        self.advice = advice; self.spark = spark; self.dailyMove = dailyMove
        self.realizedVol = realizedVol; self.volRegime = volRegime; self.generatedAt = generatedAt
        self.momentumQuality = momentumQuality; self.recentExtreme = recentExtreme
        self.recentExtremeSpan = recentExtremeSpan; self.priceAsOf = priceAsOf
        self.massiveTradeSequence = massiveTradeSequence
        self.priceSource = priceSource
    }

    /// Same idea with a FRESHER market price/timestamp (stale self-heal, 2026-07-27). The
    /// advice (stop/target/EV, computed at scan time) is deliberately untouched — those are
    /// fixed LEVELS; `price`/`priceAsOf` are "where the market is now", which is exactly what
    /// the live board and the monitor's crossing checks already treat them as.
    nonisolated func withLivePrice(_ newPrice: Double, asOf: Date?, massiveTradeSequence: Int64? = nil,
                                  priceSource: StockSagePriceSource? = nil) -> StockSageIdea {
        StockSageIdea(symbol: symbol, market: market, price: newPrice, advice: advice,
                      spark: spark, dailyMove: dailyMove, realizedVol: realizedVol,
                      volRegime: volRegime, generatedAt: generatedAt,
                      momentumQuality: momentumQuality, recentExtreme: recentExtreme,
                      recentExtremeSpan: recentExtremeSpan, priceAsOf: asOf,
                      massiveTradeSequence: massiveTradeSequence, priceSource: priceSource).withNBBO(nbbo)
    }
}

// MARK: - StockSageStore
//
// In-memory store for tracked symbols. Reworked from the package's SwiftData
// `MarketStore` (renamed to avoid colliding with Chat A's `MarketStore` in
// `Views/MarketsStub.swift`, and de-SwiftData'd to drop the force-try container
// init).
//
// **Data source:** the StockSage v32 package shipped NO live price feed, so this
// store starts from a small, clearly-labeled SAMPLE set purely so the signal /
// briefing / monitor layers are demonstrable end-to-end. When Chat A's Phase-2
// Yahoo Finance feed lands, replace `seedSampleData()` with real fetches — every
// downstream layer is data-source-agnostic and just consumes `StockSageSymbol`s.
@MainActor
final class StockSageStore: ObservableObject {
    static let shared = StockSageStore()
    private let defaults: UserDefaults
    private let heldSymbols: @MainActor () -> [String]
    private let journalTrades: @MainActor () -> [TradeRecord]

    @Published private(set) var symbols: [StockSageSymbol] = []
    /// P3 (2026-07-28 review): uppercased-symbol → index into `symbols`. Rebuilt only by the
    /// shape-changing writers (loadCachedQuotes / addSymbol / removeSymbol / replaceAll /
    /// seedSampleData / first tracked quote); ordinary per-row replacements preserve the index.
    private(set) var symbolIndex: [String: Int] = [:]
    private func rebuildSymbolIndex() {
        symbolIndex = Dictionary(symbols.enumerated().map { ($0.element.symbol.uppercased(), $0.offset) },
                                 uniquingKeysWith: { a, _ in a })
    }
    /// O(1) board price lookup — replaces the per-row `store.symbols.first { … }` scan
    /// (MarketsView.currentPrice), which was O(n) with two String allocations per element and
    /// was called once per ForEach row.
    func latestPrice(_ symbol: String) -> Double? {
        latestQuote(symbol)?.price
    }

    /// The matching price/clock/source observation, without a second linear lookup.
    func latestQuote(_ symbol: String) -> StockSageQuote? {
        symbolIndex[symbol.uppercased()].flatMap { symbols[$0].latest }
    }

    @Published private(set) var journalSplits: [String: StockSageMassiveSplits.Snapshot] = [:]
    private var journalSplitGeneration = UUID()
    private var journalSplitAttempts: [String: (since: Date, at: Date, credentialRevision: String?, policyRevision: String?)] = [:]

    /// One serial sweep for open positions only. The view's native task cancellation plus
    /// generation guard prevents an obsolete sweep publishing after an edit/removal.
    func refreshJournalSplits(_ trades: [TradeRecord]) async {
        let generation = UUID()
        journalSplitGeneration = generation
        let now = Date()
        let access = StockSageMassive.Access()
        let captured = access.capture()
        let credentialRevision = access.credentialRevision()
        let policyRevision = access.policyRevision()
        let requests = Dictionary(trades.filter { $0.isOpen && StockSageMassive.covers($0.symbol) }
            .map { ($0.symbol.uppercased(), $0.openedAt) }, uniquingKeysWith: min)
        let retained = journalSplits.filter { requests[$0.key] != nil }
        if retained != journalSplits { journalSplits = retained }
        journalSplitAttempts = journalSplitAttempts.filter { requests[$0.key] != nil }
        guard captured.isCurrent(), ToolPolicy.isExternalAllowed, !Task.isCancelled else { return }
        for symbol in requests.keys.sorted() {
            guard generation == journalSplitGeneration, captured.isCurrent(), !Task.isCancelled, let since = requests[symbol] else { return }
            if journalSplits[symbol]?.covers(since: since, now: now) == true { continue }
            // Failure is NOT a no-split answer. Bound transient retries without blocking an
            // earlier newly logged position whose wider date range has not been requested.
            if let attempt = journalSplitAttempts[symbol], attempt.since <= since,
               attempt.credentialRevision == credentialRevision, attempt.policyRevision == policyRevision,
               now.timeIntervalSince(attempt.at) >= 0, now.timeIntervalSince(attempt.at) < 60 { continue }
            let snapshot = await StockSageMassiveSplits.fetch(symbol: symbol, since: since, now: now, access: access)
            guard generation == journalSplitGeneration, captured.isCurrent(), !Task.isCancelled else { return }
            if let snapshot { journalSplits[symbol] = snapshot }
            else { journalSplitAttempts[symbol] = (since, Date(), credentialRevision, policyRevision) }
        }
    }

    /// Uses the SAME board observation as latestPrice, never an unrelated cached bar clock.
    func journalBasis(_ trade: TradeRecord, now: Date = Date()) -> StockSageMassiveSplits.Basis {
        guard !isSampleData, let index = symbolIndex[trade.symbol.uppercased()],
              let quote = symbols[index].latest, quote.priceSource != .sample,
              quote.price > 0, quote.price.isFinite else { return .unavailable("no real priced observation") }
        return StockSageMassiveSplits.comparison(trade, snapshot: journalSplits[trade.symbol.uppercased()],
                                                markAsOf: quote.marketTime, now: now)
    }
    /// O(1) board-membership check — replaces the per-row linear `contains` scan next to
    /// `priceAlertRow`.
    func isOnBoard(_ symbol: String) -> Bool { symbolIndex[symbol.uppercased()] != nil }
    /// OWNER DIRECTIVE (2026-07-16, Tadawul+NASDAQ restriction): FX pairs left the universe, but
    /// the SAR→USD rate still powers every .SR honesty correction (holdingValue, pctOfAccountUSD,
    /// USD portfolio totals). Fetched as INFRA — direct-by-symbol like the regime's ^VIX — never
    /// a feed row or idea. Preserve its market time/source, including on failed refreshes.
    /// Old/undated rates may support labelled valuation, never new risk sizing.
    @Published private(set) var infraFX: [String: StockSageQuote] = [:]

    func fxConversionToUSD(_ currency: String, forSizing: Bool = false, now: Date = Date())
    -> (rate: Double, marketTime: Date?, isFresh: Bool)? {
        let ccy = currency.uppercased()
        if ccy == "USD" { return (1, nil, true) }
        let direct = "\(ccy)USD=X", inverse = "USD\(ccy)=X"
        return StockSageCurrency.fxRateToUSD(currency: ccy, observations: [
            (latestQuote(direct), false), (latestQuote(inverse), true),
            (infraFX[direct], false), (infraFX[inverse], true)
        ], forSizing: forSizing, now: now)
    }
    /// Distinguishes the built-in demo data from a real feed, so the UI/tool can
    /// say "sample data" honestly rather than implying live quotes.
    @Published private(set) var isSampleData = true
    /// True when the board is seeded from the DISK CACHE (real last-good prices) rather
    /// than sample data or a live fetch — cleared on the next successful refresh.
    @Published private(set) var loadedFromCache = false
    /// When the cached snapshot was saved (for an honest "last good as of …" label).
    @Published private(set) var cacheSavedAt: Date?

    /// When the last successful live refresh completed (nil = still on the sample
    /// seed). Drives the "updated HH:mm" status in the Markets header.
    @Published private(set) var lastUpdated: Date?
    /// The newest quote MARKET timestamp from the last refresh (not our fetch time) — so the banner
    /// can tell genuinely-live prices from a days-old weekend/holiday close. nil when unknown.
    /// NOTE: this is the max across ALL symbols, so always-on crypto keeps it ≈ now — use
    /// `closeableQuoteAsOf` for the "is the (mostly equity) board live?" question.
    @Published private(set) var quoteAsOf: Date?

    /// Freshest market time among CLOSEABLE (non-24/7) assets — equities/indices/FX. The "live" banner
    /// keys off THIS, not the global `quoteAsOf`, so a 24/7 crypto quote can't make a days-old weekend
    /// equity board read "live". nil when no closeable asset carries a market time (e.g. an all-crypto
    /// board) → the caller treats that as not-stale, since crypto genuinely is live.
    static func closeableQuoteAsOf(_ symbols: [StockSageSymbol]) -> Date? {
        symbols.filter { StockSageAllocation.assetClass($0.symbol) != "Crypto" && $0.latest?.priceSource != .sample }
            .compactMap { $0.latest?.marketTime }.max()
    }
    var closeableQuoteAsOf: Date? { Self.closeableQuoteAsOf(symbols) }

    /// Source of the SAME observation the header/banner dates. A tie across providers is
    /// mixed, never whichever row happens to be first. Match the closeable-first clock rule.
    static func quoteSourceLabel(_ symbols: [StockSageSymbol], asOf: Date?) -> String {
        guard let asOf else { return "source unknown" }
        let eligible = closeableQuoteAsOf(symbols) == nil ? symbols
            : symbols.filter { StockSageAllocation.assetClass($0.symbol) != "Crypto" }
        let labels = Set(eligible.compactMap { symbol -> String? in
            guard let quote = symbol.latest, quote.priceSource != .sample, quote.marketTime == asOf else { return nil }
            return quote.priceSource?.label ?? "source unknown"
        })
        return labels.count == 1 ? labels.first! : labels.isEmpty ? "source unknown" : "mixed sources"
    }
    /// True while a live fetch is in flight — spins the refresh control.
    @Published private(set) var isRefreshing = false
    /// Human-readable reason the last refresh produced no live data (offline,
    /// web access off, feed unreachable). nil when the feed is healthy.
    @Published private(set) var feedError: String?

    // Advice/ideas — the advisor run across the universe on real candle history.
    @Published private(set) var ideas: [StockSageIdea] = []
    @Published private(set) var isLoadingIdeas = false
    /// Live fetch progress during refreshIdeas: (current, total) symbol count. nil when idle.
    /// UNIT: `current` counts symbols ATTEMPTED so far (cache-served + fetch-attempted,
    /// hit or miss) — NOT symbols successfully priced. Monotonically non-decreasing within a
    /// scan by construction (see `performRefreshIdeas`'s `attemptedSoFar`/`priorAttempted`);
    /// do not feed a priced-only count into this without re-checking that invariant.
    @Published private(set) var ideasProgress: (current: Int, total: Int)?
    /// In-flight ideas-refresh task, retained so the UI can cancel it (backlog #12).
    private var ideasRefreshTask: Task<Void, Never>?
    /// In-flight earnings sweep, retained so a NEW scan's sweep cancels its PREDECESSOR (major
    /// fix 2026-09-06) — without this, two `refreshIdeas` calls in quick succession leave two
    /// ~900-symbol `refreshEarningsForTracked` sweeps interleaved on the MainActor (the method's
    /// own `Task.isCancelled` check inside can never fire on an unstructured, un-cancelled Task),
    /// up to doubling the ~900/24h Yahoo quoteSummary call budget.
    private var earningsSweepTask: Task<Void, Never>?
    @Published private(set) var ideasUpdated: Date?
    @Published private(set) var ideasError: String?
    /// What changed vs the last FULL scan (symbol → .new/.actionChanged) — WRITTEN ONLY by
    /// performRefreshIdeas; a partial retry or the QA seed must never touch this (see
    /// PLAN_2026-07-07_scan_deltas.md). Absent baseline ⇒ empty (first-run honesty rule).
    @Published private(set) var scanDeltas: [String: ScanDelta] = [:]
    /// Symbols the last analysis couldn't fetch history for (feed miss / rate-limit) —
    /// surfaced so the board never silently ranks on a partial universe.
    @Published private(set) var ideasMissing: [String] = []
    /// THROTTLE FALLBACK (Stage 1/2, PLAN_2026-07-08_equity2000.md): true when a chunk beyond
    /// the first returned < 30% coverage (429-storm signature) and the scan stopped launching
    /// further chunks. Completed chunks' results stay on the board; `ideasMissing` names the
    /// rest. Post-restriction's ~4-chunk 901-name universe (Tadawul+NASDAQ 2026-07-16), this is live-reachable (Stage 1
    /// shipped it dormant at n=210's single chunk); still directly exercised via
    /// `StockSageScanChunking.shouldThrottle` in tests.
    @Published private(set) var scanThrottled = false
    /// True when the MOST RECENT `refreshIdeas()` scan was cancelled before reaching scan-end
    /// (SCAN-END-ONCE commit never ran). Reset to false at the start of every scan. Exists so a
    /// caller (MarketsView's tab-open `.task`) can skip recording a durable trend snapshot off a
    /// partial/cancelled board — see the honesty-floor note at that call site.
    @Published private(set) var lastScanCancelled = false

    /// Signal alerts — events (flips, stop/target crossings) detected between
    /// successive Ideas refreshes. Opt-in (off by default); a capped event log.
    ///
    /// The FLAG is persisted (read back in `init(defaults:heldSymbols:)`) so the owner's choice
    /// survives a relaunch. The LOG (`alerts`) is deliberately memory-only: after a relaunch with
    /// the flag on, the card correctly reads "On — no events yet". Persisting the toggle must
    /// never be read as persisting the events.
    @Published var alertsEnabled = false {
        didSet { if oldValue != alertsEnabled { defaults.set(alertsEnabled, forKey: Self.alertsEnabledKey) } }
    }
    @Published private(set) var alerts: [IdeaAlert] = []
    private static let maxAlerts = 50
    private static let alertsEnabledKey = "stocksage.alerts.enabled"

    func clearAlerts() { alerts = [] }

    // User-added watchlist tickers (beyond the curated universe), persisted.
    @Published private(set) var userSymbols: [String] = []
    @Published private(set) var isAddingSymbol = false
    @Published private(set) var addSymbolError: String?
    @Published private(set) var watchlistPersistenceError: String?
    private static let userSymbolsKey = "stocksage_user_symbols"
    private static let userMarketLabel = "★ My watchlist"

    // User-set price alerts (target levels), persisted as JSON.
    @Published private(set) var priceAlerts: [PriceAlert] = []
    @Published private(set) var priceAlertsPersistenceError: String?
    private var pendingPriceAlertTriggers: [UUID: Date] = [:]
    private static let priceAlertsKey = "stocksage_price_alerts"

    /// Single home for "what symbols are tracked" (board ∪ watchlist ∪ portfolio ∪ open
    /// journal trades). Pure — no store/network access — so callers (and tests) can build the
    /// union from any inputs. Uppercased + deduplicated; stable order is board order first,
    /// then the other three lists in first-seen order.
    nonisolated static func trackedSymbols(board: [String], watchlist: [String], portfolio: [String], journalOpen: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for symbol in board + watchlist + portfolio + journalOpen {
            let upper = symbol.uppercased()
            if seen.insert(upper).inserted {
                result.append(upper)
            }
        }
        return result
    }

    /// Instance convenience: feeds `trackedSymbols` from this store's board and watchlist
    /// (`userSymbols`), plus the shared portfolio and journal singletons. Board input is
    /// `symbols` (the board ROWS, populated from the on-disk cache at `init` — see
    /// `loadCachedQuotes`) `+ ideas` (major fix 2026-09-06: `ideas` alone is EMPTY until a full
    /// scan completes minutes later and excludes any symbol whose history fetch failed, so
    /// before the first scan — or for any name the scan couldn't analyze — this union used to
    /// omit hundreds of board names entirely: neither streamed, nor stream-gap-polled, nor
    /// earnings-swept). `symbols.map(\.symbol) + ideas.map(\.symbol)` may briefly repeat a symbol
    /// across the two arrays; `trackedSymbols` already dedupes.
    var trackedSymbolsUnion: [String] {
        Self.trackedSymbols(
            board: symbols.map(\.symbol) + ideas.map(\.symbol),
            watchlist: userSymbols,
            portfolio: offBoardHoldingSymbols,
            journalOpen: []
        )
    }

    /// Bare watchlist/scan state for isolated tests. Production alone performs the cache,
    /// sample and calibration bootstrap in the convenience initializer below.
    init(defaults: UserDefaults, heldSymbols: @escaping @MainActor () -> [String],
         journalTrades: @escaping @MainActor () -> [TradeRecord] = { [] }) {
        self.defaults = defaults
        self.heldSymbols = heldSymbols
        self.journalTrades = journalTrades
        do { userSymbols = try backupSymbols() }
        catch { watchlistPersistenceError = "Saved watchlist could not be read. It has not been changed." }
        do { priceAlerts = try Self.loadPriceAlerts(from: defaults) }
        catch { priceAlertsPersistenceError = "Saved price alerts could not be read. They were preserved; recover the saved alerts before editing or monitoring." }
        // Absent key ⇒ false ⇒ the opt-in default is unchanged on a first run.
        alertsEnabled = defaults.bool(forKey: Self.alertsEnabledKey)
    }

    private convenience init() {
        self.init(defaults: .standard, heldSymbols: {
            Self.trackedSymbols(board: [], watchlist: [],
                portfolio: StockSagePortfolio.shared.positions.map(\.symbol),
                journalOpen: StockSageJournalStore.shared.open.map(\.symbol))
        }, journalTrades: { StockSageJournalStore.shared.trades })
        seedSampleData()
        loadCachedQuotes()   // prefer real last-good prices over the sample seed when we have them
        loadCatalystRecords()   // A2: restore checkedAt/earningsDates so the TTL guard isn't blind on relaunch
        let eventNow = Date()
        for record in StockSageCompanyEventCache.load()?.entries ?? [] where record.fresh(at: eventNow) && StockSageMassive.covers(record.symbol) {
            let old = companyEventChecks[record.symbol]?[record.feed]
            if old == nil || old!.checkedAt < record.checkedAt { companyEventChecks[record.symbol, default: [:]][record.feed] = record }
        }
        // Calibration runtime activation (Decision 2): restore the last persisted fit so the
        // effective calibration survives a relaunch instead of resetting to nil every session.
        // Decode-fail (no key, corrupt blob, schema mismatch) ⇒ both stay nil ⇒ the conservative
        // linear prior — silently honest, matching loadPriceAlerts' failure posture above.
        if let snap = StockSageConvictionCalibration.Snapshot.load() {
            backtestConvictionCalibration = snap.usableCalibration
            persistedCalibrationSnapshot = snap
        }
        // Keep the saved fit for audit. Backtests and calibration now require
        // their explicit controls; opening the app never refits saved research.

    }

    // MARK: - Test-environment gate (F2, calibration runtime activation adversarial review)
    //
    // True whenever the process is hosted by the XCTest/Swift-Testing runner — Swift Testing
    // suites under `xcodebuild test` still load through the XCTest bundle machinery, so the
    // XCTestCase class is present in-process either way. Shared by automatic calibration,
    // provider refresh and AI assessment work to keep test hosts isolated.
    // Production is completely unaffected: `NSClassFromString` only resolves a
    // class when the XCTest framework is actually loaded, which never happens in a shipped app.
    nonisolated static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    // MARK: Price alerts (user-set target levels)

    private static func loadPriceAlerts(from defaults: UserDefaults) throws -> [PriceAlert] {
        // Preserve baseline loading: backup validation must not hide decodable saved records.
        guard let stored = try StockSageRecordStorage.object(forKey: priceAlertsKey, defaults: defaults) else { return [] }
        guard let data = stored as? Data else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode([PriceAlert].self, from: data)
    }

    private static func readPriceAlerts(from defaults: UserDefaults) throws -> [PriceAlert] {
        guard let stored = try StockSageRecordStorage.object(forKey: priceAlertsKey, defaults: defaults) else { return [] }
        guard let data = stored as? Data,
              let decoded = try? JSONDecoder().decode([PriceAlert].self, from: data),
              StockSageBackup.priceAlertValidationError(in: decoded) == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func applyingPendingTriggers(to records: [PriceAlert]) -> [PriceAlert] {
        records.map { record in
            var updated = record
            if updated.triggeredAt == nil, let date = pendingPriceAlertTriggers[updated.id] { updated.triggeredAt = date }
            return updated
        }
    }

    /// Read the committed collection before any edit. Corruption is not an empty collection.
    private func mutatePriceAlerts(_ change: (inout [PriceAlert]) -> Bool) -> Bool {
        do {
            try StockSageRecordWriter.require(defaults)
            var records = applyingPendingTriggers(to: try Self.loadPriceAlerts(from: defaults))
            let changed = change(&records)
            let data = try JSONEncoder().encode(records)
            let warning = try StockSageRecordStorage.set(data, forKey: Self.priceAlertsKey, defaults: defaults)
            priceAlerts = records
            pendingPriceAlertTriggers = [:]
            priceAlertsPersistenceError = warning
            return changed
        } catch {
            priceAlertsPersistenceError = error is StockSageFileLock.Failure || error is StockSageRecordStorage.Failure ? error.localizedDescription
                : "Price alerts could not be saved. Existing storage was preserved; recover saved alerts before editing or monitoring."
            return false
        }
    }

    func priceAlertsForMonitoring() -> [PriceAlert] {
        do { try StockSageRecordWriter.require(defaults) }
        catch {
            let message = error.localizedDescription
            if priceAlertsPersistenceError != message { priceAlertsPersistenceError = message }
            return []
        }
        do {
            let records = try Self.loadPriceAlerts(from: defaults)
            if !pendingPriceAlertTriggers.isEmpty {
                // Recovery must save accepted deliveries before resuming, not wait for an Add.
                guard mutatePriceAlerts({ _ in true }) else { return [] }
                return priceAlerts
            }
            if priceAlerts != records { priceAlerts = records }
            if priceAlertsPersistenceError != nil,
               priceAlertsPersistenceError != StockSageRecordStorage.Failure.durabilityUnconfirmed.localizedDescription {
                priceAlertsPersistenceError = nil
            }
            return records
        }
        catch {
            let message = "Saved price alerts could not be read. Monitoring these alerts is paused; existing storage was preserved."
            // Background retries must not reopen the same modal. User mutations still report each failure.
            if priceAlertsPersistenceError != message { priceAlertsPersistenceError = message }
            return []
        }
    }

    @discardableResult func addPriceAlert(symbol: String, target: Double, direction: PriceAlert.Direction) -> Bool {
        let up = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !up.isEmpty, target > 0, target.isFinite else { return false }
        // Dedupe: don't stack an identical armed alert (a card's bell can be tapped twice).
        return mutatePriceAlerts { records in
            guard !records.contains(where: {
                $0.isArmed && $0.symbol == up && $0.target == target && $0.direction == direction
            }) else { return false }
            records.append(PriceAlert(symbol: up, target: target, direction: direction))
            return true
        }
    }

    func removePriceAlert(_ id: UUID) {
        _ = mutatePriceAlerts { records in
            let count = records.count
            records.removeAll { $0.id == id }
            return records.count != count
        }
    }

    /// Re-arm with a new one-shot ID so an old in-flight cycle cannot fire or latch this arm.
    func resetPriceAlert(_ id: UUID) {
        _ = mutatePriceAlerts { records in
            guard let i = records.firstIndex(where: { $0.id == id }) else { return false }
            records[i] = records[i].rearmed()
            return true
        }
    }

    /// Mark alerts triggered (one-shot). Called by the Monitor after it fires them.
    func markPriceAlertsTriggered(_ ids: [UUID], at when: Date = Date()) {
        guard !ids.isEmpty else { return }
        do { try StockSageRecordWriter.require(defaults) }
        catch { priceAlertsPersistenceError = error.localizedDescription; return }
        let set = Set(ids)
        for id in ids { pendingPriceAlertTriggers[id] = when }
        // Delivery already happened: retain its latch even if the disk becomes unreadable.
        for i in priceAlerts.indices where set.contains(priceAlerts[i].id) {
            priceAlerts[i].triggeredAt = when
        }
        _ = mutatePriceAlerts { _ in true }
    }

    /// Pure reconcile step for the new-listing badge set (L3-03, 2026-07-07 audit). Given the
    /// CURRENT set and a batch of freshly-priced quotes, returns the set with each quote's symbol
    /// inserted when the feed says `isNewListing == true` and removed when it says `false` —
    /// symmetric, so a stale flag also clears once the feed stops reporting the symbol as new.
    /// Never infers the flag: the only source of truth is `LiveQuote.isNewListing` itself.
    /// `nonisolated static` and side-effect-free so it's unit-testable without the
    /// `@MainActor` singleton (`mergeLiveQuotes`/`addSymbol`/`applyPolledQuotes` are its callers).
    nonisolated static func reconcileNewListings(
        current: Set<String>, pricedQuotes: [String: StockSageQuoteService.LiveQuote]
    ) -> Set<String> {
        var result = current
        for (sym, q) in pricedQuotes {
            if q.isNewListing {
                result.insert(sym)
            } else {
                result.remove(sym)
            }
        }
        return result
    }

    /// Merge freshly-fetched live quotes into the matching tracked rows (used by the
    /// watchlist-only monitor so those names show live prices even though the full
    /// auto-refresh is paused). Deliberately does NOT flip isSampleData/loadedFromCache or
    /// `lastUpdated` — it only updates observed rows, so the board never over-claims that
    /// the WHOLE snapshot is live.
    @discardableResult
    func mergeLiveQuotes(_ quotes: [String: StockSageQuoteService.LiveQuote],
                         including requested: [StockSageSymbol] = []) -> Bool {
        guard !quotes.isEmpty else { return false }
        // Holdings can enter the feed before a full refresh creates their price row.
        // A stopped board sweep may also price a missing curated row. Stage definitions only;
        // the shared merger validates every first observation and existing idea's clock.
        let missing = Set(quotes.keys.map { $0.uppercased() }).subtracting(symbolIndex.keys)
        let personal = Set(userSymbols.map { $0.uppercased() }).union(offBoardHoldingSymbols)
        let definitions = requested.filter {
            missing.contains($0.symbol.uppercased())
                && ($0.market != Self.userMarketLabel || personal.contains($0.symbol.uppercased()))
        }.map { StockSageSymbol(id: $0.id, symbol: $0.symbol.uppercased(), market: $0.market) }
        let added = missing.isEmpty ? [] : Self.composeTrackedDefs(base: definitions,
            userSymbols: userSymbols.map { $0.uppercased() }.filter { missing.contains($0) },
            offBoardHoldings: offBoardHoldingSymbols.map { $0.uppercased() }.filter { missing.contains($0) })
        var stagedIndex = symbolIndex
        for (offset, row) in added.enumerated() { stagedIndex[row.symbol] = symbols.count + offset }
        let merged = Self.mergedPolledQuotes(symbols: added.isEmpty ? symbols : symbols + added,
            ideas: ideas, symbolIndex: stagedIndex, quotes: quotes)
        guard !merged.acceptedKeys.isEmpty || !merged.baselineKeys.isEmpty else { return false }
        symbols = added.isEmpty ? merged.symbols : merged.symbols.filter {
            symbolIndex[$0.symbol.uppercased()] != nil || merged.acceptedKeys.contains($0.symbol.uppercased())
        }
        if !added.isEmpty { rebuildSymbolIndex() }
        // Equality-guarded like the NBBO merge below (:2717). An accepted tick for a symbol that
        // is not on the ideas board leaves `ideas` byte-identical, and an unguarded assignment to
        // an @Published array still fires objectWillChange — which invalidates the whole Markets
        // body at the publication rate. Comparing is far cheaper than that redraw.
        if merged.ideas != ideas { ideas = merged.ideas }
        let priced = quotes.filter { merged.acceptedKeys.union(merged.baselineKeys).contains($0.key.uppercased()) }
        let reconciled = Self.reconcileNewListings(current: newListings, pricedQuotes: priced)
        if reconciled != newListings { newListings = reconciled }
        if let newest = merged.newestMarketTime {
            quoteAsOf = [quoteAsOf, newest].compactMap { $0 }.max()
        }
        return !merged.acceptedKeys.isEmpty
    }

    /// Pure: which disk-cache entries survive Q11 retention — only symbols still in `tracked`
    /// (major fix 2026-09-06). Also reused at offline restoration: removal must survive a
    /// relaunch BEFORE any refresh gets the opportunity to write a filtered cache.
    nonisolated static func retainedCacheEntries(
        previous: [StockSageQuoteCache.Entry], tracked: Set<String>
    ) -> [StockSageQuoteCache.Entry] {
        previous.filter { tracked.contains($0.symbol.uppercased()) }
    }

    /// Seed the board from the disk cache (last successful quotes) so launch shows real
    /// last-good numbers instantly + works offline, instead of fabricated sample data.
    private func loadCachedQuotes() {
        guard let persisted = StockSageQuoteCache.load(), !persisted.entries.isEmpty else { return }
        let defs = trackedDefs()
        let cache = persisted.retaining(tracked: Set(defs.map(\.symbol)))
        guard !cache.entries.isEmpty else { return }
        let labels = Dictionary(defs.map { ($0.symbol.uppercased(), $0.market) },
                                uniquingKeysWith: { a, _ in a })
        symbols = cache.symbols(marketFor: { labels[$0.uppercased()] ?? Self.userMarketLabel })
        rebuildSymbolIndex()
        isSampleData = false
        loadedFromCache = true
        cacheSavedAt = cache.savedAt
        // Restore the brand-new-listing flag from the reloaded cache entries — without this a
        // cached placeholder-flat row (real previousClose unknown) silently reads as a genuine
        // 0%-move "hold" after relaunch, before any live refresh has re-derived it.
        newListings = Set(cache.entries.filter(\.isNewListing).map { $0.symbol.uppercased() })
    }

    /// Which base universe `trackedDefs(scope:)` draws from before the user's watchlist is
    /// appended. `.full` (default) is the whole 901-name `worldwide` (Tadawul+NASDAQ since 2026-07-16; was Stage 2's 2,420) — used by every
    /// USER-INITIATED path (manual refresh, Find-Ideas scan) and by `refresh()`'s default.
    /// `.core` is the curated ~210-name `groups`-derived set — used ONLY by the monitor's
    /// unattended background auto-cycle (review round-2 finding 1) so a ~45s unpaced loop can't
    /// pull the whole universe every cycle (feed-cooldown risk). See `StockSageMonitor.start`'s loop.
    /// `.streamGap` (B2, owner: "every tracked stock live") is neither a base-universe slice nor
    /// `.full`/`.core`'s composition — it resolves to `streamGapCandidates`: every TRACKED symbol
    /// (`trackedSymbolsUnion`) minus what `StockSageLiveStream` already streams, filtered down to
    /// symbols whose market is trading right now. It exists because the live WebSocket stream is
    /// US-only (StockSageLiveStream's own doc) — Tadawul names (and anything else unsubscribed)
    /// have no other live path once `.core`'s poll is skipped (watchlist-only mode, N2).
    enum TrackedScope { case full, core, streamGap }

    /// Pure diff: which of `tracked` still needs a poll because the live stream doesn't carry it
    /// AND its market is actually open right now. `subscribed` is
    /// `StockSageLiveStream.shared.subscribed` — the union of symbols on a connection that is
    /// actually AUTHORIZED and streaming right now (major fix 2026-09-06: `subscribed` used to
    /// be assigned from the merely-REQUESTED union the instant `start()` ran, before any socket
    /// even opened — so a symbol whose connection never authorized, or dropped and is backing
    /// off, read as "covered" and got no gap-poll at all; see `StockSageLiveStream.subscribed`'s
    /// own doc) — so a symbol the stream is still trying to connect for correctly still counts as
    /// a gap. `isTrading` is injected (rather than calling `marketIsTrading` inline) so this
    /// stays a pure function of its three inputs, directly unit-testable without touching the
    /// wall clock or `StockSageLiveStream.shared`.
    nonisolated static func streamGapCandidates(
        tracked: [String], subscribed: Set<String>, needsBaseline: Set<String> = [], isTrading: (String) -> Bool
    ) -> [String] {
        let subscribedUpper = Set(subscribed.map { $0.uppercased() })
        return tracked.filter { (!subscribedUpper.contains($0.uppercased()) || needsBaseline.contains($0.uppercased())) && isTrading($0) }
    }

    /// The FX pairs the engine needs for currency conversions of KEPT-universe names
    /// (post-restriction: `.SR` ⇒ SAR is the only non-USD currency). Fetched by
    /// `refreshInfraFX()`, consumed by MarketsView's `fxRatesToUSD` as the fallback when the
    /// pair isn't user-tracked. Legacy holdings in OTHER currencies keep the existing honest
    /// degradation (excluded from USD totals + disclosed as untracked).
    nonisolated static let infraFXSymbols = ["USDSAR=X"]

    /// Best-effort infra FX refresh (1 request; failure keeps the last known rate).
    private func refreshInfraFX(allowed: () -> Bool = { ToolPolicy.isExternalAllowed }) async {
        guard !Task.isCancelled, allowed() else { return }
        let quotes = await StockSageQuoteService.fetchQuotes(for: Self.infraFXSymbols)
        guard !Task.isCancelled, allowed() else { return }
        let merged = Self.mergedInfraFX(infraFX, incoming: quotes, now: Date())
        if merged != infraFX { infraFX = merged }
    }

    /// Same monotonic clock contract as board quotes. No fetch-time refresh of an old rate.
    nonisolated static func mergedInfraFX(_ previous: [String: StockSageQuote],
        incoming: [String: StockSageQuoteService.LiveQuote], now: Date
    ) -> [String: StockSageQuote] {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0 else { return previous }
        var merged = previous
        for (symbol, q) in incoming.sorted(by: { $0.key < $1.key }) {
            let key = symbol.uppercased()
            guard infraFXSymbols.contains(key), q.symbol.uppercased() == key,
                  q.price > 0, q.price.isFinite, q.priceSource != .sample,
                  q.marketTime.map({ $0 <= now }) ?? true else { continue }
            // A corrupt future current clock cannot prevent recovery to a real past quote.
            let current = merged[key]?.marketTime.flatMap { $0 <= now ? $0 : nil }
            guard acceptsQuote(q.marketTime, after: current, priceSource: q.priceSource,
                               afterPriceSource: merged[key]?.priceSource, now: now) else { continue }
            merged[key] = StockSageQuote(price: q.price, previousPrice: q.previousClose,
                                         time: now, marketTime: q.marketTime, priceSource: q.priceSource)
        }
        return merged
    }

    /// Off-board holdings: portfolio positions ∪ open journal trades, regardless of whether
    /// they're on the board or the watchlist (B1, 2026-09-06). `trackedDefs` needs these to build
    /// each a priceable SymbolDef; `refresh()`'s post-await "is this user-market row still
    /// tracked?" guard needs the SAME set, or a portfolio-only holding's freshly-fetched row would
    /// be stripped as "no longer tracked" in the very refresh that priced it. Reuses the pure
    /// `trackedSymbols` union (TRACKED, 2026-09-06) with board/watchlist left empty — this is
    /// only the two off-board inputs.
    private var offBoardHoldingSymbols: [String] {
        heldSymbols()
    }

    private nonisolated final class FirstQuoteRequest: Sendable {
        let cancelled = Mutex(false)
    }
    private var firstQuoteRequests: [String: FirstQuoteRequest] = [:]

    /// One targeted fetch when personal tracking changes, even while exchanges are closed.
    func refreshMissingTrackedQuotes() async {
        let access = StockSageMassive.Access().capture()
        await refreshMissingTrackedQuotes(allowed: access.isCurrent,
            fetch: { await StockSageQuoteService.fetchQuoteBatch(for: $0) })
    }

    func refreshMissingTrackedQuotes(allowed: () -> Bool,
        fetch: ([String]) async -> StockSageQuoteService.QuoteBatch) async {
        guard allowed(), !Task.isCancelled else { return }
        let now = Date()
        let requested = Set(Self.trackedSymbols(board: [], watchlist: userSymbols,
            portfolio: offBoardHoldingSymbols, journalOpen: []).filter {
                (firstQuoteRequests[$0]?.cancelled.withLock { $0 } ?? true)
                    && latestQuote($0)?.usableHoldingPrice(isSampleData: isSampleData, now: now) == nil
            })
        guard !requested.isEmpty else { return }
        let request = FirstQuoteRequest()
        for symbol in requested { firstQuoteRequests[symbol] = request }
        defer {
            for symbol in requested where firstQuoteRequests[symbol] === request {
                firstQuoteRequests.removeValue(forKey: symbol)
            }
        }
        let batch = await withTaskCancellationHandler {
            await fetch(requested.sorted())
        } onCancel: {
            // Native task replacement can dispatch before the cancelled transport returns.
            request.cancelled.withLock { $0 = true }
        }
        guard allowed(), !Task.isCancelled, batch.stop != .invalidated else { return }
        let current = Set(Self.trackedSymbols(board: [], watchlist: userSymbols,
            portfolio: offBoardHoldingSymbols, journalOpen: []))
        applyPolledQuotes(batch.quotes.filter { requested.contains($0.key.uppercased())
            && current.contains($0.key.uppercased()) })
    }

    /// Pure rule `trackedDefs(scope:)` is a thin shell over: curated universe (`base`) ∪
    /// `userSymbols` (watchlist) ∪ `offBoardHoldings` (portfolio/journal-open holdings outside
    /// the universe and watchlist), each unknown symbol getting a `userMarketLabel` SymbolDef the
    /// same way an unknown user-typed ticker always has. Pulled out as a `static func` so it's
    /// directly testable without the private, instance-bound `trackedDefs(scope:)` itself (see
    /// StockSageTests.swift's `coreIsTheGroupsDerivedCuratedSubsetOfWorldwide` comment for why
    /// that method has no test seam of its own — this is the same fix applied to the OTHER half
    /// of its composition). Stays MainActor-isolated (like the rest of the class, and like
    /// `StockSageSymbol`'s own initializer) rather than `nonisolated` — but is still a pure
    /// function of its three inputs (no `self`, no singleton reads), so a `@MainActor` test can
    /// pin it directly without touching `StockSageStore.shared`.
    static func composeTrackedDefs(
        base: [StockSageSymbol], userSymbols: [String], offBoardHoldings: [String]
    ) -> [StockSageSymbol] {
        var defs = base
        var known = Set(defs.map { $0.symbol.uppercased() })
        for s in userSymbols where !known.contains(s.uppercased()) {
            defs.append(StockSageSymbol(symbol: s, market: Self.userMarketLabel))
            known.insert(s.uppercased())
        }
        for s in offBoardHoldings where !known.contains(s.uppercased()) {
            defs.append(StockSageSymbol(symbol: s, market: Self.userMarketLabel))
            known.insert(s.uppercased())
        }
        return defs
    }

    /// Every tracked instrument definition: the curated universe + the user's added tickers +
    /// off-board portfolio/journal-open holdings (B1, deduped). Drives both the live feed and the
    /// ideas analysis, so user picks AND off-board holdings survive refreshes and get priced.
    /// `.streamGap` (B2) is a different shape entirely — not a base-universe composition, just
    /// the tracked-minus-streamed diff — so it's branched separately rather than folded into
    /// `composeTrackedDefs`. Market labels for the synthesized rows come from the CURRENT board
    /// (a symbol already on screen keeps its known label); an as-yet-unseen tracked symbol falls
    /// back to `userMarketLabel`, the same convention `composeTrackedDefs` uses for one.
    private func trackedDefs(scope: TrackedScope = .full) -> [StockSageSymbol] {
        guard scope != .streamGap else {
            let candidates = Self.streamGapCandidates(
                tracked: trackedSymbolsUnion,
                subscribed: StockSageLiveStream.shared.subscribed,
                needsBaseline: Set(trackedSymbolsUnion.filter { key in
                    symbolIndex[key].map { symbols[$0].sessionChangePercent == nil } ?? true
                }),
                isTrading: { Self.marketIsTrading(symbol: $0) }
            )
            let knownLabels = Dictionary(symbols.map { ($0.symbol.uppercased(), $0.market) }, uniquingKeysWith: { a, _ in a })
            return candidates.map { StockSageSymbol(symbol: $0, market: knownLabels[$0.uppercased()] ?? Self.userMarketLabel) }
        }
        let base = scope == .full ? StockSageUniverse.worldwide : StockSageUniverse.core
        return Self.composeTrackedDefs(base: base, userSymbols: userSymbols, offBoardHoldings: offBoardHoldingSymbols)
    }

    /// Pure validation/normalization for a user-typed ticker. Returns the
    /// normalized symbol (or nil) and a rejection reason (or nil). Testable.
    static func validateNewSymbol(_ raw: String, alreadyTracked: Set<String>) -> (symbol: String?, error: String?) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty else { return (nil, "Enter a ticker.") }
        guard s.count <= 20, !s.contains(" ") else { return (nil, "That doesn't look like a ticker.") }
        // Crypto is out of scope by owner decision (2026-07-28). The curated universe already
        // carries none, but a hand-typed ticker was the one remaining way in — refusing it HERE
        // rather than at each call site is what makes "this app holds no crypto" an enforced
        // property instead of a default that the next added symbol could quietly break.
        guard !s.hasSuffix("-USD") else { return (nil, "This app doesn't trade crypto.") }
        guard !alreadyTracked.contains(s) else { return (nil, "\(s) is already in your watchlist.") }
        return (s, nil)
    }

    /// Personal membership is separate from the market catalog and quote subscriptions.
    func isWatchlisted(_ symbol: String) -> Bool {
        userSymbols.contains { $0.uppercased() == symbol.uppercased() }
    }

    /// Saved entries stay visible before the first quote arrives or while offline.
    var watchlistSymbols: [StockSageSymbol] {
        Self.composeTrackedDefs(base: symbols, userSymbols: userSymbols, offBoardHoldings: [])
            .filter { isWatchlisted($0.symbol) }
    }

    /// Catalog/board tickers are local additions. Unknown tickers still need a valid quote.
    /// Returns this call's error, so a concurrent caller cannot mistake a busy no-op for success.
    @discardableResult
    func addSymbol(_ raw: String,
                   fetchQuotes: ([String]) async -> [String: StockSageQuoteService.LiveQuote] = {
                       await StockSageQuoteService.fetchQuotes(for: $0)
                   }) async -> String? {
        guard !isAddingSymbol else { return "Another ticker is being added. Try again when it finishes." }
        isAddingSymbol = true
        defer { isAddingSymbol = false }
        addSymbolError = nil
        func reject(_ reason: String) -> String { addSymbolError = reason; return reason }
        guard !Task.isCancelled else { return reject("Watchlist addition cancelled.") }
        let saved: [String]
        do {
            try StockSageRecordWriter.require(defaults)
            saved = try backupSymbols()
            watchlistPersistenceError = nil
        } catch { return reject(recordWatchlistFailure(error)) }
        let validation = Self.validateNewSymbol(raw, alreadyTracked: Set(saved.map { $0.uppercased() }))
        guard let symbol = validation.symbol else { return reject(validation.error ?? "Enter a ticker.") }
        let known = symbols.first { $0.symbol.uppercased() == symbol }
            ?? StockSageUniverse.catalog.first { $0.symbol == symbol }
        var quote: StockSageQuoteService.LiveQuote?
        if known == nil {
            if let reason = ToolPolicy.webToolsDisabledReason() { return reject(reason) }
            quote = await fetchQuotes([symbol])[symbol]
            guard !Task.isCancelled else { return reject("Watchlist addition cancelled.") }
            if let reason = ToolPolicy.webToolsDisabledReason() { return reject(reason) }
            guard let q = quote, q.symbol.uppercased() == symbol, q.price.isFinite, q.price > 0,
                  q.previousClose.isFinite else {
                return reject("Couldn't find a tradeable price for “\(symbol)”. Check the ticker (e.g. AAPL, 2222.SR).")
            }
        }
        do {
            // Re-read after any await; an import may already have added this ticker.
            let update = try prepareBackupImport([symbol])
            guard update.added > 0 else { return reject("\(symbol) is already in your watchlist.") }
            try update.apply()
        } catch { return reject(recordWatchlistFailure(error)) }
        // Existing rows retain their market label, quote history and provenance.
        if !symbols.contains(where: { $0.symbol.uppercased() == symbol }) {
            symbols.append(known ?? StockSageSymbol(symbol: symbol, market: Self.userMarketLabel))
            rebuildSymbolIndex()
        }
        if let quote { mergeLiveQuotes([symbol: quote]) }
        return nil
    }

    /// Read the saved preference, not a possibly stale or failed-load in-memory fallback.
    func backupSymbols() throws -> [String] {
        guard let stored = try StockSageRecordStorage.object(forKey: Self.userSymbolsKey, defaults: defaults) else { return [] }
        guard let symbols = stored as? [String] else { throw StockSageBackup.BackupError.sourceReadFailed("watchlist") }
        return symbols
    }

    @discardableResult private func recordWatchlistFailure(_ error: Error) -> String {
        let message = error is StockSageFileLock.Failure || error is StockSageRecordStorage.Failure ? error.localizedDescription
            : "Saved watchlist could not be read. It has not been changed."
        watchlistPersistenceError = message
        return message
    }

    /// Read committed alerts at export time; load's empty fallback must never become a false
    /// successful backup when the saved value is corrupt or has the wrong defaults type.
    func backupPriceAlerts() throws -> [PriceAlert] {
        do { return try Self.readPriceAlerts(from: defaults) }
        catch { throw StockSageBackup.BackupError.sourceReadFailed("price alerts") }
    }

    /// Backup tickers were validated/normalized by the decoder. Restore the preference,
    /// not a quote: no network or invented prices, even when the app is offline.
    func prepareBackupImport(_ incoming: [String]) throws -> StockSageRecordStorage.PreparedImport {
        try StockSageRecordWriter.require(defaults)
        // Only explicit additions may restore a removed ticker. Memory can predate another
        // store's deletion, so the committed preference is the base for this mutation.
        var merged = try backupSymbols()
        var known = Set(merged.map { $0.uppercased() })
        let additions = incoming.filter { known.insert($0.uppercased()).inserted }
        merged.append(contentsOf: additions)
        let symbols = merged
        return .init(defaults: defaults, added: additions.count,
            changes: [.init(key: Self.userSymbolsKey, value: .strings(symbols))], publish: { warning in
            self.userSymbols = symbols
            self.watchlistPersistenceError = warning
        })
    }

    /// Committed alerts win by immutable one-shot ID; only explicit backup records may be added.
    /// Memory-only IDs may have been deleted/rearmed by another writer, so never resurrect them.
    func preparePriceAlertBackupImport(_ incoming: [PriceAlert]) throws -> StockSageRecordStorage.PreparedImport {
        try StockSageRecordWriter.require(defaults)
        let disk = try Self.readPriceAlerts(from: defaults)
        var merged = applyingPendingTriggers(to: disk)
        var ids = Set(merged.map(\.id))
        let additions = incoming.filter { ids.insert($0.id).inserted }
        merged.append(contentsOf: additions)
        let data = try JSONEncoder().encode(merged)
        let records = merged
        return .init(defaults: defaults, added: additions.count,
            changes: [.init(key: Self.priceAlertsKey, value: .data(data))], publish: { warning in
            self.priceAlerts = records
            self.pendingPriceAlertTriggers = [:]
            self.priceAlertsPersistenceError = warning
        })
    }

    /// Remove a watchlist entry; curated/held instruments remain tracked.
    func removeSymbol(_ symbol: String) {
        let up = symbol.uppercased()
        do {
            try StockSageRecordWriter.require(defaults)
            var saved = try backupSymbols()
            saved.removeAll { $0.uppercased() == up }
            let warning = try StockSageRecordStorage.set(saved, forKey: Self.userSymbolsKey, defaults: defaults)
            userSymbols = saved
            watchlistPersistenceError = warning
        } catch { recordWatchlistFailure(error); return }
        // Removing a watchlist preference must not untrack an actual holding (or a
        // curated name from a legacy/imported watchlist). Otherwise remove its quote/idea rows.
        guard !trackedDefs().contains(where: { $0.symbol.uppercased() == up }) else { return }
        symbols = symbols.filter { $0.symbol.uppercased() != up }
        ideas.removeAll { $0.symbol.uppercased() == up }
        ideasMissing.removeAll { $0.uppercased() == up }
        scanDeltas = scanDeltas.filter { $0.key.uppercased() != up }
        newListings.remove(up)
        rebuildSymbolIndex()
    }

    /// Analyze the worldwide universe on real 1-year candle history and rank the
    /// results into actionable ideas (strongest buys first). Heavy (one history fetch per
    /// symbol). NOT purely user-triggered: MarketsView's tab-open `.task` also auto-fires this
    /// when the board is empty (`if store.ideas.isEmpty { await store.refreshIdeas() }`), on top
    /// of the explicit "Find ideas" button and "Retry failed" affordance — self-guards re-entry
    /// via `isLoadingIdeas` either way. Whether that auto-trigger should still pull the FULL
    /// whole-universe scan on every empty-board tab-open, vs. a smaller scope, is an OPEN OWNER
    /// QUESTION as of this writing — not resolved by this comment fix. Non-destructive on
    /// failure. No-op-with-reason when external access is off.
    func refreshIdeas() async {
        guard !isLoadingIdeas else { return }
        if let reason = ToolPolicy.webToolsDisabledReason() {
            ideasError = reason
            return
        }
        isLoadingIdeas = true
        defer { isLoadingIdeas = false }   // clears on EVERY path: success, feed-failure early-return, AND cancel
        let task = Task { await self.performRefreshIdeas() }
        ideasRefreshTask = task
        // The 120s watchdog is now PER-CHUNK (armed inside performRefreshIdeas around each
        // chunk's fetch+build) rather than one clock for the whole scan — a stall kills the
        // current chunk, not chunks already committed. This outer task has no watchdog of its
        // own; it simply awaits the (self-bounding) chunked work.
        await task.value                   // keep refreshIdeas awaitable so callers see populated `ideas`
        ideasRefreshTask = nil
    }

    /// The heavy ideas scan, run as a cancellable child task. MainActor-isolated (inherited),
    /// so no actor hops are added. Cancellation (from `cancelIdeasRefresh` or a chunk watchdog)
    /// stops it applying stale results.
    ///
    /// CHUNKED PROGRESSIVE SCAN (Stage 1) + UNIVERSE PROMOTION (Stage 2), both
    /// PLAN_2026-07-08_equity2000.md: `trackedDefs()` is split into `StockSageScanChunking.chunks`
    /// (~250 wide; chunk 0 is always the array's natural head, so the curated Saudi-first core
    /// scans and appears on the board first). Each chunk is fetched, built, and MERGED into
    /// `ideas` independently — replace-by-symbol, re-sorted, board published — so the board
    /// grows live instead of waiting for the whole universe. Post-restriction the universe is 901
    /// names (~10 chunks); the merge loop that was single-shot-equivalent at Stage 1's n=210 now
    /// runs its full multi-chunk streaming path live.
    /// SCAN-END-ONCE semantics (delta baseline with the DEG-01 missing-but-tracked carry-forward,
    /// missingAfterScan, history-cache save, paper trades, earnings kick, and alert detection)
    /// all run exactly once, after the FINAL chunk, over the accumulated full-scan result —
    /// never per chunk. (`newListings` is untouched here, matching the pre-chunking scan —
    /// this store's ideas path has never written it; only the separate quote-refresh path does.)
    private func performRefreshIdeas() async {
        ideasError = nil
        scanThrottled = false
        lastScanCancelled = false
        let universe = trackedDefs()
        let total = universe.count
        ideasProgress = (current: 0, total: total)
        defer { ideasProgress = nil }   // clear on EVERY exit (success + the cancel/feed-failure early-returns), not just success

        // PERF FIX (review round 1): `.load()` decodes the whole multi-MB on-disk JSON cache
        // synchronously — hoisted into a detached task so that decode runs off the MainActor
        // instead of blocking it once per scan. `nonisolated static func`, so no actor hop is
        // needed to call it from a detached context. Same one-load-per-scan cadence as before.
        let cache = await Task.detached { StockSageHistoryCache.load() }.value
        // Reconstructed ONCE here (was rebuilt from `cache?.priceHistories()` inside the chunk
        // loop on every iteration — an O(chunks) re-decode of the same dictionary for a value
        // that never changes across chunks within one scan).
        let cachePriceHistories = cache?.priceHistories() ?? [:]
        let cal = convictionCalibration                           // read on the main actor before ANY await
        let journalTrades = self.journalTrades()   // read on the main actor before ANY await
        // Benchmark fetched ONCE up front, shared by every chunk's buildIdeas call.
        let benchmark = await StockSageQuoteService.fetchHistory("^GSPC", range: "1y")
        await refreshInfraFX()   // SAR rate for .SR conversions (infra — FX left the universe 2026-07-16)
        guard !Task.isCancelled else { lastScanCancelled = true; return }

        // ALERTS FIX (review round 1): snapshot the board BEFORE the chunk loop starts
        // publishing. The loop below does `ideas = ranked` after EVERY chunk merges (so the
        // board grows live) — if alert-detect compared against `ideas` read AFTER the loop, it
        // would be comparing the final board to itself (detect(new, new) never fires; alerts
        // went dead). `preScanBoard` is the one-and-only "previous" for this scan, taken before
        // any chunk publish. The first-ever-scan skip guard below keys on `!preScanBoard.isEmpty`
        // (not `!ideas.isEmpty`, which by scan-end has already been overwritten) — same "don't
        // alert on the very first population" semantics as the legacy single-shot scan.
        let preScanBoard = ideas

        // THE SHARED CHUNK LOOP (review round-2 finding 3): fetch→build→merge→publish per chunk,
        // watchdog + cancel-forwarding + throttle-fallback, now factored into `runChunkedScan` so
        // `retryFailedIdeas` runs the identical machinery instead of a second, drifting hammer.
        // onThrottle wires the LIVE @Published banner (was set inline, mid-loop, pre-extraction).
        let scan = await runChunkedScan(defs: universe, total: total, startingRanked: [],
                                        cache: cache, cachePriceHistories: cachePriceHistories,
                                        benchmark: benchmark, calibration: cal, journalTrades: journalTrades,
                                        onThrottle: { [weak self] in self?.scanThrottled = true })

        // Exit coverage is independent of watchlist/entry membership. Do not expand the
        // scan universe or feed these supplemental histories into ranking/calibration.
        let paperHistories: [String: StockSagePriceHistory]
        if !scan.wasCancelled, !scan.firstChunkTotallyFailed, !scanThrottled, !Task.isCancelled {
            paperHistories = await paperExitHistories(existing: scan.accumulatedHistories)
        } else { paperHistories = scan.accumulatedHistories }
        let historyUniverse = Set(universe.map { $0.symbol.uppercased() })

        if scan.wasCancelled || Task.isCancelled {
            lastScanCancelled = true
            // CANCEL-01 (post-ship critique fleet, orchestrator-confirmed; round-2 fix,
            // 2026-07-08): a cancel throws away every chunk history the scan already paid
            // network cost for unless a best-effort save runs — otherwise a same-day re-scan
            // re-fetches everything cancel discarded (429-risk). BUT `StockSageHistoryCache
            // .save()` atomically REPLACES the whole on-disk file, so naively saving JUST
            // `scan.accumulatedHistories` (e.g. ~250 entries from chunk 0) would DESTROY a
            // same-day-fresh prior cache's other ~2,170 entries — inverting the very
            // 429-protection this save exists for. INVARIANT: this save must never SHRINK a
            // same-day cache. `cancelSaveDecision` (pure, tested) picks the non-destructive
            // action: merge over the prior cache with `savedAt: now` ONLY when the prior cache
            // is genuinely from today (every carried entry really was saved today, so the
            // stamp stays honest); otherwise save the accumulated set alone ONLY if it can't
            // shrink coverage (superset of the prior cache's symbols, or no prior cache); else
            // skip the save entirely (the pre-hoist behavior). Per-entry `savedAt` (schema v2)
            // is the complete future fix — out of scope here. Scan-identity semantics (delta
            // baseline, alerts) stay behind the wasCancelled branch below as before.
            if let today = StockSageScanChunking.utcDayKey(Date()),
               let toSave = Self.cancelSaveDecision(priorCacheSymbols: Set(cachePriceHistories.keys),
                                                     priorCacheSavedAtDayKey: cache.flatMap { StockSageScanChunking.utcDayKey($0.savedAt) },
                                                     accumulated: scan.accumulatedHistories,
                                                     priorCacheHistories: cachePriceHistories,
                                                     nowDayKey: today) {
                // Concurrency R2: serialize through CacheWriter so this cancel save can't reorder past
                // a still-in-flight full-scan save and shrink a same-day-fresh cache.
                Task.detached { await StockSageHistoryCache.from(histories: toSave, universe: historyUniverse, savedAt: Date()).saveSerialized() }
            }
            // CANCEL NAMES COVERAGE (post-ship critique fleet, orchestrator-confirmed): a cancel
            // can land AFTER one or more chunks already published to the board (`ideas` was set
            // live inside runChunkedScan). Silently returning here would leave `ideasMissing`
            // describing the OLD scan's gaps and `scanDeltas` describing a baseline the board no
            // longer matches — a fake-honest board. INVARIANT: partial coverage is NAMED, never
            // silently truncated. So: if anything published, run a REDUCED commit — mirror the
            // normal path's missingAfterScan call (universe attempted THIS scan, analyzed =
            // symbols actually on the published board, stillTracked = current tracked set) so the
            // existing "N priced · M couldn't be fetched" banner names the un-scanned remainder,
            // and clear scanDeltas (they'd describe the PREVIOUS baseline against a board that
            // just changed — an empty dict is an honest absence, not a lie). Deliberately do NOT
            // write the delta baseline, set ideasUpdated, or run alerts/paper-trade/earnings —
            // those are SCAN-END-ONCE, full-scan-commit semantics; a cancelled scan never reaches
            // scan-end.
            let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
            let publishedBoardSymbols = Set(scan.ranked.map { $0.symbol.uppercased() })
            if let commit = Self.cancelledScanCommit(universe: universe.map(\.symbol),
                                                      publishedBoardSymbols: publishedBoardSymbols,
                                                      stillTracked: stillTracked) {
                ideasMissing = commit.ideasMissing
                scanDeltas = commit.scanDeltas
            }
            return
        }

        if scan.firstChunkTotallyFailed {
            ideasError = "Couldn't reach the market feed for analysis — try again."
            return
        }
        // A watchdog timeout or throttle trip needs no branch here — either way, everything
        // below runs over whatever chunks DID complete: "stop launching more chunks" is not
        // "discard what we have" (partial success is honest success, same as any individual
        // symbol's fetch failure).
        let ranked = scan.ranked
        let accumulatedHistories = scan.accumulatedHistories

        // Persist ALL histories fetched across every chunk this scan for OFFLINE net-cost
        // validation / backtests (StockSageHistoryCache). Best-effort and DETACHED so the JSON
        // encode runs off the main actor and never blocks the commit below; ZERO new network —
        // it saves bytes already downloaded and otherwise discarded after buildIdeas. Full-scan
        // completion (this path only) means `accumulatedHistories` genuinely IS today's complete
        // result, so an unconditional whole-file replace stays honest — unlike the cancel path
        // above, which needs `cancelSaveDecision` to avoid shrinking a same-day cache.
        let historiesToSave = accumulatedHistories
        // Concurrency R2: serialize through CacheWriter (same funnel as the cancel save above) so two
        // detached savers can neither reorder nor shrink a same-day cache.
        Task.detached { await StockSageHistoryCache.from(histories: historiesToSave, universe: historyUniverse, savedAt: Date()).saveSerialized() }

        // SCAN-END-ONCE (plan step 2): everything below runs exactly once, over the FULL
        // accumulated result — same order/guards as the pre-chunking single-shot scan.
        //
        // Re-reconcile vs the CURRENT tracked set (mirror refresh() at the liveFiltered step): a
        // removeSymbol() that landed DURING any chunk's await must win, else a pre-await
        // snapshot resurrects a dropped ticker into ranked ideas AND the capital allocator.
        let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
        let finalRanked = ranked.filter { stillTracked.contains($0.symbol.uppercased()) }
            .sorted { Self.rankScore($0.advice) > Self.rankScore($1.advice) }
        invalidateDerivedResearch()
        // Detect alert events vs the PRE-SCAN snapshot (taken before the loop's mid-scan
        // publishes) — once, vs the full board. Using `ideas` here would compare the
        // just-published finalRanked to itself (see preScanBoard's doc comment above).
        if alertsEnabled, !preScanBoard.isEmpty {
            // Both sides come from the same board (Sharia screening removed 2026-07-28), so the
            // previous/current pairing stays symmetric — the property the screened version existed
            // to preserve.
            let fired = StockSageAlerts.detect(previous: preScanBoard, current: finalRanked)
            if !fired.isEmpty { alerts = Array((fired + alerts).prefix(Self.maxAlerts)) }
        }
        // Partial success is honest success: keep the names that priced, and NAME the ones that
        // didn't so the EV ranking isn't silently computed on a subset.
        let analyzed = Set(finalRanked.map { $0.symbol.uppercased() })
        // Indices are DELIBERATELY skipped by buildIdeas (not buyable) — don't report them as fetch
        // failures, or ~17 healthy index tickers show a permanent "couldn't be fetched" with a retry
        // button that can never clear.
        let missing = Self.missingAfterScan(universe: universe.map(\.symbol),
                                            analyzed: analyzed, stillTracked: stillTracked)
        ideasMissing = missing
        // Scan deltas ("New" / "was <Action>" chips): compute vs the PRE-refresh persisted
        // baseline, THEN persist the new scan's map as the next baseline. Only this full-scan
        // commit writes the snapshot — retryFailedIdeas (partial) and seedQAIdeas (QA fixture)
        // deliberately never call save() (PLAN_2026-07-07_scan_deltas.md).
        let snapshotStore = StockSageScanSnapshotStore.shared
        scanDeltas = StockSageScanDelta.deltas(current: finalRanked, previous: snapshotStore.entries)
        // DEG-01: symbols missing-but-still-tracked (feed miss/429 THIS scan) carry their PRIOR
        // baseline entry forward instead of dropping out — see nextBaseline's doc comment.
        let nextBaseline = StockSageScanDelta.nextBaseline(ranked: finalRanked, missingButTracked: missing,
                                                            previous: snapshotStore.entries)
        snapshotStore.save(entries: nextBaseline)
        ideas = Self.ideasWithLatestPrices(finalRanked, symbols: symbols, previous: ideas)
        // FORWARD PAPER TRADING: auto-open a fake-money position for each long-actionable idea and mark
        // existing open paper trades to the fresh histories (net-of-cost). Separate store, never conflated
        // with the real journal; does NOT feed win-rate calibration (F01/F02). Best-effort, synchronous.
        updatePaperTrades(ideas: finalRanked, histories: paperHistories)
        // Populate earnings for EVERY tracked symbol (non-blocking), not just the board's top
        // names (A4, 2026-09-06) — TTL-cached per symbol, so this is cheap after the first sweep.
        restartEarningsSweep()
        // Same for seasonality — the TOM rank tilt must not depend on which sheets were opened.
        Task { await refreshSeasonalityForTopIdeas() }
        ideasUpdated = Date()

    }

    /// Cancel an in-flight ideas scan (backlog #12). The outer refreshIdeas defer clears the spinner.
    func cancelIdeasRefresh() { ideasRefreshTask?.cancel() }

    /// Result of `runChunkedScan` — everything a caller needs to commit (or discard) the scan.
    struct ChunkedScanResult {
        /// Scan accumulation, not current membership: cancel bookkeeping needs to know
        /// that a chunk published even if all of its ideas have since been removed.
        var ranked: [StockSageIdea]
        var accumulatedHistories: [String: StockSagePriceHistory]
        var scanThrottled: Bool
        var firstChunkTotallyFailed: Bool
        var wasCancelled: Bool
    }

    /// THE SHARED CHUNK LOOP (review round-2 finding 3): fetch → build → merge → publish, one
    /// chunk at a time, with the per-chunk 120s watchdog + cancel-forwarding + throttle-fallback
    /// — extracted out of `performRefreshIdeas` so `retryFailedIdeas` (previously an un-chunked
    /// single-shot hammer over the whole missing-symbol subset, up to ~2,100 names at scale) runs
    /// the SAME machinery instead of a second, drifting implementation. `cache`/`cachePriceHistories`
    /// are optional — `retryFailedIdeas` passes nil to keep its existing "always re-fetch the
    /// missing subset" behavior byte-identical (adding a cache-skip there would be a NEW behavior
    /// change, out of scope for this fix). `ideas`/`ideasProgress` are published live as the loop
    /// runs (both callers want the board to grow live). `onThrottle` fires the instant a chunk
    /// trips the fallback (mid-scan, not just in the final `ChunkedScanResult`) so a caller that
    /// wants the LIVE `@Published scanThrottled` banner (performRefreshIdeas) can wire it up;
    /// `retryFailedIdeas` passes nil — retry never had a throttle banner and must not start
    /// flipping the FULL-SCAN flag for a partial-subset retry (see its call site). The caller
    /// applies its OWN final tracked-set filtering, snapshot/alerts/history-cache-save policy
    /// AFTER this returns. Intermediate live publications also reconcile current tracking;
    /// the accumulated result retains the scan's history for cancel bookkeeping.
    func runChunkedScan(defs: [StockSageSymbol], total: Int, startingRanked: [StockSageIdea],
                                 cache: StockSageHistoryCache?, cachePriceHistories: [String: StockSagePriceHistory],
                                 benchmark: StockSagePriceHistory?, calibration: StockSageConvictionCalibration?,
                                 journalTrades: [TradeRecord], onThrottle: (() -> Void)? = nil,
                                 fetchAndBuild: (@MainActor ([StockSageSymbol]) async ->
                                    (histories: [String: StockSagePriceHistory], built: [StockSageIdea]))? = nil) async -> ChunkedScanResult {
        let chunks = StockSageScanChunking.chunks(defs)
        var accumulatedHistories: [String: StockSagePriceHistory] = [:]
        var ranked = startingRanked
        var firstChunkTotallyFailed = false
        var attemptedSoFar = 0
        // LOCAL throttle flag — NOT `self.scanThrottled` (that @Published property is
        // performRefreshIdeas' own full-scan banner state, cleared at ITS start; retryFailedIdeas
        // shares this loop but must never mutate that banner for a partial-subset retry). Each
        // caller decides what to do with the returned `scanThrottled` on `ChunkedScanResult`.
        var throttled = false

        for (chunkIndex, chunkDefs) in chunks.enumerated() {
            guard !Task.isCancelled else { return ChunkedScanResult(ranked: ranked, accumulatedHistories: accumulatedHistories, scanThrottled: throttled, firstChunkTotallyFailed: false, wasCancelled: true) }

            let symbols = chunkDefs.map(\.symbol)
            let (fromCache, toFetch): ([String], [String]) = cache != nil
                ? StockSageScanChunking.partitionByCacheFreshness(symbols: symbols, cache: cache)
                : ([], symbols)
            // Built as a `let` (comprehension, not a mutating loop) so the `chunkWork` Task below
            // captures an IMMUTABLE snapshot — silences the Swift 6 "mutated after capture by
            // sendable closure" warning the mutating `var` raised (the var was re-declared and
            // re-filled each loop iteration, which the compiler reads as a capture-then-mutate
            // race even though each iteration's value is fully built before the Task is created).
            // Behavior identical: same keys, same "cache hit wins" population.
            // uniquingKeysWith (NOT uniqueKeysWithValues, which TRAPS on a collision): two chunk
            // symbols differing only in case collapse to one uppercased key — the old `var`+assign
            // loop took last-write-wins there, so keep that exact behavior, never crash.
            let cachedHistories: [String: StockSagePriceHistory] = Dictionary(
                fromCache.compactMap { sym in
                    cachePriceHistories[sym.uppercased()].map { (sym.uppercased(), $0) }
                }, uniquingKeysWith: { _, latest in latest })

            let priorAttempted = attemptedSoFar + cachedHistories.count
            let chunkWork = Task { [weak self] () -> (histories: [String: StockSagePriceHistory], built: [StockSageIdea]) in
                // Tests can supply a suspended chunk while exercising this real loop's
                // cancellation, merge and publication. Production keeps the path below.
                if let fetchAndBuild { return await fetchAndBuild(chunkDefs) }
                let fetched = await StockSageQuoteService.fetchHistories(for: toFetch, onProgress: { [weak self] n in
                    self?.ideasProgress = (current: priorAttempted + n, total: total)
                })
                let merged = cachedHistories.merging(fetched) { _, new in new }
                guard !merged.isEmpty else { return (merged, []) }
                let built = await Self.buildIdeas(defs: chunkDefs, histories: merged, benchmark: benchmark,
                                                  calibration: calibration, journalTrades: journalTrades)
                return (merged, built)
            }
            let chunkWatchdog = Task {
                try? await Task.sleep(for: .seconds(120))
                if !Task.isCancelled { chunkWork.cancel() }
            }
            let (chunkHistories, built) = await withTaskCancellationHandler {
                await chunkWork.value
            } onCancel: {
                chunkWork.cancel()
            }
            chunkWatchdog.cancel()
            let chunkTimedOut = chunkWork.isCancelled

            guard !Task.isCancelled else { return ChunkedScanResult(ranked: ranked, accumulatedHistories: accumulatedHistories, scanThrottled: throttled, firstChunkTotallyFailed: false, wasCancelled: true) }

            let attempted = symbols.count
            let priced = chunkHistories.count

            if chunkIndex == 0 {
                guard !chunkHistories.isEmpty else {
                    firstChunkTotallyFailed = true
                    break
                }
            } else if StockSageScanChunking.shouldThrottle(chunkIndex: chunkIndex, priced: priced, attempted: attempted) {
                throttled = true
                onThrottle?()
            }

            accumulatedHistories.merge(chunkHistories) { _, new in new }
            attemptedSoFar += attempted
            ideasProgress = (current: attemptedSoFar, total: total)

            if !built.isEmpty {
                ranked = StockSageScanChunking.mergeChunk(current: ranked, newlyBuilt: built, rankScore: Self.rankScore)
                // A removal during this chunk's await must win on the LIVE board, including
                // retries/cancelled scans that never reach the final commit's membership filter.
                let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
                let visible = ranked.filter { stillTracked.contains($0.symbol.uppercased()) }
                ideas = Self.ideasWithLatestPrices(visible, symbols: self.symbols, previous: ideas)
            }

            // Audit 2026-07-12 (concurrency R1): a per-chunk watchdog timeout truncates the universe
            // scan to a PARTIAL board, but it set neither wasCancelled nor throttled — so the partial
            // board was returned as a COMPLETE success (ideasUpdated stamped fresh) and poisoned the
            // durable per-day money-velocity trend (MarketsView's record guard only skips on
            // lastScanCancelled||scanThrottled). A timeout is functionally the SAME "scan stopped
            // early, board is partial" state as a throttle trip, so raise the SAME signal: the
            // velocity guard skips it AND the partial-board banner surfaces the truncation — one
            // point, zero new plumbing.
            if chunkTimedOut, !throttled { throttled = true; onThrottle?() }
            if chunkTimedOut || (chunkIndex > 0 && throttled) { break }
        }

        return ChunkedScanResult(ranked: ranked, accumulatedHistories: accumulatedHistories,
                                  scanThrottled: throttled, firstChunkTotallyFailed: firstChunkTotallyFailed,
                                  wasCancelled: false)
    }

    /// Advance the forward PAPER-trading harness (fake money, honest net-of-cost). Runs after each ideas
    /// refresh on the MainActor with the just-fetched `histories` + `ideas`: closes any open paper trade a
    /// new bar resolved (stop/target/time-stop), then opens a paper trade for each long-actionable idea
    /// without an open position. All state lives in `StockSagePaperTradeStore` (SEPARATE from the real
    /// journal). Disabled ⇒ byte-identical to no paper trading. Pure orchestration lives in
    /// `StockSagePaperTrader.step`; this is only the thin persistence boundary. F01/F02 fence: paper
    /// outcomes never feed `convictionCalibration`.
    private var paperExitCursor: String?

    func paperExitHistories(existing: [String: StockSagePriceHistory],
        paper: StockSagePaperTradeStore = .shared,
        allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
        fetch: ([String]) async -> [String: StockSagePriceHistory] = {
            await StockSageQuoteService.fetchHistories(for: $0, range: "1y", concurrency: 6)
        }
    ) async -> [String: StockSagePriceHistory] {
        guard paper.enabled, paper.canWrite, !Task.isCancelled, allowed() else { return existing }
        let held = Set(paper.open.filter { $0.side == .long && $0.target != nil }.map { $0.symbol.uppercased() })
        let missing = held.subtracting(existing.keys.map { $0.uppercased() }).sorted()
        let ordered = missing.filter { $0 > (paperExitCursor ?? "") } + missing.filter { $0 <= (paperExitCursor ?? "") }
        // ponytail: at most six extra symbols per completed scan; rotate even failed requests.
        let batch = Array(ordered.prefix(6))
        guard let last = batch.last else { return existing }
        paperExitCursor = last
        let histories = await fetch(batch)
        guard paper.enabled, paper.canWrite, !Task.isCancelled, allowed() else { return existing }
        let stillHeld = Set(paper.open.map { $0.symbol.uppercased() })
        var result = existing
        for symbol in batch where stillHeld.contains(symbol) {
            if let h = histories[symbol], h.symbol.uppercased() == symbol { result[symbol] = h }
        }
        return result
    }

    private func updatePaperTrades(ideas: [StockSageIdea], histories: [String: StockSagePriceHistory]) {
        let store = StockSagePaperTradeStore.shared
        guard store.enabled, store.canWrite else { return }
        let (closes, opens) = StockSagePaperTrader.step(
            current: store.trades, ideas: ideas, histories: histories, openDate: Date(),
            costsFor: { StockSageNetEdge.defaultCosts(forSymbol: $0) })
        // MEM-01a: one mutation + ONE UserDefaults save instead of a per-call re-encode of the
        // whole (growing) array for every close and every open this cycle.
        store.apply(closes: closes, opens: opens)
        // Bias-corrected forward scoreboard: mark still-open trades to the latest close so the
        // closed-only selection bias (fast stop-outs resolve first) is corrected. Latest close per
        // symbol, from THIS scan's histories.
        var latestClose: [String: Double] = [:]
        var firstBarAt: [String: Date] = [:]
        var markAsOf: [String: Date] = [:]
        for (sym, h) in histories {
            if let c = h.closes.last, c > 0 { latestClose[sym.uppercased()] = c }
            // Oldest bar we have for this symbol: a position opened before it has an unverifiable
            // entry basis, so the scoreboard leaves it unmarked rather than marking a dead basis.
            if let first = h.dates.first { firstBarAt[sym.uppercased()] = first }
            // As-of for the MARK itself: the date of the bar `latestClose` came from. NOT the scan
            // clock and NOT the cache's savedAt — a cache-served symbol can carry a bar up to 7
            // days old, which is exactly the class of defect already reported at MarketsView:799.
            if let c = h.closes.last, c > 0, let last = h.dates.last { markAsOf[sym.uppercased()] = last }
        }
        store.updateScoreboard(latestClose: latestClose, firstBarAt: firstBarAt, markAsOf: markAsOf)
    }

    /// Re-fetch ONLY the symbols the last scan couldn't price and merge them in, re-ranking.
    /// Cheap relative to a full refresh; user-triggered from the "Retry failed" affordance.
    ///
    /// CHUNKED RETRY (review round-2 finding 3): at the full-universe scan scale (901 names post-restriction; was 2,420), `ideasMissing`
    /// can hold up to ~2,100 names (everything past a throttle trip) — retrying that as one
    /// un-chunked `fetchHistories` call was an unpaced hammer with no per-chunk watchdog/throttle/
    /// cancel of its own. Now routed through the SAME `runChunkedScan` the full scan uses (chunks +
    /// per-chunk watchdog + shouldThrottle + the cancel handler), just over the missing subset.
    /// `cache: nil` keeps retry's existing "always re-fetch, never cache-skip" behavior byte-identical
    /// (see runChunkedScan's doc comment); `onThrottle: nil` keeps retry silent on the FULL-SCAN
    /// `scanThrottled` banner (a partial retry throttling internally is not "the whole board's scan
    /// paused"). Retry's own semantics are otherwise UNCHANGED: merge into board, stillTracked
    /// reconcile, no snapshot write, no ideasUpdated advance (all below, exactly as before).
    ///
    /// CANCEL-BUTTON-DEAD-DURING-RETRY (post-ship critique fleet, orchestrator-confirmed): retained
    /// in `ideasRefreshTask` exactly like `refreshIdeas`, so the Cancel button (which renders
    /// whenever `isLoadingIdeas`, true for both operations) actually cancels a retry too — it was
    /// previously a no-op mid-retry. Thin public wrapper mirrors `refreshIdeas`'s task-retention
    /// pattern; the work lives in `performRetryFailedIdeas`.
    func retryFailedIdeas() async {
        guard !isLoadingIdeas, !ideasMissing.isEmpty else { return }
        if let reason = ToolPolicy.webToolsDisabledReason() { ideasError = reason; return }
        isLoadingIdeas = true
        defer { isLoadingIdeas = false }
        let task = Task { await self.performRetryFailedIdeas() }
        ideasRefreshTask = task
        await task.value
        ideasRefreshTask = nil
    }

    private func performRetryFailedIdeas() async {
        ideasError = nil
        // PROGRESS-RESEED (post-ship critique fleet, orchestrator-confirmed): mirror
        // performRefreshIdeas — without this, the previous operation's ideasProgress (e.g. a
        // finished "2400/2400") stays visible for retry's first frames instead of reflecting the
        // subset actually being retried.
        let retryTotal = ideasMissing.count
        ideasProgress = (current: 0, total: retryTotal)
        defer { ideasProgress = nil }
        let cal = convictionCalibration                           // read on the main actor before the await hop
        let journalTrades = self.journalTrades()   // read on the main actor before the await hop
        let retrySet = Set(ideasMissing.map { $0.uppercased() })
        // CONCURRENCY #3: ONE universe snapshot BEFORE the await — the missing-list below must
        // be computed against the same set that was scanned, not a fresh post-await read that
        // can contain a just-added (priced, on-board) ticker and falsely banner it as a failure.
        let universe = trackedDefs()
        let defs = universe.filter { retrySet.contains($0.symbol.uppercased()) }
        let benchmark = await StockSageQuoteService.fetchHistory("^GSPC", range: "1y")
        guard !Task.isCancelled else { return }

        let scan = await runChunkedScan(defs: defs, total: defs.count, startingRanked: ideas,
                                        cache: nil, cachePriceHistories: [:],
                                        benchmark: benchmark, calibration: cal, journalTrades: journalTrades)
        if scan.wasCancelled {
            // Same honesty rule as the full-scan cancel path: if the cancelled retry already
            // merged some previously-missing symbols onto the board, re-name what's STILL missing
            // instead of leaving ideasMissing describing symbols that just got fetched (which
            // would make the "Retry failed" affordance look stuck even after it half-worked).
            let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
            let publishedBoardSymbols = Set(scan.ranked.map { $0.symbol.uppercased() })
            if let commit = Self.cancelledScanCommit(universe: universe.map(\.symbol),
                                                      publishedBoardSymbols: publishedBoardSymbols,
                                                      stillTracked: stillTracked) {
                ideasMissing = commit.ideasMissing
                // Deliberately do NOT touch scanDeltas here — retry never wrote deltas in the
                // first place (DEG-02/PLAN_2026-07-07_scan_deltas.md), so there is nothing to
                // clear; clearing them would erase a valid full-scan baseline over a partial retry.
            }
            return
        }
        guard !scan.accumulatedHistories.isEmpty else {
            ideasError = "Still couldn't reach those symbols — try again later."
            return
        }
        // Re-reconcile vs the current tracked set (mirror refreshIdeas): a removeSymbol() during the
        // retry await must not resurrect the dropped ticker via the pre-await `defs`/`built`.
        let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
        let merged = scan.ranked.filter { stillTracked.contains($0.symbol.uppercased()) }
            .sorted { Self.rankScore($0.advice) > Self.rankScore($1.advice) }
        ideas = Self.ideasWithLatestPrices(merged, symbols: symbols, previous: ideas)
        let analyzed = Set(merged.map { $0.symbol.uppercased() })
        ideasMissing = Self.missingAfterScan(universe: universe.map(\.symbol),
                                             analyzed: analyzed, stillTracked: stillTracked)
        // STALE-THROTTLE-BANNER (post-ship critique fleet, orchestrator-confirmed): a retry that
        // prices EVERYTHING previously-missing leaves the "Extended scan paused" banner rendering
        // forever otherwise (scanThrottled is only ever cleared at a FULL scan's start).
        if ideasMissing.isEmpty { scanThrottled = false }
        // DEG-02: deliberately NOT advancing ideasUpdated here — this path re-analyzes only the
        // FAILED subset, and ideasUpdated drives the whole board's staleness chrome (ideasIsStale
        // chip/dim + its a11y clause). Bumping it on a partial merge would reset that chrome for
        // every card, including ones untouched by this retry. The retried cards' own
        // idea.generatedAt still carries their individual freshness.
    }

    /// CONCURRENCY #3: the "couldn't be fetched" list, derived from ONE pre-await `universe`
    /// snapshot — shared by refreshIdeas AND retryFailedIdeas so the two paths cannot disagree.
    /// A ticker ADDED during the await is absent from `universe` → never falsely bannered as a
    /// fetch failure (the next full refresh scans it); a ticker REMOVED during the await is
    /// dropped via `stillTracked`; indices are never "missing" (not buyable, no idea to build).
    /// Pure + testable (StockSageIdeasMissingTests).
    nonisolated static func missingAfterScan(universe: [String], analyzed: Set<String>,
                                             stillTracked: Set<String>) -> [String] {
        universe.filter {
            stillTracked.contains($0.uppercased()) &&
            !analyzed.contains($0.uppercased()) &&
            StockSageAllocation.assetClass($0) != "Index"
        }
    }

    /// Result of `cancelledScanCommit` — nil when a cancel published nothing (true no-op: leave
    /// `ideasMissing`/`scanDeltas` exactly as they were before this scan started).
    struct CancelledScanCommit: Equatable {
        var ideasMissing: [String]
        var scanDeltas: [String: ScanDelta]   // always [:] — named for call-site clarity, not variance
    }

    /// CANCEL NAMES COVERAGE (post-ship critique fleet, orchestrator-confirmed): the reduced,
    /// honest commit `performRefreshIdeas` runs when a scan is cancelled AFTER at least one chunk
    /// already published to the board. Pure over its inputs so the cancel-commit DECISION (run vs
    /// no-op, and what it names) is unit-testable without the MainActor store. Mirrors the
    /// normal-path call to `missingAfterScan` exactly — same three inputs, same semantics — and
    /// always clears deltas to `[:]` (the previous baseline no longer describes the changed
    /// board; an empty dict is an honest absence, never a stale claim). Returns nil when nothing
    /// published (`publishedBoardSymbols` empty) — the caller must leave prior state untouched,
    /// not overwrite it with an equally-stale "nothing missing".
    nonisolated static func cancelledScanCommit(universe: [String], publishedBoardSymbols: Set<String>,
                                                stillTracked: Set<String>) -> CancelledScanCommit? {
        guard !publishedBoardSymbols.isEmpty else { return nil }
        let missing = missingAfterScan(universe: universe, analyzed: publishedBoardSymbols, stillTracked: stillTracked)
        return CancelledScanCommit(ideasMissing: missing, scanDeltas: [:])
    }

    /// What a CANCELLED scan's best-effort `HistoryCache` save should write, if anything.
    /// `StockSageHistoryCache.save()` atomically REPLACES the whole on-disk file — so a cancel
    /// after chunk 0 of a midday re-scan (prior cache already same-day-fresh, one entry per universe name)
    /// blindly saving just `scan.accumulatedHistories` (~250 entries) would DESTROY the other
    /// ~2,170 same-day-fresh entries, inverting the very 429-protection this best-effort save
    /// exists for (`partitionByCacheFreshness` would re-fetch everything the cancel just erased).
    /// Two honest cases:
    /// - Prior cache is from the SAME UTC day as `now`: every one of its carried-forward entries
    ///   genuinely WAS saved today, so merging `accumulated` OVER `priorCacheHistories` and
    ///   stamping `savedAt: now` stays honest — `.merge` with `{ _, new in new }` lets freshly
    ///   re-fetched symbols win over their stale-same-day counterpart.
    /// - Prior cache is from an EARLIER day (or there is no prior cache): none of its entries are
    ///   "saved today", so they can't be merged under a single honest `savedAt`. Save
    ///   `accumulated` ALONE only when it is a superset of the prior cache's symbols (or there's
    ///   no prior cache) — i.e. only when doing so can't shrink coverage. Otherwise SKIP the save
    ///   entirely (the pre-hoist behavior): a partial cross-day accumulation is not allowed to
    ///   evict entries the next scan's `partitionByCacheFreshness` would otherwise still be able
    ///   to skip re-fetching — no save at all is the safe, honest default.
    /// Per-entry `savedAt` (schema v2) is the complete fix and is intentionally NOT done here
    /// (out of scope for this fix; see the doc comment on the call site).
    nonisolated static func cancelSaveDecision(priorCacheSymbols: Set<String>, priorCacheSavedAtDayKey: Int?,
                                               accumulated: [String: StockSagePriceHistory],
                                               priorCacheHistories: [String: StockSagePriceHistory],
                                               nowDayKey: Int) -> [String: StockSagePriceHistory]? {
        guard !accumulated.isEmpty else { return nil }
        if let priorDay = priorCacheSavedAtDayKey, priorDay == nowDayKey {
            return priorCacheHistories.merging(accumulated) { _, new in new }
        }
        let accumulatedSymbols = Set(accumulated.keys.map { $0.uppercased() })
        if priorCacheSymbols.isEmpty || accumulatedSymbols.isSuperset(of: priorCacheSymbols) {
            return accumulated
        }
        return nil
    }

    /// Build ranked ideas off the main actor (the advisor runs every indicator over each
    /// symbol's full year). Pure over its inputs; everything it touches is Sendable.
    nonisolated static func buildIdeas(defs: [StockSageSymbol],
                                       histories: [String: StockSagePriceHistory],
                                       benchmark: StockSagePriceHistory? = nil,
                                       calibration: StockSageConvictionCalibration? = nil,
                                       journalTrades: [TradeRecord] = []) async -> [StockSageIdea] {
        await Task.detached(priority: .userInitiated) {
            var out: [StockSageIdea] = []
            // Sector rotation (HARDENING_BACKLOG #31, reframed flag-only): rank ONCE per
            // buildIdeas call (not per-symbol) and reuse across the loop — same cost profile as
            // `calibration`/`benchmark`. journalTrades defaults to [] so `analyze` returns [] and
            // every per-symbol lookup below is a no-op — omitting it is byte-identical to today.
            let sectorRotation = StockSageSectorRotation.analyze(allTrades: journalTrades)
            for sym in defs {
                guard let history = histories[sym.symbol.uppercased()], let price = history.latestClose else { continue }
                // An index LEVEL (^GSPC/^VIX) is not a buyable instrument — never surface it as a
                // buy/stop/target/size idea (it would also pollute the EV/velocity/allocator math).
                guard StockSageAllocation.assetClass(sym.symbol) != "Index" else { continue }
                // Relative-strength-vs-S&P only means something for EQUITIES — pass the benchmark only
                // there so FX/crypto don't get a meaningless "Leading/Lagging the S&P" term (and an
                // index never benchmarks against itself, now moot since indices are excluded above).
                let bench = StockSageAllocation.assetClass(sym.symbol) == "Equity" ? benchmark : nil
                var advice = StockSageAdvisor.advise(history: history, benchmark: bench)
                // Re-size on the CALIBRATED win-prob (advise() used the conservative linear prior — it
                // is pure and can't see the runtime calibration). nil calibration ⇒ recompute returns the
                // SAME prior weight, so the value is unchanged. Only suggestedWeight differs; the
                // directional score, action, conviction, stop and target are advise()'s deterministic output.
                if let calibration {
                    // Realized vol from the FULL raw closes (matches the advisor) for vol-targeting.
                    let realizedVolForSizing = StockSageIndicators.annualizedVolatility(history.closes)
                    let calibratedWeight = StockSageAdvisor.suggestedWeight(
                        action: advice.action, conviction: advice.conviction, price: price,
                        stop: advice.stopPrice, target: advice.targetPrice,
                        realizedVol: realizedVolForSizing, calibration: calibration)
                    advice = TradeAdvice(action: advice.action, conviction: advice.conviction,
                                         regime: advice.regime, rationale: advice.rationale,
                                         stopPrice: advice.stopPrice, targetPrice: advice.targetPrice,
                                         suggestedWeight: calibratedWeight, caveat: advice.caveat,
                                         stopMultiplier: advice.stopMultiplier, stopReason: advice.stopReason,
                                         timeframeAligned: advice.timeframeAligned, confluenceNote: advice.confluenceNote)
                }
                // Honesty-only risk reads (EDGE_RESEARCH #4/#5): flag-only notes appended to the
                // rationale shown in the detail-sheet "Why" ForEach. NOT a sizing/score input —
                // advise() is untouched. Computed once per idea here, never in the bar-by-bar backtester.
                var extraNotes: [String] = []
                if let shape = StockSageReturnShape.returnShape(closes: history.closes), shape.isLeftTailed {
                    extraNotes.append("⚠ Left-tailed history — worst days exceed what its volatility implies; your stop may gap. " + shape.note)
                }
                if let stab = StockSageVolStability.volStability(closes: history.closes) {
                    if case .erratic = stab.band {
                        extraNotes.append("⚠ Whippy volatility — stop width / size are less reliable here; trade smaller. " + stab.note)
                    }
                }
                // Vol regime brake (EDGE_RESEARCH #1): flag in "Why" + applies sizingMultiplier in allocator.
                let volRegime = StockSageVolRegime.regime(closes: history.closes)
                if let vr = volRegime, vr.sizingMultiplier < 0.95 {
                    extraNotes.append("⚠ " + vr.note)
                }
                // Sector-rotation confirmation (HARDENING_BACKLOG #31, reframed flag-only — see
                // StockSageSectorRotation.swift header). Surfaced note ONLY: `advice.conviction`,
                // `.suggestedWeight`, `.stopPrice`, `.targetPrice` are untouched below, exactly
                // like the ReturnShape/VolStability blocks above.
                if let rotation = sectorRotation.first(where: { $0.sector == StockSageSector.sector(sym.symbol) }),
                   rotation.isRotatingIn {
                    extraNotes.append("⚠ " + rotation.note)
                }
                // Execution-timing advisory (week-horizon velocity research #2): flag-only, never
                // touches score/conviction/sizing — see StockSageExecutionTiming's header for the
                // evidence and the .bullTrend/.bearTrend-only gate.
                if let timingNote = StockSageExecutionTiming.sessionNote(action: advice.action, regime: advice.regime, symbol: sym.symbol) {   // wave-2 #6: US-gated microstructure
                    extraNotes.append("⏱ " + timingNote)
                }
                if !extraNotes.isEmpty {
                    advice = TradeAdvice(action: advice.action, conviction: advice.conviction,
                                         regime: advice.regime, rationale: advice.rationale + extraNotes,
                                         stopPrice: advice.stopPrice, targetPrice: advice.targetPrice,
                                         suggestedWeight: advice.suggestedWeight, caveat: advice.caveat,
                                         stopMultiplier: advice.stopMultiplier, stopReason: advice.stopReason,
                                         timeframeAligned: advice.timeframeAligned, confluenceNote: advice.confluenceNote)
                }
                let recent = Array(history.closes.suffix(63))
                let spark = SparkSeries.downsample(recent)
                // True daily move from the UN-downsampled closes (spark points are ~2 days apart).
                let dailyMove = StockSageExpectedValue.typicalDailyMove(recent)
                // Realized vol from the FULL raw closes (matches the advisor) for allocator vol-targeting.
                let realizedVol = StockSageIndicators.annualizedVolatility(history.closes)
                // Momentum quality from the FULL raw closes — requires at least 21 bars for the
                // loosest internal signal (Kaufman efficiencyRatio, period 20 → needs count > 20).
                // When closes are too short for ALL signals, momentumQuality() returns the neutral
                // sentinel 1.0 (no data ⇒ no penalty), which is NOT a real quality score — store
                // nil instead so callers know "unknown" vs a measured value.
                let momentumQuality: Double? = history.closes.count > 20
                    ? StockSageExpectedValue.momentumQuality(for: StockSageIdea(symbol: sym.symbol,
                        market: sym.market, price: price, advice: advice, spark: spark),
                        closes: history.closes)
                    : nil
                // At-the-extreme honesty fix (L1, 2026-07-07): compute over the RAW `recent`
                // window (same array `dailyMove` uses), NOT the downsampled `spark` — a true
                // high/low that downsample skips must not be missed. span = recent.count
                // (min(history.closes.count, 63)) is the ACTUAL window checked, so the chip can
                // say "At N-day high/low" with a real N instead of assuming a fixed 63.
                let recentExtreme = SparkSeries.extreme(recent)
                let recentExtremeSpan = recent.count
                // Price-staleness label (round-3 honesty hunt): the LAST BAR's own date, whether
                // that bar came from a fresh fetch or a same-UTC-day cache reuse — distinct from
                // `generatedAt` below, which is always "now" regardless of where the price came from.
                let priceAsOf = history.dates.last
                out.append(StockSageIdea(symbol: sym.symbol, market: sym.market,
                                         price: price, advice: advice, spark: spark,
                                         dailyMove: dailyMove, realizedVol: realizedVol,
                                         volRegime: volRegime, generatedAt: Date(),
                                         momentumQuality: momentumQuality,
                                         recentExtreme: recentExtreme, recentExtremeSpan: recentExtremeSpan,
                                         priceAsOf: priceAsOf, priceSource: history.priceSource))
            }
            return out
        }.value
    }

    // Risk-parity — inverse-vol target weights across the owner's holdings.
    @Published private(set) var riskParity: [RiskParityTarget] = []
    /// Holdings excluded from the risk-parity calculation — no fetchable price history, or
    /// non-positive volatility — too sparse to size.
    @Published private(set) var riskParityDropped: [String] = []
    @Published private(set) var isComputingParity = false
    @Published private(set) var parityError: String?

    /// Fetch each holding's history, derive its annualized volatility, and compute
    /// inverse-vol (risk-parity) target weights + rebalance deltas. User-triggered;
    /// non-destructive on failure.
    func refreshRiskParity() async {
        guard !isComputingParity else { return }
        let positions = StockSagePortfolio.shared.positions
        guard !positions.isEmpty else {
            riskParity = []
            parityError = "Add holdings to your portfolio first."
            return
        }
        if let reason = ToolPolicy.webToolsDisabledReason() {
            parityError = reason
            return
        }
        isComputingParity = true
        parityError = nil
        let histories = await StockSageQuoteService.fetchHistories(for: Array(Set(positions.map(\.symbol))).sorted())
        isComputingParity = false

        let (holdings, dropped) = Self.splitRiskParityHoldings(positions: positions, histories: histories)
        guard !holdings.isEmpty else {
            parityError = "Couldn't get enough history to risk-size the portfolio."
            return
        }
        riskParityDropped = dropped
        riskParity = StockSageRiskParity.targets(holdings)
    }

    /// Pure split of positions into risk-sizeable holdings vs the ones excluded (no fetchable
    /// history, non-positive volatility, or no price) — the exclusion is recorded AT THE POINT
    /// each position fails, not re-derived afterward by filtering the already-filtered
    /// `holdings` array (that predicate could never be true, since everything appended there
    /// already satisfies volatility > 0 by construction). Pure + testable without a network fetch.
    nonisolated static func splitRiskParityHoldings(positions: [PortfolioPosition],
                                                     histories: [String: StockSagePriceHistory])
        -> (holdings: [RiskParityHolding], dropped: [String]) {
        var holdings: [RiskParityHolding] = []
        var dropped: [String] = []
        for p in StockSagePortfolio.holdingBySymbol(in: positions).values.sorted(by: { $0.symbol < $1.symbol }) {
            guard let history = histories[p.symbol.uppercased()],
                  let vol = StockSageIndicators.annualizedVolatility(history.closes), vol > 0,
                  let price = history.latestClose else {
                dropped.append(p.symbol)
                continue
            }
            holdings.append(RiskParityHolding(symbol: p.symbol, currentValue: price * p.shares, volatility: vol))
        }
        return (holdings, dropped)
    }

    // Market regime — the risk-on/off meta-gauge.
    @Published private(set) var regime: MarketRegime?
    @Published private(set) var regimeGaugedAt: Date?
    @Published private(set) var isLoadingRegime = false
    @Published private(set) var regimeError: String?
    @Published private(set) var regimeEvidence: [String: (source: StockSagePriceSource, asOf: Date)] = [:]

    /// Gauge the market regime: the S&P 500 vs its 200DMA + index momentum, the
    /// VIX level, and breadth (fraction of a large-cap sample above their own
    /// 200DMA). User-triggered; non-destructive on failure.
    func refreshRegime(now: () -> Date = Date.init,
        allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
        load: () async -> (StockSagePriceHistory?, StockSageQuoteService.LiveQuote?, [String: StockSagePriceHistory]) = {
            async let index = StockSageQuoteService.fetchHistory("^GSPC", range: "1y")
            async let quotes = StockSageQuoteService.fetchQuotes(for: ["^VIX"])
            async let breadth = StockSageQuoteService.fetchHistories(for: StockSageRegime.breadthSample)
            return await (index, quotes["^VIX"], breadth)
        }
    ) async {
        guard !isLoadingRegime else { return }
        if !allowed() {
            regimeError = "Web access unavailable — gauge not refreshed."
            return
        }
        isLoadingRegime = true
        defer { isLoadingRegime = false }
        regimeError = nil

        let sample = StockSageRegime.breadthSample
        let (idx, vixQuote, hists) = await load()
        let checkedAt = now()

        // 7.1 — fail closed on an invalidation that landed mid-fetch. `fetchHistories` returns [:]
        // the moment web access is revoked, and every leg nils once this task is cancelled — and
        // the auto-gauge at MarketsView:586 sits in a `.task` SwiftUI cancels when the tab
        // disappears, with the single-request index leg normally resolving long before the
        // 14-name breadth fan-out. Publishing past that point stamps `regimeGaugedAt` fresh on a
        // breadth computed from whatever subset arrived.
        guard allowed(), !Task.isCancelled else {
            regimeError = ToolPolicy.webToolsDisabledReason() ?? "Gauge interrupted — try again."
            return
        }

        guard let idx, idx.symbol.uppercased() == "^GSPC",
              let indexAt = StockSageRegime.historyAsOf(idx, now: checkedAt) else {
            regimeError = "Market index evidence is missing, invalid or stale — previous gauge retained. Try again."
            return
        }
        // Breadth: fraction of the sample above its own 200DMA (names without a
        // computable 200DMA are excluded from the denominator — see the helper).
        //
        // 7.2 (owner-approved 2026-09-11): that exclusion means a thin fetch still produces a
        // confident percentage — 1 of 14 names reads as "100% of names above their 200DMA" — and
        // breadth multiplies every Deploy-capital weight through `sizingBias`. Below the coverage
        // floor, abstain and SAY SO. A nil breadth already abstains cleanly in `assess`, so sizing
        // falls back to neutral rather than to a bias derived from half a sample.
        let priced = sample.compactMap { symbol -> StockSagePriceHistory? in
            guard let h = hists[symbol], h.symbol.uppercased() == symbol,
                  StockSageRegime.historyAsOf(h, now: checkedAt) != nil else { return nil }
            return h
        }
        let eligible = StockSageRegime.breadthEligibleCount(priced)
        let hasCoverage = StockSageRegime.breadthHasCoverage(eligible: eligible, requested: sample.count)
        let breadth = hasCoverage ? StockSageRegime.breadth(priced) : nil
        if !hasCoverage {
            regimeError = "Breadth unavailable — only \(eligible) of \(sample.count) sample names returned enough history. The regime below is gauged without it."
        }

        var evidence: [String: (source: StockSagePriceSource, asOf: Date)] = ["^GSPC": (idx.priceSource!, indexAt)]
        if hasCoverage {
            for h in priced where StockSageRegime.breadthEligibleCount([h]) == 1 {
                evidence[h.symbol.uppercased()] = (h.priceSource!, h.dates.last!)
            }
        }
        var vix: Double?
        if let q = vixQuote, q.symbol.uppercased() == "^VIX", q.price.isFinite, q.price > 0,
           q.priceSource == .yahoo || q.priceSource == .massiveSIP,
           !StockSageQuoteFreshness.isStale(symbol: "^VIX", marketTime: q.marketTime, asOf: checkedAt),
           let at = q.marketTime, let source = q.priceSource {
            vix = q.price
            evidence["^VIX"] = (source, at)
        } else {
            regimeError = [regimeError, "VIX unavailable — no fresh attributed observation; gauge excludes this vote."].compactMap { $0 }.joined(separator: " ")
        }
        regime = StockSageRegime.assess(indexCloses: idx.closes, vix: vix, breadthAbove200: breadth)
        regimeEvidence = evidence
        regimeGaugedAt = checkedAt
    }

    /// True when the regime is older than ~6 trading hours (or never gauged) — a
    /// signal that any regime-derived sizing should be treated cautiously.
    var regimeIsStale: Bool {
        regimeIsStale(at: Date())
    }

    func regimeIsStale(at now: Date) -> Bool {
        guard let at = regimeGaugedAt, now >= at, now.timeIntervalSince(at) <= 6 * 3600,
              regimeEvidence["^GSPC"] != nil else { return true }
        return regimeEvidence.contains { symbol, input in
            symbol == "^VIX" ? StockSageQuoteFreshness.isStale(symbol: symbol, marketTime: input.asOf, asOf: now)
                : StockSageHistoryCache.isStale(newest: input.asOf, asOf: now)
        }
    }

    var regimeEvidenceText: String {
        guard let oldest = regimeEvidence.values.map(\.asOf).min() else { return "Input dates unverified" }
        let sources = Set(regimeEvidence.values.map { $0.source.label }).sorted().joined(separator: ", ")
        return "Inputs: \(sources) · oldest observation \(oldest.formatted(date: .abbreviated, time: .shortened))"
    }

    var ideasIsStale: Bool {
        guard let at = ideasUpdated else { return false }
        return Date().timeIntervalSince(at) > 4 * 3600
    }

    // Multi-timeframe — daily+weekly trend agreement, cached per symbol.
    @Published private(set) var multiTimeframe: [String: MultiTimeframeTrend] = [:]
    @Published private(set) var derivedResearchRevision = UUID()
    private var derivedRequests: [String: UUID] = [:]

    func invalidateDerivedResearch() {
        multiTimeframe.removeAll(); liquidity.removeAll(); trailingStop.removeAll()
        derivedRequests.removeAll()
        derivedResearchRevision = UUID()
    }

    /// Fetch a daily (1y) AND a weekly (2y, interval=1wk) history for one symbol and
    /// replace the detail study using attributed input dates, never an indefinite cache hit.
    func refreshMultiTimeframe(symbol: String,
        allowed: () -> Bool = { ToolPolicy.isExternalAllowed },
        now: () -> Date = Date.init,
        history: @MainActor @Sendable (String, String, String) async -> StockSagePriceHistory? = {
            await StockSageQuoteService.fetchHistory($0, range: $1, interval: $2)
        }
    ) async {
        let up = symbol.uppercased()
        guard !Task.isCancelled else { return }
        let key = "mtf:" + up, request = UUID()
        derivedRequests[key] = request
        multiTimeframe.removeValue(forKey: up)
        defer { if derivedRequests[key] == request { derivedRequests.removeValue(forKey: key) } }
        guard allowed() else { return }
        async let dailyHistory = history(symbol, "1y", "1d")
        async let weeklyHistory = history(symbol, "2y", "1wk")
        guard let d = await dailyHistory, let w = await weeklyHistory,
              !Task.isCancelled, allowed(), derivedRequests[key] == request,
              d.symbol.uppercased() == up, w.symbol.uppercased() == up,
              let dailyDate = StockSageRegime.historyAsOf(d, now: now()),
              StockSageRegime.historyAsOf(w, now: now(), coveringDailyDate: dailyDate) != nil else { return }
        multiTimeframe[up] = StockSageMultiTimeframe.assess(dailyCloses: d.closes, weeklyCloses: w.closes)
    }

    // Strategy backtest — the advisor's rules aggregated across a sample universe.
    @Published private(set) var strategyBacktest: StrategyBacktest?
    @Published private(set) var isLoadingStrategy = false
    @Published private(set) var strategyError: String?
    /// Conviction→win-probability calibration learned from the strategy BACKTEST's trades. nil until
    /// a backtest has run with enough trades.
    @Published private(set) var backtestConvictionCalibration: StockSageConvictionCalibration?
    /// Provenance (source recipe + data-as-of date) for `backtestConvictionCalibration` when it came
    /// from a PERSISTED fit (manual backtest or an offline auto-fit) — nil when no snapshot has ever
    /// been saved/loaded this run. Display-only (Decision 5); has no effect on ranking/sizing.
    @Published private(set) var persistedCalibrationSnapshot: StockSageConvictionCalibration.Snapshot?

    /// F12 (2026-07-02): memoization for the journal calibration fit + OOS check. The fit
    /// (chronological split + IRLS + PAV + OOS selector) used to re-run on EVERY read of
    /// `convictionCalibration` — 33 read sites per MarketsView body render, on the MainActor.
    /// Keyed by VALUE equality of the journal's trades array, so ANY journal mutation
    /// (add/close/remove — current AND future mutators alike, no per-func invalidation hooks to
    /// forget) invalidates on the very next read: a just-closed trade still affects the very next
    /// render. Behavior identical, work amortized. `fitCount` exists purely so tests can pin the
    /// memoization contract (compute-once on repeat reads, recompute-on-change).
    struct JournalCalibrationCache {
        private var key: [TradeRecord]?
        private var cachedFit: StockSageConvictionCalibration?
        private var cachedOOS: StockSageConvictionCalibration.OOSCalibrationCheck?
        private(set) var fitCount = 0

        nonisolated mutating func value(for trades: [TradeRecord])
            -> (fit: StockSageConvictionCalibration?, oos: StockSageConvictionCalibration.OOSCalibrationCheck?) {
            if key != trades {
                cachedFit = StockSageConvictionCalibration.fit(fromJournal: trades)
                cachedOOS = StockSageConvictionCalibration.validateOutOfSample(trades)
                key = trades
                fitCount += 1
            }
            return (cachedFit, cachedOOS)
        }
    }
    private var calibrationFitCache = JournalCalibrationCache()

    /// QA-capture determinism seam (F6, calibration runtime activation review). When true,
    /// `convictionCalibration` below drops the persisted/backtest leg entirely — every EV/sizing/
    /// velocity/chip consumer (33+ read sites in MarketsView, per the memoization comment above)
    /// falls through to the journal fit (nil during a QA capture — `QASnapshots.seedQAJournal`
    /// deliberately keeps the seeded journal under the 30-trade calibration floor) or the
    /// conservative linear prior. WITHOUT this, the capture's rendered pixels — not just the chip
    /// tooltip, but every EV$/Size/velocity number derived from `convictionCalibration` — would
    /// depend on whatever `stocksage.calibration.v1` happens to hold on the CAPTURE MACHINE, or on
    /// whether Trigger B's async launch auto-fit (init, above) raced to completion before the
    /// capture ran. Gating here, at the single read choke point, makes both irrelevant: even if
    /// Trigger B's Task completes mid-capture and mutates `backtestConvictionCalibration`, this
    /// getter never surfaces it while suppressed — no separate gate on Trigger B itself is needed.
    /// The legacy capture override shares the store's MainActor isolation.
    static var qaSuppressPersistedCalibration = false

    /// EFFECTIVE conviction calibration the whole app sizes/ranks on: the owner's OWN realized edge
    /// (their journal) when it has enough closed conviction-trades, ELSE the sample-backtest fit, ELSE
    /// nil (callers fall back to the conservative linear prior). The journal beats a generic backtest —
    /// it captures the owner's real fills, slippage, and discipline. Check `.method` for provenance
    /// (isotonicWilson/beta/platt/identity) — conservatism depends on the fit path, NOT on non-nil.
    /// Cached per journal state (F12); any journal change is picked up on the very next read.
    var convictionCalibration: StockSageConvictionCalibration? {
        let journalFit = calibrationFitCache.value(for: journalTrades()).fit
        if Self.qaSuppressPersistedCalibration { return journalFit }
        return journalFit ?? backtestConvictionCalibration
    }

    /// OUT-OF-SAMPLE honesty check of the conviction→win-prob map on the owner's journal: fit on their
    /// earlier trades, score on later held-out ones (purged/embargoed split) vs a no-skill base-rate
    /// predictor. nil until the journal has enough closed trades to split + fit — so it shows only once
    /// there's a real OOS verdict to give (small-sample-noisy by nature). Cached with the fit (F12).
    var calibrationOOS: StockSageConvictionCalibration.OOSCalibrationCheck? {
        calibrationFitCache.value(for: journalTrades()).oos
    }

    /// True when the EFFECTIVE calibration (`convictionCalibration`) is the backtest leg — the
    /// owner's journal isn't rich enough to fit its own map yet. Gates the persisted-provenance
    /// help line in MarketsView's calibrationChip (Decision 5): the journal fit carries no
    /// snapshot of its own, so provenance only ever applies to the backtest leg.
    var convictionCalibrationIsFromBacktest: Bool {
        calibrationFitCache.value(for: journalTrades()).fit == nil
            && backtestConvictionCalibration != nil
    }

    /// Staleness rule for the offline auto-fit trigger (Decision 3): no snapshot ever persisted,
    /// or its training data is more than 7 days old. Mirrors `StockSageHistoryCache.isStale`'s
    /// default 7-day window (StockSageHistoryCache.swift:80-85) — `fittedAt` is the DATA as-of
    /// date (F5: equals the fit-run time for the manual-backtest/scan-end writers, which fit on
    /// data fetched immediately prior; equals `cache.savedAt` for the cache-offline writer — see
    /// `Snapshot.fittedAt`'s doc), so this measures data age, not fit-run age.
    /// `nonisolated` + pure so it's unit-testable without the `@MainActor` singleton.
    nonisolated static func shouldAutoFit(snapshot: StockSageConvictionCalibration.Snapshot?, now: Date) -> Bool {
        guard let s = snapshot, s.usableCalibration != nil else { return true }
        return now.timeIntervalSince(s.fittedAt) > 7 * 86_400
    }

    /// Fit a fresh conviction calibration from the given histories (offline, zero new network —
    /// `StockSageStrategyBacktest.offlineCalibrationFit` never touches `StockSageQuoteService`)
    /// and persist it. No-op when the pooled sample is too thin to fit honestly (keeps the
    /// existing snapshot + in-memory value; its displayed `fittedAt` stays honest either way).
    /// `defaults`/`key` injectable (F4, mirrors `Snapshot.load`/`save`'s own seam) purely so tests
    /// can drive this REAL method end-to-end against an isolated suite instead of `.standard` —
    /// production callers (both triggers + init) never pass them, so they get the exact same
    /// `.standard`/`"stocksage.calibration.v1"` behavior as before this seam existed.
    func autoFitCalibration(histories: [String: StockSagePriceHistory], benchmark: StockSagePriceHistory?,
                            source: String, dataAsOf: Date,
                            defaults: UserDefaults = .standard, key: String = "stocksage.calibration.v1") async {
        let fit = await Task.detached {
            StockSageStrategyBacktest.offlineCalibrationFit(histories: histories, benchmark: benchmark)
        }.value
        guard let fit else { return }
        let candidate = StockSageConvictionCalibration.Snapshot(calibration: fit, source: source, fittedAt: dataAsOf, oosBrier: nil)
        // F3 (recency-vs-richness, adjudicated on review): recency wins only AT the staleness
        // boundary — a richer fresh fit is never silently displaced by a thinner one. Trigger A
        // (scan-end) calls this on EVERY completed scan, so without this guard a small scan-day
        // sample could stomp a much richer existing fit (a full 5y manual backtest, or an earlier
        // richer auto-fit) purely because it ran more recently. Persist+assign only when there's
        // nothing to lose: no existing snapshot, the existing one is already stale (>7d — the same
        // rule `shouldAutoFit` uses), or the candidate is at least as rich (sampleCount) as what's
        // there. Trigger B (launch) only ever calls this method when `shouldAutoFit(existing)` is
        // already true (see `init`), so for Trigger B the first two disjuncts already hold —
        // this guard is a no-op there, behavior unchanged. Memory and disk update TOGETHER or NOT
        // AT ALL (one `if`, both writes inside it), so they can never diverge.
        let existing = persistedCalibrationSnapshot
        let shouldReplace = existing.map { Self.shouldAutoFit(snapshot: $0, now: Date()) || candidate.sampleCount >= $0.sampleCount } ?? true
        guard shouldReplace else { return }
        backtestConvictionCalibration = fit
        persistedCalibrationSnapshot = candidate
        // Cross-process: single whole-value key, last-writer-wins. Both writers derive from the
        // same HistoryCache, so a lost write costs at most one equivalent refit — no merge needed.
        candidate.save(defaults: defaults, key: key)
    }

    /// Fetch ~5y for a bounded equity sample, walk-forward each off-main, and
    /// aggregate honest strategy-wide stats. User-triggered (heavy).
    func refreshStrategyBacktest() async {
        guard !isLoadingStrategy else { return }
        if let reason = ToolPolicy.webToolsDisabledReason() {
            strategyError = reason
            return
        }
        isLoadingStrategy = true
        defer { isLoadingStrategy = false }
        strategyError = nil

        let symbols = StockSageStrategyBacktest.sampleSymbols
        // Fetch the ^GSPC benchmark at the SAME 5y range as the symbol histories — a 1y slice
        // would leave the first ~4y of every symbol with no benchmark → RS silently disabled for
        // most of the backtest, defeating the fidelity fix. Use 5y so the date-aligned pointer has
        // full coverage over the entire symbol window.
        async let benchmarkTask = StockSageQuoteService.fetchHistory("^GSPC", range: "5y")
        let histories = await StockSageQuoteService.fetchHistories(for: symbols, range: "5y")
        let benchmark = await benchmarkTask
        guard !histories.isEmpty else {
            strategyError = "Couldn't load histories to backtest the strategy — try again."
            return
        }
        let (results, trades, tradeDates, observations): ([BacktestResult], [BacktestTrade], [Date], [StockSageConvictionCalibration.Observation]) = await Task.detached {
            var rs: [BacktestResult] = []
            var ts: [BacktestTrade] = []
            var ds: [Date] = []
            var observations: [StockSageConvictionCalibration.Observation] = []
            for sym in symbols {
                guard let h = histories[sym.uppercased()] else { continue }
                // Faithful: charge asset-class costs AND feed the ^GSPC benchmark so the backtest
                // measures the SAME relative-strength term the live ideas path uses. The date-aligned
                // pointer inside runDetailed handles holiday calendar mismatches between symbol and
                // benchmark (symbol bar-counts differ from ^GSPC's — a naive index slice is wrong).
                let d = StockSageBacktester.runDetailed(h, costs: StockSageNetEdge.defaultCosts(forSymbol: sym),
                                                        benchmark: benchmark)
                rs.append(d.result)
                ts.append(contentsOf: d.trades)
                // Thread entry dates aligned 1:1 with trades for the pooled chronological DD.
                // entryIndex = i+1 (the fill bar), always in-bounds: i < n-1 so entryIndex ≤ n-1.
                ds.append(contentsOf: d.trades.map { h.dates[$0.entryIndex] })
                observations.append(contentsOf: StockSageConvictionCalibration.observations(fromBacktest: d.trades, dates: h.dates))
            }
            return (rs, ts, ds, observations)
        }.value
        strategyBacktest = StockSageStrategyBacktest.aggregate(results, trades: trades, tradeEntryDates: tradeDates)
        // Learn conviction→win-prob from the realized BACKTEST trades (nil if too thin). The computed
        // `convictionCalibration` prefers the owner's journal fit over this when their journal is rich enough.
        // Keep prediction AND label-availability times through selection across symbols.
        // Entry dates above remain solely the aggregate drawdown's existing timeline.
        backtestConvictionCalibration = StockSageConvictionCalibration.fit(observations: observations)
        // Decision 4: the manual backtest persists its fit too, same as the offline auto-fit
        // triggers — so a calibration earned from a full 5y run also survives a relaunch.
        if let cal = backtestConvictionCalibration {
            let snap = StockSageConvictionCalibration.Snapshot(calibration: cal, source: "strategy-backtest-5y", fittedAt: Date(), oosBrier: nil)
            persistedCalibrationSnapshot = snap
            // Cross-process: single whole-value key, last-writer-wins. Both writers derive from the
            // same HistoryCache, so a lost write costs at most one equivalent refit — no merge needed.
            snap.save()
        }
    }

    // Portfolio risk analytics — the full backward-looking risk/return suite.
    @Published private(set) var analytics: PortfolioAnalytics?
    @Published private(set) var correlation: CorrelationMatrix?
    @Published private(set) var isLoadingAnalytics = false
    @Published private(set) var analyticsError: String?
    /// Audit 2026-07-12 pass-3 (finding ③): the analytics blend weights holdings by pence-normalized
    /// price×shares but does NOT FX-convert cross-currency (this path fetches no =X rates). True when
    /// the analyzed holdings span >1 quote currency → the panel discloses the weights are approximate.
    @Published private(set) var analyticsWeightsApproximate = false
    private var analyticsComposition: [String: Double]?

    func analyticsMatches(positions: [PortfolioPosition]) -> Bool {
        analytics != nil && analyticsComposition == StockSagePortfolio.holdingBySymbol(in: positions).mapValues(\.shares)
    }

    /// Fetch each holding's history and compute the portfolio risk/return suite
    /// (Sharpe/Sortino/Calmar, max drawdown, VaR, correlation → diversification).
    /// User-triggered; heavy compute runs off-main; non-destructive on failure.
    func refreshPortfolioAnalytics() async {
        guard !isLoadingAnalytics else { return }
        let positions = StockSagePortfolio.shared.positions
        guard !positions.isEmpty else {
            analytics = nil
            analyticsError = "Add holdings to your portfolio first."
            return
        }
        if let reason = ToolPolicy.webToolsDisabledReason() {
            analyticsError = reason
            return
        }
        isLoadingAnalytics = true
        defer { isLoadingAnalytics = false }
        analyticsError = nil

        async let gspcHistory = StockSageQuoteService.fetchHistory("^GSPC", range: "1y")
        let histories = await StockSageQuoteService.fetchHistories(for: StockSagePortfolio.holdingBySymbol(in: positions).keys.sorted())
        await applyPortfolioAnalytics(positions: positions, histories: histories, benchmark: gspcHistory)
    }

    /// Shared assembly seam: tests supply histories, never owner holdings or provider requests.
    func applyPortfolioAnalytics(positions: [PortfolioPosition], histories: [String: StockSagePriceHistory],
                                 benchmark: StockSagePriceHistory?) async {
        let holdings = StockSagePortfolio.holdingBySymbol(in: positions).values.sorted { $0.symbol < $1.symbol }
        // Build DATED returns per holding so co-movement stats can align by calendar
        // day, not array position — holdings span exchanges with different holidays.
        var symbols: [String] = []
        var weights: [Double] = []
        var datedHoldingReturns: [[(date: Date, ret: Double)]] = []
        for p in holdings {
            guard let h = histories[p.symbol.uppercased()], let price = h.latestClose else { continue }
            let dr = StockSagePortfolioAnalytics.datedReturns(dates: h.dates, closes: h.closes)
            guard !dr.isEmpty else { continue }
            symbols.append(p.symbol)
            // Audit 2026-07-12 pass-3 (finding ③): normalize pence-quoted listings (.L/.JO ÷100) so a
            // London holding isn't ~100× over-weighted in the risk-stat blend. FX cross-currency
            // conversion (SAR/EUR→USD) is NOT applied here — this path fetches no =X rates — so the
            // weights remain approximate for multi-currency books; the panel discloses that (see
            // portfolioAnalyticsUnconverted). Pence is the ~100× error and is fixed unconditionally.
            weights.append(StockSageCurrency.majorUnitValue(symbol: p.symbol, rawValue: price * p.shares))
            datedHoldingReturns.append(dr)
        }
        guard !symbols.isEmpty else {
            analyticsError = "Couldn't load enough history to analyze the portfolio."
            return
        }

        let marketDated = benchmark.map {
            StockSagePortfolioAnalytics.datedReturns(dates: $0.dates, closes: $0.closes)
        } ?? []

        // A benchmark's holidays must not erase a holding's real returns from risk statistics.
        let holdingVecs = StockSagePortfolioAnalytics.alignByDate(datedHoldingReturns)

        // Analytics suite over date-aligned data: rebuild pseudo-closes (cumulative
        // product of 1+ret) so compute()'s closes path runs on the aligned returns.
        func weightedCloses(_ vectors: [[Double]]) -> [(weight: Double, closes: [Double])] {
            zip(weights, vectors).map { w, rets in
                var closes: [Double] = [100]
                for r in rets { closes.append(closes[closes.count - 1] * (1 + r)) }
                return (weight: w, closes: closes)
            }
        }
        let alignedHoldings = weightedCloses(holdingVecs)
        let attemptedCount = holdings.count   // Unique instruments, not storage lots.
        let computed = await Task.detached {
            StockSagePortfolioAnalytics.compute(holdings: alignedHoldings, attempted: attemptedCount)
        }.value
        analytics = computed
        analyticsComposition = StockSagePortfolio.holdingBySymbol(in: positions).mapValues(\.shares)
        // Disclose (finding ③): weights are pence-normalized but NOT FX-converted, so a book spanning
        // >1 quote currency has approximate weights — the panel shows a caveat instead of implying the
        // blend is exact. Keyed on the ANALYZED symbols (those that loaded), not all positions.
        analyticsWeightsApproximate = Set(symbols.map { StockSageCurrency.conversionCurrencyForSymbol($0) }).count > 1
        if computed == nil {
            analyticsError = "Not enough overlapping history across your holdings yet."
        }

        // Heatmap from the date-aligned holding return vectors.
        if symbols.count >= 2, (holdingVecs.first?.count ?? 0) >= 5 {
            // F3 (audit 2026-07-12): carry the defined-ness mask so the heatmap renders an undefined
            // (zero-variance) pair as "—" instead of a fabricated green "0.0 independent" cell.
            correlation = CorrelationMatrix(symbols: symbols,
                                            matrix: StockSagePortfolioAnalytics.correlationMatrix(holdingVecs),
                                            defined: StockSagePortfolioAnalytics.correlationDefinedMask(holdingVecs))
        } else {
            correlation = nil
        }

        // Beta: value-weighted portfolio vs the SAME-DAY market vector.
        let betaAligned = StockSagePortfolioAnalytics.alignByDate(datedHoldingReturns + [marketDated])
        let marketVec = betaAligned.last ?? []
        let port = StockSagePortfolioAnalytics.portfolioReturns(holdings: weightedCloses(Array(betaAligned.dropLast())))
        portfolioBeta = (port.isEmpty || marketVec.isEmpty)
            ? nil : StockSagePortfolioAnalytics.beta(portfolio: port, market: marketVec)
    }

    /// Portfolio beta vs the S&P 500 (computed alongside the analytics).
    @Published private(set) var portfolioBeta: Double?

    // Correlation pre-check — how a candidate would affect portfolio concentration.
    @Published private(set) var precheck: [String: CorrelationPrecheck] = [:]
    /// The holdings fingerprint each cached verdict was computed under, so the
    /// cache RECOMPUTES when the book changes (add/remove a holding) instead of
    /// serving a stale concentration verdict.
    private var precheckFingerprint: [String: String] = [:]
    /// F14 (2026-07-02): date-tagged daily returns for every symbol refreshPrecheck fetched
    /// (candidate + holdings) — the detail-sheet cluster check correlates on THESE, calendar-
    /// aligned via `StockSagePortfolioAnalytics.alignByDate`, instead of pairing ~2-day
    /// down-sampled sparks positionally (which biases cross-calendar pairs — Tadawul/US,
    /// crypto/equity — toward 0 and could show a false-green "adds diversification" while the
    /// sibling precheck row, built on real daily closes, disagreed in the same sheet). Reuses
    /// the precheck's OWN fetch — no extra network call. An absent symbol ⇒ unknown: the
    /// cluster check renders nothing rather than a fabricated coefficient.
    @Published private(set) var precheckDatedReturns: [String: [(date: Date, ret: Double)]] = [:]

    /// Compute (and cache) how adding `symbol` would correlate with the current
    /// holdings. Cached per (symbol + holdings fingerprint); no-op when access is off.
    func refreshPrecheck(symbol: String) async {
        let up = symbol.uppercased()
        let positions = StockSagePortfolio.shared.positions
        let fingerprint = positions.map { $0.symbol.uppercased() }.sorted().joined(separator: ",")
        // Fresh only if the verdict was computed under the CURRENT book.
        guard precheckFingerprint[up] != fingerprint else { return }
        if ToolPolicy.webToolsDisabledReason() != nil { return }
        guard !positions.isEmpty else {
            precheck[up] = CorrelationPrecheck(verdict: .noHoldings, avgCorrelation: 0,
                                               comparedCount: 0, mostCorrelatedSymbol: nil, mostCorrelation: 0)
            precheckFingerprint[up] = fingerprint
            return
        }
        var symbols = Set(positions.map { $0.symbol.uppercased() })
        symbols.insert(up)
        let hists = await StockSageQuoteService.fetchHistories(for: Array(symbols))
        // F14: stash every fetched symbol's DATE-TAGGED returns for the cluster check — even when
        // the candidate itself failed to fetch, a holding's series can serve a later candidate.
        for (sym, h) in hists {
            precheckDatedReturns[sym] = StockSagePortfolioAnalytics.datedReturns(dates: h.dates, closes: h.closes)
        }
        guard hists[up] != nil, let candReturns = precheckDatedReturns[up] else { return }
        // DATE-ALIGNED (2026-09-11). This used positional `assess`, which paired the candidate and
        // each holding by index from the END of each series. Tadawul trades Sun–Thu and US markets
        // Mon–Fri, so index N from the end is a DIFFERENT CALENDAR DAY in each: the coefficient was
        // computed across mismatched days. A genuinely concentrated pair could read "Diversifying"
        // on the idea sheet — a false green on the exact question the row exists to answer. These
        // are the same date-tagged series the sibling cluster check already correlates on, so the
        // two rows in one sheet can no longer disagree with each other.
        let holdDated: [(symbol: String, returns: [(date: Date, ret: Double)])] = positions.compactMap { p in
            let psym = p.symbol.uppercased()
            guard psym != up else { return nil }
            // An unfetched holding is passed with an EMPTY series on purpose: assessDated skips it
            // and TALLIES it. Dropping it here instead would shrink the book silently, and the
            // sentence would claim to cover holdings it never looked at.
            return (p.symbol, precheckDatedReturns[psym] ?? [])
        }
        // No Task.detached: this is a pure reduction over a few hundred doubles per holding, and the
        // hop off the main actor cost more than the work. It also let the `precheck` write land in a
        // later turn of the run loop than the fingerprint write below.
        precheck[up] = StockSageCorrelationPrecheck.assessDated(candidate: candReturns, holdings: holdDated)
        precheckFingerprint[up] = fingerprint
    }

    // Fast-lane cross-correlation (FASTMONEY_BACKLOG #7) — how much the crypto and equity fast-lane
    // boards are ACTUALLY moving together right now. Mirrors refreshPrecheck's exact pattern:
    // fingerprint-cached (recomputes only when the fast-lane's symbol SET changes), ToolPolicy-gated,
    // pure StockSageExpectedValue.laneCorrelation over fetched histories (no new fetch code — reuses
    // StockSageQuoteService.fetchHistories, the SAME call refreshPrecheck uses).
    @Published private(set) var laneCorrelationValue: Double?
    /// G1: true once a fetch ATTEMPT has finished for the current membership (success, nil result,
    /// or policy-blocked) — lets the view show "Correlation unavailable" instead of a permanent
    /// "fetching…" spinner when the value is nil but nothing is in flight (mirrors the MTF row's
    /// mtfFetchCompleted fix). Reset to false when a new fetch starts.
    @Published private(set) var laneCorrelationCompleted: Bool = false
    private var laneCorrelationFingerprint: String?

    /// Fetch history for the CURRENT crypto+equity fast-lane symbols and compute their average
    /// cross-group correlation. No-op if access is off or either side is empty (nothing to
    /// correlate — clears the stale value so a picker toggle to a one-sided view can't show a
    /// number from the OLD symbol set).
    func refreshLaneCorrelation(holds: VelocityHoldDays = .defaults) async {
        let split = StockSageExpectedValue.fastLaneByClass(ideas, holds: holds, calibration: convictionCalibration)
        guard !split.crypto.isEmpty, !split.equity.isEmpty else {
            laneCorrelationValue = nil; laneCorrelationFingerprint = nil; return
        }
        let symbols = (split.crypto + split.equity).map(\.symbol)
        let fingerprint = symbols.sorted().joined(separator: ",")
        guard laneCorrelationFingerprint != fingerprint else { return }
        guard ToolPolicy.webToolsDisabledReason() == nil else {
            // G1: web tools off — no fetch possible. Mark the attempt DONE so the view shows
            // "Correlation unavailable", not a permanent "fetching…" spinner that never resolves.
            laneCorrelationValue = nil; laneCorrelationCompleted = true; return
        }
        // Membership just changed (fingerprint guard above passed) — clear the stale value BEFORE
        // the await so the view falls back to the honest "Correlation — fetching…" placeholder
        // during the in-flight window instead of showing the OLD symbol set's number (which can
        // even invert the hedge-quality qualifier band). Mirrors the empty-side clear at L1356.
        laneCorrelationValue = nil
        laneCorrelationCompleted = false   // G1: a fresh fetch is now in flight
        let histories = await StockSageQuoteService.fetchHistories(for: symbols)
        guard !Task.isCancelled else { return }
        // Audit 2026-07-12: use the DATE-ALIGNED laneCorrelation (crypto 7-day vs equity 5-day weeks
        // must correlate by calendar date, not tail array index). datedReturns from dates+closes.
        let datedReturns = histories.mapValues {
            StockSagePortfolioAnalytics.datedReturns(dates: $0.dates, closes: $0.closes)
        }
        let result = StockSageExpectedValue.laneCorrelation(
            crypto: split.crypto, equity: split.equity, dated: datedReturns)
        // F11: stamp the fingerprint ONLY on a non-nil result; clear it on failure/cancellation.
        // If the fetch failed (result==nil), clearing the fingerprint ensures the next call is NOT
        // blocked by the guard above — allowing a retry after a network miss. A cancelled stale
        // task cannot reach here (guard above), so it can't clobber a fresh task's published value.
        // Mirrors the cache-on-success pattern of refreshTrailingStop/refreshLiquidity.
        laneCorrelationValue = result
        laneCorrelationFingerprint = (result != nil) ? fingerprint : nil
        laneCorrelationCompleted = true   // G1: attempt finished (success or nil result → "unavailable")
    }

    // Symbols whose latest quote had no real previousClose (a brand-new listing) — Yahoo's
    // fallback (previousClose := price) reads as a genuine flat 0%-move "hold" without this,
    // when it's actually "unevaluated." Refreshed each `refresh()` cycle alongside `quotes`.
    @Published private(set) var newListings: Set<String> = []

    // Earnings proximity — overnight-gap event risk for an equity. Only the RAW earnings DATE
    // is cached per symbol (it doesn't shift within a session); the derived daysUntil/severity
    // is recomputed FRESH on every read (see `earnings` below) so a long-running session's
    // imminent-earnings ranking demotion never goes stale relative to whenever the date happened
    // to be fetched.
    @Published private(set) var earningsDates: [String: Date] = [:]

    /// When we last ASKED the provider about a symbol — stamped on EVERY `refreshEarnings`
    /// outcome, whether it found a date or not (A2, 2026-09-06). This is what turns a negative
    /// result into an honest DATED "none known as of <checkedAt>" record instead of a claim that
    /// silently ages forever (OWNER DIRECTIVE 2026-09-06: "every stock to have a catalyst on
    /// file"). A symbol with no entry here was never checked this cache's lifetime and must keep
    /// rendering as unchecked — never conflated with "checked, none". Loaded from
    /// `StockSageCatalystRecordCache` at launch (see `loadCatalystRecords`) so a relaunch doesn't
    /// forget every checkedAt and re-ask everything immediately.
    @Published private(set) var earningsCheckedAt: [String: Date] = [:]

    /// W1 (2026-09-06): the FULL per-symbol chain result — status (dateKnown/projected/
    /// notApplicable/unchecked), the provider's confirmed flag, a date-range end, every source
    /// asked, and (for a projection) its basis. Superset of `earningsDates`/`earningsCheckedAt`
    /// above, which stay a derived, backward-compatible view over ONLY the `.dateKnown` subset —
    /// the existing earnings-proximity/rank-penalty machinery is built and tested against a REAL
    /// known date, so a `.projected` or `.notApplicable` entry must never reach it. Populated by
    /// `refreshCatalyst(symbol:)`, persisted/restored alongside the legacy dicts (see
    /// `loadCatalystRecords`/`saveCatalystRecords` below).
    @Published private(set) var catalystChain: [String: StockSageCatalystRecordCache.Record] = [:]
    private var catalystRequests: [String: UUID] = [:]

    /// Independent of earnings: empty success, unavailable and never/stale remain distinct.
    @Published private(set) var companyEventChecks: [String: [StockSageMassiveEvents.Feed: StockSageMassiveEvents.Observation]] = [:]
    @Published private(set) var companyEventCacheSaved = true
    private var companyEventGeneration = UUID()

    /// Native Markets task, keyed to tracked symbols/full refresh (never stream ticks). Daily
    /// successful TTL,15min transient retry, per-feed five-minute authentication gate. Four requests maximum
    /// in flight, five serial feed passes; earnings never wait for this independent sweep.
    func refreshCompanyEvents() async {
        guard !Self.isRunningTests, ToolPolicy.isExternalAllowed, !Task.isCancelled else { return }
        let revision = StockSageMassive.credentialRevision(defaults) ?? ""
        func current() -> Bool { revision == (StockSageMassive.credentialRevision(defaults) ?? "") }
        let generation = UUID()
        companyEventGeneration = generation
        let symbols = trackedSymbolsUnion.filter(StockSageMassive.covers)
        let allowed = Set(symbols)
        companyEventChecks = companyEventChecks.filter { allowed.contains($0.key) }
        defer {
            if companyEventGeneration == generation, current() {
                companyEventCacheSaved = StockSageCompanyEventCache(entries: companyEventChecks.values.flatMap { $0.values }).save()
            }
        }
        for feed in StockSageMassiveEvents.Feed.allCases {
            let now = Date()
            let due = symbols.filter { companyEventChecks[$0]?[feed]?.fresh(at: now, credentialRevision: revision) != true }
            guard !due.isEmpty else { continue }
            let failure = await StockSageMassiveEvents.probe(feed)
            guard !Task.isCancelled, ToolPolicy.isExternalAllowed, companyEventGeneration == generation, current() else { return }
            if let failure {
                var updated = companyEventChecks
                for symbol in due {
                    updated[symbol, default: [:]][feed] = .init(symbol: symbol, feed: feed, checkedAt: now,
                                                              outcome: .unavailable, event: nil, failure: failure, credentialRevision: revision)
                }
                companyEventChecks = updated
                continue
            }
            for start in stride(from: 0, to: due.count, by: 4) {
                guard !Task.isCancelled, ToolPolicy.isExternalAllowed, companyEventGeneration == generation, current() else { return }
                let chunk = Array(due[start..<min(start + 4, due.count)])
                let records = await withTaskGroup(of: StockSageMassiveEvents.Observation.self, returning: [StockSageMassiveEvents.Observation].self) { group in
                    for symbol in chunk { group.addTask { await StockSageMassiveEvents.fetch(feed, symbol: symbol) } }
                    var results: [StockSageMassiveEvents.Observation] = []
                    for await record in group { results.append(record) }
                    return results
                }
                guard !Task.isCancelled, ToolPolicy.isExternalAllowed, companyEventGeneration == generation, current() else { return }
                var updated = companyEventChecks
                for record in records { updated[record.symbol, default: [:]][feed] = record }
                companyEventChecks = updated
                if start + 4 < due.count { try? await Task.sleep(for: .milliseconds(750)) }
            }
            // Preserve completed feed progress across view cancellation/app relaunch.
            companyEventCacheSaved = StockSageCompanyEventCache(entries: companyEventChecks.values.flatMap { $0.values }).save()
        }
    }

    /// How long a "checked, nothing found" record stays honest before `refreshEarnings` re-asks.
    /// A dated negative observation is only as good as its date — refreshed at most once a day so
    /// it can't quietly go stale across a session (or a cache) that outlives one day.
    nonisolated static let earningsCheckTTL: TimeInterval = 24 * 3600

    /// Pure derivation: raw earnings dates → proximity, evaluated at `now`. A free function (not
    /// baked into a cached dict) so it's directly testable with an injected `now` — the SAME
    /// cached raw date must yield a DIFFERENT severity as real time passes, unlike the frozen
    /// fetch-time value the pre-fix code cached.
    nonisolated static func deriveEarningsProximity(_ dates: [String: Date], now: Date = Date()) -> [String: EarningsProximity] {
        // F32: evict entries whose date is more than 1 day in the past. The session cache never
        // auto-expires, so after a report date passes mid-session max(0,days) floors at 0 and the
        // .imminent badge + −2000 rank demotion would persist for hours.
        // NOTE — one-instant deliberate difference vs the fetch-time guard in refreshEarnings:
        //   fetch guard:   date.timeIntervalSinceNow > -86_400   (strict, evicts at exactly -86400s)
        //   derive guard:  date.timeIntervalSince(now) >= -86_400 (non-strict, keeps at exactly -86400s)
        // The derive guard is deliberately conservative: it keeps the warning for one instant longer
        // than the fetch guard would. Do NOT change either boundary.
        dates.compactMapValues { date in
            guard date.timeIntervalSince(now) >= -86_400 else { return nil }
            return StockSageEarnings.proximity(now: now, earnings: date)
        }
    }

    /// Earnings proximity — overnight-gap event risk for an equity. Recomputed fresh from
    /// `earningsDates` on every access; never cached as a stale derived value.
    var earnings: [String: EarningsProximity] { Self.deriveEarningsProximity(earningsDates) }

    /// Pure TTL gate `refreshEarnings` checks BEFORE ever awaiting the network: re-ask only when
    /// the symbol was never checked (`checkedAt == nil`) or the last check is at/older than
    /// `earningsCheckTTL`. `nonisolated static` with an explicit `now` (not a bare `Date()`) so
    /// the exact 24h boundary is directly testable without racing the wall clock.
    nonisolated static func shouldRefreshEarnings(checkedAt: Date?, now: Date = Date()) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= earningsCheckTTL
    }

    /// Pure core of `refreshEarnings`, `self`-free and directly unit-testable with a stub `fetch`
    /// (no singleton, no network): TTL-gates first, and only when the gate passes does it await
    /// the injected fetch — so a caller can assert "still fresh → fetch never even runs" without
    /// mocking a real request. Returns nil for "TTL says still fresh, nothing to stamp" OR for
    /// "asked but got no real answer" (`.unavailable` — external access off, non-equity, timeout,
    /// non-200, parse failure; blocker fix 2026-09-06: `fetchNextEarnings` used to return `nil`
    /// identically for that AND for "asked, 200, no date", so a FAILED request was stamped as a
    /// dated "none known" observation — see StockSageEarningsTests). Only `.answered` stamps
    /// `checkedAt`: `(now, nil)` for an honest negative (200 with no date, or only a stale past
    /// date — the SAME `> -86_400` guard `refreshEarnings` always had, value unchanged) or
    /// `(now, date)` for a usable future date.
    nonisolated static func earningsRefreshOutcome(
        checkedAt: Date?, now: Date = Date(), fetch: () async -> StockSageEarnings.EarningsFetch
    ) async -> (checkedAt: Date, earningsDate: Date?)? {
        guard shouldRefreshEarnings(checkedAt: checkedAt, now: now) else { return nil }
        guard case .answered(let fetched) = await fetch() else { return nil }   // never answered ⇒ stamp NOTHING
        let usable = fetched.flatMap { $0.timeIntervalSince(now) > -86_400 ? $0 : nil }   // ignore a stale past date
        return (now, usable)
    }

    /// Full chain for ONE tracked symbol: Massive/Benzinga earnings first, then Yahoo
    /// `calendarEvents` (reading the range + estimate flag) → optional history-based projection
    /// (Yahoo `earningsHistory` for non-US equities only) → `.unchecked`. Non-equities
    /// (index/forex/crypto, `^TASI.SR` included
    /// via its `^` prefix) never reach the chain at all — `.notApplicable` is a pure
    /// classification, assigned once and left alone (no network, no TTL: it can't go stale).
    /// TTL-gated 24h off `catalystChain[symbol]?.checkedAt`, same constant and same "never
    /// checked ⇒ due now" rule as the legacy `shouldRefreshEarnings` this replaces in the sweep.
    func refreshCatalyst(symbol: String, now: Date = Date(),
                         allowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
                         resolve: ((String, Date) async -> StockSageCatalystChain.Outcome)? = nil) async {
        guard !Task.isCancelled else { return }
        let up = symbol.uppercased()
        guard StockSageAllocation.assetClass(up) == "Equity" else {
            if catalystChain[up]?.status != .notApplicable {
                catalystChain[up] = .init(symbol: up, earningsDate: nil, checkedAt: now,
                                          source: "—", status: .notApplicable)
            }
            return
        }
        let revision = StockSageMassive.credentialRevision(defaults) ?? ""
        let isUS = StockSageMassive.covers(up)
        func current() -> Bool { revision == (StockSageMassive.credentialRevision(defaults) ?? "") }
        guard (isUS && catalystChain[up]?.credentialRevision != revision)
            || Self.shouldRefreshEarnings(checkedAt: catalystChain[up]?.checkedAt, now: now) else { return }
        guard allowed() else { return }   // never stamp on a request never made
        let request = UUID()
        catalystRequests[up] = request
        defer { if catalystRequests[up] == request { catalystRequests[up] = nil } }

        if let resolve {
            let outcome = await resolve(up, now)
            guard catalystRequests[up] == request, current() else { return }
            publishCatalyst(outcome, symbol: up, checkedAt: now, credentialRevision: revision, allowed: allowed)
            return
        }

        let history: (() async -> StockSageCatalystChain.Answer<[Date]>)?
        if isUS {
            // The retired US fundamentals leg had no transport. Do not silently add Yahoo US history.
            history = nil
        } else {
            history = {
                let dates = await StockSageEarnings.fetchEarningsHistory(for: up)
                // TODO(SAHMK): Yahoo's `earningsHistory` module for Tadawul
                // is unverified live for `.SR` (429-rate-limited today — see
                // research_tadawul_realtime_2026-09-06.md). If it comes back empty (`.answered([])`,
                // not `.unavailable`), this symbol lands on `.unchecked` with `sourcesAsked`
                // recording the attempt — the next real fix is a SAHMK Pro key (owner-provisioned),
                // not a code change here.
                guard let dates else { return .unavailable }
                return .answered(dates)
            }
        }
        let outcome = await StockSageCatalystChain.resolve(
            now: now,
            stillValid: { allowed() && self.catalystRequests[up] == request && current() },
            massiveCalendar: { await StockSageMassiveEarnings.fetch(up, now: now) },
            yahooCalendar: {
                switch await StockSageEarnings.fetchEarningsCalendarOutcome(for: up) {
                case .answered(let info): return .answered(info)
                case .unavailable:        return .unavailable
                }
            },
            history: history
        )
        guard catalystRequests[up] == request, current() else { return }
        publishCatalyst(outcome, symbol: up, checkedAt: now, credentialRevision: revision, allowed: allowed)
    }

    /// Shared synchronous publication of a completed chain; no cache I/O here.
    func publishCatalyst(_ outcome: StockSageCatalystChain.Outcome, symbol: String, checkedAt now: Date,
                         credentialRevision: String? = nil,
                         allowed: () -> Bool = { ToolPolicy.isExternalAllowed }) {
        guard !Task.isCancelled, allowed() else { return }
        let up = symbol.uppercased()
        // Never stamp a dated negative for a question nobody actually answered (blocker fix
        // 2026-09-06) — `.unchecked` from a chain where every provider was `.unavailable` (e.g.
        // external access flickered off mid-symbol, or Yahoo's 429s exhausted every retry) must
        // leave this symbol exactly as it was: absent from `catalystChain`/`earningsCheckedAt`,
        // rendering "not fetched yet", never a false "checked, none known as of <now>".
        guard outcome.status != .unchecked || outcome.anySourceAnswered else { return }
        catalystChain[up] = .init(symbol: up, earningsDate: outcome.earningsDate, checkedAt: now,
                                  source: outcome.source, status: outcome.status,
                                  confirmed: outcome.confirmed, dateRangeEnd: outcome.dateRangeEnd,
                                  sourcesAsked: outcome.sourcesAsked, projectionBasis: outcome.projectionBasis,
                                  credentialRevision: credentialRevision)
        // Keep the legacy dicts in sync for the existing earnings-proximity/rank-penalty
        // machinery — ONLY a genuinely KNOWN date feeds them; a `.projected` guess must never be
        // mistaken for an announced report (that machinery demotes rank on an announced one).
        earningsCheckedAt[up] = now
        earningsDates[up] = (outcome.status == .dateKnown) ? outcome.earningsDate : nil
    }

    /// Feed earnings for EVERY tracked symbol — board ∪ watchlist ∪ portfolio ∪ open journal
    /// trades (A4, 2026-09-06; replaces the old top-15-ideas-only sweep) — so the "every stock to
    /// have a catalyst on file" owner directive (2026-09-06: cost gates waived, provider rate
    /// limits still bind) covers the FULL tracked set, not just the top-ranked board names.
    /// TTL-gated per symbol via `refreshCatalyst`'s own guard (W1, 2026-09-06 — was
    /// `refreshEarnings`, now superseded by the Massive/Benzinga→Yahoo→optional projection chain), so a re-sweep
    /// after the board is already fully checked is cheap — only never-checked or >24h-stale names
    /// actually hit the network. 4-parallel chunking unchanged from the old top-15 sweep; each
    /// chunk boundary checks `Task.isCancelled` so a superseded scan's sweep (e.g. `refreshIdeas`
    /// firing again before this one finished) doesn't keep grinding through hundreds of names
    /// after the caller moved on — whatever chunks DID complete are saved via the `defer` either
    /// way. Symbols this sweep hasn't reached yet are simply absent from `earningsCheckedAt` —
    /// UNCHECKED, never fabricated as "none known" (honesty floor). The shared Massive/Benzinga
    /// availability probe remains once per sweep; no retired-provider probe is performed.
    func restartEarningsSweep() {
        earningsSweepTask?.cancel()
        guard !Self.isRunningTests else { return }
        earningsSweepTask = Task { [weak self] in await self?.refreshEarningsForTracked() }
    }

    func refreshEarningsForTracked() async {
        defer { saveCatalystRecords() }
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled else { return }
        let revision = StockSageMassive.credentialRevision(defaults)
        let all = trackedSymbolsUnion
        if all.contains(where: StockSageMassive.covers) {
            await StockSageMassiveEarnings.probeAvailability()
        }
        guard ToolPolicy.isExternalAllowed, !Task.isCancelled,
              revision == StockSageMassive.credentialRevision(defaults) else { return }
        let chunks = stride(from: 0, to: all.count, by: 4).map { Array(all[$0 ..< min($0 + 4, all.count)]) }
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled || revision != StockSageMassive.credentialRevision(defaults) { return }
            await withTaskGroup(of: Void.self) { group in
                for symbol in chunk { group.addTask { await self.refreshCatalyst(symbol: symbol) } }
                for await _ in group { }
            }
            // Pacing (major fix 2026-09-06; STANDING RULES: Yahoo 429s this Mac's IP today).
            // Every Massive/Benzinga miss in a chunk hits Yahoo `calendarEvents`, and a non-US
            // equity hits it a second time for `earningsHistory` — with ZERO delay between
            // chunks, a sustained throttle turned one ~900-name sweep into up to ~2,700 requests
            // fired as fast as 4-way parallelism allowed (only per-request backoff existed, no
            // shared cooldown across the sweep). 4 symbols / 750ms caps the whole sweep at
            // roughly 5.3 req/s regardless of chunk count; skip the sleep after the last chunk.
            if index < chunks.count - 1 {
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    // MARK: - Catalyst-record disk cache (A1 cache type, A2 store wiring)
    //
    // `earningsDates`/`earningsCheckedAt` are in-memory only by default (like `ideas`, per the
    // comment on `seedQAIdeas`) — without persistence, every relaunch forgets every checkedAt and
    // the TTL guard re-asks the whole tracked set from scratch. These two pure conversions (no
    // store/network access, directly testable) are the ONLY place that shapes a Record; the
    // instance methods below are thin I/O shells over them.

    /// Pure: per-symbol earnings state → disk-cache Records, one per symbol we've EVER checked
    /// (has a `checkedAt`). A symbol with no `checkedAt` entry was never asked and gets no
    /// Record — never fabricated (mirrors the cache type's own doc).
    nonisolated static func catalystRecords(
        earningsDates: [String: Date], earningsCheckedAt: [String: Date]
    ) -> [StockSageCatalystRecordCache.Record] {
        earningsCheckedAt.map { symbol, checkedAt in
            .init(symbol: symbol, earningsDate: earningsDates[symbol], checkedAt: checkedAt, source: "yahoo")
        }
    }

    /// Pure inverse: rebuild the two per-symbol dicts from loaded cache records.
    nonisolated static func applyCatalystRecords(
        _ records: [StockSageCatalystRecordCache.Record]
    ) -> (dates: [String: Date], checkedAt: [String: Date]) {
        var dates: [String: Date] = [:]
        var checkedAt: [String: Date] = [:]
        for r in records {
            checkedAt[r.symbol] = r.checkedAt
            // Only a non-PROJECTED date may reach `earningsDates` — the same rule `refreshCatalyst`
            // applies at write time (blocker fix 2026-09-06). Without this, a relaunch bypasses
            // that write-time guard entirely: a `.projected` GUESS becomes a KNOWN date the moment
            // it round-trips through disk, feeding the earnings-proximity/rank-penalty machinery
            // (and the "Earnings in ~N days (<date>)" headline) an announced report that was never
            // actually obtained. Pipeline-1 records (status decodes to `.unchecked`) and
            // `.notApplicable`/`.unchecked` W1 records are unaffected — neither ever carries a
            // `.projected` status, so this stays backward-compatible.
            if r.status != .projected, let d = r.earningsDate { dates[r.symbol] = d }
        }
        return (dates, checkedAt)
    }

    /// Restore the disk catalyst-record cache into `earningsDates`/`earningsCheckedAt` — called
    /// from `init` beside `loadCachedQuotes()` so a relaunch keeps every prior checkedAt (the TTL
    /// guard would otherwise see `nil` for everything and re-ask the whole tracked set at once).
    private func loadCatalystRecords() {
        guard let cache = StockSageCatalystRecordCache.load() else { return }
        let restored = Self.applyCatalystRecords(cache.entries)
        earningsDates = restored.dates
        earningsCheckedAt = restored.checkedAt
        // W1 (2026-09-06): restore the FULL chain state too (status/confirmed/dateRangeEnd/
        // sourcesAsked/projectionBasis) so a relaunch keeps `.notApplicable`/`.projected`
        // classifications, not just the legacy known-date subset above.
        catalystChain = Dictionary(cache.entries.map { ($0.symbol, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Persist the current catalyst state to disk — called at the end of every
    /// `refreshEarningsForTracked` sweep (its `defer`), never mid-sweep. `catalystChain` (W1) is
    /// the authoritative superset once `refreshCatalyst` has run; a symbol somehow present only in
    /// the legacy dicts (e.g. the AAPL sample-data seed, which writes `earningsDates` directly and
    /// never touches `catalystChain`) is still covered via the old pure conversion, merged in
    /// without overwriting a genuine chain record for the same symbol.
    private func saveCatalystRecords() {
        let legacy = Self.catalystRecords(earningsDates: earningsDates, earningsCheckedAt: earningsCheckedAt)
        var bySymbol = Dictionary(legacy.map { ($0.symbol, $0) }, uniquingKeysWith: { _, last in last })
        for (symbol, record) in catalystChain { bySymbol[symbol] = record }
        StockSageCatalystRecordCache(entries: Array(bySymbol.values), savedAt: Date()).save()
    }

    // Monthly seasonality — calendar-month return tendency over a long history.
    @Published private(set) var seasonality: [String: MonthlySeasonality] = [:]

    /// Populate seasonality for the top ideas (non-blocking) so the TOM rank tilt
    /// (`seasonalityRankBonus`, activated 2026-07-09) applies uniformly at the top of the board
    /// instead of only to symbols whose detail sheet happened to be opened — a navigation-
    /// dependent BONUS input is a fairness hazard the demote-only earnings/liquidity partials
    /// don't have (they err safe; a view-history-gated boost doesn't). Mirrors the old
    /// top-15-ideas earnings sweep's chunking shape (now `refreshEarningsForTracked`, which swept
    /// wider to the full tracked set in A4, 2026-09-06) — 4-parallel chunks, cached-once per symbol.
    /// This one deliberately stays top-15-only (seasonality only feeds a board-rank TILT, not a
    /// coverage obligation).
    func refreshSeasonalityForTopIdeas(limit: Int = 15) async {
        guard StockSageAdvisor.turnOfMonthEnabled else { return }
        // 2026-07-09 review fix: prefetch in the order the tilt actually AFFECTS — the untilted
        // EV rank (the tilted rank needs this very data, so the untilted key is the honest
        // pre-pass) — not raw advisor-score order, whose top-15 can miss EV-board leaders and
        // re-create the navigation-dependent coverage gap this prefetch exists to close.
        let evTop = StockSageExpectedValue.rankByEV(ideas, regime: regime, earnings: earnings,
                                                    liquidity: liquidity,
                                                    calibration: convictionCalibration)
        let top = Array(evTop.prefix(limit))
        let chunks = stride(from: 0, to: top.count, by: 4).map { Array(top[$0 ..< min($0 + 4, top.count)]) }
        for chunk in chunks {
            await withTaskGroup(of: Void.self) { group in
                for idea in chunk { group.addTask { await self.refreshSeasonality(symbol: idea.symbol) } }
                for await _ in group { }
            }
        }
    }

    func refreshSeasonality(symbol: String) async {
        let up = symbol.uppercased()
        guard seasonality[up] == nil else { return }
        if ToolPolicy.webToolsDisabledReason() != nil { return }
        guard let h = await StockSageQuoteService.fetchHistory(symbol, range: "10y", interval: "1mo") else { return }
        seasonality[up] = await Task.detached {
            StockSageSeasonality.compute(dates: h.dates, closes: h.closes)
        }.value
    }

    func applyLiveNBBO(_ quotes: [String: StockSageNBBO], now: Date = Date()) {
        let updated = Self.ideasWithNBBO(ideas, quotes: quotes, now: now)
        if updated != ideas { ideas = updated }
    }

    /// The legacy store uses uppercase IDs. Refuse native mixed-case tick projection;
    /// those exact observations remain in the whole-market cache, never aliased to another stock.
    nonisolated static func liveTicksForStore(_ ticks: [String: StockSageLiveStream.Tick]) -> [String: StockSageLiveStream.Tick] {
        ticks.filter { key, tick in key == tick.symbol && tick.symbol == tick.symbol.uppercased() }
    }

    /// One already-coalesced UI batch. Full-market retention belongs to FeedIngress;
    /// the existing merge applies only matching rows/ideas in one pass and preserves ordering.
    /// True when this tick cannot advance the stored row, so the merge may skip it entirely.
    ///
    /// Deliberately a STRICT SUBSET of what `acceptsQuote` rejects: the same SIP timestamp AND the
    /// same trade sequence is the same trade republished, and an equal-timestamp tie is only ever
    /// broken by a STRICTLY greater sequence, so no skipped tick could have been applied. An
    /// unknown sequence on either side cannot prove sameness and is never skipped; a non-SIP prior
    /// is a different ordering regime and is never compared by SIP sequence.
    ///
    /// This matters because the whole-market socket republishes the last trade for every selected
    /// symbol on every publication, so most symbols in a cycle carry a tick already stored.
    nonisolated static func tickIsRedundant(_ tick: StockSageLiveStream.Tick, prior: StockSageQuote?) -> Bool {
        guard let prior, prior.priceSource == .massiveSIP,
              let priorTime = prior.marketTime, priorTime == tick.timestamp,
              let priorSequence = prior.massiveTradeSequence, let sequence = tick.sequence else { return false }
        return priorSequence == sequence
    }

    func applyLiveTicks(_ ticks: [String: StockSageLiveStream.Tick]) {
        var quotes: [String: StockSageQuoteService.LiveQuote] = [:]
        for (key, tick) in Self.liveTicksForStore(ticks) {
            let prior = symbolIndex[key].flatMap { symbols[$0].latest }
            // Skip the republished-last-trade case before doing any per-symbol work.
            if Self.tickIsRedundant(tick, prior: prior) { continue }
            let carry = prior?.hasSessionBaseline(symbol: key, at: tick.timestamp) == true
            quotes[key] = .init(symbol: key, price: tick.price, previousClose: carry ? prior!.previousPrice : tick.price,
                marketTime: tick.timestamp, isNewListing: newListings.contains(key),
                massiveTradeSequence: tick.sequence, priceSource: .massiveSIP,
                previousCloseSource: carry ? prior?.previousCloseSource : nil,
                previousCloseQuoteTime: carry ? prior?.previousCloseQuoteTime : nil)
        }
        applyPolledQuotes(quotes)
    }

    // Volume-confirmed catalysts (external-report item 9) — computed from the SAME on-disk
    // history the scan already caches, so surfacing them costs zero extra network calls.
    // Empty until a scan has cached histories; empty is the honest state, never a placeholder.
    @Published private(set) var catalysts: [StockSageCatalyst.Signal] = []

    /// Stamped ONLY by a full `refresh()` — never by a streamed tick. Expensive derived work
    /// (the catalyst rescan reloads the entire on-disk history) keys off this instead of
    /// `lastUpdated`, which now moves twice a second while streaming.
    @Published private(set) var lastFullRefreshAt: Date?

    /// Recompute catalysts from cached history. Pure read of what is already on disk — no
    /// fetching, so it is safe to call after any scan/refresh without touching the API budget.
    func refreshCatalysts() async {
        let cache = await Task.detached { StockSageHistoryCache.load() }.value
        guard let histories = cache?.priceHistories(), !histories.isEmpty else {
            catalysts = []; return
        }
        // 9.2: `liquidity` is in-memory and empty until a detail sheet is opened, so feeding the
        // mechanical-flow flag from it alone left the flag inert for the whole board in a normal
        // session. Compute ADV from the histories already in hand, preferring a measured profile.
        let advBySymbol = StockSageLiquidity.advDollarBySymbol(
            histories: histories, known: liquidity.mapValues(\.avgDollarVolume))
        let found = await Task.detached {
            StockSageCatalyst.scan(histories, advDollarBySymbol: advBySymbol)
        }.value
        catalysts = found
    }

    // Liquidity — avg daily $ volume + tier, cached per symbol (equities/crypto only).
    @Published private(set) var liquidity: [String: LiquidityProfile] = [:]

    func refreshLiquidity(symbol: String,
        allowed: () -> Bool = { ToolPolicy.webToolsDisabledReason() == nil },
        history: (String, String) async -> StockSagePriceHistory? = {
            await StockSageQuoteService.fetchHistory($0, range: $1)
        }
    ) async {
        let up = symbol.uppercased()
        // USD-priced only: a foreign listing's local-currency volume mislabeled "$"
        // (and London's pence quotes) would give a wrong tier/number. FX/index too.
        guard StockSageLiquidity.isUSDPriced(symbol) else { return }
        guard !Task.isCancelled else { return }
        let key = "liquidity:" + up, request = UUID()
        derivedRequests[key] = request
        liquidity.removeValue(forKey: up)
        defer { if derivedRequests[key] == request { derivedRequests.removeValue(forKey: key) } }
        guard allowed() else { return }
        guard let h = await history(symbol, "3mo"), !Task.isCancelled, allowed(), derivedRequests[key] == request,
              h.symbol.uppercased() == up, StockSageRegime.historyAsOf(h, now: Date()) != nil else { return }
        if let p = StockSageLiquidity.profile(closes: h.closes, volumes: h.volumes) {
            liquidity[up] = p
        }
    }

    // ATR trailing-stop suggestion, cached per symbol.
    @Published private(set) var trailingStop: [String: TrailingStop] = [:]

    func refreshTrailingStop(symbol: String,
        allowed: () -> Bool = { ToolPolicy.webToolsDisabledReason() == nil },
        history: (String, String) async -> StockSagePriceHistory? = {
            await StockSageQuoteService.fetchHistory($0, range: $1)
        }
    ) async {
        let up = symbol.uppercased()
        guard !Task.isCancelled else { return }
        let key = "trailing:" + up, request = UUID()
        derivedRequests[key] = request
        trailingStop.removeValue(forKey: up)
        defer { if derivedRequests[key] == request { derivedRequests.removeValue(forKey: key) } }
        guard allowed() else { return }
        guard let h = await history(symbol, "6mo"), !Task.isCancelled, allowed(), derivedRequests[key] == request,
              h.symbol.uppercased() == up, StockSageRegime.historyAsOf(h, now: Date()) != nil else { return }
        if let ts = StockSageTrailingStop.suggest(highs: h.highs, lows: h.lows, closes: h.closes) {
            trailingStop[up] = ts
        }
    }

    // Backtest — the honesty check for one symbol.
    @Published private(set) var backtest: BacktestResult?
    /// Same strategy/symbol re-simulated with a WIDE ATR Chandelier trailing exit (vs `backtest`'s
    /// fixed 2:1) — a head-to-head so the owner can judge whether trailing helps (usually drawdown
    /// control, not more return). nil until a single-symbol backtest runs.
    @Published private(set) var backtestTrail: BacktestResult?
    @Published private(set) var backtestSymbol: String?
    @Published private(set) var isBacktesting = false
    @Published private(set) var backtestError: String?

    /// Fetch a multi-year history for `symbol` and walk-forward backtest the
    /// advisor's rules over it. User-triggered; non-destructive on failure.
    func runBacktest(symbol: String) async {
        guard !isBacktesting else { return }
        backtestSymbol = symbol                     // surface which symbol, even while running/failed
        // Clear the prior symbol's result BEFORE any early-return — else a web-disabled
        // (or otherwise bailed) run leaves the old symbol's backtest on screen attributed
        // to the new backtestSymbol (audit L3-02, 2026-07-07).
        backtest = nil
        backtestTrail = nil
        underwater = nil
        if let reason = ToolPolicy.webToolsDisabledReason() {
            backtestError = reason
            return
        }
        isBacktesting = true
        defer { isBacktesting = false }             // stays true across the fetch AND the O(bars²) compute
        backtestError = nil
        // 5 years of daily bars → room to trade after the 200-day warmup.
        let history = await StockSageQuoteService.fetchHistory(symbol, range: "5y")
        guard let history else {
            backtestError = "Couldn't load enough history to backtest \(symbol)."
            return
        }
        // The walk-forward is O(bars²) (advisor re-run each bar) — keep it off-main.
        // Charge the symbol's asset-class round-trip cost so the equity curve is honest.
        let btCosts = StockSageNetEdge.defaultCosts(forSymbol: symbol)
        // Same entry rules, two EXITS — the fixed 2:1 AND a wide ATR Chandelier trail (3×ATR/22) —
        // so the owner sees the research's claim head-to-head (trailing = drawdown control, usually
        // not more return). Both off-main in one hop; entries are identical, only simulateExit differs.
        let (fixed, trail) = await Task.detached(priority: .userInitiated) {
            (StockSageBacktester.run(history, costs: btCosts),
             StockSageBacktester.run(history, costs: btCosts, exitMode: .chandelierTrail(atrMult: 3, period: 22)))
        }.value
        backtest = fixed
        backtestTrail = trail
        // Buy-and-hold underwater curve over the same 5y window (cheap, O(n)).
        underwater = StockSageDrawdown.underwater(history.closes)
    }

    /// Buy-and-hold underwater curve for the last backtested symbol (5y closes).
    @Published private(set) var underwater: UnderwaterCurve?

    /// Ranking score for the "best ideas now" board: strongest conviction buys
    /// first, holds/avoids in the middle, sells last.
    // internal (not private): the board's default `.signal` ordering, pinned by
    // StockSageRankScoreTests (AUDIT F41) — a single sign slip silently reorders the board.
    static func rankScore(_ a: TradeAdvice) -> Double {
        switch a.action {
        case .strongBuy: return 2 + a.conviction
        case .buy:       return 1 + a.conviction
        case .hold:      return 0
        case .avoid:     return -0.1
        case .reduce:    return -1 - a.conviction
        case .sell:      return -2 - a.conviction
        }
    }

    // MARK: - Live worldwide feed

    /// Pure: should a refresh bail on a low-coverage response and keep whatever's already on
    /// screen rather than committing a partial board? True whenever coverage collapsed below 50%
    /// and there's an existing snapshot worth protecting — including the very first live refresh
    /// (the store always has at least the sample seed, so this isn't isSampleData-gated).
    /// Testable without a network fetch.
    nonisolated static func coverageGuardShouldBail(coverage: Double, hasExistingSymbols: Bool) -> Bool {
        coverage < 0.5 && hasExistingSymbols
    }

    /// Pull live quotes for the worldwide universe and swap them in, flipping the
    /// store off "sample". A no-op-with-reason when external access is disabled,
    /// and a non-destructive no-op when the feed is unreachable — the existing
    /// (sample or last-good) data stays on screen rather than blanking out.
    ///
    /// `scope` (review round-2 finding 1, orchestrator-flagged safe default — OWNER REVIEW
    /// PENDING): defaults to `.full` (the whole restricted universe) — every USER-INITIATED
    /// call site (the manual refresh button, the .task onAppear pull, the "check now" alert test)
    /// uses this default unchanged, matching the "verified-gentle" one-shot pulls the review
    /// cleared. ONLY `StockSageMonitor`'s unattended ~45s background auto-cycle passes `.core`,
    /// scoping its own recurring pull to the curated ~210-name core + the user's watchlist so the
    /// unattended loop can't repeatedly hammer the full promoted universe (feed-cooldown risk that
    /// could take the whole app's feed down). Nothing else about refresh()'s semantics changes —
    /// coverage-guard/bail, cache save, and the merge below all run over whichever `universe` this
    /// scope resolved to.
    /// One targeted retry for board rows whose quotes remain materially stale (the freshness
    /// definition already tolerates weekends/overnights, so these are genuine feed misses).
    /// Successes merge into the board AND into any matching idea's price label.
    /// Retry budget for the heal sweep. WHY (second review, 2026-07-28): the first version
    /// refetched EVERY row `isStale()` flagged, on every refresh. The equity staleness tolerance
    /// is 48h and a Friday close is ~65h old by Monday morning — so all weekend every equity row
    /// read stale, all ~900 were refetched on every cycle, and the feed returned the same closing
    /// price, which is still stale. A self-inflicted 429 storm against the keyless endpoint, and
    /// very likely a cause of the staleness this heal was written to fix.
    ///
    /// Brakes, in order: (1) SCOPE — a `.core` monitor tick must only heal the rows it actually
    /// attempted to fetch this cycle (`scopedTo`), never the ~700 rows a `.core` refresh never
    /// touched (review 2026-07-28 Q1: this was the missing brake — the market-trading gate and
    /// cap below shipped earlier, 5bfe6f9, but the sweep still ran over the WHOLE board regardless
    /// of scope). (2) market actually TRADING (a weekend close is not a fetch failure, it is the
    /// truth). (3) BACKOFF — even during trading hours a symbol whose last heal came back with the
    /// same marketTime it already had gets no gain from re-asking; skip it until a newer stamp
    /// lands. (4) cap how many are retried per sweep.
    private static let healBatchCap = 40

    /// Per-symbol marketTime stamp recorded after a heal that did NOT advance the quote — re-asking
    /// before that stamp changes is pure feed cost with zero possible gain. Cleared the moment a
    /// newer marketTime lands (or the feed omits marketTime entirely, so a transient gap can still
    /// retry next pass).
    private var healBackoff: [String: Date] = [:]

    /// Pure candidate selection for one heal pass — scope + staleness + backoff + cap, none of it
    /// touching the network. Extracted so the review's four brakes are pinned by a direct test
    /// (StockSageHealStaleQuotesTests) without spinning up a Store or a fetch.
    nonisolated static func healCandidates(
        symbols: [StockSageSymbol], scope: Set<String>, backoff: [String: Date], cap: Int,
        asOf now: Date = Date()
    ) -> [String] {
        let candidates = symbols.filter { s in
            let key = s.symbol.uppercased()
            // Inlined via StockSageQuoteFreshness (explicitly `nonisolated`) rather than
            // `s.isStale()`/`s.latest` — under this module's MainActor default isolation those
            // instance members infer MainActor isolation, which a `nonisolated static` can't call.
            let marketTime = s.quotes.last?.marketTime
            guard scope.contains(key),
                  StockSageQuoteFreshness.isStale(symbol: s.symbol, marketTime: marketTime, asOf: now)
            else { return false }
            guard let recorded = backoff[key] else { return true }
            return recorded != marketTime
        }
        return Array(candidates.prefix(cap).map(\.symbol))
    }

    private func healStaleQuotes(scopedTo scope: Set<String>,
                                 allowed: () -> Bool = { ToolPolicy.isExternalAllowed }) async {
        guard !Task.isCancelled, allowed() else { return }
        let now = Date()
        let tradingSymbols = symbols.filter { Self.marketIsTrading(symbol: $0.symbol, at: now) }
        let staleSymbols = Self.healCandidates(
            symbols: tradingSymbols, scope: scope, backoff: healBackoff, cap: Self.healBatchCap, asOf: now
        )
        guard !staleSymbols.isEmpty else { return }
        let recovered = await StockSageQuoteService.fetchQuotes(for: staleSymbols)
        guard !Task.isCancelled, allowed(), !recovered.isEmpty else { return }
        for (sym, q) in recovered {
            let key = sym.uppercased()
            let before = symbols.first { $0.symbol.uppercased() == key }?.latest?.marketTime
            mergeLiveQuote(q, symbol: sym)
            // No advance ⇒ the feed has nothing newer; don't re-ask until it does.
            if let t = q.marketTime, t == before { healBackoff[key] = t } else { healBackoff[key] = nil }
        }
    }

    /// Is this symbol's venue currently trading? A closed market's last print is the correct
    /// price, not a stale one worth refetching. Crypto is always trading; unknown venues are
    /// treated as trading so a classification gap can never SUPPRESS a real heal.
    nonisolated static func marketIsTrading(symbol: String, at date: Date = Date()) -> Bool {
        if StockSageAllocation.assetClass(symbol) == "Crypto" { return true }
        let cal = Calendar(identifier: .gregorian)
        if symbol.uppercased().hasSuffix(".SR") {
            return StockSageMarketHours.tadawulState(at: date, calendar: cal).phase == .open
        }
        let phase = StockSageMarketHours.nasdaqState(at: date, calendar: cal).phase
        // Pre/after-hours DO print, so a stale row can genuinely be healed then.
        return phase == .open || phase == .preMarket || phase == .afterHours
    }

    /// B2/N2 (owner: "every tracked stock live"): poll every tracked symbol the live stream
    /// doesn't cover (Tadawul, or anything else the stream hasn't subscribed) while its market is
    /// open, and merge whatever comes back into the board. Deliberately calls `mergeLiveQuotes`
    /// — NOT `refresh()` — so this stays a light per-cycle top-up: no coverage-guard bail, no
    /// disk-cache write, no `lastFullRefreshAt` stamp (that would wrongly re-trigger the
    /// catalyst rescan every cycle for a sweep touching a handful of rows). Called by
    /// `StockSageMonitor` every cycle REGARDLESS of watchlist-only mode, because that mode skips
    /// `refresh(scope: .core)` entirely — without this, watchlist-only + a Tadawul board name
    /// leaves that name polled by nothing at all (N2).
    /// Max symbols one `refreshStreamGap` sweep may poll (blocker fix 2026-09-06, revised for the
    /// W3 30s cadence — major fix 2026-09-06). `subscribed` is empty whenever the live stream is
    /// off (`stocksage.liveStream` toggle, MarketsView.swift) OR simply never started yet (Markets
    /// tab not shown while the monitor is already looping) — without a cap, `streamGapCandidates`
    /// then returns EVERY tracked trading symbol (872 streamable US names during a US session).
    /// 20 per 30s-cadence sweep keeps the sustained rate BELOW the pre-W3 60-per-60s baseline
    /// (60/60s vs 20/30s = 40/60s) even before `lastStreamGapAt`'s floor below removes the
    /// possibility of two callers stacking — a deliberately conservative number given Yahoo is
    /// already 429ing this Mac's IP today (STANDING RULES).
    nonisolated static let streamGapMaxPerSweep = 20

    /// Pure rotation: take at most `limit` symbols from `all` starting at `cursor`, wrapping
    /// around — so a candidate set bigger than the cap is still covered across SUCCESSIVE
    /// sweeps instead of the same head being re-polled forever while the tail starves. Returns
    /// the picked slice and the next cursor. Directly testable without a real candidate list.
    nonisolated static func rotatedSweepSlice(all: [String], cursor: Int, limit: Int) -> (picked: [String], nextCursor: Int) {
        guard !all.isEmpty, limit > 0 else { return ([], 0) }
        let n = min(all.count, limit)
        let start = ((cursor % all.count) + all.count) % all.count   // defensive: never negative
        let picked = (0..<n).map { all[(start + $0) % all.count] }
        return (picked, (start + n) % all.count)
    }

    /// Rotating cursor for `refreshStreamGap`'s cap — instance state so successive sweeps advance.
    private var streamGapCursor = 0

    /// Wall-clock floor between stream-gap sweeps (major fix 2026-09-06). MarketsView's 30s
    /// `.task` timer and `StockSageMonitor`'s every-cycle call are two OWNERS of one polling
    /// budget, not two independent budgets — without a floor, a monitor cycle landing between two
    /// MarketsView ticks (or the two simply racing) doubles the effective rate against an
    /// endpoint (Yahoo, for every name not served by the retained Massive snapshot route) that's
    /// already 429ing this Mac's IP today (STANDING RULES). 25s sits just under the 30s cadence so
    /// the owner's stated
    /// "every 30 seconds" still holds while a redundant near-simultaneous call is dropped.
    nonisolated static let streamGapMinInterval: TimeInterval = 25

    /// Pure boundary check, directly testable without a real clock or a running sweep — `nil`
    /// (never swept yet) always sweeps.
    nonisolated static func shouldSweepStreamGap(lastAt: Date?, now: Date,
                                                 minInterval: TimeInterval = streamGapMinInterval) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= minInterval
    }

    private var lastStreamGapAt: Date?

    func refreshStreamGap() async {
        let access = StockSageMassive.Access().capture()
        await refreshStreamGap(candidates: trackedDefs(scope: .streamGap).map(\.symbol),
            allowed: access.isCurrent, fetch: { await StockSageQuoteService.fetchQuotes(for: $0) })
    }

    func refreshStreamGap(candidates all: [String], allowed: () -> Bool,
                          fetch: ([String]) async -> [String: StockSageQuoteService.LiveQuote]) async {
        guard allowed(), !Task.isCancelled else { return }
        let now = Date()
        guard Self.shouldSweepStreamGap(lastAt: lastStreamGapAt, now: now) else { return }
        guard !all.isEmpty else { return }
        lastStreamGapAt = now
        let (candidates, nextCursor) = Self.rotatedSweepSlice(all: all, cursor: streamGapCursor, limit: Self.streamGapMaxPerSweep)
        streamGapCursor = nextCursor
        let quotes = await fetch(candidates)
        guard allowed(), !Task.isCancelled else { return }
        applyPolledQuotes(quotes)
    }

    /// Apply a batch of polled quotes — the `.streamGap` timer's 30s top-up (MarketsView) for
    /// tracked symbols the live stream doesn't carry (Tadawul, or a name mid-(re)connect) — via
    /// the in-place merge above. Stamps `lastUpdated`/`quoteAsOf` (a poll IS a live observation)
    /// but DELIBERATELY never `lastFullRefreshAt`: that field gates the catalyst rescan
    /// (`refreshCatalysts`, reloads the whole on-disk history), which must not re-run every 30s
    /// for a sweep touching a handful of rows. A valid first observation also prices a newly
    /// tracked holding/watchlist entry; arbitrary untracked symbols never create board rows.
    func applyPolledQuotes(_ quotes: [String: StockSageQuoteService.LiveQuote]) {
        if mergeLiveQuotes(quotes) { lastUpdated = Date() }
    }

    /// Shared merge for targeted fetches: rebuilds the board row with the fresh quote (same
    /// two-quote shape refresh() commits) and relabels any matching idea's price honestly.
    private func mergeLiveQuote(_ q: StockSageQuoteService.LiveQuote, symbol: String) {
        mergeLiveQuotes([symbol.uppercased(): q])
    }

    func refresh(scope: TrackedScope = .full) async {
        let isCurrent = StockSageMassive.Access().capture().isCurrent
        await refresh(universe: trackedDefs(scope: scope), allowed: isCurrent,
            fetchQuotes: { await StockSageQuoteService.fetchQuoteBatch(for: $0) },
            refreshFX: { await self.refreshInfraFX(allowed: isCurrent) },
            heal: { await self.healStaleQuotes(scopedTo: $0, allowed: isCurrent) })
    }

    /// The production refresh boundary, with provider work replaceable by isolated fixtures.
    func refresh(universe: [StockSageSymbol], allowed: () -> Bool,
                 fetchQuotes: ([String]) async -> StockSageQuoteService.QuoteBatch,
                 refreshFX: () async -> Void, heal: (Set<String>) async -> Void) async {
        guard !isRefreshing, !Task.isCancelled else { return }
        if !allowed() {
            feedError = ToolPolicy.webToolsDisabledReason() ?? "Quote refresh unavailable."
            return
        }

        isRefreshing = true
        // Held for the WHOLE cycle (review 2026-07-28 Q3): releasing it before the merge/heal/
        // commit below let a second refresh() interleave with this one's writes.
        defer { isRefreshing = false }
        let batch = await fetchQuotes(universe.map(\.symbol))
        guard !Task.isCancelled, allowed(), batch.stop != .invalidated else { return }
        if batch.stop == .yahooThrottled {
            if mergeLiveQuotes(batch.quotes, including: universe) { lastUpdated = Date() }
            feedError = "Partial market data — Yahoo limited quote requests. Accepted quotes were updated; previous prices were kept for the rest."
            return
        }
        let quotes = batch.quotes
        await refreshFX()   // SAR rate for .SR conversions (infra — FX left the universe 2026-07-16)
        guard !Task.isCancelled, allowed() else { return }

        // Merge each curated symbol (keeps the friendly market label) with its
        // live quote; drop any the feed couldn't price.
        var baselineRepairKeys: Set<String> = []
        let live: [StockSageSymbol] = universe.compactMap { sym in
            let key = sym.symbol.uppercased()
            guard let q = quotes[key], q.symbol.uppercased() == key,
                  q.price > 0, q.price.isFinite, q.previousClose.isFinite else { return nil }
            let existing = symbolIndex[key].map { symbols[$0] }
            let accepted = Self.acceptsQuote(q.marketTime, after: existing?.latest?.marketTime,
                massiveTradeSequence: q.massiveTradeSequence,
                afterMassiveTradeSequence: existing?.latest?.massiveTradeSequence,
                priceSource: q.priceSource, afterPriceSource: existing?.latest?.priceSource)
            guard let updated = Self.mergedQuote(q, after: existing?.latest, symbol: key,
                                                acceptPrice: accepted, now: Date()) else { return existing }
            if !accepted {
                guard var existing, updated != existing.latest else { return existing }
                existing.quotes[existing.quotes.count - 1] = updated
                baselineRepairKeys.insert(key)
                return existing
            }
            return StockSageSymbol(id: existing?.id ?? UUID(), symbol: sym.symbol, market: sym.market, quotes: [
                StockSageQuote(price: q.previousClose, previousPrice: q.previousClose,
                               time: Date(timeIntervalSinceNow: -86_400)),
                // Carry the real MARKET time separately so per-row staleness can flag a days-old
                // weekend/holiday close; `time` stays the observation time. nil marketTime ⇒ not judged.
                updated,
            ])
        }
        // A cancelled cycle is not an outage. StockSageQuoteService.fetchQuotes fail-closes to
        // [:] on Task.isCancelled (five sites), which lands here as an empty board and used to
        // assert a feed failure that never happened — the app blaming the network for its own
        // cancellation. Leave the previous state and message untouched instead.
        guard !Task.isCancelled, allowed() else { return }
        guard !live.isEmpty else {
            feedError = "Couldn't reach the market feed — showing the last data."
            return
        }
        // Don't let a partial outage replace a full board with a handful of rows: if coverage
        // collapsed and there's an existing snapshot on screen (sample, cached, OR already-live —
        // deliberately NOT gated on `!isSampleData`, so a low-coverage FIRST-EVER refresh also
        // bails instead of silently truncating the board with feedError left nil), keep it.
        let coverage = Double(live.count) / Double(max(universe.count, 1))
        if Self.coverageGuardShouldBail(coverage: coverage, hasExistingSymbols: !symbols.isEmpty) {
            feedError = "Partial market data this refresh — keeping the previous snapshot."
            return
        }
        // Preserve user-added tickers this refresh's pre-await snapshot may have
        // missed — e.g. a symbol added DURING the network await would otherwise be
        // wiped by the wholesale replace until the next cycle.
        // A removeSymbol() that landed DURING the await must win: this refresh's pre-await snapshot
        // still fetched + priced that ticker, so it sits in `live` and would otherwise revert the
        // removal on screen AND re-persist it to the cache (surviving relaunch). Drop any user-market
        // row whose symbol is no longer tracked. Curated rows are untouched (removeSymbol no-ops there).
        // B1: "tracked" here must also cover off-board portfolio/journal-open holdings — trackedDefs
        // now hands them a userMarketLabel row too, so without offBoardHoldingSymbols here this guard
        // would immediately strip a portfolio-only holding's row the very refresh that priced it.
        let tracked = Set(userSymbols.map { $0.uppercased() }).union(offBoardHoldingSymbols)
        let liveFiltered = live.filter {
            $0.market != Self.userMarketLabel || tracked.contains($0.symbol.uppercased())
        }
        let liveKeys = Set(liveFiltered.map { $0.symbol.uppercased() })
        let preservedUserRows = symbols.filter {
            $0.market == Self.userMarketLabel && !liveKeys.contains($0.symbol.uppercased())
        }
        // SCOPE FIX (review round-2 finding 1): a `.core` refresh's `universe` only covers
        // ~210+watchlist names — WITHOUT this, `replaceAll` below would wholesale-replace the
        // WHOLE board with just those rows, truncating away any catalogExtra-only rows a prior
        // `.full` refresh had populated (the monitor's background cycle runs every ~45s and would
        // visibly shrink the board on its very next tick). `preservedOutOfScopeRows` keeps every
        // existing row this cycle's scope didn't even attempt to fetch, so a `.core` cycle MERGES
        // into the board instead of truncating it. `.full` refreshes: `universe` already covers
        // everything, so this is always empty — byte-identical to before.
        let scopedKeys = Set(universe.map { $0.symbol.uppercased() })
        // User-market rows are EXCLUDED here — they already have their own preservation lane
        // (preservedUserRows above); including them double-preserved a row added DURING the
        // fetch await (absent from both pre-await scopedKeys and liveKeys → matched both
        // filters → duplicate board row, persisted to the cache; review round-3 finding 1).
        let preservedOutOfScopeRows = symbols.filter {
            $0.market != Self.userMarketLabel
                && !scopedKeys.contains($0.symbol.uppercased())
                && !liveKeys.contains($0.symbol.uppercased())
        }
        let committed = liveFiltered + preservedUserRows + preservedOutOfScopeRows
        // Set the new-listing honesty flags only once BOTH non-destructive bails have
        // passed (empty-feed L1162, coverage L1170) — assigning before them let a failed
        // or partial refresh wipe the flags while keeping the old rows, so a cached
        // placeholder-flat IPO row read as a genuine 0.00% move (audit L3-01, 2026-07-07).
        // This cycle's quotes are authoritative ONLY for the symbols it actually fetched
        // (scopedKeys) — flags for out-of-scope rows the cycle didn't attempt carry forward,
        // else every ~45s .core tick wipes the catalogExtra rows' new-listing honesty badges
        // (review round-3 finding 2; same honesty lineage as audit L3-01).
        // FIX (2nd-read hunt, 2026-07-08): was `.subtracting(scopedKeys)`, which wrongly dropped
        // the flag for an in-scope symbol the feed simply THROTTLED/MISSED this cycle (present in
        // scopedKeys, absent from quotes.keys — e.g. a user-added new listing preserved via
        // preservedUserRows) — its tile fabricated a flat "+0.0%" instead of staying "N/A (new)".
        // reconcileNewListings only clears a flag for a symbol THIS cycle actually re-priced
        // (present in quotes with isNewListing==false); anything absent from quotes.keys — whether
        // throttled-in-scope or genuinely out-of-scope — carries its flag forward untouched.
        let acceptedQuotes = quotes.filter { key, q in
            let current = symbolIndex[key].flatMap { symbols[$0].latest }
            return q.symbol.uppercased() == key && q.price > 0 && q.price.isFinite && q.previousClose.isFinite
                && Self.acceptsQuote(q.marketTime, after: current?.marketTime,
                    massiveTradeSequence: q.massiveTradeSequence, afterMassiveTradeSequence: current?.massiveTradeSequence,
                    priceSource: q.priceSource, afterPriceSource: current?.priceSource)
        }
        let baselineRepairs = quotes.filter { baselineRepairKeys.contains($0.key) }
        newListings = Self.reconcileNewListings(current: newListings,
            pricedQuotes: acceptedQuotes.merging(baselineRepairs) { _, repaired in repaired })
        replaceAll(committed, isSample: false)
        // Mirror this sweep's live prices onto the matching ideas — same invariant applyLiveTick
        // and mergeLiveQuote already hold ("the card and the row can never disagree", review
        // 2026-07-28 Q9). Without this, refresh() left every idea card on its scan-time daily-bar
        // close while the board row beside it showed the live quote. `withLivePrice` deliberately
        // leaves stop/target/EV untouched — those are fixed LEVELS (StockSageIdea.withLivePrice).
        // `asOf: q.marketTime` — NOT `?? Date()` — so a timestamp-less quote leaves `priceAsOf`
        // nil, which `cardIsStale` correctly treats as "can't judge" (fail-closed unknown).
        ideas = Self.mergedPolledQuotes(symbols: [], ideas: ideas, symbolIndex: [:], quotes: acceptedQuotes).ideas
        ideas = Self.ideasWithLatestPrices(ideas, symbols: symbols, previous: [])
        // STALE SELF-HEAL (owner directive 2026-07-27: "fix all stale stocks"): any row still
        // MATERIALLY stale after this refresh (beyond the weekend-tolerant freshness window) is
        // exactly what a throttled/partial sweep left behind — retry those alone, once.
        await heal(scopedKeys)
        guard !Task.isCancelled, allowed() else { return }
        feedError = nil
        lastUpdated = Date()
        lastFullRefreshAt = Date()
        // Newest MARKET time across the priced quotes — the banner uses this (not fetch time) to
        // tell live from a stale close. nil when the feed omitted timestamps for all of them.
        // Max-merge (review Q7): a scoped/partial sweep carrying older stamps must not roll the
        // as-of backwards, and a sweep with no stamps must not blank it.
        if let newest = acceptedQuotes.values.compactMap(\.marketTime).max() {
            quoteAsOf = max(quoteAsOf ?? .distantPast, newest)
        }
        // Persist EXACTLY what is on screen (incl. preserved user-added tickers the feed missed this
        // cycle) — caching only `live` dropped them, so a tracked ticker vanished from the offline /
        // last-good board on next launch.
        loadedFromCache = false
        // Q11: a scoped/throttled sweep's `committed` legitimately omits an in-scope CURATED
        // symbol the feed missed this cycle (no preservation lane covers that case — only
        // user-market and out-of-scope rows are preserved above) — writing `committed` straight
        // to disk would ERASE that symbol's last-good cache entry every time the feed hiccups on
        // it. Merge over whatever is already on disk so a missed symbol keeps its last-good
        // price/marketTime; on-screen (`committed`/`symbols`) is unaffected — this only protects
        // what's persisted for the next launch.
        let freshCache = StockSageQuoteCache.from(symbols: symbols, savedAt: lastUpdated ?? Date(), newListings: newListings)
        // Q11's retention merge (StockSageQuoteCache.merging) carries forward every on-disk
        // entry `freshCache` doesn't have — including a symbol `removeSymbol` just dropped from
        // `userSymbols`/`symbols` above, which never touches the disk cache (major fix
        // 2026-09-06). Pre-filter `previous` to symbols STILL tracked (any scope — curated
        // universe ∪ watchlist ∪ off-board holdings) so a removed ticker actually leaves the
        // disk cache. Offline restoration also filters independently, so it does not need to
        // wait for this refresh before respecting the removal.
        let stillTracked = Set(trackedDefs().map { $0.symbol.uppercased() })
        let retainedPrevious = StockSageQuoteCache.load().map {
            StockSageQuoteCache(entries: Self.retainedCacheEntries(previous: $0.entries, tracked: stillTracked), savedAt: $0.savedAt)
        }
        StockSageQuoteCache.merging(previous: retainedPrevious, new: freshCache).save()
    }

    func fetchAllSymbols() -> [StockSageSymbol] {
        symbols.sorted { $0.symbol < $1.symbol }
    }

    func symbol(named name: String) -> StockSageSymbol? {
        symbols.first { $0.symbol.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Replace the whole set (e.g. when a live feed delivers a fresh snapshot).
    /// Marks the store as no-longer-sample.
    func replaceAll(_ newSymbols: [StockSageSymbol], isSample: Bool = false) {
        symbols = newSymbols
        rebuildSymbolIndex()
        isSampleData = isSample
    }

    // MARK: - Sample data
    //
    // A handful of TASI + US names with one prior + current quote each, chosen to
    // exercise every signal branch (a strong mover, a moderate mover, a flat
    // one). NOT live — see the type doc above.
    // Internal (not private) so a test can deterministically restore the known sample state —
    // the shared singleton's `isSampleData` flips to false once any test calls refresh().
    func seedSampleData() {
        symbols = [
            Self.sample("2222.SR", "TASI", previous: 28.50, current: 30.40),   // +6.7% → strong buy
            Self.sample("1120.SR", "TASI", previous: 92.10, current: 89.30),   // -3.0% → sell
            Self.sample("AAPL",    "NASDAQ", previous: 226.0, current: 227.1), // +0.5% → hold
            Self.sample("NVDA",    "NASDAQ", previous: 118.0, current: 126.5), // +7.2% → strong buy
            Self.sample("7010.SR", "TASI", previous: 41.0,  current: 42.3),    // +3.2% → buy
        ]
        rebuildSymbolIndex()
        isSampleData = true
    }

    private static func sample(_ ticker: String, _ market: String,
                               previous: Double, current: Double) -> StockSageSymbol {
        StockSageSymbol(symbol: ticker, market: market, quotes: [
            StockSageQuote(price: previous, previousPrice: previous,
                           time: Date(timeIntervalSinceNow: -3600)),
            // marketTime present so fail-closed staleness (2026-07-27) doesn't badge the
            // sample board — the SAMPLE label is the honesty surface for seeded data.
            StockSageQuote(price: current, previousPrice: previous, marketTime: Date(), priceSource: .sample),
        ])
    }

    // MARK: - QA fixture ideas (QA/test-only seam — reachable ONLY from the --qa
    // capture path in QASnapshots.checkAndRun; never on a normal launch)

    /// Deterministic synthetic histories that exercise real advisor branches.
    /// Series are the TEST SUITE'S PROVEN generators (StockSageAdvisorTests /
    /// StockSageBuildIdeasDirectTests) inlined — the test target can't be imported here.
    /// Pure + nonisolated so a test can pipe them through buildIdeas without
    /// touching the shared singleton (parallel-test safe).
    // NOTE — deviation from spec, flagged in the final report: spec said `nonisolated`, but
    // StockSageSymbol's hand-written init (StockSageModels.swift) has no `nonisolated` marker,
    // so under this module's default-actor-isolation build setting it is @MainActor-isolated
    // (unlike StockSagePriceHistory below, whose synthesized memberwise init is nonisolated for
    // free, and unlike StockSageIdea's init at line 38 which IS explicitly marked nonisolated).
    // Spec's two-files-only scope forbids editing StockSageModels.swift, so this stays isolated
    // (main-actor) instead — its only caller, seedQAIdeas, is already on @MainActor.
    static func qaFixtureDefs() -> [StockSageSymbol] {
        [
            StockSageSymbol(symbol: "NVDA",    market: "NASDAQ"),  // strongBuy, bullTrend
            StockSageSymbol(symbol: "AAPL",    market: "NASDAQ"),  // buy (+ seeded earnings warning)
            StockSageSymbol(symbol: "1120.SR", market: "TASI"),    // sell-family, bearTrend (short plan)
            StockSageSymbol(symbol: "MSFT",    market: "NASDAQ"),  // strongBuy (was BTC-USD; crypto removed 2026-07-28)
            StockSageSymbol(symbol: "7010.SR", market: "TASI"),    // vol-regime brake ⚠ note
        ]
    }

    nonisolated static func qaFixtureHistories() -> [String: StockSagePriceHistory] {
        func hist(_ sym: String, _ closes: [Double]) -> StockSagePriceHistory {
            // Date the bars so the LAST close lands on today (one bar per prior day). Deterministic
            // in rendered output — the fixture prices are fixed and the sparkline uses only closes,
            // but priceAsOf (= dates.last) must read as TODAY so the QA board shows a fresh scan,
            // not a stale-everything board. Epoch-anchored dates (1970) made every fixture card
            // trip cardIsStale's price-freshness axis (added 2026-07-08) — a false stale badge on a
            // board meant to represent the normal fresh-scan case.
            let base = Date().addingTimeInterval(-Double(max(0, closes.count - 1)) * 86_400)
            let dates = closes.enumerated().map { base.addingTimeInterval(Double($0.offset) * 86_400) }
            return StockSagePriceHistory(symbol: sym, dates: dates,
                opens: closes, highs: closes.map { $0 * 1.005 }, lows: closes.map { $0 * 0.995 },
                closes: closes, volumes: closes.map { _ in 100_000 }, priceSource: .sample)
        }
        // TrendFixtures.up(250): accelerating uptrend → pinned strongBuy + stop/target + ⏱ note
        // (StockSageBuildIdeasDirectTests.executionTimingNoteAppearsForBullTrendBuy).
        let up250 = (0..<250).map { 50.0 + 0.0153 * pow(Double($0), 2) }
        // TrendFixtures.up(70): lighter 50DMA branch → pinned .buy
        // (StockSageAdvisorTests.fiftyBarHistoryUsesLighterTrendScore).
        let up70 = (0..<70).map { 50.0 + 0.0153 * pow(Double($0), 2) }
        // Gentle linear downtrend 200→~50 → pinned sell/reduce + bearTrend, short stop/target
        // (StockSageAdvisorTests.cleanDowntrendIsASellShortSetup).
        let down250 = (0..<250).map { 200.0 - Double($0) * 0.602 }
        // 293 bars: 272 calm sinusoidal then 21 alternating ±3% → vol-regime brake note
        // (StockSageBuildIdeasDirectTests.volRegimeBrakeNoteAppearsWhenRecentVolElevated).
        var px = 100.0; var brake = [px]
        for i in 0..<272 { px *= (1 + sin(Double(i)) * 0.005); brake.append(px) }
        for i in 0..<20  { px *= (1 + (i % 2 == 0 ? 1.0 : -1.0) * 0.030); brake.append(px) }
        return [
            "NVDA":    hist("NVDA", up250),
            "AAPL":    hist("AAPL", up70),
            "1120.SR": hist("1120.SR", down250),
            // The advisor is scale-invariant (returns/ATR%/momentum are all ratios), so this
            // reuses up250 unscaled — same demo action the BTC-USD row produced before crypto
            // was removed (2026-07-28).
            "MSFT": hist("MSFT", up250),
            "7010.SR": hist("7010.SR", brake),
        ]
    }

    /// Seed the shared store with deterministic fixture ideas COMPUTED THROUGH THE REAL
    /// buildIdeas/advise pipeline. Forces the sample-labeled state first (seedSampleData →
    /// isSampleData = true) so the fixture board is honestly bannered "Sample data" —
    /// never rendered under the cached/live banner. In-memory only: nothing here persists
    /// (ideas/earningsDates are not written to disk; paper-trading/alerts/monitor untouched).
    func seedQAIdeas(previousScanEntries: [String: String] = [:]) async {
        seedSampleData()   // honest labeling: whole board = sample, isSampleData = true
        // Provenance honesty (2026-07-08): the --qa launch may already have loaded the disk
        // cache (loadedFromCache=true) before this seed replaces the board with fixtures. Clear
        // both flags so MarketsView.feedBanner (isSampleData checked first) falls through to
        // the honest "⚠︎ SAMPLE prices (not real)" branch rather than a cached-data claim
        // sitting above it. In-memory only,
        // deliberately NO restore closure (unlike seedQAPortfolio/seedQAJournal, whose fixture
        // CONTENT could leak into the owner's persisted state via a later save()): these two
        // flags are never persisted anywhere, and this seam is reachable only from the
        // capture-only --qa process, which qa.sh quits right after captureAll() returns —
        // the same reason `ideas` below is fixture-replaced without a restore.
        loadedFromCache = false
        cacheSavedAt = nil
        let built = await Self.buildIdeas(defs: Self.qaFixtureDefs(),
                                          histories: Self.qaFixtureHistories(),
                                          benchmark: nil,          // no RS term → deterministic
                                          calibration: nil,        // prior sizing → deterministic
                                          journalTrades: [])       // sector rotation no-op
        ideas = built.sorted { Self.rankScore($0.advice) > Self.rankScore($1.advice) }
        ideasUpdated = Date()
        // Earnings warning on the buy card: ≤3 days → .imminent (StockSageEarnings severity)
        // → "⚠︎ earnings ~2d" chip + rank demotion visible on the AAPL card. In-memory only.
        earningsDates["AAPL"] = Date().addingTimeInterval(2 * 86_400)
        // Fixture input only; never read or save the owner's previous-scan baseline.
        scanDeltas = StockSageScanDelta.deltas(current: ideas, previous: previousScanEntries)
    }
}
