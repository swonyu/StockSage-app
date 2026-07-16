import Foundation
import Combine

// MARK: - Forward paper-trading harness
//
// The backtester answers "would the rules have worked on HISTORY?" (overfit-prone). The journal
// answers "what did the OWNER actually do?" (real money, but empty until they log). This fills the
// gap between them: it auto-"trades" every long-actionable idea the engine generates with FAKE money,
// marks each to a realistic NET-OF-COST fill, and closes it when a real future bar crosses the
// stop/target/time-stop. The accumulating realized outcomes are a genuinely FORWARD, out-of-sample
// test — overfit-proof, because the bars that decide each trade did not exist when the rules were
// frozen. It is the data source the calibration/measurement stack is otherwise starving for.
//
// HONESTY FLOOR (non-negotiable):
//   • NET-OF-COST fills, never mid. A naive paper fill overstates and lies — the app's own cost
//     research is the reason. Cost is applied EXACTLY as the backtester applies it (see below).
//   • PAPER ≠ REAL. Paper trades live in a SEPARATE store (`StockSagePaperTradeStore`, distinct
//     UserDefaults key) and are NEVER mixed into the real `StockSageJournalStore`.
//   • nil = unknown. A trade with no bars after `openedAt` stays open; nothing is fabricated.
//
// FENCE (F01/F02; framing updated 2026-07-09 after the owner gate-lift): paper outcomes do NOT
// feed the production `StockSageStore.convictionCalibration` / `fit(fromJournal:)`. That map stays
// real-journal-only. Wiring paper → production sizing is now an EVIDENCE-decidable change (no owner
// gate) — but it remains deliberately NOT taken: paper fills are frictionless simulations, and the
// honesty floor requires any calibration input to be labeled by provenance. Revisit only with a
// measured case that paper-fill bias is bounded (e.g. vs realized-cost capture data, shipped 2026-07-09).
//
// BACKTEST PARITY (derive, never copy): exit selection reuses `StockSageBacktester.simulateExit`
// (gap-honest stop fills, stop-wins-ties, `.timeStop` backstop) and the net-R convention is matched
// byte-for-byte — a closed paper trade's `TradeRecord.realizedR` equals the backtester's net R for
// the same trade, so the two paths cannot silently diverge.

enum StockSagePaperTrader {

    /// Open a PAPER trade from a freshly-generated idea. Long-only (the app is long-biased; stops and
    /// targets are long-side): returns nil unless the action is buy-side AND a stop+target exist AND
    /// the risk is defined (entry above stop). No fabrication on missing data — nil means "not a paper
    /// candidate", handled by the caller. `entry` is kept GROSS (the idea's quote); the round-trip cost
    /// is netted in at the exit, exactly as `StockSageBacktester.runTrades` does.
    static func open(from idea: StockSageIdea, at openDate: Date,
                     nominalRisk: Double = 100) -> TradeRecord? {
        let a = idea.advice
        guard a.action == .strongBuy || a.action == .buy else { return nil }
        guard let stop = a.stopPrice, let target = a.targetPrice else { return nil }
        let entry = idea.price
        let risk = entry - stop
        guard entry > 0, risk > 0 else { return nil }   // a long's stop sits below entry → defined risk
        // Nominal fixed-risk sizing so the reused $ analytics are sensible; R is the scale-free truth.
        let shares = Swift.max(1, (nominalRisk / risk).rounded())
        return TradeRecord(symbol: idea.symbol, side: .long, entry: entry, stop: stop,
                           target: target, shares: shares, openedAt: openDate,
                           note: "paper (auto)", conviction: a.conviction)
    }

