import Foundation
import Combine

// MARK: - Trade journal (records the OWNER's decisions; not advice)
//
// The backtester answers "would the rules have worked?"; the journal answers
// "what did I actually do, and how is it going?" Each record is a trade the owner
// chose to take — entry, protective stop, optional target, size — with an optional
// close. P&L and R-multiple are computed PURELY off those numbers so the math is
// testable and honest: R = profit ÷ the risk you defined at entry (entry→stop).

struct TradeRecord: Codable, Sendable, Equatable, Identifiable {
    enum Side: String, Codable, Sendable, CaseIterable {
        case long = "Long"
        case short = "Short"
    }
    let id: UUID
    let symbol: String
    let side: Side
    let entry: Double
    let stop: Double
    let target: Double?
    let shares: Double
    let openedAt: Date
    var exitPrice: Double?
    var closedAt: Date?
    /// Optional free-text note. Optional + defaulted so older persisted records
    /// (encoded before this field existed) still decode cleanly.
    var note: String?
    /// The advisor's conviction (0–1) at entry, when this trade came from an idea. Optional +
    /// defaulted (old records decode as nil). Lets the OWNER's realized win-rate-by-conviction
    /// calibrate EV/sizing — their own executions (fills, slippage, discipline), not just the
    /// sample backtest. Manual trades without a conviction are simply excluded from the fit.
    var conviction: Double?
    /// The price the plan quoted when the owner decided to ENTER — for measuring real execution
    /// cost against the plan. Optional + defaulted (old records decode as nil); never a P&L input.
    let plannedEntry: Double?
    /// The actual entry fill. Optional + defaulted; never a P&L input.
    let entryFill: Double?
    /// The price quoted when the owner decided to EXIT (set at close time). Optional + defaulted.
    var plannedExit: Double?
    /// The actual exit fill (set at close time). Optional + defaulted.
    var exitFill: Double?

    init(id: UUID = UUID(), symbol: String, side: Side, entry: Double, stop: Double,
         target: Double?, shares: Double, openedAt: Date,
         exitPrice: Double? = nil, closedAt: Date? = nil, note: String? = nil, conviction: Double? = nil,
         plannedEntry: Double? = nil, entryFill: Double? = nil, plannedExit: Double? = nil, exitFill: Double? = nil) {
        self.id = id; self.symbol = symbol; self.side = side
        self.entry = entry; self.stop = stop; self.target = target
        self.shares = shares; self.openedAt = openedAt
        self.exitPrice = exitPrice; self.closedAt = closedAt; self.note = note; self.conviction = conviction
        self.plannedEntry = plannedEntry; self.entryFill = entryFill
        self.plannedExit = plannedExit; self.exitFill = exitFill
    }

    nonisolated var isOpen: Bool { closedAt == nil }

    /// Cost-positive, direction-adjusted slippage in bps of the planned price for one execution
    /// leg. Positive = you paid more than planned (a buy filled higher, or a sell filled lower);
    /// negative = price improvement. nil (never fabricated) unless both prices are positive finite.
    nonisolated static func legSlippageBps(planned: Double, fill: Double, isBuy: Bool) -> Double? {
        guard planned > 0, fill > 0, planned.isFinite, fill.isFinite else { return nil }
        return ((isBuy ? fill - planned : planned - fill) / planned) * 10_000
    }

    /// Entry-leg slippage — nil unless BOTH plannedEntry and entryFill are set. A long enters via
    /// a BUY; a short enters via a SELL.
    nonisolated var entrySlippageBps: Double? {
        guard let p = plannedEntry, let f = entryFill else { return nil }
        return Self.legSlippageBps(planned: p, fill: f, isBuy: side == .long)
    }

    /// Exit-leg slippage — nil unless BOTH plannedExit and exitFill are set AND the trade is
    /// closed. A long exits via a SELL; a short exits via a BUY.
    nonisolated var exitSlippageBps: Double? {
        guard !isOpen, let p = plannedExit, let f = exitFill else { return nil }
        return Self.legSlippageBps(planned: p, fill: f, isBuy: side == .short)
    }

    /// Risk per share defined at entry (entry→stop distance).
    nonisolated var riskPerShare: Double { abs(entry - stop) }

    /// P&L at a given mark price (sign respects side).
    nonisolated func profit(at price: Double) -> Double {
        side == .long ? (price - entry) * shares : (entry - price) * shares
    }

    /// R-multiple at a mark price = profit-per-share ÷ risk-per-share. nil if the
    /// stop equals entry (no defined risk → R is undefined, not infinite).
    nonisolated func rMultiple(at price: Double) -> Double? {
        let risk = riskPerShare
        guard risk > 0 else { return nil }
        let perShare = side == .long ? (price - entry) : (entry - price)
        return perShare / risk
    }

    nonisolated var realizedProfit: Double? { exitPrice.map { profit(at: $0) } }
    nonisolated var realizedR: Double? { exitPrice.flatMap { rMultiple(at: $0) } }

    /// Whole calendar days held — to `closedAt` if closed, else to `now`. Never negative.
    nonisolated func daysHeld(asOf now: Date) -> Int {
        Swift.max(0, Int(((closedAt ?? now).timeIntervalSince(openedAt) / 86_400).rounded(.down)))
    }
}

/// Aggregate stats over the CLOSED trades — the owner's realized track record.
struct JournalStats: Sendable, Equatable {
    let closed: Int
    let wins: Int
    let winRate: Double
    let totalR: Double
    let totalProfit: Double
    let avgR: Double
    /// First-real-trade review (2026-07-16): `totalProfit` is a RAW sum of each closed trade's
    /// `realizedProfit`, and profit is in the symbol's NATIVE quote currency (SAR for .SR, pence
    /// for .L) — so a mixed-currency book sums SAR + USD at 1:1, a meaningless number the honesty
    /// floor forbids presenting. This is the single ISO currency code when EVERY closed trade
    /// shares one (→ the sum is valid and labelable), else nil = MIXED (the display must refuse to
    /// show it as one figure). A USD-only book (the whole NASDAQ half) gets "USD" ⇒ byte-identical
    /// bare rendering. Uses conversionCurrencyForSymbol (the denomination leg — the currency the
    /// profit is actually in).
    let profitCurrency: String?
    /// A representative closed-trade symbol for the single-currency case (nil when mixed/empty) —
    /// lets the display render `totalProfit` through `StockSageCurrency.signedAmount`, which
    /// applies the pence ÷100 major-unit normalization a bare currency code can't (an all-.L book
    /// sums PENCE, so "+4000 GBP" must render as "+40.00 GBP"). Any contributing trade's symbol
    /// works since the book is one currency; the first (sorted, deterministic) is used.
    let profitSymbol: String?
}

