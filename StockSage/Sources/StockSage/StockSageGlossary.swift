import Foundation

// MARK: - Glossary & asset-class risk notes
//
// Every number in the Markets tab is backward-looking and rules-based, not a
// forecast. These plain-language explainers (shown as ⓘ tooltips on each card)
// say what each stat means AND that it describes the past. The asset-class notes
// surface the structural risks of FX / crypto / index instruments that a single
// price line hides.

/// The money-velocity vocabulary — each term gets a plain-English explainer that
/// restates its honest caveat (see `StockSageGlossary.explain`).
enum MoneyVelocityTerm: String, CaseIterable, Sendable {
    case ev = "EV"
    case velocity = "EV / day"
    case fastLane = "Fast lane"
    case weeklyR = "Weekly R"
    case weeklyDollars = "$ / week"
    case compounding = "Compounding"
    case drawdownSurvival = "Drawdown survival"
    case gpPerHour = "gp / hour"   // RuneScape GE flip metric — surfaced by RuneScapeMarketView, not MarketsView
}

/// The user-facing money-velocity CAPTIONS, centralized so a test can guarantee each
/// keeps its honest hedge — a structural guard against a future edit silently dropping a
/// caveat. The views reference these (not inline literals).
enum MoneyVelocityCopy {
    nonisolated static let bestOpportunity =
        "Highest estimated EV among current buy ideas — an estimate from conviction, NOT a forecast. Tap for the full plan; size with a stop and the cap."
    nonisolated static let fastLane =
        "Faster turnover = more compounding cycles, but also more chances to be wrong. Estimated EV/day, not a forecast."
    nonisolated static let summary =
        "Estimates from conviction & a rough hold — ranks SPEED of payoff, doesn't predict it. Risk control > speed; always size with a stop."
    nonisolated static let weeklyDollars = "gross, before costs — estimate, high variance, NOT income."
    /// F03/F44 net-headline companion (2026-07-09): same hedges, net framing.
    nonisolated static let weeklyDollarsNet = "net of est. costs — estimate, high variance, NOT income."
    /// FASTMONEY_BACKLOG #7 — the honest tail on the crypto-vs-equity rotation-gap warning.
    nonisolated static let cannotHedgeOvernight =
        "You can't hedge 24/7 crypto with 9:30–4 equity hours — overnight risk moves while those positions are simply not tradeable; size down if you can't watch it."
    /// Shared hedge tail for the velocity-history lines (trend + since-last-session).
    nonisolated static let ownHistory = "your own history, not a forecast."
    /// Drawdown-brake tail on the summary card.
    nonisolated static let drawdownBrake = "Size to survive variance."
    /// The forward growth projection's caveat — the highest-risk honesty surface.
    nonisolated static let growthProjection = "Assumes your past edge persists — it may not, and real variance lowers this. NOT a prediction."
    /// Compact tail for the Today-tab "Best bet" stat tile (rendered after the EV figure).
    /// "gross" qualifier added (round-J 2026-07-09, re-landed) — every other EV surface labels
    /// gross/net; this tile's underlying figure (best.ev.evR, TodayView) is gross, so the tag
    /// must say so too.
    nonisolated static let bestBetTile = "gross EV · estimate"
    /// TOM-tilt disclosure suffix for every `bestOpportunity`-CROWNED surface (C1 wave HIGH,
    /// extended to the Today tile in-turn 2026-07-09): the owner's KEEP ratification is
    /// premised on UI-disclosure, and the tilt crowns on every sort and tab. Centralized here
    /// so the three consuming files (MarketsView ×3 sites, TodayView tile) cannot drift.
    /// Empty when the tilt cannot be moving the crown.
    nonisolated static func tomTiltSuffix(seasonalityPopulated: Bool) -> String {
        (StockSageAdvisor.turnOfMonthEnabled && seasonalityPopulated)
            ? " Pick includes each name's seasonal month tilt (capped ±0.03 rank units) — a weak, backward-looking tendency, not a forecast."
            : ""
    }
    nonisolated static let all: [String] = [bestOpportunity, fastLane, summary, weeklyDollars, weeklyDollarsNet, cannotHedgeOvernight, ownHistory, drawdownBrake, growthProjection, bestBetTile]
}

enum StockSageGlossary {