    /// Mark each OPEN long paper trade to the given symbol's history and close any that crossed
    /// stop / target / the time-stop backstop. PURE + deterministic (dates come from the bars, no
    /// `Date.now`). Exit selection is delegated to `StockSageBacktester.simulateExit`; the round-trip
    /// cost is netted into the stored `exitPrice` so `TradeRecord.realizedR` == the backtester's net R:
    ///   costPerShare = max(0, roundTripBps)/10_000 · entry ;  exitPrice = grossExit − costPerShare.
    /// A trade whose symbol ≠ this history, that is already closed, or that has no bar after `openedAt`
    /// is returned UNCHANGED (still open — honesty: no new data ⇒ no close).
    static func markToMarket(_ open: [TradeRecord], history: StockSagePriceHistory,
                             costs: StockSageNetEdge.CostAssumption,
                             maxHoldingBars: Int = 63) -> [TradeRecord] {
        let dates = history.dates, opens = history.opens, highs = history.highs
        let lows = history.lows, closes = history.closes
        let n = closes.count
        guard n > 0, opens.count == n, highs.count == n, lows.count == n, dates.count == n else { return open }
        let costFactor = Swift.max(0, costs.roundTripBps) / 10_000   // × entry ⇒ per-share round-trip cost
        return open.map { t in
            guard t.isOpen, t.side == .long,
                  t.symbol.uppercased() == history.symbol.uppercased(),
                  let target = t.target else { return t }
            // First bar STRICTLY after the open — no look-ahead onto the entry bar itself.
            guard let startIdx = dates.firstIndex(where: { $0 > t.openedAt }) else { return t }
            let (exitIdx, grossExit, outcome) = StockSageBacktester.simulateExit(
                entryIdx: startIdx, stop: t.stop, target: target,
                opens: opens, highs: highs, lows: lows, closes: closes, n: n,
                mode: .timeStop(maxBars: maxHoldingBars))
            guard outcome != .openAtEnd else { return t }   // neither level nor time-stop reached → hold
            var closed = t
            closed.exitPrice = grossExit - costFactor * t.entry   // long: net proceeds per share
            closed.closedAt = dates[exitIdx]
            return closed
        }
    }

    /// One forward step: mark existing open trades to their latest history and open new paper trades
    /// for long-actionable ideas that don't already have an open position. Returns the closes to apply
    /// and the new trades to add — PURE (no I/O); the store persists them. Dedup: at most one open paper
    /// trade per symbol.
    static func step(current: [TradeRecord], ideas: [StockSageIdea],
                     histories: [String: StockSagePriceHistory], openDate: Date,
                     costsFor: (String) -> StockSageNetEdge.CostAssumption,
                     nominalRisk: Double = 100, maxHoldingBars: Int = 63)
        -> (closes: [TradeRecord], opens: [TradeRecord]) {
        // 1. Mark-to-market every currently-open trade against its own symbol's history.
        var closes: [TradeRecord] = []
        for t in current where t.isOpen {
            guard let h = histories[t.symbol] ?? histories[t.symbol.uppercased()] else { continue }
            if let u = markToMarket([t], history: h, costs: costsFor(t.symbol),
                                    maxHoldingBars: maxHoldingBars).first, !u.isOpen {
                closes.append(u)
            }
        }
        // Symbols that remain open after this step's closes — don't double-open into them.
        let closedIds = Set(closes.map(\.id))
        let stillOpen = Set(current.filter { $0.isOpen && !closedIds.contains($0.id) }
                                    .map { $0.symbol.uppercased() })
        // 2. Open new paper trades for long-actionable ideas without an open position.
        var opens: [TradeRecord] = []
        var openedThisStep = Set<String>()
        for idea in ideas {
            let sym = idea.symbol.uppercased()
            guard !stillOpen.contains(sym), !openedThisStep.contains(sym) else { continue }
            if let t = open(from: idea, at: openDate, nominalRisk: nominalRisk) {
                opens.append(t)
                openedThisStep.insert(sym)
            }
        }
        return (closes, opens)
    }

