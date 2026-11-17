import Foundation

// MARK: - Week-horizon refuse-list (coded policy, not a silent omission)
//
// RESEARCH_2026-07-02_week_horizon_velocity.md (deep-research 2026-07-02; 23 claims verified by
// adversarial 3-vote; roadmap item #1 — "the biggest lever"): at the 1–5 day horizon essentially
// NO documented equity edge survives realistic retail transaction costs as a standalone strategy.
// The fastest money at this horizon is the ~1–1.7%/month of COST-AVOIDANCE from refusing the
// documented net-negative setups — so the refuse-list is encoded HERE, in code, where it is
// testable, surfaceable in the UI, and consulted before any future short-horizon signal ships —
// instead of living only in a research markdown a future session may not read.
//
// POLICY/ADVISORY ONLY — nothing here touches score, conviction, sizing, or any rank key. The
// continuous turnover-aware cost machinery already ships (iter6: netEVR charges the round-trip
// per cycle, netVelocity amortizes it per day, the net-cost floor demotes at −500k, thin
// liquidity demotes at −3000). A second turnover penalty here would double-count it.

/// One documented net-negative-after-retail-costs short-horizon setup. Every number in
/// `evidence` is sourced + adversarially verified in RESEARCH_2026-07-02_week_horizon_velocity.md.
struct RefusedSetup: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let evidence: String
}

enum StockSageRefuseList {
    /// The coded refuse-list (research refuse-list items 1–7, verbatim substance).
    nonisolated static let all: [RefusedSetup] = [
        RefusedSetup(id: "naive-reversal",
                     title: "Naive short-term reversal as a standalone weekly strategy",
                     evidence: "Canonical reversal decile: +0.37%/mo GROSS becomes −1.28%/mo NET (t=−6.02) after ~1.65%/mo costs (Novy-Marx & Velikov, RFS 2016; verified 3-0)."),
        RefusedSetup(id: "standalone-pead",
                     title: "Standalone PEAD / earnings-drift trading",
                     evidence: "Costs consume 70–100% of paper PEAD profits; the drift is 0.04%/mo in liquid names vs 2.43%/mo in illiquid (untradeable) ones (verified 3-0)."),
        RefusedSetup(id: "anomaly-rotation",
                     title: "~90%-turnover monthly anomaly rotation",
                     evidence: "Round-trip costs exceed 1%/mo — more than the gross spread of all but two documented variants (verified)."),
        RefusedSetup(id: "overnight-roundtrip",
                     title: "Daily overnight/intraday round-trip harvesting",
                     evidence: "The overnight premium is real but the DAILY round-trip is cost-devoured — the source paper itself calls it cost-unattractive, and the NightShares ETF implementations shuttered (verified). Hold the overnight session via entry timing instead (already shipped, zero added turnover)."),
        RefusedSetup(id: "funding-seasonality",
                     title: "Crypto funding-rate-seasonality timing",
                     evidence: "Peak-to-trough intraday funding spread ~2.5bps vs 4–10bps/side retail taker fees; single mid-tier source, ~3-month sample — weak evidence AND a negative conclusion (verified)."),
        RefusedSetup(id: "illiquid-anomaly",
                     title: "Implementing any anomaly in the small/illiquid names where its paper edge lives",
                     evidence: "The paper edge concentrates exactly where retail fills cannot: real slippage in thin names is worse than any modeled cost; the tradable-liquidity version of the same anomaly is typically near zero (verified 3-0)."),
        RefusedSetup(id: "unhaircut-effect",
                     title: "Taking any published in-sample effect size at face value",
                     evidence: "Published predictors decay 26% out-of-sample and 58% post-publication (McLean & Pontiff, JF; verified 3-0 ×3) — haircut 50–60% BEFORE evaluating, then demand a net-of-cost simulation."),
    ]

    /// Three edges verified 2026-07-03 (RESEARCH_2026-07-03_candidate_edges.md lines 45-47) whose
    /// PUBLISHED gross edge lives on a substrate retail cannot hold (a short leg, extreme leverage,
    /// or a micro-cap tier where realistic round-trip costs run 10-20x the large-cap assumption) —
    /// NOT 1-5 day setups, so kept OUT of `all` (which is test-pinned at exactly 7 and whose
    /// `policyNote` prefix claims a 1-5 day horizon). Refused at ANY horizon instead.
    nonisolated static let antiEdges: [RefusedSetup] = [
        RefusedSetup(id: "vol-managed-momentum",
                     title: "Vol-managed / vol-timing overlay on momentum (WML)",
                     evidence: "The timing overlay is cheap and clears its own break-even, but it overlays the long-short WML factor retail cannot hold — a short leg plus up to ~864% leverage at the 99th pct of the scaled position; the long-only leverage-capped form is where most of the paper gain evaporates (Moreira-Muir; Barroso-Santa-Clara; refuted 2/3, 2026-07-03)."),
        RefusedSetup(id: "betting-against-beta",
                     title: "Betting-against-beta / low-volatility anomaly",
                     evidence: "Alpha is manufactured by micro-cap equal-weighting — realistic BAB cost is 60bps/mo standard (23bps/mo even after aggressive large-cap cost mitigation) vs a post-haircut gross of only ~16-23bps/mo, so net is NEGATIVE or economically trivial; the mechanism's core lever (lever up low-beta) is also unavailable to this engine (Frazzini-Pedersen; Novy-Marx-Velikov; fence #6). Own long-leg ablation NULL (RESEARCH_2026-07-03_low_beta_ablation.md)."),
        RefusedSetup(id: "max-lottery",
                     title: "MAX / lottery-demand effect as a long-only avoid-screen",
                     evidence: "The profitable leg is the SHORT leg in median-$6.47 / median-$21.5M-cap microcaps where realistic all-in round-trip costs run 100-300+bps, not the 13bps large-cap assumption; as a long-only large-cap avoid-screen both cost AND residual edge run ≈ 0 (Bali-Cakici-Whitelaw; fence #6/#7). Own large-cap ablation NULL (RESEARCH_2026-07-03_max_lottery_ablation.md)."),
    ]

    /// McLean & Pontiff decay — the mandatory haircut applied to ANY published effect size before
    /// it may even be EVALUATED for this engine (refuse-list #7). Policy constants for future
    /// signal ablations, not runtime multipliers — nothing in production math reads these.
    nonisolated static let outOfSampleDecay = 0.26
    nonisolated static let postPublicationDecay = 0.58

    /// The permanent honesty tail every surfacing of this policy must carry.
    nonisolated static let caveat = "A refuse-list is cost-avoidance, not alpha — the ~1–1.7%/mo it protects is money you stop burning, not money it earns. Policy from adversarially-verified research (2026-07-02); estimates from historical samples, never a promise."

    /// One-paragraph policy line for tooltips/help surfaces (the weekly-R sites use this).
    nonisolated static var policyNote: String {
        "REFUSED at the 1–5 day horizon (documented net-negative after retail costs): "
        + all.map(\.title).joined(separator: "; ")
        + ". Also refused at ANY horizon (verified anti-edges, 2026-07-03 — the published edge lives on a substrate retail cannot hold): "
        + antiEdges.map(\.title).joined(separator: "; ")
        + ". " + caveat
    }
}
