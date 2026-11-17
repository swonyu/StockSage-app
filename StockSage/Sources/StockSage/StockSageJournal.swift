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
    private(set) var entry: Double
    private(set) var stop: Double
    private(set) var target: Double?
    private(set) var shares: Double
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
    /// New legacy PAPER closes keep the observed gross fill separate from modeled costs.
    /// nil preserves older netted-exit records and real journal accounting unchanged.
    var modeledPaperCostPerShare: Double?
    /// Recorded price/cost units. Legacy nil is preserved and never inferred from the ticker.
    let denomination: StockSagePriceDenomination?

    init(id: UUID = UUID(), symbol: String, side: Side, entry: Double, stop: Double,
         target: Double?, shares: Double, openedAt: Date,
         exitPrice: Double? = nil, closedAt: Date? = nil, note: String? = nil, conviction: Double? = nil,
         plannedEntry: Double? = nil, entryFill: Double? = nil, plannedExit: Double? = nil, exitFill: Double? = nil,
         modeledPaperCostPerShare: Double? = nil, denomination: StockSagePriceDenomination? = nil) {
        self.id = id; self.symbol = symbol; self.side = side
        self.entry = entry; self.stop = stop; self.target = target
        self.shares = shares; self.openedAt = openedAt
        self.exitPrice = exitPrice; self.closedAt = closedAt; self.note = note; self.conviction = conviction
        self.plannedEntry = plannedEntry; self.entryFill = entryFill
        self.plannedExit = plannedExit; self.exitFill = exitFill
        self.modeledPaperCostPerShare = modeledPaperCostPerShare
        self.denomination = denomination
    }

    nonisolated var isOpen: Bool { closedAt == nil }

    /// Validate the recorded pair without repairing/deleting legacy evidence. Equal timestamps
    /// are allowed (exports have second precision); calibration imposes its stricter time split.
    nonisolated var closureError: String? {
        guard openedAt.timeIntervalSinceReferenceDate.isFinite else { return "The journal open time must be finite." }
        if let cost = modeledPaperCostPerShare {
            guard cost.isFinite, cost >= 0, closedAt != nil, exitPrice != nil else {
                return "Modeled paper costs require a closed fill and a nonnegative finite amount."
            }
        }
        switch (exitPrice, closedAt) {
        case (nil, nil): return nil
        case let (exit?, close?):
            guard exit > 0, exit.isFinite else { return "The journal exit price must be positive and finite." }
            guard close.timeIntervalSinceReferenceDate.isFinite, close >= openedAt else {
                return "The journal close time must be finite and not precede its open time."
            }
            return nil
        default: return "A journal exit price and close time must both be present, or both absent."
        }
    }

    nonisolated var isFinalized: Bool { !isOpen && closureError == nil }

    nonisolated var ownerJournalError: String? {
        modeledPaperCostPerShare != nil ? "Modeled paper fills cannot be imported into the owner journal." : closureError
    }

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
        guard isFinalized, let p = plannedExit, let f = exitFill else { return nil }
        return Self.legSlippageBps(planned: p, fill: f, isBuy: side == .short)
    }

    /// Risk per share defined at entry (entry→stop distance).
    nonisolated var riskPerShare: Double { abs(entry - stop) }

    /// Entry-leg execution cost expressed in R (the unit the rest of the journal reasons in):
    /// slippage as a fraction of the planned price, times that price, divided by the trade's own
    /// risk-per-share. nil unless the leg has both prices AND a defined risk. Positive = the fill
    /// cost you R vs the plan. Reuses `entrySlippageBps` so the cost sign convention matches.
    nonisolated var entrySlippageR: Double? {
        guard let bps = entrySlippageBps, let p = plannedEntry, riskPerShare > 0 else { return nil }
        return (bps / 10_000) * p / riskPerShare
    }
    /// Exit-leg execution cost in R — same construction as `entrySlippageR` off `exitSlippageBps`.
    nonisolated var exitSlippageR: Double? {
        guard let bps = exitSlippageBps, let p = plannedExit, riskPerShare > 0 else { return nil }
        return (bps / 10_000) * p / riskPerShare
    }

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

    nonisolated var realizedProfit: Double? {
        guard isFinalized, let exitPrice else { return nil }
        let perShare = side == .long ? exitPrice - entry : entry - exitPrice
        let gross = perShare * shares
        let costPerShare = modeledPaperCostPerShare ?? 0
        let cost = costPerShare * shares
        // A nonzero amount underflowing to zero is unavailable, not a break-even fill.
        guard gross.isFinite, cost.isFinite,
              perShare == 0 || shares == 0 || gross != 0,
              costPerShare == 0 || shares == 0 || cost != 0 else { return nil }
        let value = gross - cost
        return value.isFinite ? value : nil
    }
    /// Same-record amount only. No current quote can retroactively establish old fill units.
    nonisolated var realizedMajorProfit: Double? {
        guard let denomination, let raw = realizedProfit else { return nil }
        return denomination.majorValue(rawValue: raw)
    }
    nonisolated var rawUnitLabel: String {
        denomination?.quoteUnitLabel ?? "raw units (currency unconfirmed)"
    }
    nonisolated var realizedProfitDescription: String {
        guard let raw = realizedProfit else { return "Unavailable" }
        if let denomination, let major = denomination.majorValue(rawValue: raw) {
            return StockSageCurrency.signedAmount(major, currency: denomination.currencyCode)
        }
        if let denomination {
            return StockSageCurrency.adaptivePrice(raw) + " " + denomination.quoteUnitLabel
                + " (conversion to major currency units unavailable)"
        }
        return String(format: "%+.2f", raw) + " raw units (currency unconfirmed)"
    }

    nonisolated var realizedR: Double? {
        guard isFinalized, let exitPrice, let gross = rMultiple(at: exitPrice) else { return nil }
        let perShare = side == .long ? exitPrice - entry : entry - exitPrice
        let costPerShare = modeledPaperCostPerShare ?? 0
        let costR = costPerShare / riskPerShare
        guard gross.isFinite, costR.isFinite,
              perShare == 0 || gross != 0,
              costPerShare == 0 || costR != 0 else { return nil }
        let value = gross - costR
        guard value.isFinite else { return nil }
        return value
    }

    /// Whole calendar days held — to `closedAt` if closed, else to `now`. Never negative.
    nonisolated func daysHeld(asOf now: Date) -> Int {
        let days = ((closedAt ?? now).timeIntervalSince(openedAt) / 86_400).rounded(.down)
        guard days.isFinite, days > 0, days < Double(Int.max) else { return 0 }
        return Int(days)
    }

    /// Value-preserving corporate-action rebase (retro split adjustment, 2026-07-26 CLBK 2.2:1):
    /// divide every price field by `ratio`, multiply shares by it — position VALUE and every
    /// R-multiple are unchanged; only the quote basis moves to match a retro-adjusted price
    /// series. entry/stop/target/shares are private(set) so this is the ONLY mutation path
    /// after opening (a trade's terms are otherwise immutable).
    /// ponytail: plannedEntry/entryFill stay `let` and unrebased. Paper positions persist the
    /// rebase; real-journal comparisons rebase a disposable copy only and never use its fill
    /// analytics. Actual journal reconciliation needs a separate, explicit accounting path.
    nonisolated mutating func rebase(dividingBy ratio: Double) {
        guard ratio > 0, ratio.isFinite else { return }
        entry /= ratio
        stop /= ratio
        if let t = target { target = t / ratio }
        shares *= ratio
        // Audit trail (2026-07-26): a silent rebase is invisible in the book — the note tag is
        // what the scoreboard counts to disclose "N positions auto-rebased for corporate actions".
        note = ((note?.isEmpty == false) ? note! + " " : "") + String(format: "[rebased ×%.4g]", ratio)
    }
}