    /// FORWARD, out-of-sample, net-of-cost read on the paper record — the campaign's milestone metric
    /// (DSR > 0.95) applied forward. All from the CLOSED paper trades' realized R (already net-of-cost).
    /// nil under 4 closed-with-R (moments needs ≥4). The per-trade Sharpe matches StockSageBacktester's
    /// convention (mean ÷ SAMPLE stdev); `trials: 1` ⇒ DSR == PSR — a forward OOS test of the
    /// already-selected strategy incurs no NEW selection bias, so no haircut is honest.
    nonisolated static func forwardStats(_ trades: [TradeRecord]) -> PaperForwardStats? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard let m = StockSageDeflatedSharpe.moments(rs) else { return nil }   // nil ⇒ <4 closed-with-R
        let n = rs.count
        let avgR = rs.reduce(0, +) / Double(n)
        let variance = rs.reduce(0) { $0 + ($1 - avgR) * ($1 - avgR) } / Double(n - 1)   // sample (n−1)
        let sd = variance.squareRoot()
        let sharpe = sd > 0 ? avgR / sd : 0
        let d = StockSageDeflatedSharpe.deflated(observedSharpe: sharpe, nTrades: n,
                                                 skew: m.skew, kurtosis: m.kurtosis,
                                                 trials: 1, varTrialSharpe: 0)
        let wins = rs.filter { $0 > 0 }.count
        return PaperForwardStats(closed: n, winRate: Double(wins) / Double(n), avgR: avgR,
                                 sharpe: sharpe, deflated: d,
                                 health: StockSageJournal.systemHealth(trades))
    }

    /// Honest framing for any surface that shows the paper track record.
    nonisolated static let caveat =
        "Paper (fake-money) forward test — the engine auto-opens each long idea and marks it to a "
        + "NET-OF-COST fill, closing on stop/target/time-stop. It measures the rules going forward, "
        + "out-of-sample; it is NOT the owner's real trades and does NOT feed win-rate calibration."

    /// BIAS-CORRECTED forward read. The closed-only `forwardStats` is SELECTION-BIASED — a stop is a
    /// near boundary hit quickly, a 2× target a far one hit slowly, so the trades that close FIRST
    /// over-represent losers (measured 2026-07-12: closed-only −0.50R on ~8% resolved vs +0.07R on
    /// the full book). This brackets the truth by ALSO marking each still-open long to its latest
    /// close: realized-only from below, full-book from above. The open marks are UNREALIZED (an open
    /// winner can still reverse to its stop) and GROSS (no exit cost netted yet), so they lean
    /// OPTIMISTIC — the truth sits between the two bounds and converges as the book resolves. Neither
    /// bound is an edge claim; both are typically ≈0 (value is risk-discipline, not alpha).
    ///
    /// PURE + testable: `latestClose` (symbol→latest close) is passed in — the store builds it from
    /// the scan's histories. Unrealized R for a long = (close − entry) / (entry − stop). nil under 4
    /// evaluable trades (too thin for any read).
    nonisolated static func scoreboard(_ trades: [TradeRecord],
                                       latestClose: [String: Double]) -> PaperForwardScoreboard? {
        let realized = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        var full = realized
        var marked = 0
        for t in trades where t.isOpen && t.side == .long {
            guard let c = latestClose[t.symbol.uppercased()], c > 0, t.entry != t.stop else { continue }
            full.append((c - t.entry) / (t.entry - t.stop))   // unrealized R at the latest close
            marked += 1
        }
        guard full.count >= 4 else { return nil }
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        func win(_ a: [Double]) -> Double { a.isEmpty ? 0 : Double(a.filter { $0 > 0 }.count) / Double(a.count) }
        return PaperForwardScoreboard(realizedN: realized.count, realizedAvgR: avg(realized),
                                      realizedWinRate: win(realized), fullN: full.count,
                                      fullAvgR: avg(full), fullWinRate: win(full), openMarked: marked)
    }
}