/// The EDGE decomposition over closed trades — why the expectancy is what it is.
struct JournalEdge: Sendable, Equatable {
    let avgWinR: Double        // average R of winning trades (R > 0)
    let avgLossR: Double       // average R of losing trades, as a POSITIVE magnitude
    let payoffRatio: Double    // avgWinR ÷ avgLossR (0 if no losses yet)
    let expectancyR: Double    // R you make per trade on average (= mean realized R)
    let closedWithR: Int       // closed trades with a defined R
    let profitFactor: Double?  // Σ winning R ÷ Σ |losing R|; nil with no losses yet
}

/// The shape of realized R outcomes across ordered bins.
struct RDistribution: Sendable, Equatable {
    struct Bin: Sendable, Equatable, Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }
    let bins: [Bin]    // ordered: ≤−1, −1..0, 0..1, 1..2, >2
    let total: Int
    /// 3rd standardized moment of the realized-R sample. Negative = LEFT-tailed (rare big
    /// losses — fragile); positive = RIGHT-tailed (rare big wins — robust). 0 for a
    /// symmetric or degenerate (zero-variance) sample.
    let skewness: Double
    /// 4th standardized moment, RAW (not excess) — a normal distribution's raw kurtosis is 3.
    /// >3 = fat-tailed (more extreme outcomes than normal); <3 = thin-tailed. 3 for a
    /// degenerate (zero-variance) sample (neutral — no shape to read).
    let kurtosis: Double

    nonisolated var shapeNote: String {
        if skewness < -0.2 { return "Left-skewed — rare big losses (fragile edge)." }
        if skewness > 0.2 { return "Right-skewed — rare big wins (robust edge)." }
        return "Roughly symmetric R outcomes."
    }
}

/// Realized performance split by trade side (long vs short).
struct SidePnL: Sendable, Equatable, Identifiable {
    let side: TradeRecord.Side
    let trades: Int
    let wins: Int
    let totalR: Double
    let avgR: Double
    let winRate: Double
    var closedWithR: Int = 0   // trades with a DEFINED R — the real sample size avgR/totalR average over
    var id: String { side.rawValue }
}

/// Realized R for one calendar month (closed trades).
struct MonthlyPnL: Sendable, Equatable, Identifiable {
    let month: String   // "YYYY-MM" (UTC)
    let trades: Int
    let totalR: Double
    var id: String { month }
}

/// Realized performance for one calendar year (closed trades) — for record-keeping.
struct YearlyPnL: Sendable, Equatable, Identifiable {
    let year: String            // "YYYY" (UTC)
    let trades: Int
    let wins: Int
    let winRate: Double         // 0–1
    let realizedDollars: Double // RAW sum of realized P&L in each trade's NATIVE currency — a
                                // valid single figure ONLY when profitSymbol != nil (see below)
    let totalR: Double
    /// First-real-trade review (2026-07-16): `realizedDollars` sums native-currency profit, so a
    /// year mixing `.SR` (SAR) and NASDAQ (USD) trades is a meaningless 1:1 sum. Representative
    /// closed-trade symbol when the YEAR's contributing trades are one currency (→ the display
    /// renders it via `signedAmount`, pence-aware; USD byte-identical), nil = MIXED (the row shows
    /// "mixed" not a fabricated number). Same rule as `JournalStats.profitSymbol`.
    let profitSymbol: String?
    var id: String { year }
}

/// Realized performance for one sector (closed trades).
struct SectorPnL: Sendable, Equatable, Identifiable {
    let sector: String
    let trades: Int
    let wins: Int
    let totalR: Double
    let winRate: Double
    var closedWithR: Int = 0   // trades with a DEFINED R — the real sample size totalR averages over
    var id: String { sector }
}

/// Honesty gate for per-bucket attribution (by-side / by-sector / by-setup): a bucket with too
/// few closed trades is mostly luck, so the UI can show "too few to tell" instead of a win% that
/// reads like an edge. Same min-n discipline systemHealth (n≥20) and kellyInputs (n≥10) already use.
struct BucketReliability: Sendable, Equatable {
    let n: Int
    let minN: Int
    nonisolated var isReliable: Bool { n >= minN }
    nonisolated var tooFewLabel: String { "too few to tell (n=\(n), need \(minN))" }
}

/// A live "what to do RIGHT NOW" verdict for one OPEN trade, from its current mark price. The
/// journal otherwise only does post-mortem analytics — this is the only surface that acts on a
/// position while it is still open. Advisory only: the app places no orders.
struct OpenAction: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable { case stopHit = "STOP HIT", targetHit = "TARGET HIT",
                                       nearStop = "Near stop", inProfit = "In profit", holding = "Holding" }
    let symbol: String
    let kind: Kind
    let detail: String
    let rNow: Double?      // current R-multiple at the mark (nil if entry == stop)
    var id: String { symbol }
    /// Stop/target hit → the owner must act now.
    nonisolated var isUrgent: Bool { kind == .stopHit || kind == .targetHit }
}

/// Best/worst closed trade + the current consecutive win-or-loss streak.
struct JournalStreak: Sendable, Equatable {
    let bestR: Double
    let bestSymbol: String
    let worstR: Double
    let worstSymbol: String
    let streakCount: Int     // consecutive most-recent same-result trades (0 if none decisive)
    let streakIsWin: Bool    // true = winning streak
}

/// The expectancy with its sampling error — so a thin record reads as noise.
struct ExpectancyCI: Sendable, Equatable {
    let expectancyR: Double   // mean realized R
    let stdErrR: Double       // sample stdev ÷ √n
    let n: Int
    /// Distinguishable from zero only when the mean is ≥1 standard error away.
    /// NOTE: a 1σ bar (~p 0.32 at the boundary), NOT the 2σ confirmation standard the
    /// panel's "≈N more trades" line names — surfaces must say "1σ", never "significant".
    /// Degenerate guard (review fix 2026-07-16): stdErr == 0 (e.g. two identical
    /// scratch trades) made 0 ≥ 0 read as distinguishable-from-zero; a zero mean
    /// never is. With zero spread, distinguishable ⇔ the mean itself is nonzero.
    nonisolated var isSignificant: Bool {
        stdErrR > 0 ? abs(expectancyR) >= stdErrR : abs(expectancyR) > 0
    }