/// Aggregate stats over coherently FINALIZED trades — the owner's realized track record.
struct JournalStats: Sendable, Equatable {
    let closed: Int
    /// Known wins among records with usable raw P&L; winRate requires full coverage.
    let wins: Int
    let winRate: Double
    let totalR: Double
    let totalProfit: Double
    let avgR: Double
    /// Common recorded major currency, even if its total is unavailable; nil for unknown/mixed/empty books.
    let profitCurrency: String?
    /// Representative identity only; never use its raw-unit scale on the normalized sum.
    let profitSymbol: String?
    /// Coverage is independent for raw P&L, normalized money, and R. The canonical
    /// calculator always supplies these counts; legacy summary initializers stay source-compatible.
    var closedWithProfit: Int = 0
    var closedWithMajorProfit: Int = 0
    var closedWithR: Int = 0
    nonisolated var hasCompleteProfitCoverage: Bool { closedWithProfit == closed }
    nonisolated var hasCompleteRCoverage: Bool { closedWithR == closed }

    nonisolated var profitUnavailableReason: String? {
        guard closed > 0 else { return nil }
        if !hasCompleteProfitCoverage {
            return "A combined P&L and win rate are unavailable: usable P&L exists for \(closedWithProfit) of \(closed) finalized records. The other amounts cannot be represented; the records are unchanged."
        }
        if closedWithMajorProfit < closed {
            return "A combined P&L is unavailable: a recorded currency or unit is unknown, or its conversion cannot be represented. Each record retains its original values."
        }
        if profitCurrency == nil {
            return "A combined P&L is unavailable across different currencies. Each record retains its original values."
        }
        if !totalProfit.isFinite {
            return "A combined P&L is unavailable because the sum cannot be represented. Each record retains its original values."
        }
        return nil
    }

    nonisolated var rUnavailableReason: String? {
        guard closed > 0 else { return nil }
        if !hasCompleteRCoverage {
            return "Usable R exists for \(closedWithR) of \(closed) finalized records. R is undefined or cannot be represented for the others, so a complete R total and average are unavailable."
        }
        if !totalR.isFinite || !avgR.isFinite {
            return "The R total or average for these finalized records cannot be represented. The records are unchanged."
        }
        return nil
    }

    /// Counts remain valid even when a derived sum cannot be represented.
    nonisolated var hasFiniteAggregates: Bool {
        [winRate, totalR, totalProfit, avgR].allSatisfy(\.isFinite)
    }
}

/// The EDGE decomposition over closed trades — why the expectancy is what it is.
struct JournalEdge: Sendable, Equatable {
    let avgWinR: Double        // average R of winning trades (R > 0)
    let avgLossR: Double       // average R of losing trades, as a POSITIVE magnitude
    let payoffRatio: Double    // avgWinR ÷ avgLossR (0 if no losses yet)
    let expectancyR: Double    // R you make per trade on average (= mean realized R)
    let closedWithR: Int       // closed trades with a defined R
    let profitFactor: Double?  // Σ winning R ÷ Σ |losing R|; nil with no losses yet
    nonisolated var isAvailable: Bool {
        [avgWinR, avgLossR, payoffRatio, expectancyR].allSatisfy(\.isFinite)
            && (profitFactor.map { $0.isFinite && $0 >= 0 } ?? true)
    }
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
    let hasDispersion: Bool