/// A bias-corrected forward read on the paper book (see `StockSagePaperTrader.scoreboard`). Two
/// bounds — closed-only realized R, and the full book with still-open longs marked to their latest
/// close — that bracket the truth. Labeled PAPER + "unrealized marks lean optimistic" at any surface.
struct PaperForwardScoreboard: Sendable, Equatable {
    let realizedN: Int          // closed trades with a defined R (the biased lower bound's basis)
    let realizedAvgR: Double
    let realizedWinRate: Double
    let fullN: Int              // realized + open-marked (the optimistic upper bound's basis)
    let fullAvgR: Double
    let fullWinRate: Double
    let openMarked: Int
    /// Fraction of the evaluable book that has actually RESOLVED (closed). Low ⇒ the closed-only read
    /// is heavily selection-biased and the full-book mark carries most of the weight.
    nonisolated var resolvedFrac: Double { fullN > 0 ? Double(realizedN) / Double(fullN) : 0 }
}

/// A FORWARD, out-of-sample, net-of-cost read on the paper track record — the campaign's milestone
/// metric (DSR > 0.95) applied to the accumulating paper record. Distinct from the strategy backtest's
/// HISTORICAL DSR: this is genuinely forward (the bars that closed each trade did not exist when the
/// rules were frozen), so `trials: 1` (no selection-bias haircut) is honest ⇒ DSR == PSR. All fields
/// derive from the CLOSED paper trades' realized R (already net-of-cost). Labeled PAPER at any surface.
struct PaperForwardStats: Sendable, Equatable {
    let closed: Int
    let winRate: Double
    let avgR: Double
    let sharpe: Double                            // per-trade mean ÷ sample-stdev (matches the backtester)
    let deflated: StockSageDeflatedSharpe.Result  // psr/dsr on the FORWARD R-series
    let health: SystemHealth?
    /// dsr > 0.95 — the milestone bar, measured FORWARD/out-of-sample on paper (honest "unproven"
    /// until enough paper trades resolve).
    nonisolated var passesForwardBar: Bool { deflated.passes }
}

// MARK: - Persisted PAPER-trade store (separate from the real journal — never conflated)

@MainActor
final class StockSagePaperTradeStore: ObservableObject {
    static let shared = StockSagePaperTradeStore()

    @Published private(set) var trades: [TradeRecord] = []
    /// DISTINCT from the journal's "stocksage.journal.v1" — paper and real never share storage.
    private let key: String
    private let defaults: UserDefaults
    /// Master switch. The owner asked for paper trading, so it is ON by default; OFF ⇒ the store is
    /// never mutated by the refresh (byte-identical to no paper trading).
    var enabled = true