    /// Plain-English explainer for a money-velocity term. Each one names the metric AND
    /// states why it's an estimate, never a forecast.
    nonisolated static func explain(_ term: MoneyVelocityTerm) -> String {
        switch term {
        case .ev:
            return "Expected value (R) = pWin·reward − (1−pWin), where pWin is an ESTIMATE mapped from conviction (a conservative \(StockSageExpectedValue.assumedWinBandLabel)), not a real probability. It ranks payoff per trade; it does not predict any single outcome."
        case .velocity:
            return "Velocity = EV ÷ typical hold = expected R per DAY. A setup that resolves faster compounds more, so it can outrank an equal-EV slower one. Built on an estimated hold — a rough assumption, not a measurement."
        case .fastLane:
            // Hierarchy lens 2026-07-09: was "ranked by EV/day" — stale since velocityRankKey
            // moved to log-growth ordering; the Today's-plan card explains its DIFFERENT order
            // by exactly this distinction, so the hover must not contradict it.
            return "The positive-EV setups that have a defined velocity (crypto/equity), ORDERED by growth rate — per-day log-growth at ½-Kelly, cost-haircut — so a steady compounder can out-rank a higher-EV/day lottery setup; the displayed figure is still EV/day. Faster turnover means more compounding cycles AND more chances to be wrong."
        case .weeklyR:
            return "Sum of the top few fast-lane GROSS velocities (before round-trip costs) × ~5 trading days — an estimate of weekly R IF you take and re-cycle those setups. It can include ideas the net-cost floor demotes on the boards (the 'Fastest' pick excludes them). High variance; not a promise."
        case .weeklyDollars:
            return "Weekly R × the dollar value of 1R (account × risk %). Gross, before costs. An estimate that assumes you take the top setups — NOT income."
        case .compounding:
            return "Your OWN closed-trade R compounded at a fixed risk % per trade, ×(1 + f·R) each. The PAST path of your trades, not a projection of future returns."
        case .drawdownSurvival:
            return "k losing trades in a row at risk f shrink the account by (1 − f)^k. The counterweight to velocity: size so a normal losing streak stays survivable — staying in the game is how velocity pays off. Assumes each loss is a CLEAN 1R stop-out; an overnight gap or slippage past the stop can lose MORE than 1R, so this is a best-case FLOOR, not a guarantee."
        case .gpPerHour:
            return "OSRS flip velocity: (sell − buy − GE tax) × the 4-hour buy limit ÷ 4h = gp per hour. A CEILING, not a rate you'll hit: it assumes you fill the ENTIRE buy limit and resell instantly. Real fills are VOLUME-GATED — a thin item can take hours to fill (or never), so a high gp/hour on low volume is mostly theoretical."
        }
    }

    /// Umbrella ⓘ for the money-velocity surfaces.
    nonisolated static let moneyVelocityHelp = """
    Money velocity ranks the SPEED of expected payoff, not just its size — so capital recycles faster and compounds. \
    Every figure here (EV, EV/day, weekly R, $/week, gp/hour) is an ESTIMATE built on an estimated win-probability and a \
    rough hold, not a forecast. Compounding shows your PAST path; the drawdown line is the brake. Risk control > speed: \
    always size with a stop.
    """

    // Per-card help — concise, honest, hover-reveal.
    nonisolated static let analyticsHelp = """
    Sharpe: annualized return per unit of TOTAL volatility — higher = smoother. \
    Sortino: like Sharpe but penalizes only DOWNSIDE volatility (upside swings don't count against you). \
    Calmar: annual return ÷ worst drawdown. VaR95: a daily loss the book exceeds ~1 day in 20 — a routine bad day, NOT a worst case. \
    Diversification (0–100): higher = better diversified — it rewards LOW or negative cross-holding correlation and holding more names. Independent (uncorrelated) holdings already score high; only strongly HEDGED, inversely-correlated books approach 100, and 0 = one concentrated bet. All backward-looking: past behavior, not a prediction.
    """

    nonisolated static let regimeHelp = """
    A risk-on/off gauge from the S&P 500 vs its 200-day average, its momentum, the VIX, and breadth \
    (how many large-caps are above their own 200-day line). It sets a sizing BIAS — smaller risk-off, larger risk-on — \
    not a buy/sell call. A gauge of conditions, not a forecast; re-gauge it intraday as things move.
    """

    nonisolated static let kellyHelp = """
    Kelly = the bet fraction that maximizes long-run growth GIVEN your edge (win-rate W and payoff ratio R): f* = W − (1−W)/R. \
    Full Kelly is famously too aggressive — one bad streak ruins it — so the panel shows Full (for reference only), HALF, and a suggestion capped at 20%. \
    Garbage in, garbage out: if your W and R estimates are optimistic, so is the size.
    """

    nonisolated static let heatmapHelp = """
    Pairwise correlation of daily returns. Green (≤0) = the two move independently or opposite — real diversification. \
    Red (>0, deeper = closer to +1) = they move together, so they're closer to one position than two. \
    Correlations rise in crashes exactly when you need diversification most — treat low correlation as fragile.
    """

    nonisolated static let strategyHelp = """
    The advisor's fixed rules run across a sample of names over ~5 years and pooled: total trades, blended win-rate, \
    expectancy (avg R), total R, worst single-name drawdown, % of names profitable. Backward-looking, small-sample, \
    survivorship-biased, and the rules are FIXED not optimized — an illustration of behavior, not a promise.
    """

    nonisolated static let journalHelp = """
    Your own record of trades taken. R-multiple = profit ÷ the risk you defined at entry (entry→stop), so +2R means you made \
    twice what you risked. Stats cover CLOSED trades only. A journal documents your decisions — it doesn't validate them.
    """

    nonisolated static let betaHelp = """
    Beta vs the S&P 500: how much your book moves WITH the market. β=1 tracks it; β>1 AMPLIFIES both gains and losses \
    (β1.5 ≈ 50% bigger swings than the index); β<1 damps it; β<0 moves opposite (a hedge). Backward-looking over ~1 year \
    of daily returns — it drifts as holdings and correlations change.
    """

    /// Structural risk note for FX / crypto / index symbols; nil for a plain equity.
    nonisolated static func assetClassRiskNote(for symbol: String) -> String? {
        switch StockSageAllocation.assetClass(symbol) {
        case "Crypto":
            return "Crypto trades 24/7 with no circuit breakers and weekend gaps, and has historically run 2–4× equity volatility — size smaller and expect deeper swings than the indicators imply."
        case "Forex":
            return "FX trades ~24/5 and is driven by rates, macro and central-bank policy, with weekend gaps. Leverage is implicit — treat the full notional as your risk, not the margin."
        case "Index":
            return "This is an index LEVEL, not directly tradable — use it as a regime/context gauge; get exposure via an ETF or future, whose costs and tracking differ."
        default:
            return nil
        }
    }
}