    nonisolated var shapeNote: String {
        guard skewness.isFinite, kurtosis.isFinite else {
            return "Sample shape unavailable: the derived moments cannot be represented."
        }
        guard hasDispersion else { return "No variation in recorded R outcomes; sample shape is undefined." }
        if skewness < -0.2 { return "Left-skewed recorded R outcomes; the sample has a longer loss tail." }
        if skewness > 0.2 { return "Right-skewed recorded R outcomes; the sample has a longer gain tail." }
        return "Roughly symmetric recorded R outcomes."
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
    var closedWithProfit: Int = 0 // raw P&L coverage required for the whole-bucket win rate
    var id: String { side.rawValue }
}

/// Realized R for one calendar month (closed trades).
struct MonthlyPnL: Sendable, Equatable, Identifiable {
    let month: String   // "YYYY-MM" (UTC)
    let trades: Int
    let totalR: Double
    var closedWithR: Int = 0
    var id: String { month }
}

/// Realized performance for one calendar year (closed trades) — for record-keeping.
struct YearlyPnL: Sendable, Equatable, Identifiable {
    let year: String            // "YYYY" (UTC)
    let trades: Int
    let wins: Int
    let winRate: Double         // 0–1, or unavailable when raw P&L coverage is incomplete
    /// Major quote-currency units. Never present a mixed-currency sum as one amount.
    let realizedDollars: Double
    let totalR: Double
    let profitSymbol: String?
    var profitCurrency: String? = nil
    var closedWithProfit: Int = 0
    var closedWithMajorProfit: Int = 0
    var closedWithR: Int = 0
    var profitUnavailableReason: String? = nil
    var rUnavailableReason: String? = nil
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
    var closedWithProfit: Int = 0 // raw P&L coverage required for the whole-bucket win rate
    var id: String { sector }
}

/// One conviction band's PREDICTED win% (from the active calibration) beside the owner's OWN
/// realized win% at that conviction — the classic reliability-diagram row. The single most honest
/// read on a win-probability model: "the engine said 60%, your fills at that conviction won 45%."
/// Display-only; the calibration is NOT refit from this (it already trains on the same journal via
/// the leak-free OOS selector) — this only VISUALISES predicted-vs-actual so the owner can judge it.
struct ConvictionReliability: Sendable, Equatable, Identifiable {
    let bandLabel: String    // e.g. "40–60%" — the conviction range this row covers
    let predicted: Double    // calibration's winProb for the band (0–1)
    let actualWinRate: Double // owner's realized win-rate among closed trades in this band (0–1)
    let n: Int               // closed trades WITH a conviction that fell in this band
    var id: String { bandLabel }
    /// Gap between what was promised and what happened (actual − predicted). Negative = the model
    /// was OPTIMISTIC at this conviction (you won less than it said) — the dangerous direction.
    nonisolated var delta: Double { actualWinRate - predicted }
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
    let tradeID: UUID
    var id: String { tradeID.uuidString }
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
        guard expectancyR.isFinite, stdErrR.isFinite, stdErrR >= 0, n >= 2 else { return false }
        return stdErrR > 0 ? abs(expectancyR) >= stdErrR : abs(expectancyR) > 0
    }

    nonisolated var note: String {
        guard expectancyR.isFinite, stdErrR.isFinite, stdErrR >= 0, n >= 2 else {
            return "Expectancy uncertainty unavailable: the derived statistics cannot be represented."
        }
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
    /// Median of `defaultCosts(symbol).priceVisibleRoundTripBps/2` over the SAME legs — the
    /// PRICE-VISIBLE half (spread + slippage) ONLY. `medianBps` above is measured from
    /// planned-vs-fill PRICES, and a commission never moves a fill price, so half a fee-inclusive
    /// round trip was not apples-to-apples: it charged the owner's fills for a leg no fill price
    /// can contain (.SR/EM 30 -> 15 bps/leg, crypto 35 -> 25; zero-fee classes unchanged).
    let assumedMedianBpsPerLeg: Double
    /// Median of `defaultCosts(symbol).takerFeeBps/2` over the SAME legs — the commission the
    /// owner ALSO pays but which no fill price shows. Displayed BESIDE, never inside,
    /// `assumedMedianBpsPerLeg`: the two sum to the pre-2026-09-12 fee-inclusive figure, so the
    /// split is lossless.
    let assumedFeeMedianBpsPerLeg: Double
    let legs: Int
    let minLegs: Int                    // 5
    /// Total execution cost across all measured legs, in R — the unit the rest of the journal
    /// reasons in. bps is abstract; "your fills shaved ≈0.15R off the average trade" is the
    /// discipline number. Positive = cost; nil legs (no planned/fill pair, or zero risk) excluded.
    let totalR: Double
    /// R cost per CLOSED TRADE that contributed ≥1 measured leg — the per-trade drag, comparable
    /// to the expectancy figures elsewhere in the panel.
    let perTradeR: Double
    /// Legs that actually fed totalR — a STRICTER population than `legs`: an R-leg additionally
    /// needs riskPerShare > 0, so a bps-measured leg on an entry==stop trade counts in `legs`
    /// but not here. The panel's Cost/trade .help must cite THIS count, not `legs` (review
    /// 2026-07-26: the two silently diverge exactly on zero-risk trades).
    let rLegs: Int
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
    /// Shared presentation boundary: never present NaN/infinity as an observed
    /// amount or ratio. Finite ordinary formatting is unchanged.
    nonisolated static func formattedFinite(_ value: Double, format: String) -> String {
        guard value.isFinite else { return "Unavailable" }
        return String(format: format, value)
    }

    /// Compounding curve: starting at ×1, each closed trade (by close time) multiplies
    /// the account by (1 + fraction·R). Clamped at 0 (ruin is absorbing). Pure — this
    /// is the PAST path of the owner's OWN trades at a fixed risk %, NOT a projection.
    nonisolated static func compoundingCurve(_ trades: [TradeRecord], fraction: Double = 0.01) -> CompoundingCurve? {
        let rs = trades.filter(\.isFinalized)
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            .compactMap { $0.realizedR }
        guard !rs.isEmpty, rs.allSatisfy(\.isFinite),
              fraction.isFinite, (0...1).contains(fraction) else { return nil }
        var mult = 1.0
        var out: [Double] = []
        out.reserveCapacity(rs.count)
        for r in rs {
            let periodReturn = fraction * r
            guard periodReturn.isFinite, fraction == 0 || r == 0 || periodReturn != 0 else { return nil }
            let factor = 1 + periodReturn
            guard factor.isFinite, periodReturn == 0 || factor != 1 else { return nil }
            if mult == 0 || factor <= 0 {
                mult = 0  // Real wipeout is absorbing; arithmetic failure is not wipeout.
            } else {
                let next = mult * factor
                guard next.isFinite, next > 0 else { return nil }
                mult = next
            }
            out.append(mult)
        }
        return CompoundingCurve(multiples: out, fraction: fraction)
    }

    /// Realized P&L rolled up by calendar year (UTC) — $ + R + win-rate + count, newest
    /// first. Closed trades only. For the owner's own record-keeping; NOT tax advice.
    nonisolated static func yearlyPnL(_ trades: [TradeRecord]) -> [YearlyPnL] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var byYear: [String: [TradeRecord]] = [:]
        for t in trades where t.isFinalized {
            guard let c = t.closedAt else { continue }
            byYear[String(cal.component(.year, from: c)), default: []].append(t)
        }
        return byYear.map { year, ts in
            // Reuse the same complete-population accounting as the whole journal.
            let summary = stats(ts)
            return YearlyPnL(year: year, trades: summary.closed, wins: summary.wins,
                             winRate: summary.winRate, realizedDollars: summary.totalProfit,
                             totalR: summary.totalR, profitSymbol: summary.profitSymbol,
                             profitCurrency: summary.profitCurrency,
                             closedWithProfit: summary.closedWithProfit,
                             closedWithMajorProfit: summary.closedWithMajorProfit,
                             closedWithR: summary.closedWithR,
                             profitUnavailableReason: summary.profitUnavailableReason,
                             rUnavailableReason: summary.totalR.isFinite ? nil : summary.rUnavailableReason)
        }.sorted { $0.year > $1.year }
    }