    /// `defaults`/`key` are injectable ONLY so tests can isolate storage in an ephemeral suite;
    /// production (`.shared`) uses `.standard` + the paper key, byte-identical to a fixed private init.
    init(defaults: UserDefaults = .standard, key: String = "stocksage.papertrades.v1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    var open: [TradeRecord] { trades.filter { $0.isOpen } }
    var closed: [TradeRecord] { trades.filter { !$0.isOpen } }

    // Reused analytics (labeled PAPER at the eventual UI) — the same honest machinery the real journal uses.
    var stats: JournalStats { StockSageJournal.stats(trades) }
    var edgeStats: JournalEdge { StockSageJournal.edge(trades) }
    var systemHealth: SystemHealth? { StockSageJournal.systemHealth(trades) }
    var rDistribution: RDistribution? { StockSageJournal.rDistribution(trades) }
    var expectancyCI: ExpectancyCI? { StockSageJournal.expectancyConfidence(trades) }
    var equityRisk: JournalRisk? { StockSageJournal.equityRisk(trades) }
    /// The FORWARD net-of-cost milestone read (DSR/PSR) on the paper record — the honest "is the engine
    /// actually good, going forward?" gauge. nil until ≥4 paper trades have closed.
    var forwardStats: PaperForwardStats? { StockSagePaperTrader.forwardStats(trades) }

    /// The BIAS-CORRECTED forward scoreboard — recomputed each scan from the scan's histories (needs
    /// current prices to mark still-open trades, so it is nil until a scan has run this session).
    @Published private(set) var scoreboard: PaperForwardScoreboard?

    /// Recompute the scoreboard from the latest per-symbol closes (the scan's histories). Called from
    /// `StockSageStore.updatePaperTrades` where those histories are in hand.
    func updateScoreboard(latestClose: [String: Double]) {
        scoreboard = StockSagePaperTrader.scoreboard(trades, latestClose: latestClose)
    }

    func hasOpen(symbol: String) -> Bool {
        trades.contains { $0.isOpen && $0.symbol.uppercased() == symbol.uppercased() }
    }

    func add(_ t: TradeRecord) { trades.insert(t, at: 0); save() }

    /// Replace an open trade with its closed version (matched by id) — the mark-to-market apply.
    func applyClose(_ closed: TradeRecord) {
        guard let i = trades.firstIndex(where: { $0.id == closed.id }) else { return }
        trades[i] = closed
        save()
    }

    /// MEM-01a: batch counterpart to calling `applyClose` then `add` in a loop, one per element —
    /// each of those calls re-encodes the WHOLE (growing) `trades` array to UserDefaults, so a
    /// cycle with N closes + M opens paid N+M full-array encodes. This mutates `trades` once and
    /// saves once. End state is IDENTICAL to `for c in closes { applyClose(c) }; for o in opens
    /// { add(o) }`: closes replace in place by id (order-independent — distinct ids), opens are
    /// each `insert(at: 0)`, which — applied in loop order — ends up REVERSED at the front
    /// (opens = [o1,o2] inserted one at a time yields [o2,o1,...]); `opens.reversed()` replicates
    /// that in one `insert(contentsOf:at:)`. A no-op close (id not found — mirrors applyClose's
    /// own guard) is skipped rather than silently appended.
    func apply(closes: [TradeRecord], opens: [TradeRecord]) {
        guard !closes.isEmpty || !opens.isEmpty else { return }
        for c in closes {
            guard let i = trades.firstIndex(where: { $0.id == c.id }) else { continue }
            trades[i] = c
        }
        trades.insert(contentsOf: opens.reversed(), at: 0)
        save()
    }

    // Deletions are explicit user intent — they BYPASS the reconciling save below (a merged
    // save would resurrect the removed record from disk). ponytail: no tombstones — a
    // CONCURRENT process's next merged save can still resurrect a removed trade; add
    // tombstoned ids if removal-under-concurrency ever matters.
    func remove(_ id: UUID) { trades.removeAll { $0.id == id }; save(reconciling: false) }
    /// Owner "clear paper history" — wipes the paper record only (the real journal is untouched).
    func reset() { trades = []; save(reconciling: false) }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TradeRecord].self, from: data) else { return }
        trades = decoded
    }

    /// LOST-UPDATE FIX (2026-07-09 — found from LIVE data, not review: GE/SAN.MC/O39.SI each
    /// carried TWO open trades while the store held ZERO closes. Impossible in one process —
    /// step() only re-opens a symbol after a close — so a SECOND app instance (the owner's app
    /// and QA launches share this Mac) had clobbered the whole-array key with its stale
    /// in-memory copy, resurrecting closed trades as open and losing the closes forever.
    /// Reconcile with the on-disk truth before writing:
    ///   • per id, a CLOSED record beats an open one (a close is terminal — markToMarket only
    ///     ever moves open→closed, and `isOpen` is computed from `closedAt`);
    ///   • ids this process has never seen (another process's opens) are preserved, appended.
    /// Deletions pass `reconciling: false` (see remove/reset).
    private func save(reconciling: Bool = true) {
        if reconciling,
           let data = defaults.data(forKey: key),
           let disk = try? JSONDecoder().decode([TradeRecord].self, from: data) {
            var mineIds = Set(trades.map(\.id))
            for d in disk {
                if let i = trades.firstIndex(where: { $0.id == d.id }) {
                    if trades[i].isOpen && !d.isOpen { trades[i] = d }   // disk close wins
                } else if !mineIds.contains(d.id) {
                    trades.append(d)                                     // foreign trade — never drop
                    mineIds.insert(d.id)
                }
            }
        }
        if let data = try? JSONEncoder().encode(trades) {
            defaults.set(data, forKey: key)
        }
    }
}
