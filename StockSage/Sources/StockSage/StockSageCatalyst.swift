import Foundation

/// Volume-confirmed catalyst detection — external-report item 9, owner-signed 2026-07-28.
///
/// The report's argument, which is sound: acting on news/price alone is noise-prone, so a
/// candidate catalyst should be confirmed by ORDER FLOW. The quantitative proxy available to a
/// retail app is relative volume (RVOL) — today's volume against its own recent baseline —
/// combined with a real price dislocation. Both must fire (dual confirmation) or nothing is
/// reported.
///
/// HONESTY FLOOR — read before trusting anything here:
/// This is a DETECTOR, not an edge. It says "unusual volume accompanied an unusual move",
/// which is a description of the past, not a prediction. No walk-forward validation has been
/// run on it, so it carries `unvalidated` and MUST be surfaced with that word attached. The
/// report's framing of catalyst trading as "rapid capital extraction" is explicitly NOT adopted:
/// the same volume spike marks a takeover and a collapse.
enum StockSageCatalyst {

    /// Volume-spike severity. Multiples are the conventional desk tiers the report describes;
    /// they are thresholds for ATTENTION, never position size.
    enum Tier: String, Sendable, Equatable {
        case notable      // >= 2x  — worth a look, needs price confirmation
        case significant  // >= 5x  — material information being priced aggressively
        case major        // >= 10x — event territory (earnings, M&A, regulatory)

        nonisolated static func forRVOL(_ rvol: Double) -> Tier? {
            if rvol >= 10 { return .major }
            if rvol >= 5 { return .significant }
            if rvol >= 2 { return .notable }
            return nil
        }
    }

    struct Signal: Sendable, Equatable {
        let symbol: String
        /// Latest volume ÷ mean volume of the preceding `baselineBars`.
        let rvol: Double
        /// Latest close vs the prior close, in percent (signed — direction is NOT a verdict).
        let priceChangePct: Double
        let tier: Tier
        /// True when the name's average dollar volume is large enough that spikes are routinely
        /// mechanical (index rebalances, passive flows) rather than informational — the report's
        /// own caution. Not a rejection: a flag the reader weighs.
        ///
        /// OPTIONAL (2026-09-12): nil means the ADV is UNKNOWN for this name, which is the normal
        /// case on the whole-board path — `liquidity` is in-memory and empty until a detail sheet
        /// is opened. It used to collapse to `false` via `(advDollar ?? 0) >= threshold`, so
        /// "never measured" rendered identically to "measured, and it is information". They are
        /// different facts and only one of them is a finding.
        let likelyMechanicalFlow: Bool?
        let caveat: String
        /// Calendar day of the bar the spike was measured on — nil when the caller supplied no
        /// `dates` (or a ragged one that cannot be aligned to `closes`). A `var` with a default so
        /// every existing `Signal(...)` literal keeps compiling, and so an undated signal renders
        /// exactly as it did before this field existed.
        var barDate: Date? = nil
    }

    /// Baseline length in bars (the report's "20 or 50 day ADV"; 20 is the responsive choice).
    nonisolated static let baselineBars = 20
    /// Dual-confirmation floors. RVOL 3.0 is the report's stated trigger; the price floor is
    /// deliberately conservative so a volume spike alone can never raise a signal.
    nonisolated static let minRVOL = 3.0
    nonisolated static let minAbsPriceMovePct = 4.0
    /// Above this average dollar volume, spikes are commonly passive/mechanical (report: large
    /// caps trading ~$5B/day rebalance on schedule).
    nonisolated static let mechanicalFlowADVDollar = 5_000_000_000.0
    /// A measured bar older than this many full days is HISTORY, not a move happening now. Mirrors
    /// `StockSageHistoryCache.isStale`'s default `maxAgeDays` (7 ≈ 5 trading days) AND its
    /// truncating `Int(interval / 86_400) > maxAgeDays` arithmetic, so the two never disagree
    /// about the same bar.
    nonisolated static let staleBarDays = 7