    /// A HYPOTHETICAL forward account multiple: compound the measured expectancy (R/trade)
    /// over `trades` future trades at risk `fraction` — ×(1 + fraction·expectancyR)^trades.
    /// nil for non-positive trades/fraction or a wipeout step (1 + f·e ≤ 0). This is NOT a
    /// prediction — it assumes the past edge persists and ignores variance (which lowers it).
    nonisolated static func projectGrowth(expectancyR: Double, trades: Int, fraction: Double = 0.01) -> GrowthProjection? {
        guard expectancyR.isFinite, trades > 0, fraction.isFinite,
              fraction > 0, fraction <= 1 else { return nil }
        let periodReturn = fraction * expectancyR
        guard periodReturn.isFinite, expectancyR == 0 || periodReturn != 0 else { return nil }
        let step = 1 + periodReturn
        guard step.isFinite, step > 0, periodReturn == 0 || step != 1 else { return nil }
        let multiple = pow(step, Double(trades))
        guard multiple.isFinite, multiple > 0 else { return nil }
        return GrowthProjection(expectancyR: expectancyR, fraction: fraction, trades: trades,
                                multiple: multiple)
    }

    /// Expectancy trend: mean R of the first half vs the most-recent half of closed
    /// trades (by close time). `band` = the flat zone. nil under 6 closed-with-R.
    nonisolated static func expectancyTrend(_ trades: [TradeRecord], band: Double = 0.10) -> ExpectancyTrend? {
        let rs = trades.filter(\.isFinalized)
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
            .compactMap { $0.realizedR }
        guard rs.count >= 6, band.isFinite, band >= 0 else { return nil }
        let half = rs.count / 2
        let early = Array(rs.prefix(half))
        let recent = Array(rs.suffix(rs.count - half))
        let earlyR = early.reduce(0, +) / Double(early.count)
        let recentR = recent.reduce(0, +) / Double(recent.count)
        let delta = recentR - earlyR
        guard earlyR.isFinite, recentR.isFinite, delta.isFinite else { return nil }
        let dir: ExpectancyTrend.Direction = delta > band ? .improving : (delta < -band ? .fading : .flat)
        return ExpectancyTrend(earlyR: earlyR, recentR: recentR, direction: dir)
    }

