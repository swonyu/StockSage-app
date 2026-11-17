import Foundation

// MARK: - Fractional Kelly position sizing
//
// The Kelly criterion gives the bet fraction that maximizes long-run geometric
// growth: f* = W − (1−W)/R, where W = win rate and R = payoff ratio (avg win ÷
// avg loss). But FULL Kelly is brutal — Gehm (1983) showed >50% drawdowns even
// with a real edge — so practitioners use a FRACTION (¼–½ Kelly), which cuts
// volatility far more than it cuts growth. Pure + deterministic → unit-tested.
// Honest: Kelly is only as good as your W and R estimates, which are usually
// optimistic; the caveat says so and the suggestion is capped.

struct KellyResult: Sendable, Equatable {
    let edge: Double              // expected value per unit risked: W·R − (1−W)
    let fullKelly: Double         // f* clamped to [0,1]
    let halfKelly: Double
    let quarterKelly: Double
    /// The recommended fraction: half-Kelly, hard-capped at 20% of the account.
    let suggestedFraction: Double
    let dollarsToAllocate: Double  // suggestedFraction × accountSize — CAPITAL to allocate under
                                   // the lose-the-whole-bet Kelly model, NOT the stop-risk dollars
                                   // the position sizer risks (that's ~1% of the account per trade)
    let note: String
    let caveat: String
    /// How much of the payoff ratio R was shaved off by round-trip costs (0 without a
    /// `CostProfile`) — the fraction of the win that commission/slippage/spread quietly eat.
    let costAdjustment: Double
}

/// Round-trip trading costs expressed in the SAME unit as the payoff ratio R (a fraction of
/// the risked amount — the entry-to-stop distance), so they subtract directly from R rather
/// than needing a separate dollar model. 10-50bps round-trip costs quietly eat a thin edge;
/// naming them is honest and changes sizing, not just the net-of-cost EV shown elsewhere.
struct CostProfile: Sendable, Equatable {
    let commissionPct: Double   // e.g. 0.1 = 0.1% round-trip commission
    let slippagePct: Double
    let bidAskPct: Double
    nonisolated var roundTripR: Double { Swift.max(0, commissionPct + slippagePct + bidAskPct) / 100 }
}

/// A whole BOOK of per-position Kelly fractions scaled to a portfolio heat ceiling. Per-position
/// Kelly sees one trade at a time — ten half-Kelly bets at 0.20 each sum to 2.0× the account (a
/// 2× leveraged ruin setup no single Kelly call can detect). This pins the SUMMED stop-risk to a cap.
struct PortfolioKelly: Sendable, Equatable {
    let scaledFractions: [Double]    // each per-position fraction after uniform down-scaling
    let bookRequestedHeat: Double    // Σ requested per-position fractions (could exceed 1.0)
    let bookHeat: Double             // Σ scaled = min(requested, cap)
    let scaleApplied: Double         // 1.0 when under the cap, else cap/requested
    let maxPortfolioHeat: Double
    let caveat: String
}

enum StockSageKelly {
    nonisolated static let caveat = "Kelly assumes your win-rate and payoff estimates are accurate — they rarely are. Use a fraction (¼–½) and a hard cap; over-betting compounds into ruin."

    /// Kelly inputs (W, R) implied by a backtest: W = win rate, R = avg-win-R ÷
    /// avg-loss-R. nil when the backtest lacks both a winner and a loser to form a
    /// real payoff ratio (a one-sided sample can't size honestly).
    nonisolated static func inputs(winRate: Double, avgWinR: Double, avgLossR: Double)
        -> (winRate: Double, payoffRatio: Double)? {
        guard avgWinR > 0, avgLossR > 0 else { return nil }
        return (winRate, avgWinR / avgLossR)
    }

    /// Never suggest risking more than this share of the account, whatever Kelly says.
    nonisolated static let maxFraction = 0.20

    /// Kelly from win rate `W` (0–1) and payoff ratio `R` (avg win ÷ avg loss). Optional `costs`
    /// shaves round-trip commission/slippage/spread directly off R before sizing — nil (the
    /// default) reproduces today's result byte-for-byte; a `CostProfile` whose round-trip cost
    /// meets or exceeds R means costs ate the entire reward, so fStar floors at 0 (don't bet),
    /// same as a non-positive raw edge.
    nonisolated static func compute(winRate: Double, payoffRatio: Double, accountSize: Double,
                                    costs: CostProfile? = nil) -> KellyResult {
        let w = Swift.max(0, Swift.min(1, winRate))
        let r = Swift.max(0.0001, payoffRatio)          // guard divide-by-zero
        let costAdjustment = costs?.roundTripR ?? 0
        // Costs subtract directly from R (they eat the win, not the win-rate); floored so a
        // cost that exceeds R never flips the sign and inflates the divisor toward 0 the wrong way.
        let netR = Swift.max(0.0001, r - costAdjustment)
        let edge = w * netR - (1 - w)                    // EV per $1 risked, net of costs
        // f* = W − (1−W)/R, clamped: a non-positive edge ⇒ 0 (don't bet).
        let fStar = Swift.max(0, Swift.min(1, w - (1 - w) / netR))
        let half = fStar / 2
        let quarter = fStar / 4
        let suggested = Swift.min(maxFraction, half)

        let note: String
        if fStar <= 0 {
            note = costAdjustment > 0 && r - costAdjustment <= 0
                ? "Round-trip costs eat the entire reward — no edge left after costs."
                : "No positive edge — Kelly says don't bet."
        } else if half >= maxFraction {
            note = "Half-Kelly exceeds the \(Int(maxFraction * 100))% cap — capped for safety."
        } else if costAdjustment > 0 {
            note = "Half-Kelly recommended (reward cut ~\(String(format: "%.2f", costAdjustment))R for round-trip costs); full Kelly risks deep drawdowns."
        } else {
            note = "Half-Kelly recommended; full Kelly risks deep drawdowns."
        }

        return KellyResult(edge: edge, fullKelly: fStar, halfKelly: half, quarterKelly: quarter,
                           suggestedFraction: suggested,
                           dollarsToAllocate: suggested * Swift.max(0, accountSize),
                           note: note, caveat: caveat, costAdjustment: costAdjustment)
    }

    /// Scale a book of per-position fractions (each already half-Kelly-capped via suggestedFraction)
    /// so their SUM never exceeds `maxPortfolioHeat` — the collective over-bet per-position Kelly
    /// can't see. Uniform scaling preserves the per-position ranking; under the cap it's a no-op.
    nonisolated static func portfolioCap(_ perPositionFractions: [Double],
                                         maxPortfolioHeat: Double = 0.30) -> PortfolioKelly {
        let cap = Swift.min(1, Swift.max(0, maxPortfolioHeat))
        let fracs = perPositionFractions.map { Swift.max(0, $0) }      // no negative bets
        let requested = fracs.reduce(0, +)
        let scale = (requested > cap && requested > 0) ? cap / requested : 1
        let scaled = fracs.map { $0 * scale }
        return PortfolioKelly(scaledFractions: scaled, bookRequestedHeat: requested,
                              bookHeat: scaled.reduce(0, +), scaleApplied: scale, maxPortfolioHeat: cap,
                              caveat: caveat + " Caps SUMMED stop-risk, not joint tail risk — correlated names can still gap together past this.")
    }
}