    nonisolated var note: String {
        let tail = isSignificant ? "" : " — not yet distinguishable from zero (thin/noisy sample)"
        return String(format: "Expectancy %+.2fR ± %.2fR (n=%d)%@", expectancyR, stdErrR, n, tail)
    }
}

/// Average days held for winners vs losers — the "cut winners early / ride losers" check.
struct HoldingPeriod: Sendable, Equatable {
    let avgWinDays: Double
    let avgLossDays: Double
    let winCount: Int
    let lossCount: Int

    /// The classic discipline leak: holding winners SHORTER than losers.
    nonisolated var ridingLosers: Bool { winCount > 0 && lossCount > 0 && avgWinDays < avgLossDays }

    nonisolated var note: String {
        // Review fix 2026-07-16: an empty bucket rendered its sentinel 0 as a measured
        // "winners 0d" average — a side with no trades reads "—", never a fake figure.
        let winStr = winCount > 0 ? String(format: "%.0fd", avgWinDays) : "—"
        let lossStr = lossCount > 0 ? String(format: "%.0fd", avgLossDays) : "—"
        let base = "Avg hold: winners \(winStr) vs non-winners \(lossStr)"
        guard winCount > 0, lossCount > 0 else { return base + "." }
        if avgWinDays < avgLossDays { return base + " — you cut winners early / ride non-winners." }
        if avgWinDays > avgLossDays { return base + " — you give winners room and cut non-winners fast." }
        return base + "."
    }
}

/// The owner's realized equity-curve risk: worst losing run + deepest drawdown.
struct JournalRisk: Sendable, Equatable {
    let maxConsecutiveLosses: Int
    let maxDrawdownR: Double   // worst peak→trough of cumulative R (positive magnitude)
}

/// The owner's REALIZED execution cost, measured from their own logged fills — vs. the
/// asset-class ASSUMED cost the engine's cost table uses for the same legs. Display only: see
/// the fence on `StockSageJournal.measuredSlippage`.
struct MeasuredSlippage: Sendable, Equatable {
    let medianBps: Double               // median SIGNED bps/leg over the owner's fills (negative = price improvement)
    let assumedMedianBpsPerLeg: Double   // median of defaultCosts(symbol).roundTripBps/2 over the SAME legs — apples-to-apples
    let legs: Int
    let minLegs: Int                    // 5
    nonisolated var meetsFloor: Bool { legs >= minLegs }
}

/// An honest one-glance verdict on the journal's realized track record.
struct SystemHealth: Sendable, Equatable {
    enum Verdict: String, Sendable {
        case negative = "Negative"      // losing
        case unproven = "Unproven"      // too few / not significant
        case developing = "Developing"  // real but not yet robust
        case strong = "Strong"          // significant + healthy PF + contained DD
    }
    let verdict: Verdict
    let reason: String
}

/// Is the edge improving or fading? Recent-half mean R vs first-half mean R.
struct ExpectancyTrend: Sendable, Equatable {
    enum Direction: String, Sendable {
        case improving = "improving"
        case fading = "fading"
        case flat = "flat"
    }
    let earlyR: Double      // mean R of the FIRST half (by close time)
    let recentR: Double     // mean R of the most-recent half
    let direction: Direction
    nonisolated var delta: Double { recentR - earlyR }
}

/// A HYPOTHETICAL forward projection of account growth from the measured edge.
struct GrowthProjection: Sendable, Equatable {
    let expectancyR: Double   // measured mean R per closed trade
    let fraction: Double      // risk per trade
    let trades: Int           // future trades modeled
    let multiple: Double      // ×(1 + fraction·expectancyR)^trades
}

/// The account-growth multiple your logged R produced, compounded at a fixed risk %.
struct CompoundingCurve: Sendable, Equatable {
    let multiples: [Double]   // running growth multiple after each closed trade
    let fraction: Double      // risk per trade (e.g. 0.01 = 1%)
    nonisolated var finalMultiple: Double { multiples.last ?? 1 }
    /// The curve clamps at 0 (ruin is absorbing) — a flat line AT 0 means wiped out on
    /// this or an earlier trade, not merely "stuck". Distinguish that from a genuine ×0
    /// nonexistent case (multiples is never empty when this type exists) in the UI.
    nonisolated var isRuined: Bool { finalMultiple == 0 }
}

enum StockSageJournal {
    /// Compounding curve: starting at ×1, each closed trade (by close time) multiplies
    /// the account by (1 + fraction·R). Clamped at 0 (ruin is absorbing). Pure — this
    /// is the PAST path of the owner's OWN trades at a fixed risk %, NOT a projection.
    nonisolated static func compoundingCurve(_ trades: [TradeRecord], fraction: Double = 0.01) -> CompoundingCurve? {
        let rs = trades.filter { !$0.isOpen }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            .compactMap { $0.realizedR }
        guard !rs.isEmpty else { return nil }
        var mult = 1.0
        var out: [Double] = []
        out.reserveCapacity(rs.count)
        for r in rs {
            mult = Swift.max(0, mult * (1 + fraction * r))
            out.append(mult)
        }
        return CompoundingCurve(multiples: out, fraction: fraction)
    }