    /// Classify track-record health from the already-computed stats. Pure decision
    /// table so the thresholds are unit-tested in isolation. `deepDrawdownR` = the
    /// peak→trough R that downgrades an otherwise-strong system.
    nonisolated static func classifyHealth(profitFactor: Double?, expectancyR: Double, significant: Bool,
                                           n: Int, maxDrawdownR: Double,
                                           minTrades: Int = 20, deepDrawdownR: Double = 8) -> SystemHealth {
        guard expectancyR.isFinite, maxDrawdownR.isFinite, maxDrawdownR >= 0,
              deepDrawdownR.isFinite, deepDrawdownR > 0, n >= 0, minTrades > 0,
              profitFactor.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            return SystemHealth(verdict: .unproven,
                                reason: "Track-record assessment unavailable: derived statistics cannot be represented. Retained trades are unchanged.")
        }
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
        if n < minTrades || !significant || expectancyR == 0 {
            return SystemHealth(verdict: .unproven,
                                reason: "Too little to trust (n=\(n)\(significant ? "" : ", mean <1σ from zero")). Keep logging before sizing up.")
        }
        let pfStrong = profitFactor.map { $0 >= 1.5 } ?? true   // no losses ⇒ effectively ∞
        if pfStrong && maxDrawdownR < deepDrawdownR {
            return SystemHealth(verdict: .strong,
                                reason: "Recorded mean ≥1 standard error above zero; this does not establish a future edge — PF \(pfStr), expectancy \(expStr)R over \(n), worst DD −\(ddStr)R.")
        }
        return SystemHealth(verdict: .developing,
                            reason: maxDrawdownR >= deepDrawdownR
                                ? "Recorded mean ≥1 standard error above zero, with a deep −\(ddStr)R drawdown (PF \(pfStr), n=\(n)). Future performance is unproven."
                                : "Recorded mean ≥1 standard error above zero with a small payoff margin (PF \(pfStr), n=\(n)). Future performance is unproven.")
    }

    /// System health requires usable R for every finalized record. Money can be
    /// unavailable independently; an empty finalized population has no assessment.
    nonisolated static func systemHealth(_ trades: [TradeRecord], minTrades: Int = 20) -> SystemHealth? {
        let closed = trades.filter(\.isFinalized)
        guard !closed.isEmpty else { return nil }
        let rs = closed.compactMap { $0.realizedR }
        guard rs.count == closed.count else {
            return SystemHealth(verdict: .unproven,
                                reason: "Track-record assessment unavailable: usable R exists for \(rs.count) of \(closed.count) finalized records. The retained records are unchanged.")
        }
        let e = edge(trades)
        let uncertainty = expectancyConfidence(trades)
        guard e.isAvailable, let risk = equityRisk(trades),
              rs.count < 2 || uncertainty != nil else {
            return SystemHealth(verdict: .unproven,
                                reason: "Track-record assessment unavailable: derived statistics cannot be represented. Retained trades are unchanged.")
        }
        return classifyHealth(profitFactor: e.profitFactor, expectancyR: e.expectancyR,
                              significant: uncertainty?.isSignificant ?? false,
                              n: rs.count, maxDrawdownR: risk.maxDrawdownR,
                              minTrades: minTrades)
    }

    /// Kelly inputs (win-rate, payoff) from the OWNER's own closed trades. Requires
    /// a meaningful sample (≥`minTrades`) AND at least one win and one loss to form
    /// an honest payoff. nil otherwise — never size off 3 lucky trades.
    nonisolated static func kellyInputs(_ trades: [TradeRecord], minTrades: Int = 10)
        -> (winRate: Double, payoffRatio: Double, n: Int)? {
        let rs = trades.filter(\.isFinalized).compactMap { $0.realizedR }
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
        let ordered = trades.filter(\.isFinalized)
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        let rs = ordered.compactMap { $0.realizedR }
        guard !rs.isEmpty else { return nil }

        var maxRun = 0, run = 0
        for r in rs {
            if r < 0 { run += 1; maxRun = Swift.max(maxRun, run) } else { run = 0 }
        }
        var cum = 0.0, peak = 0.0, maxDD = 0.0
        for r in rs {
            cum += r
            guard cum.isFinite else { return nil }
            peak = Swift.max(peak, cum)
            let drawdown = peak - cum
            guard drawdown.isFinite else { return nil }
            maxDD = Swift.max(maxDD, drawdown)
        }
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
        let closed = trades.filter(\.isFinalized)
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
        let rs = trades.filter(\.isFinalized).compactMap { $0.realizedR }
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
        guard mean.isFinite, variance.isFinite, variance >= 0, sd.isFinite else { return nil }
        let skewness: Double
        let kurtosis: Double
        if sd > 0 {
            skewness = rs.reduce(0) { $0 + pow(($1 - mean) / sd, 3) } / n
            kurtosis = rs.reduce(0) { $0 + pow(($1 - mean) / sd, 4) } / n
        } else {
            skewness = 0   // no variance → no shape to read, not "perfectly symmetric" by inference
            kurtosis = 3   // normal distribution's raw kurtosis — the neutral baseline
        }
        guard skewness.isFinite, kurtosis.isFinite else { return nil }
        return RDistribution(bins: zip(labels, counts).map { RDistribution.Bin(label: $0, count: $1) },
                             total: rs.count, skewness: skewness, kurtosis: kurtosis, hasDispersion: sd > 0)
    }

    /// How many TOTAL and how many MORE trades to reach |mean R| ≥ z·stderr (z=2 ≈
    /// 95%): N ≥ (z·s/|mean|)². nil when the mean is ~0 (a zero edge never confirms)
    /// or <2 trades. A sample-size estimate, not a promise the edge survives.
    nonisolated static func tradesToSignificance(_ trades: [TradeRecord], z: Double = 2) -> (needed: Int, more: Int)? {
        let rs = trades.filter(\.isFinalized).compactMap { $0.realizedR }
        guard rs.count >= 2, z.isFinite, z > 0 else { return nil }
        let n = rs.count
        let mean = rs.reduce(0, +) / Double(n)
        guard mean.isFinite, abs(mean) > 1e-9 else { return nil }
        let variance = rs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
        let s = variance.squareRoot()
        guard variance.isFinite, variance >= 0, s.isFinite else { return nil }
        guard s > 0 else { return (needed: n, more: 0) }   // observed zero spread; no extra sample estimated
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
        let rs = trades.filter(\.isFinalized).compactMap { $0.realizedR }
        guard rs.count >= 2 else { return nil }
        let n = rs.count
        let mean = rs.reduce(0, +) / Double(n)
        let variance = rs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)   // sample variance
        let stdErr = variance.squareRoot() / Double(n).squareRoot()
        guard mean.isFinite, variance.isFinite, variance >= 0, stdErr.isFinite else { return nil }
        return ExpectancyCI(expectancyR: mean, stdErrR: stdErr, n: n)
    }

    /// Best/worst realized trade and the current streak (by close time). Breakeven
    /// (R == 0) trades don't count toward the streak. nil with no closed-with-R trades.
    nonisolated static func streak(_ trades: [TradeRecord]) -> JournalStreak? {
        let closed = trades.filter(\.isFinalized).compactMap { t in t.realizedR.map { (t, $0) } }
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
        let closed = trades.filter(\.isFinalized)
        let rs = closed.compactMap { $0.realizedR }
        let profits = closed.compactMap { $0.realizedProfit }
        let majorProfits = closed.compactMap { $0.realizedMajorProfit }
        let wins = profits.filter { $0 > 0 }.count
        let rSum = rs.reduce(0, +)
        let totalR = rs.count == closed.count && rSum.isFinite ? rSum : .nan
        let average = closed.isEmpty ? 0 : totalR / Double(closed.count)
        let avgR = average.isFinite && (totalR == 0 || average != 0) ? average : .nan

        // Currency identity remains known even when its amount cannot be represented.
        // Never select a currency from only the records whose arithmetic succeeded.
        let currencies = Set(closed.compactMap { $0.denomination?.currencyCode })
        let single = !closed.isEmpty && currencies.count == 1
            && closed.allSatisfy { $0.denomination != nil }
        let majorSum = majorProfits.reduce(0, +)
        let completeMoney = profits.count == closed.count && majorProfits.count == closed.count
        let totalProfit = closed.isEmpty ? 0
            : (single && completeMoney && majorSum.isFinite ? majorSum : .nan)
        return JournalStats(
            closed: closed.count,
            wins: wins,
            winRate: closed.isEmpty ? 0
                : (profits.count == closed.count ? Double(wins) / Double(closed.count) : .nan),
            totalR: totalR,
            totalProfit: totalProfit,
            avgR: avgR,
            profitCurrency: single ? currencies.first : nil,
            profitSymbol: single ? closed.map(\.symbol).sorted().first : nil,
            closedWithProfit: profits.count,
            closedWithMajorProfit: majorProfits.count,
            closedWithR: rs.count)
    }

    /// Edge decomposition: average win R, average loss R, payoff ratio, and the
    /// per-trade expectancy (winRate·avgWin − lossRate·avgLoss == mean realized R).
    nonisolated static func edge(_ trades: [TradeRecord]) -> JournalEdge {
        let rs = trades.filter(\.isFinalized).compactMap { $0.realizedR }
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
        let closed = trades.filter(\.isFinalized)
        return TradeRecord.Side.allCases.compactMap { side in
            let ts = closed.filter { $0.side == side }
            guard !ts.isEmpty else { return nil }
            let rs = ts.compactMap { $0.realizedR }
            let profits = ts.compactMap { $0.realizedProfit }
            let wins = profits.filter { $0 > 0 }.count
            // The visible row names this R subset; an empty subset is unavailable,
            // not an observed zero. Win rate requires every raw P&L to be usable.
            let sum = rs.reduce(0, +)
            let total = !rs.isEmpty && sum.isFinite ? sum : .nan
            let average = !rs.isEmpty ? total / Double(rs.count) : .nan
            return SidePnL(side: side, trades: ts.count, wins: wins,
                           totalR: total,
                           avgR: average.isFinite && (total == 0 || average != 0) ? average : .nan,
                           winRate: profits.count == ts.count ? Double(wins) / Double(ts.count) : .nan,
                           closedWithR: rs.count, closedWithProfit: profits.count)
        }
    }

    /// Reliability diagram: for each of the calibration's conviction bands, the PREDICTED win% next
    /// to the owner's OWN realized win% among closed trades whose recorded conviction fell in that
    /// band. Buckets by the SAME half-open index math `calibration.winProb`/`fit` use, so a row's
    /// actual sample is exactly the trades the predicted number was meant to cover. Only closed
    /// trades that CARRY a conviction and a defined win/loss count. Empty (no calibration, or no
    /// convicted closed trades) → []. Display-only; refits nothing.
    nonisolated static func convictionReliability(_ trades: [TradeRecord],
                                                  calibration: StockSageConvictionCalibration) -> [ConvictionReliability] {
        let bins = calibration.bins
        guard !bins.isEmpty else { return [] }
        let nBands = bins.count
        // wins[i]/total[i] over closed trades carrying a conviction, bucketed like winProb(_:).
        var wins = Array(repeating: 0, count: nBands)
        var total = Array(repeating: 0, count: nBands)
        for t in trades where t.isFinalized {
            guard let c = t.conviction, let r = t.realizedR else { continue }
            let cc = Swift.max(0, Swift.min(1, c))
            let idx = Swift.min(nBands - 1, Int(cc * Double(nBands)))
            total[idx] += 1
            if r > 0 { wins[idx] += 1 }
        }
        let width = 1.0 / Double(nBands)
        return (0..<nBands).compactMap { i in
            guard total[i] > 0 else { return nil }   // no convicted trades in this band ⇒ nothing to compare
            let lo = Int((Double(i) * width * 100).rounded())
            let hi = Int((Double(i + 1) * width * 100).rounded())
            return ConvictionReliability(bandLabel: "\(lo)–\(hi)%",
                                         predicted: bins[i].winProb,
                                         actualWinRate: Double(wins[i]) / Double(total[i]),
                                         n: total[i])
        }
    }

    /// Realized R grouped by close MONTH (UTC), most-recent first.
    nonisolated static func monthlyPnL(_ trades: [TradeRecord]) -> [MonthlyPnL] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var groups: [String: (count: Int, rCount: Int, r: Double)] = [:]
        for t in trades where t.isFinalized {
            guard let closed = t.closedAt else { continue }
            let c = cal.dateComponents([.year, .month], from: closed)
            guard let y = c.year, let m = c.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            var g = groups[key] ?? (0, 0, 0)
            // Every finalized record still counts. A whole-month total must cover
            // every one of them; missing R cannot silently turn into zero or a subset.
            g.count += 1
            if let r = t.realizedR { g.rCount += 1; g.r += r }
            groups[key] = g
        }
        return groups.map {
            MonthlyPnL(month: $0.key, trades: $0.value.count,
                       totalR: $0.value.rCount == $0.value.count && $0.value.r.isFinite ? $0.value.r : .nan,
                       closedWithR: $0.value.rCount)
        }
            .sorted { $0.month > $1.month }   // YYYY-MM string sort = chronological, newest first
    }

    /// Realized P&L grouped by the symbol's sector — which industries you actually
    /// make money in. Closed trades only, sorted by total R (best first).
    nonisolated static func bySector(_ trades: [TradeRecord]) -> [SectorPnL] {
        let closed = trades.filter(\.isFinalized)
        var groups: [String: [TradeRecord]] = [:]
        for t in closed { groups[StockSageSector.sector(t.symbol), default: []].append(t) }
        return groups.map { sector, ts in
            let profits = ts.compactMap { $0.realizedProfit }
            let wins = profits.filter { $0 > 0 }.count
            let rs = ts.compactMap { $0.realizedR }
            let sum = rs.reduce(0, +)
            return SectorPnL(sector: sector, trades: ts.count, wins: wins,
                             totalR: !rs.isEmpty && sum.isFinite ? sum : .nan,
                             winRate: profits.count == ts.count ? Double(wins) / Double(ts.count) : .nan,
                             closedWithR: rs.count, closedWithProfit: profits.count)
        }
        // Dictionary iteration order (the pre-sort array) is randomized per process launch —
        // a deterministic secondary key stops a tied ranking from flipping between app launches.
        .sorted {
            if $0.totalR.isFinite != $1.totalR.isFinite { return $0.totalR.isFinite }
            if $0.totalR.isFinite && $0.totalR != $1.totalR { return $0.totalR > $1.totalR }
            return $0.sector < $1.sector
        }
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
            guard t.isOpen, t.closureError == nil, let px = mark(t.symbol), px > 0, px.isFinite,
                  t.entry > 0, t.entry.isFinite, t.stop > 0, t.stop.isFinite,
                  t.shares > 0, t.shares.isFinite, t.target.map({ $0 > 0 && $0.isFinite }) ?? true else { return nil }
            let isLong = t.side == .long
            let rNow = t.rMultiple(at: px).flatMap { $0.isFinite ? $0 : nil }
            // Stop hit — long: at/below the stop; short: at/above.
            if isLong ? px <= t.stop : px >= t.stop {
                return OpenAction(symbol: t.symbol, kind: .stopHit,
                                  detail: String(format: "%.2f at/through your %.2f stop — crossed level, not a confirmed fill; verify the position.", px, t.stop),
                                  rNow: rNow, tradeID: t.id)
            }
            // Target hit — long: at/above the target; short: at/below.
            if let tgt = t.target, (isLong ? px >= tgt : px <= tgt) {
                return OpenAction(symbol: t.symbol, kind: .targetHit,
                                  detail: String(format: "%.2f reached your %.2f target — take profit or trail the stop.", px, tgt),
                                  rNow: rNow, tradeID: t.id)
            }
            // Within the last 25% before the stop (−0.75R … −1R).
            if let r = rNow, r > -1, r <= -0.75 {
                return OpenAction(symbol: t.symbol, kind: .nearStop,
                                  detail: String(format: "%.2f is near your stop (now %+.2fR) — be ready to act.", px, r),
                                  rNow: r, tradeID: t.id)
            }
            if let r = rNow, r > 0 {
                return OpenAction(symbol: t.symbol, kind: .inProfit,
                                  detail: String(format: "up %+.2fR — consider trailing the stop to lock it in.", r),
                                  rNow: r, tradeID: t.id)
            }
            return OpenAction(symbol: t.symbol, kind: .holding, detail: "holding — no level crossed.", rNow: rNow, tradeID: t.id)
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
    /// This historical record count deliberately preserves legacy close flags; unlike realized
    /// analytics it is not a count of validated closures. Invalid fields never contribute R.
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
    /// asset-class ASSUMED cost for those same legs — half the PRICE-VISIBLE round trip
    /// (spread + slippage), with the fee half reported separately as
    /// `assumedFeeMedianBpsPerLeg`, because the measurement is planned-vs-fill PRICES. nil
    /// with zero legs; `meetsFloor` (n >= minLegs, default 5) gates whether the UI trusts it.
    nonisolated static func measuredSlippage(_ trades: [TradeRecord], minLegs: Int = 5) -> MeasuredSlippage? {
        var measured: [Double] = []
        var assumed: [Double] = []
        var assumedFee: [Double] = []
        var totalR = 0.0
        var contributingTrades = 0
        var rLegs = 0
        for t in trades where t.isFinalized {
            let costs = StockSageNetEdge.defaultCosts(forSymbol: t.symbol)
            // PRICE-VISIBLE half only (2026-09-12). `measured` is planned-vs-fill PRICES and a
            // commission never moves a fill price, so half a FEE-INCLUSIVE round trip was not
            // apples-to-apples — it flattered the fills on every fee-carrying book (.SR/EM
            // 30 -> 15, crypto 35 -> 25; zero-fee classes unchanged). The fee half is carried
            // alongside, never folded in. `roundTripBps` is untouched: it is the gate/NetEdge
            // number and must stay byte-identical.
            let assumedPerLeg = costs.priceVisibleRoundTripBps / 2
            let assumedFeePerLeg = costs.takerFeeBps / 2
            // Appended in EXACT lockstep with `measured`, so the `guard !measured.isEmpty` below
            // also protects `median(assumedFee)` — `median` indexes `sorted[n/2 - 1]` and traps
            // on an empty array.
            if let s = t.entrySlippageBps { measured.append(s); assumed.append(assumedPerLeg); assumedFee.append(assumedFeePerLeg) }
            if let s = t.exitSlippageBps { measured.append(s); assumed.append(assumedPerLeg); assumedFee.append(assumedFeePerLeg) }
            // R cost accrues per LEG (each leg has its own planned/fill + the trade's risk).
            // Counted separately from `measured`: an R-leg also needs risk > 0 (see rLegs doc).
            let legR = (t.entrySlippageR ?? 0) + (t.exitSlippageR ?? 0)
            rLegs += (t.entrySlippageR != nil ? 1 : 0) + (t.exitSlippageR != nil ? 1 : 0)
            if t.entrySlippageR != nil || t.exitSlippageR != nil {
                totalR += legR
                contributingTrades += 1
            }
        }
        guard !measured.isEmpty else { return nil }
        return MeasuredSlippage(medianBps: median(measured), assumedMedianBpsPerLeg: median(assumed),
                                assumedFeeMedianBpsPerLeg: median(assumedFee),
                                legs: measured.count, minLegs: minLegs,
                                totalR: totalR,
                                perTradeR: contributingTrades > 0 ? totalR / Double(contributingTrades) : 0,
                                rLegs: rLegs)
    }
}