    /// Whether a measured bar is too old to describe as something happening now.
    nonisolated static func isStaleBar(_ barDate: Date?, now: Date) -> Bool {
        guard let barDate else { return false }   // undated: unknown, not stale
        let secs = now.timeIntervalSince(barDate)
        guard secs.isFinite, secs >= 0 else { return false }
        return Int(secs / 86_400) > staleBarDays
    }

    nonisolated static let caveat =
        "UNVALIDATED detector: unusual volume alongside an unusual move. It describes what just "
        + "happened, never what happens next — the same spike marks a takeover and a collapse. "
        + "No walk-forward validation has been run, so it carries no measured edge."

    /// Detect a volume-confirmed dislocation on the latest bar. nil when there is not enough
    /// history, when the baseline has no volume (FX/indices report 0), or when EITHER leg of the
    /// dual confirmation fails. Never guesses from partial data.
    nonisolated static func detect(symbol: String,
                                   closes: [Double],
                                   volumes: [Double],
                                   dates: [Date] = [],
                                   advDollar: Double? = nil,
                                   minRVOL: Double = minRVOL,
                                   minAbsPriceMovePct: Double = minAbsPriceMovePct) -> Signal? {
        // baselineBars bars of baseline + the spike bar = baselineBars + 1 is sufficient (the
        // prior close needed for the move sits inside that window). Was +2 — one bar too strict,
        // which silently skipped freshly-listed names with exactly the minimum history.
        // (Defect found by the DeepSeek review lane, 2026-07-28; verified by hand before fixing.)
        guard closes.count >= baselineBars + 1, volumes.count == closes.count else { return nil }
        let latestVolume = volumes[volumes.count - 1]
        // Baseline EXCLUDES the latest bar — including it would dilute the very spike we measure.
        let baseline = Array(volumes[(volumes.count - 1 - baselineBars)..<(volumes.count - 1)])
        let meanBaseline = baseline.reduce(0, +) / Double(baseline.count)
        guard meanBaseline > 0, latestVolume > 0 else { return nil }   // 0-volume assets: not judged

        let rvol = latestVolume / meanBaseline
        let prior = closes[closes.count - 2]
        guard prior != 0 else { return nil }
        let changePct = (closes[closes.count - 1] - prior) / abs(prior) * 100

        // DUAL CONFIRMATION — both legs or nothing.
        guard rvol >= minRVOL, abs(changePct) >= minAbsPriceMovePct,
              let tier = Tier.forRVOL(rvol) else { return nil }

        return Signal(symbol: symbol, rvol: rvol, priceChangePct: changePct, tier: tier,
                      // nil ADV stays nil: `(advDollar ?? 0) >= threshold` made "never measured"
                      // indistinguishable from "measured, below the bar". A non-finite ADV is
                      // likewise unknown, not "small".
                      likelyMechanicalFlow: advDollar.flatMap { $0.isFinite ? $0 >= mechanicalFlowADVDollar : nil },
                      caveat: caveat,
                      // Equal-length ONLY: a ragged `dates` cannot be aligned to `closes`, and a
                      // dateless caller must keep detecting — a guard-return-nil here would
                      // silently kill the detector for every caller that has no dates.
                      barDate: dates.count == closes.count ? dates.last : nil)
    }

    /// Scan many symbols, strongest volume confirmation first. Pure: no I/O, no network.
    nonisolated static func scan(_ histories: [String: StockSagePriceHistory],
                                 advDollarBySymbol: [String: Double] = [:]) -> [Signal] {
        histories.compactMap { symbol, h in
            detect(symbol: symbol, closes: h.closes, volumes: h.volumes, dates: h.dates,
                   advDollar: advDollarBySymbol[symbol])
        }
        .sorted { $0.rvol > $1.rvol }
    }
}