    /// Realized P&L rolled up by calendar year (UTC) — $ + R + win-rate + count, newest
    /// first. Closed trades only. For the owner's own record-keeping; NOT tax advice.
    nonisolated static func yearlyPnL(_ trades: [TradeRecord]) -> [YearlyPnL] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var byYear: [String: [TradeRecord]] = [:]
        for t in trades where !t.isOpen {
            guard let c = t.closedAt else { continue }
            byYear[String(cal.component(.year, from: c)), default: []].append(t)
        }
        return byYear.map { year, ts in
            let wins = ts.filter { ($0.realizedProfit ?? 0) > 0 }.count
            // Single currency this year's realizedDollars is in, or nil when the year mixes
            // currencies (the raw sum is then meaningless); representative = sorted-first symbol.
            let contributing = ts.filter { $0.realizedProfit != nil }
            let currencies = Set(contributing.map { StockSageCurrency.conversionCurrencyForSymbol($0.symbol) })
            return YearlyPnL(year: year, trades: ts.count, wins: wins,
                             winRate: ts.isEmpty ? 0 : Double(wins) / Double(ts.count),
                             realizedDollars: ts.compactMap(\.realizedProfit).reduce(0, +),
                             totalR: ts.compactMap(\.realizedR).reduce(0, +),
                             profitSymbol: currencies.count == 1 ? contributing.map(\.symbol).sorted().first : nil)
        }.sorted { $0.year > $1.year }
    }

    /// A HYPOTHETICAL forward account multiple: compound the measured expectancy (R/trade)
    /// over `trades` future trades at risk `fraction` — ×(1 + fraction·expectancyR)^trades.
    /// nil for non-positive trades/fraction or a wipeout step (1 + f·e ≤ 0). This is NOT a
    /// prediction — it assumes the past edge persists and ignores variance (which lowers it).
    nonisolated static func projectGrowth(expectancyR: Double, trades: Int, fraction: Double = 0.01) -> GrowthProjection? {
        let step = 1 + fraction * expectancyR
        guard trades > 0, fraction > 0, step > 0 else { return nil }
        return GrowthProjection(expectancyR: expectancyR, fraction: fraction, trades: trades,
                                multiple: pow(step, Double(trades)))
    }

    /// Expectancy trend: mean R of the first half vs the most-recent half of closed
    /// trades (by close time). `band` = the flat zone. nil under 6 closed-with-R.
    nonisolated static func expectancyTrend(_ trades: [TradeRecord], band: Double = 0.10) -> ExpectancyTrend? {
        let rs = trades.filter { !$0.isOpen }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            .compactMap { $0.realizedR }
        guard rs.count >= 6 else { return nil }
        let half = rs.count / 2
        let early = Array(rs.prefix(half))
        let recent = Array(rs.suffix(rs.count - half))
        let earlyR = early.reduce(0, +) / Double(early.count)
        let recentR = recent.reduce(0, +) / Double(recent.count)
        let delta = recentR - earlyR
        let dir: ExpectancyTrend.Direction = delta > band ? .improving : (delta < -band ? .fading : .flat)
        return ExpectancyTrend(earlyR: earlyR, recentR: recentR, direction: dir)
    }

    /// Classify track-record health from the already-computed stats. Pure decision
    /// table so the thresholds are unit-tested in isolation. `deepDrawdownR` = the
    /// peak→trough R that downgrades an otherwise-strong system.
    nonisolated static func classifyHealth(profitFactor: Double?, expectancyR: Double, significant: Bool,
                                           n: Int, maxDrawdownR: Double,
                                           minTrades: Int = 20, deepDrawdownR: Double = 8) -> SystemHealth {
        let pfStr = profitFactor.map { String(format: "%.2f", $0) } ?? "∞"
        let ddStr = String(format: "%.1f", maxDrawdownR)
        let expStr = String(format: "%+.2f", expectancyR)

        if expectancyR < 0 || (profitFactor.map { $0 < 1 } ?? false) {
            return SystemHealth(verdict: .negative,
                                reason: "Losing so far (PF \(pfStr), expectancy \(expStr)R). Cut size or stand down.")
        }
        // Wording (review fix 2026-07-16): the `significant` input is ExpectancyCI's 1σ
        // bar — calling that "Significant edge" over-claimed against the panel's own 2σ
        // confirmation standard ("≈N more trades to confirm at 2σ"). Same thresholds,
        // honest names: say "1σ", never bare "significant".
        if n < minTrades || !significant {
            return SystemHealth(verdict: .unproven,
                                reason: "Too little to trust (n=\(n)\(significant ? "" : ", mean <1σ from zero")). Keep logging before sizing up.")
        }
        let pfStrong = profitFactor.map { $0 >= 1.5 } ?? true   // no losses ⇒ effectively ∞
        if pfStrong && maxDrawdownR < deepDrawdownR {
            return SystemHealth(verdict: .strong,
                                reason: "Edge ≥1σ above zero (not yet 2σ-confirmed) — PF \(pfStr), expectancy \(expStr)R over \(n), worst DD −\(ddStr)R.")
        }
        return SystemHealth(verdict: .developing,
                            reason: maxDrawdownR >= deepDrawdownR
                                ? "Real edge but a deep −\(ddStr)R drawdown (PF \(pfStr), n=\(n)) — robust? not proven."
                                : "Real but thin edge (PF \(pfStr), ≥1σ, n=\(n)) — promising, keep building.")
    }

    /// System health over the journal's closed trades. nil with no closed-with-R.
    nonisolated static func systemHealth(_ trades: [TradeRecord], minTrades: Int = 20) -> SystemHealth? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard !rs.isEmpty else { return nil }
        let e = edge(trades)
        return classifyHealth(profitFactor: e.profitFactor, expectancyR: e.expectancyR,
                              significant: expectancyConfidence(trades)?.isSignificant ?? false,
                              n: rs.count, maxDrawdownR: equityRisk(trades)?.maxDrawdownR ?? 0,
                              minTrades: minTrades)
    }

    /// Kelly inputs (win-rate, payoff) from the OWNER's own closed trades. Requires
    /// a meaningful sample (≥`minTrades`) AND at least one win and one loss to form
    /// an honest payoff. nil otherwise — never size off 3 lucky trades.
    nonisolated static func kellyInputs(_ trades: [TradeRecord], minTrades: Int = 10)
        -> (winRate: Double, payoffRatio: Double, n: Int)? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard rs.count >= minTrades else { return nil }
        let wins = rs.filter { $0 > 0 }
        let losses = rs.filter { $0 < 0 }
        guard !wins.isEmpty, !losses.isEmpty else { return nil }
        let winRate = Double(wins.count) / Double(rs.count)
        let avgWin = wins.reduce(0, +) / Double(wins.count)
        let avgLossMag = -losses.reduce(0, +) / Double(losses.count)
        guard let inp = StockSageKelly.inputs(winRate: winRate, avgWinR: avgWin, avgLossR: avgLossMag) else { return nil }
        return (inp.winRate, inp.payoffRatio, rs.count)
    }

    /// Worst consecutive losing run and max drawdown (in R) over CLOSED trades
    /// ordered by close time — the same drawdown math the backtester uses, applied
    /// to the OWNER's own record. nil with no closed-with-R trades.
    nonisolated static func equityRisk(_ trades: [TradeRecord]) -> JournalRisk? {
        let ordered = trades.filter { !$0.isOpen }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        let rs = ordered.compactMap { $0.realizedR }
        guard !rs.isEmpty else { return nil }

        var maxRun = 0, run = 0
        for r in rs {
            if r < 0 { run += 1; maxRun = Swift.max(maxRun, run) } else { run = 0 }
        }
        var cum = 0.0, peak = 0.0, maxDD = 0.0
        for r in rs { cum += r; peak = Swift.max(peak, cum); maxDD = Swift.max(maxDD, peak - cum) }
        return JournalRisk(maxConsecutiveLosses: maxRun, maxDrawdownR: maxDD)
    }

    /// Average holding period (days) for winning vs losing closed trades. nil with
    /// no closed trades that carry both open/close timestamps.
    nonisolated static func holdingPeriod(_ trades: [TradeRecord]) -> HoldingPeriod? {
        func days(_ t: TradeRecord) -> Double? {
            // A closedAt before openedAt (backdated close, import mistake, manual edit) is bad
            // data, not a real negative holding period — exclude it rather than let it drag the
            // averages negative, matching TradeRecord.daysHeld's own "never negative" convention.
            guard let c = t.closedAt else { return nil }
            let interval = c.timeIntervalSince(t.openedAt) / 86_400
            return interval >= 0 ? interval : nil
        }
        let closed = trades.filter { !$0.isOpen }
        // Wins are strictly profitable; a BREAKEVEN (scratch, profit==0) is a NON-winner,
        // not a loser — fold it into the non-win bucket (<= 0) so it isn't silently dropped
        // from the averages/counts (which would bias the discipline read by an invisible sample).
        let wins = closed.filter { ($0.realizedProfit ?? 0) > 0 }.compactMap(days)
        let losses = closed.filter { ($0.realizedProfit ?? 0) <= 0 }.compactMap(days)
        guard !wins.isEmpty || !losses.isEmpty else { return nil }
        return HoldingPeriod(
            avgWinDays: wins.isEmpty ? 0 : wins.reduce(0, +) / Double(wins.count),
            avgLossDays: losses.isEmpty ? 0 : losses.reduce(0, +) / Double(losses.count),
            winCount: wins.count, lossCount: losses.count)
    }

    /// Realized-R outcomes bucketed into 5 ordered bins so the SHAPE of results is
    /// visible, not just the average. Boundaries (each trade in exactly one bin):
    /// (−∞,−1] · (−1,0] · (0,1] · (1,2] · (2,∞) — lower-exclusive, upper-inclusive.
    nonisolated static func rDistribution(_ trades: [TradeRecord]) -> RDistribution? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard !rs.isEmpty else { return nil }
        var counts = [0, 0, 0, 0, 0]
        for r in rs {
            if r <= -1 { counts[0] += 1 }
            else if r <= 0 { counts[1] += 1 }
            else if r <= 1 { counts[2] += 1 }
            else if r <= 2 { counts[3] += 1 }
            else { counts[4] += 1 }
        }
        let labels = ["≤−1R", "−1..0R", "0..1R", "1..2R", ">2R"]
        // Population moments (matches StockSageReturnShape's convention) — skew/kurtosis
        // describe the SAMPLE'S shape, not an inferential estimate of a population.
        let n = Double(rs.count)
        let mean = rs.reduce(0, +) / n
        let variance = rs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sd = variance.squareRoot()
        let skewness: Double
        let kurtosis: Double
        if sd > 0 {
            skewness = rs.reduce(0) { $0 + pow(($1 - mean) / sd, 3) } / n
            kurtosis = rs.reduce(0) { $0 + pow(($1 - mean) / sd, 4) } / n
        } else {
            skewness = 0   // no variance → no shape to read, not "perfectly symmetric" by inference
            kurtosis = 3   // normal distribution's raw kurtosis — the neutral baseline
        }
        return RDistribution(bins: zip(labels, counts).map { RDistribution.Bin(label: $0, count: $1) },
                             total: rs.count, skewness: skewness, kurtosis: kurtosis)
    }

    /// How many TOTAL and how many MORE trades to reach |mean R| ≥ z·stderr (z=2 ≈
    /// 95%): N ≥ (z·s/|mean|)². nil when the mean is ~0 (a zero edge never confirms)
    /// or <2 trades. A sample-size estimate, not a promise the edge survives.
    nonisolated static func tradesToSignificance(_ trades: [TradeRecord], z: Double = 2) -> (needed: Int, more: Int)? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard rs.count >= 2 else { return nil }
        let n = rs.count
        let mean = rs.reduce(0, +) / Double(n)
        guard abs(mean) > 1e-9 else { return nil }
        let variance = rs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
        let s = variance.squareRoot()
        guard s > 0 else { return (needed: n, more: 0) }   // no spread → already certain
        let ratio = z * s / abs(mean)
        let raw = (ratio * ratio).rounded(.up)
        // A near-zero mean with a wide spread (e.g. one huge winner, one huge loser) can blow
        // `raw` past Int.max, which traps on conversion — treat "needs an astronomical sample"
        // the same as the existing "never confirms" nil case rather than crashing.
        guard raw.isFinite, raw < Double(Int.max) else { return nil }
        let needed = Int(raw)
        return (needed: needed, more: Swift.max(0, needed - n))
    }

    /// Mean realized R with its standard error (sampleStdev/√n). nil for <2 trades
    /// with a defined R (no spread to estimate).
    nonisolated static func expectancyConfidence(_ trades: [TradeRecord]) -> ExpectancyCI? {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        guard rs.count >= 2 else { return nil }
        let n = rs.count
        let mean = rs.reduce(0, +) / Double(n)
        let variance = rs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)   // sample variance
        let stdErr = variance.squareRoot() / Double(n).squareRoot()
        return ExpectancyCI(expectancyR: mean, stdErrR: stdErr, n: n)
    }

    /// Best/worst realized trade and the current streak (by close time). Breakeven
    /// (R == 0) trades don't count toward the streak. nil with no closed-with-R trades.
    nonisolated static func streak(_ trades: [TradeRecord]) -> JournalStreak? {
        let closed = trades.filter { !$0.isOpen }.compactMap { t in t.realizedR.map { (t, $0) } }
        guard !closed.isEmpty else { return nil }
        let best = closed.max { $0.1 < $1.1 }!
        let worst = closed.min { $0.1 < $1.1 }!

        let ordered = closed.sorted { ($0.0.closedAt ?? .distantPast) < ($1.0.closedAt ?? .distantPast) }
        let decisive = ordered.filter { $0.1 != 0 }
        var count = 0
        var isWin = false
        if let last = decisive.last {
            isWin = last.1 > 0
            for (_, r) in decisive.reversed() {
                if (r > 0) != isWin { break }
                count += 1
            }
        }
        return JournalStreak(bestR: best.1, bestSymbol: best.0.symbol,
                             worstR: worst.1, worstSymbol: worst.0.symbol,
                             streakCount: count, streakIsWin: isWin)
    }

    nonisolated static func stats(_ trades: [TradeRecord]) -> JournalStats {
        let closed = trades.filter { !$0.isOpen }
        let rs = closed.compactMap { $0.realizedR }
        let profits = closed.compactMap { $0.realizedProfit }
        let wins = profits.filter { $0 > 0 }.count
        let totalR = rs.reduce(0, +)
        // The single currency `totalProfit` is denominated in, or nil when the closed book mixes
        // currencies (the raw sum is then meaningless — the display must not present it as one
        // number). Keyed off the trades that actually contributed a realizedProfit; the
        // representative symbol (first, sorted → deterministic) lets the display apply pence ÷100.
        let contributing = closed.filter { $0.realizedProfit != nil }
        let currencies = Set(contributing.map { StockSageCurrency.conversionCurrencyForSymbol($0.symbol) })
        let single = currencies.count == 1
        return JournalStats(
            closed: closed.count,
            wins: wins,
            winRate: closed.isEmpty ? 0 : Double(wins) / Double(closed.count),
            totalR: totalR,
            totalProfit: profits.reduce(0, +),
            avgR: rs.isEmpty ? 0 : totalR / Double(rs.count),
            profitCurrency: single ? currencies.first : nil,
            profitSymbol: single ? contributing.map(\.symbol).sorted().first : nil)
    }

    /// Edge decomposition: average win R, average loss R, payoff ratio, and the
    /// per-trade expectancy (winRate·avgWin − lossRate·avgLoss == mean realized R).
    nonisolated static func edge(_ trades: [TradeRecord]) -> JournalEdge {
        let rs = trades.filter { !$0.isOpen }.compactMap { $0.realizedR }
        let wins = rs.filter { $0 > 0 }
        let losses = rs.filter { $0 < 0 }
        let avgWin = wins.isEmpty ? 0 : wins.reduce(0, +) / Double(wins.count)
        let avgLossMag = losses.isEmpty ? 0 : -losses.reduce(0, +) / Double(losses.count)
        let grossWin = wins.reduce(0, +)
        let grossLoss = -losses.reduce(0, +)   // positive magnitude
        return JournalEdge(
            avgWinR: avgWin,
            avgLossR: avgLossMag,
            payoffRatio: avgLossMag > 0 ? avgWin / avgLossMag : 0,
            expectancyR: rs.isEmpty ? 0 : rs.reduce(0, +) / Double(rs.count),
            closedWithR: rs.count,
            profitFactor: grossLoss > 0 ? grossWin / grossLoss : nil)
    }

    /// Realized performance split LONG vs SHORT — are you actually good at shorting,
    /// or only making money long? Closed trades only; sides with no trades omitted.
    nonisolated static func bySide(_ trades: [TradeRecord]) -> [SidePnL] {
        let closed = trades.filter { !$0.isOpen }
        return TradeRecord.Side.allCases.compactMap { side in
            let ts = closed.filter { $0.side == side }
            guard !ts.isEmpty else { return nil }
            let rs = ts.compactMap { $0.realizedR }
            let wins = ts.filter { ($0.realizedProfit ?? 0) > 0 }.count
            return SidePnL(side: side, trades: ts.count, wins: wins,
                           totalR: rs.reduce(0, +),
                           avgR: rs.isEmpty ? 0 : rs.reduce(0, +) / Double(rs.count),
                           winRate: Double(wins) / Double(ts.count),
                           closedWithR: rs.count)
        }
    }

    /// Realized R grouped by close MONTH (UTC), most-recent first.
    nonisolated static func monthlyPnL(_ trades: [TradeRecord]) -> [MonthlyPnL] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var groups: [String: (count: Int, r: Double)] = [:]
        for t in trades where !t.isOpen {
            guard let closed = t.closedAt else { continue }
            let c = cal.dateComponents([.year, .month], from: closed)
            guard let y = c.year, let m = c.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            var g = groups[key] ?? (0, 0)
            // Review fix 2026-07-16: an R-undefined closed trade (entry==stop legacy)
            // was dropped from the month's COUNT while yearlyPnL and stats.closed count
            // it — the same trade showed in the year row and vanished from its month.
            // Convention now matches: every closed trade counts; only defined Rs sum.
            g.count += 1
            if let r = t.realizedR { g.r += r }
            groups[key] = g
        }
        return groups.map { MonthlyPnL(month: $0.key, trades: $0.value.count, totalR: $0.value.r) }
            .sorted { $0.month > $1.month }   // YYYY-MM string sort = chronological, newest first
    }

    /// Realized P&L grouped by the symbol's sector — which industries you actually
    /// make money in. Closed trades only, sorted by total R (best first).
    nonisolated static func bySector(_ trades: [TradeRecord]) -> [SectorPnL] {
        let closed = trades.filter { !$0.isOpen }
        var groups: [String: [TradeRecord]] = [:]
        for t in closed { groups[StockSageSector.sector(t.symbol), default: []].append(t) }
        return groups.map { sector, ts in
            let wins = ts.filter { ($0.realizedProfit ?? 0) > 0 }.count
            let rs = ts.compactMap { $0.realizedR }
            return SectorPnL(sector: sector, trades: ts.count, wins: wins, totalR: rs.reduce(0, +),
                             winRate: ts.isEmpty ? 0 : Double(wins) / Double(ts.count),
                             closedWithR: rs.count)
        }
        // Dictionary iteration order (the pre-sort array) is randomized per process launch —
        // a deterministic secondary key stops a tied ranking from flipping between app launches.
        .sorted { $0.totalR != $1.totalR ? $0.totalR > $1.totalR : $0.sector < $1.sector }
    }

    /// Is a bucket's win%/avgR worth believing, or small-sample noise? Applies the journal's
    /// existing min-n discipline to per-bucket attribution, which previously had none.
    nonisolated static func bucketReliability(closedWithR n: Int, minN: Int = 5) -> BucketReliability {
        BucketReliability(n: n, minN: minN)
    }
    nonisolated static func reliability(_ s: SectorPnL, minN: Int = 5) -> BucketReliability {
        BucketReliability(n: s.closedWithR, minN: minN)   // R-defined sample, not raw closed count
    }
    nonisolated static func reliability(_ s: SidePnL, minN: Int = 5) -> BucketReliability {
        BucketReliability(n: s.closedWithR, minN: minN)   // R-defined sample, not raw closed count
    }

    /// Live "act now" verdict per OPEN trade from a current mark price. Side-aware (a long stops
    /// BELOW / targets ABOVE; a short mirrors it), reusing the trade's own stop/target/R. Urgent
    /// (stop/target hit) sorts first, then by |R|. Closed trades and unpriced symbols are skipped.
    nonisolated static func openActions(_ trades: [TradeRecord], mark: (String) -> Double?) -> [OpenAction] {
        let acts = trades.compactMap { t -> OpenAction? in
            guard t.isOpen, let px = mark(t.symbol) else { return nil }
            let isLong = t.side == .long
            let rNow = t.rMultiple(at: px)
            // Stop hit — long: at/below the stop; short: at/above.
            if isLong ? px <= t.stop : px >= t.stop {
                return OpenAction(symbol: t.symbol, kind: .stopHit,
                                  detail: String(format: "%.2f at/through your %.2f stop — risk is realized; exit or re-confirm the thesis.", px, t.stop),
                                  rNow: rNow)
            }
            // Target hit — long: at/above the target; short: at/below.
            if let tgt = t.target, (isLong ? px >= tgt : px <= tgt) {
                return OpenAction(symbol: t.symbol, kind: .targetHit,
                                  detail: String(format: "%.2f reached your %.2f target — take profit or trail the stop.", px, tgt),
                                  rNow: rNow)
            }
            // Within the last 25% before the stop (−0.75R … −1R).
            if let r = rNow, r > -1, r <= -0.75 {
                return OpenAction(symbol: t.symbol, kind: .nearStop,
                                  detail: String(format: "%.2f is near your stop (now %+.2fR) — be ready to act.", px, r),
                                  rNow: r)
            }
            if let r = rNow, r > 0 {
                return OpenAction(symbol: t.symbol, kind: .inProfit,
                                  detail: String(format: "up %+.2fR — consider trailing the stop to lock it in.", r),
                                  rNow: r)
            }
            return OpenAction(symbol: t.symbol, kind: .holding, detail: "holding — no level crossed.", rNow: rNow)
        }
        return acts.sorted { a, b in
            if a.isUrgent != b.isUrgent { return a.isUrgent }
            return abs(a.rNow ?? 0) > abs(b.rNow ?? 0)
        }
    }

    /// Disclaimer for every per-bucket attribution row — descriptive of the past, not predictive.
    nonisolated static let attributionCaveat =
        "Per-bucket win%/R describes what already happened in your own log — it is not predictive. Small buckets are mostly luck."

    nonisolated static let caveat =
        "Your own trade record — not advice. P&L/R are computed from the prices you entered; a journal documents decisions, it doesn't validate them."

    /// "Your history with this name" — count of CLOSED trades for one symbol (case-insensitive
    /// match, same convention as StockSagePortfolio.holding) + summed realized R over the subset
    /// that has a defined R. `count` is every closed trade regardless of whether R is defined
    /// (a closed trade with no exit price, or entry==stop, must still be counted — dropping it
    /// from `count` via compactMap(realizedR) silently undercounts "your history with this
    /// name"). `rDefinedCount` <= `count`; when they differ, the caller's .help should disclose
    /// how many of the closed trades actually contributed to totalR. nil when there are zero
    /// closed trades on the symbol — display-only, nothing here feeds ranking/EV/sizing.
    nonisolated static func history(for symbol: String, in trades: [TradeRecord]) -> (count: Int, totalR: Double, rDefinedCount: Int)? {
        let sym = symbol.uppercased()
        let closed = trades.filter { !$0.isOpen && $0.symbol.uppercased() == sym }
        guard !closed.isEmpty else { return nil }
        let rs = closed.compactMap { $0.realizedR }
        let total = rs.reduce(0, +)
        // Defensive-only and unreachable via this reduce: reduce(0, +) over Doubles cannot
        // produce IEEE -0.0 from cancelling non-zero pairs (0.05 + -0.05 == +0.0, not -0.0;
        // -0.0 only arises from an explicit negation or a -1 multiply, neither of which happens
        // here). Kept anyway as a guard against a future refactor of the summation strategy —
        // own-it precedent (AggregatedHolding.unrealizedPct) hit the same -0.0 render bug via a
        // different code path, so the cost of keeping this branch is one line.
        return (count: closed.count, totalR: total == 0 ? 0 : total, rDefinedCount: rs.count)
    }

    /// Same result as `history(for:in:)`, for every symbol in `trades`, computed in one O(T) pass
    /// instead of O(T) per symbol — for callers (the ideas board) that need this per-card across
    /// many symbols each render. `history(for:in:)` stays the semantic source of truth (and the
    /// per-symbol call site everywhere else); this is a batch-lookup convenience keyed the same
    /// way (uppercased symbol), proven identical by StockSageJournalTests.historyBySymbolMatchesHistoryForEverySymbol.
    nonisolated static func historyBySymbol(in trades: [TradeRecord]) -> [String: (count: Int, totalR: Double, rDefinedCount: Int)] {
        var closedBySymbol: [String: [TradeRecord]] = [:]
        for t in trades where !t.isOpen {
            closedBySymbol[t.symbol.uppercased(), default: []].append(t)
        }
        return closedBySymbol.mapValues { closed in
            let rs = closed.compactMap { $0.realizedR }
            let total = rs.reduce(0, +)
            return (count: closed.count, totalR: total == 0 ? 0 : total, rDefinedCount: rs.count)
        }
    }

    /// Sorted-array median: odd → middle element, even → mean of the two middles. Private —
    /// `measuredSlippage` is the only caller.
    private nonisolated static func median(_ xs: [Double]) -> Double {
        let sorted = xs.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MEASURES AND DISPLAYS ONLY. Nothing here feeds NetEdge, the cost table, or any gate —
    // NetEdge/defaultCosts/trade-gate behavior is byte-identical. Feeding measured costs into the
    // gate is a future evidence-gated change.
    /// The owner's realized per-leg execution cost (entry + exit legs of CLOSED trades) vs. the
    /// asset-class ASSUMED cost for those same legs (half the round-trip table — one leg). nil
    /// with zero legs; `meetsFloor` (n >= minLegs, default 5) gates whether the UI trusts it.
    nonisolated static func measuredSlippage(_ trades: [TradeRecord], minLegs: Int = 5) -> MeasuredSlippage? {
        var measured: [Double] = []
        var assumed: [Double] = []
        for t in trades where !t.isOpen {
            let assumedPerLeg = StockSageNetEdge.defaultCosts(forSymbol: t.symbol).roundTripBps / 2
            if let s = t.entrySlippageBps { measured.append(s); assumed.append(assumedPerLeg) }
            if let s = t.exitSlippageBps { measured.append(s); assumed.append(assumedPerLeg) }
        }
        guard !measured.isEmpty else { return nil }
        return MeasuredSlippage(medianBps: median(measured), assumedMedianBpsPerLeg: median(assumed),
                                legs: measured.count, minLegs: minLegs)
    }
}