// MARK: - Persisted journal store

@MainActor
final class StockSageJournalStore: ObservableObject {
    static let shared = StockSageJournalStore()

    @Published private(set) var trades: [TradeRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var hasLoadedRecords = false
    private let key: String
    private let defaults: UserDefaults
    private var deletions: StockSageRecordDeletions { .init(defaults: defaults, recordKey: key) }

    /// `defaults`/`key` injectable for the reconciliation tests ONLY (mirrors
    /// StockSagePaperTradeStore's seam) — production is always the `.shared` singleton on
    /// `.standard`/the v1 key; `internal` init so `@testable` can build isolated stores.
    init(defaults: UserDefaults = .standard, key: String = "stocksage.journal.v1") {
        self.defaults = defaults
        // Acquire before loading; a denied process cannot later take over with stale arrays.
        let ownership = Result { try StockSageRecordWriter.require(defaults) }
        self.key = key
        load()
        if case .failure(let error) = ownership, lastError == nil { lastError = error.localizedDescription }
    }

    var open: [TradeRecord] { trades.filter { $0.isOpen } }
    var closed: [TradeRecord] { trades.filter(\.isFinalized) }
    var invalidClosures: [TradeRecord] { trades.filter { $0.closureError != nil } }
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

    @discardableResult func add(_ t: TradeRecord) -> Bool {
        guard !deletions.contains(t.id) else {
            lastError = "This journal record was deleted. Use JSON Restore to restore its original ID."; return false
        }
        if let error = t.ownerJournalError { lastError = error; return false }
        let before = trades
        trades.insert(t, at: 0)
        guard save() else { trades = before; return false }
        return true
    }

    /// Import callers report actual writes, duplicates and rejected records separately.
    /// Reuse add's validation; never describe a rejected record as "already present".
    /// ponytail: existing per-record reconciled saves have quadratic batch cost; use an atomic
    /// batch writer if large-import measurements justify it. This is not a whole-book transaction.
    func importNew(_ incoming: [TradeRecord]) -> (added: Int, skipped: Int, rejected: Int) {
        var added = 0, skipped = 0, rejected = 0
        var firstError: String?
        for trade in incoming {
            if trades.contains(where: { $0.id == trade.id }) { skipped += 1 }
            else if add(trade) { added += 1 }
            else { rejected += 1; firstError = firstError ?? lastError }
        }
        if let firstError { lastError = firstError }
        return (added, skipped, rejected)
    }

    /// Current committed records for a full backup; do not mutate/reconcile the displayed book.
    func backupRecords() throws -> [TradeRecord] {
        do { return try deletions.read(TradeRecord.self).filter { !deletions.contains($0.id) } }
        catch { throw StockSageBackup.BackupError.sourceReadFailed("journal") }
    }

    /// Backup has already validated every incoming record. Prepare a single batch without
    /// changing memory/defaults, so a later portfolio/watchlist failure changes nothing.
    func prepareBackupImport(_ incoming: [TradeRecord]) throws -> StockSageRecordStorage.PreparedImport {
        try StockSageRecordWriter.require(defaults)
        if let error = incoming.compactMap(\.ownerJournalError).first {
            throw StockSageBackup.BackupError.restoreFailed(error)
        }
        let disk = try deletions.read(TradeRecord.self)
        guard var merged = reconciled(trades, disk: disk) else {
            throw StockSageBackup.BackupError.restoreFailed(lastError ?? "Conflicting journal records.")
        }
        var ids = Set(merged.map(\.id))
        let additions = incoming.filter { ids.insert($0.id).inserted }
        merged.insert(contentsOf: additions, at: 0)
        let data = try JSONEncoder().encode(merged)
        let records = merged
        let changes = deletions.restorationChanges(Set(additions.map(\.id)))
            + [StockSageRecordStorage.Change(key: key, value: .data(data))]
        return .init(defaults: defaults, added: additions.count, changes: changes, publish: { warning in
            self.trades = records
            self.hasLoadedRecords = true
            self.lastError = warning
        })
    }

    @discardableResult func close(_ id: UUID, exitPrice: Double, plannedExit: Double? = nil, exitFill: Double? = nil, at date: Date = Date()) -> Bool {
        guard !deletions.contains(id) else { lastError = "This journal record was deleted; it cannot be closed."; return false }
        guard let i = trades.firstIndex(where: { $0.id == id }) else { lastError = "Journal trade not found."; return false }
        var candidate = trades[i]
        candidate.exitPrice = exitPrice
        candidate.closedAt = date
        if let error = candidate.ownerJournalError { lastError = error; return false }
        guard [plannedExit, exitFill].compactMap({ $0 }).allSatisfy({ $0 > 0 && $0.isFinite }) else {
            lastError = "Journal planned/fill prices must be positive and finite when supplied."; return false
        }
        // Review 2026-07-09: nil params never WIPE an already-captured measurement — a
        // future caller using the old close(id:exitPrice:) shape must not erase fills.
        if plannedExit != nil { candidate.plannedExit = plannedExit }
        if exitFill != nil { candidate.exitFill = exitFill }
        let before = trades
        trades[i] = candidate
        guard save(replacing: before[i]) else { trades = before; return false }
        return true
    }

    // Preserve foreign records while committing a durable deletion for this ID.
    func remove(_ id: UUID) {
        _ = save(removing: [id])
    }

    private func load() {
        do {
            let decoded = try deletions.read(TradeRecord.self)
            trades = decoded.filter { !deletions.contains($0.id) }
            hasLoadedRecords = true
            lastError = nil
        } catch {
            hasLoadedRecords = false
            lastError = "Journal unavailable: couldn't read the saved trades. Existing data was preserved."
        }
    }

    /// LOST-UPDATE FIX (2026-07-09): identical defect class to StockSagePaperTradeStore's,
    /// fixed the same day from LIVE paper-store evidence (double-opens + zero closes = a
    /// second app instance clobbering the whole-array key). This journal is MONEY-CRITICAL —
    /// it feeds `convictionCalibration` (win-prob), the drawdown brake, and every analytics
    /// panel — so a clobbered close here silently distorts calibration with a lost REAL
    /// outcome. Reconcile with disk before writing: per id a CLOSED record beats an open one
    /// (a close is terminal), foreign ids (another process's adds) are preserved. Deletions
    /// exclude only deleted IDs. `qaSeed` still bypasses save() entirely (in-memory only).
    private func save(removing: Set<UUID> = [], replacing original: TradeRecord? = nil) -> Bool {
        do { try StockSageRecordWriter.require(defaults) }
        catch { lastError = error.localizedDescription; return false }
        guard let disk = try? deletions.read(TradeRecord.self) else {
            hasLoadedRecords = false
            lastError = "Couldn't read the saved journal; no records were changed."; return false
        }
        guard let records = reconciled(trades, disk: disk, replacing: original, removing: removing) else { return false }
        guard let data = try? JSONEncoder().encode(records) else {
            lastError = "Couldn't encode the journal; the previous saved records were kept."
            return false
        }
        // Encode first: a failed save must not leave a deletion marker behind.
        let warning: String?
        do {
            warning = try StockSageRecordStorage.update(deletions.deletionChanges(removing)
                + [.init(key: key, value: .data(data))], defaults: defaults)
        }
        catch { lastError = error.localizedDescription; return false }
        trades = records
        hasLoadedRecords = true
        lastError = warning
        return true
    }

    /// One reconciliation rule for ordinary saves and backup preparation: disk closes win,
    /// foreign IDs survive, and conflicting invalid closures require explicit repair.
    private func reconciled(_ records: [TradeRecord], disk: [TradeRecord], replacing original: TradeRecord? = nil,
                            removing: Set<UUID> = []) -> [TradeRecord]? {
        var merged = records.filter { !removing.contains($0.id) && !deletions.contains($0.id) }
        var ids = Set(merged.map(\.id))
        for d in disk where !removing.contains(d.id) && !deletions.contains(d.id) {
            if let i = merged.firstIndex(where: { $0.id == d.id }) {
                if let original, original.id == d.id, original != d {
                    lastError = "This journal record changed on disk. Nothing was saved; reload before amending its close."
                    return nil
                }
                if d.closureError != nil, merged[i] != d, original != d {
                    lastError = "Conflicting journal closure data changed on disk. Nothing was saved; reload and review the original record."
                    return nil
                }
                if !d.isOpen, original?.id != d.id { merged[i] = d }
            } else if ids.insert(d.id).inserted {
                merged.append(d)
            }
        }
        return merged
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