// MARK: - Persisted journal store

@MainActor
final class StockSageJournalStore: ObservableObject {
    static let shared = StockSageJournalStore()

    @Published private(set) var trades: [TradeRecord] = []
    private let key: String
    private let defaults: UserDefaults

    /// `defaults`/`key` injectable for the reconciliation tests ONLY (mirrors
    /// StockSagePaperTradeStore's seam) — production is always the `.shared` singleton on
    /// `.standard`/the v1 key; `internal` init so `@testable` can build isolated stores.
    init(defaults: UserDefaults = .standard, key: String = "stocksage.journal.v1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    var open: [TradeRecord] { trades.filter { $0.isOpen } }
    var closed: [TradeRecord] { trades.filter { !$0.isOpen } }
    var stats: JournalStats { StockSageJournal.stats(trades) }
    var edgeStats: JournalEdge { StockSageJournal.edge(trades) }
    var sectorPnL: [SectorPnL] { StockSageJournal.bySector(trades) }
    var monthlyPnL: [MonthlyPnL] { StockSageJournal.monthlyPnL(trades) }
    var yearlyPnL: [YearlyPnL] { StockSageJournal.yearlyPnL(trades) }
    var sideStats: [SidePnL] { StockSageJournal.bySide(trades) }
    var streakSummary: JournalStreak? { StockSageJournal.streak(trades) }
    var expectancyCI: ExpectancyCI? { StockSageJournal.expectancyConfidence(trades) }
    var holdingPeriod: HoldingPeriod? { StockSageJournal.holdingPeriod(trades) }
    var tradesToSignificance: (needed: Int, more: Int)? { StockSageJournal.tradesToSignificance(trades) }
    var rDistribution: RDistribution? { StockSageJournal.rDistribution(trades) }
    var equityRisk: JournalRisk? { StockSageJournal.equityRisk(trades) }
    var kellyInputs: (winRate: Double, payoffRatio: Double, n: Int)? { StockSageJournal.kellyInputs(trades) }
    var systemHealth: SystemHealth? { StockSageJournal.systemHealth(trades) }
    var expectancyTrend: ExpectancyTrend? { StockSageJournal.expectancyTrend(trades) }
    var compounding: CompoundingCurve? { StockSageJournal.compoundingCurve(trades) }

    func add(_ t: TradeRecord) {
        trades.insert(t, at: 0)
        save()
    }

    func close(_ id: UUID, exitPrice: Double, plannedExit: Double? = nil, exitFill: Double? = nil, at date: Date = Date()) {
        guard exitPrice > 0, let i = trades.firstIndex(where: { $0.id == id }) else { return }
        trades[i].exitPrice = exitPrice
        trades[i].closedAt = date
        // Review 2026-07-09: nil params never WIPE an already-captured measurement — a
        // future caller using the old close(id:exitPrice:) shape must not erase fills.
        if plannedExit != nil { trades[i].plannedExit = plannedExit }
        if exitFill != nil { trades[i].exitFill = exitFill }
        save()
    }

    // Explicit deletion — bypasses the reconciling save (a merged save would resurrect the
    // removed trade from disk). Same ponytail ceiling as the paper store: a CONCURRENT
    // process's next merged save can still resurrect it; tombstones if that ever matters.
    func remove(_ id: UUID) {
        trades.removeAll { $0.id == id }
        save(reconciling: false)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TradeRecord].self, from: data) else { return }
        trades = decoded
    }

    /// LOST-UPDATE FIX (2026-07-09): identical defect class to StockSagePaperTradeStore's,
    /// fixed the same day from LIVE paper-store evidence (double-opens + zero closes = a
    /// second app instance clobbering the whole-array key). This journal is MONEY-CRITICAL —
    /// it feeds `convictionCalibration` (win-prob), the drawdown brake, and every analytics
    /// panel — so a clobbered close here silently distorts calibration with a lost REAL
    /// outcome. Reconcile with disk before writing: per id a CLOSED record beats an open one
    /// (a close is terminal), foreign ids (another process's adds) are preserved. Deletions
    /// pass `reconciling: false`. `qaSeed` still bypasses save() entirely (in-memory only).
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

    /// QA-only in-memory REPLACE: assigns `trades` directly, bypassing `save()` so nothing
    /// touches UserDefaults — exact seam shape of `StockSagePortfolio.qaSeed`. MONEY-CRITICAL:
    /// this is a full REPLACE, never an append. `trades` feeds
    /// `StockSageStore.convictionCalibration` via a fit memoized on the trades array's VALUE
    /// (JournalCalibrationCache) — appending one fake trade to the owner's REAL journal could
    /// cross `StockSageConvictionCalibration.fit(fromJournal:)`'s minSamples=30 floor
    /// (StockSageConvictionCalibration.swift:99) mid-capture and flip calibration semantics.
    /// A REPLACE with a small fixed set (currently 3 fake trades) keeps outcomes.count < 30 ⇒ fit returns nil ⇒ calibration
    /// falls back to the backtest fit / prior — deterministic and boundary-safe. Because the fit
    /// cache keys on VALUE, the caller's restore-to-`saved` (also a qaSeed replace) recomputes
    /// the owner's real calibration on the very next read — nothing leaks past the capture window.
    func qaSeed(_ seeded: [TradeRecord]) {
        trades = seeded
    }
}
