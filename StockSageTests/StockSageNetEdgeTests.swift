import Testing
import Foundation
@testable import StockSage

// MARK: - Cost-aware net edge (pure)

struct StockSageNetEdgeTests {
    typealias NE = StockSageNetEdge

    @Test func breakEvenWinRateIsTheAfterCostBar() {
        // Clean 3:1, zero cost → netRR 3 → break-even p* = 1/(1+3) = 0.25.
        let e = NE.evaluate(entry: 100, stop: 90, target: 130)!
        #expect(abs(e.netRR - 3) < 1e-9)
        #expect(abs((e.breakEvenWinRate ?? -1) - 0.25) < 1e-9)
        #expect(e.clearsCost(estWinProb: 0.40))      // 40% beats the 25% bar
        #expect(!e.clearsCost(estWinProb: 0.20))     // 20% below it → fails
        // Costs that exceed the target → netRR ≤ 0 → no break-even, never clears at any win rate.
        let dead = NE.evaluate(entry: 100, stop: 99, target: 100.5, spreadBps: 100, slippageBps: 100)!
        #expect(dead.netRR <= 0)
        #expect(dead.breakEvenWinRate == nil)
        #expect(!dead.clearsCost(estWinProb: 0.99))
    }

    @Test func wideSetupBarelyDentedByCosts() {
        // entry 100, stop 95, target 110 → gross 2:1. 30bps round-trip + $0.05 comm = $0.35/sh.
        let e = NE.evaluate(entry: 100, stop: 95, target: 110,
                            spreadBps: 20, slippageBps: 10, commissionPerShare: 0.05, winProb: 0.5)!
        #expect(abs(e.grossRR - 2) < 1e-9)
        #expect(abs(e.costPerShare - 0.35) < 1e-9)
        #expect(abs(e.netRR - 9.65 / 5.35) < 1e-9)        // 1.8037…
        #expect(abs(e.costAsPctOfReward - 0.035) < 1e-9)  // 3.5% of the target
        #expect(abs(e.netExpectancyR! - 0.43) < 1e-9)     // (.5·9.65 − .5·5.35)/5
        #expect(!e.costErodesEdge)
        #expect(e.verdict.contains("acceptable"))
    }

    @Test func thinScalpEatenAliveByCosts() {
        // entry 100, stop 99, target 101 → gross 1:1. 100bps + $0.10 = $1.10/sh > the $1 target.
        let e = NE.evaluate(entry: 100, stop: 99, target: 101,
                            spreadBps: 50, slippageBps: 50, commissionPerShare: 0.10)!
        #expect(abs(e.costPerShare - 1.10) < 1e-9)
        #expect(e.netRR <= 0)                              // net reward negative
        #expect(e.costErodesEdge)
        #expect(e.verdict.contains("Costs exceed the target"))
    }

    @Test func zeroCostsLeaveGrossUnchanged() {
        let e = NE.evaluate(entry: 100, stop: 90, target: 130)!
        #expect(abs(e.grossRR - 3) < 1e-9 && abs(e.netRR - 3) < 1e-9)
        #expect(e.costPerShare == 0 && e.costAsPctOfReward == 0)
        #expect(e.netExpectancyR == nil)                  // no winProb → nil
    }

    @Test func defaultCostsScaleByAssetClass() {
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").assetClass == "crypto")
        // 30 spread + 20 slippage + 20 round-trip taker fee (~0.1%/fill) = 70bps.
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").roundTripBps == 70)
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").takerFeeBps == 20)
        #expect(NE.defaultCosts(forSymbol: "EURUSD=X").assetClass == "FX")
        #expect(NE.defaultCosts(forSymbol: "EURUSD=X").roundTripBps == 7)
        #expect(NE.defaultCosts(forSymbol: "^GSPC").assetClass == "index")
        // RE-RATIFIED 2026-07-09 (owner lifted the cost-table gate): .SR = Tadawul tier, 60 bps
        // RT per RESEARCH_2026-07-03_current_era_costs.md §2 (fees alone 24–36 bps RT, 3/3) —
        // hand-derived: spread 20 + slippage 10 + fees 30 = 60. Was intl/30 (dangerous-direction
        // understatement on the Saudi-first core).
        #expect(NE.defaultCosts(forSymbol: "2222.SR").assetClass == "intl (Tadawul)")
        #expect(NE.defaultCosts(forSymbol: "2222.SR").roundTripBps == 60)
        // EM re-tier (2026-07-09; owner lifted the cost-table gate). RELIANCE.NS (India NSE)
        // moves off the flat intl 30 to 'intl (EM)' / 60bps per
        // RESEARCH_2026-07-03_current_era_costs.md §2 (60–100+bps small/illiquid/EM band;
        // per-order minimums alone 52–120bps RT, CONFIRMED 2/3) — hand-derived spread 20 +
        // slippage 10 + fees 30 = 60.
        #expect(NE.defaultCosts(forSymbol: "RELIANCE.NS").assetClass == "intl (EM)")
        #expect(NE.defaultCosts(forSymbol: "RELIANCE.NS").roundTripBps == 60)
        // Non-Saudi, non-EM intl stays at the ratified liquid default (research §2: 30 ACCURATE
        // for liquid intl) — the re-tier must not leak past the .SR/EM suffixes.
        #expect(NE.defaultCosts(forSymbol: "7203.T").assetClass == "intl")
        #expect(NE.defaultCosts(forSymbol: "7203.T").roundTripBps == 30)
        #expect(NE.defaultCosts(forSymbol: "AAPL").assetClass == "US large-cap")
        #expect(NE.defaultCosts(forSymbol: "AAPL").roundTripBps == 13)
        // Crypto's wider spread must eat strictly more of the same setup than a US large-cap.
        let cr = NE.defaultCosts(forSymbol: "BTC-USD"), us = NE.defaultCosts(forSymbol: "AAPL")
        let eCr = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: cr.spreadBps, slippageBps: cr.slippageBps)!
        let eUs = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: us.spreadBps, slippageBps: us.slippageBps)!
        #expect(eCr.netRR < eUs.netRR)
    }

    @Test func emSuffixTierRoutesEveryUniverseMarketToTheSame60bps() {
        // One representative symbol per EM suffix — universe members (StockSageQuoteService.swift
        // groups) except 500325.BO: a realistic BSE code with NO catalog entry today (the .BO
        // suffix is inert until one exists; any future .BO name lands on the HIGHER tier). Per EM
        // suffix — all must land on 'intl (EM)' / 60bps / takerFeeBps 30. Citation:
        // RESEARCH_2026-07-03_current_era_costs.md §2, same derivation as above.
        for sym in ["RELIANCE.NS", "500325.BO", "600519.SS", "PETR4.SA", "AMXB.MX",
                    "EMAAR.AE", "QNBK.QA", "COMI.CA", "NPN.JO"] {
            let c = NE.defaultCosts(forSymbol: sym)
            #expect(c.assetClass == "intl (EM)", "\(sym) assetClass")
            #expect(c.roundTripBps == 60, "\(sym) roundTripBps")
            #expect(c.takerFeeBps == 30, "\(sym) takerFeeBps")
        }
        // Developed-market suffixes stay on the liquid intl default — the EM branch must not
        // leak past its own suffix list.
        for sym in ["7203.T", "SHEL.L", "0700.HK", "SAP.DE", "RY.TO"] {
            let c = NE.defaultCosts(forSymbol: sym)
            #expect(c.assetClass == "intl", "\(sym) assetClass")
            #expect(c.roundTripBps == 30, "\(sym) roundTripBps")
        }
        // Korea/Taiwan: MSCI classifies both EM, but the universe's holdings there
        // (005930.KS Samsung, 2330.TW TSMC) trade at developed-grade microstructure — the
        // EM fee-band evidence cannot honestly be cited for them, so they're deliberately
        // excluded from `emSuffixes` and stay on the liquid intl default.
        #expect(NE.defaultCosts(forSymbol: "005930.KS").assetClass == "intl")
        #expect(NE.defaultCosts(forSymbol: "005930.KS").roundTripBps == 30)
        #expect(NE.defaultCosts(forSymbol: "2330.TW").assetClass == "intl")
        #expect(NE.defaultCosts(forSymbol: "2330.TW").roundTripBps == 30)
        // .SR precedent untouched — the EM branch must not shadow or relabel the
        // measured Tadawul tier.
        #expect(NE.defaultCosts(forSymbol: "2222.SR").assetClass == "intl (Tadawul)")
        #expect(NE.defaultCosts(forSymbol: "2222.SR").roundTripBps == 60)
        // Prefix-ordering guard: the `^` branch must keep beating both the .SR and EM checks.
        #expect(NE.defaultCosts(forSymbol: "^TASI.SR").assetClass == "index")
        #expect(NE.defaultCosts(forSymbol: "^TASI.SR").roundTripBps == 8)
        // US fallback untouched.
        #expect(NE.defaultCosts(forSymbol: "AAPL").assetClass == "US large-cap")
        #expect(NE.defaultCosts(forSymbol: "AAPL").roundTripBps == 13)
        #expect(NE.defaultCosts(forSymbol: "BRK-B").assetClass == "US large-cap")   // dash, no dot
        #expect(NE.defaultCosts(forSymbol: "BRK-B").roundTripBps == 13)
        // Direction assert (mirrors the crypto-vs-US check above): on an identical setup, EM
        // net R:R < liquid-intl net R:R < US net R:R (strictly worsening cost tiers).
        let em = NE.defaultCosts(forSymbol: "RELIANCE.NS")
        let intl = NE.defaultCosts(forSymbol: "7203.T")
        let us = NE.defaultCosts(forSymbol: "AAPL")
        let eEm = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: em.spreadBps, slippageBps: em.slippageBps, takerFeeBps: em.takerFeeBps)!
        let eIntl = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: intl.spreadBps, slippageBps: intl.slippageBps, takerFeeBps: intl.takerFeeBps)!
        let eUs2 = NE.evaluate(entry: 100, stop: 90, target: 130, spreadBps: us.spreadBps, slippageBps: us.slippageBps, takerFeeBps: us.takerFeeBps)!
        #expect(eEm.netRR < eIntl.netRR)
        #expect(eIntl.netRR < eUs2.netRR)
    }

    @Test func worksForShortsAndGuardsDegenerate() {
        // Short: entry 100, stop 105 (above), target 90 (below) → gross 10/5 = 2:1.
        let s = NE.evaluate(entry: 100, stop: 105, target: 90, spreadBps: 0, slippageBps: 0)!
        #expect(abs(s.grossRR - 2) < 1e-9)
        #expect(NE.evaluate(entry: 100, stop: 100, target: 110) == nil)  // zero risk
        #expect(NE.evaluate(entry: 100, stop: 95, target: 100) == nil)   // zero reward
    }

    @Test func netExpectancyRAtExtremeWinProbs() {
        let e0 = StockSageNetEdge.evaluate(entry: 100, stop: 90, target: 130, winProb: 0)!
        let e1 = StockSageNetEdge.evaluate(entry: 100, stop: 90, target: 130, winProb: 1)!
        #expect(abs(e0.netExpectancyR! - (-1.0)) < 1e-9)
        #expect(abs(e1.netExpectancyR! - 3.0) < 1e-9)
    }

    @Test func financingCostShrinksNetFiguresAndDefaultsToZero() {
        // entry 100, stop 90, target 130 (risk 10, reward 30, R:R 3), no spread/slippage/commission
        // — isolates financing. rate 10%/yr over EXACTLY 365 days -> financingCost = entry*rate = 10
        // (rate·days/365 collapses to rate). Hand-verified via a standalone Swift snippet before
        // writing this fixture: no-financing netRR=3.0/netExpectancyR=1.0; with-financing
        // netRR=1.0/netExpectancyR=0.0 (financing DOUBLES effective risk here: netRisk 10->20).
        let noFinancing = NE.evaluate(entry: 100, stop: 90, target: 130, winProb: 0.5)!
        #expect(abs(noFinancing.netRR - 3.0) < 1e-9)
        #expect(abs(noFinancing.netExpectancyR! - 1.0) < 1e-9)

        let withFinancing = NE.evaluate(entry: 100, stop: 90, target: 130,
                                        annualFinancingRate: 0.10, holdDays: 365, winProb: 0.5)!
        #expect(abs(withFinancing.netRR - 1.0) < 1e-9)
        #expect(abs(withFinancing.netExpectancyR! - 0.0) < 1e-9)
        #expect(withFinancing.costPerShare > noFinancing.costPerShare)

        // Explicit rate/days: 0 (the default) must match omitting them entirely — same cost,
        // same net figures (compared field-by-field with tolerance, not whole-struct `==`, since
        // `verdict` is a formatted String and costPct/breakEven derive through several divisions).
        let explicitZero = NE.evaluate(entry: 100, stop: 90, target: 130,
                                       annualFinancingRate: 0, holdDays: 0, winProb: 0.5)!
        #expect(abs(explicitZero.costPerShare - noFinancing.costPerShare) < 1e-9)
        #expect(abs(explicitZero.netRR - noFinancing.netRR) < 1e-9)
        #expect(abs(explicitZero.netExpectancyR! - noFinancing.netExpectancyR!) < 1e-9)

        // A negative rate/days (caller bug) must not GENERATE a subsidy — clamped to 0, same as
        // every other cost input in this function.
        let negativeInputs = NE.evaluate(entry: 100, stop: 90, target: 130,
                                         annualFinancingRate: -0.5, holdDays: -100, winProb: 0.5)!
        #expect(abs(negativeInputs.costPerShare - noFinancing.costPerShare) < 1e-9)
        #expect(abs(negativeInputs.netRR - noFinancing.netRR) < 1e-9)
        #expect(abs(negativeInputs.netExpectancyR! - noFinancing.netExpectancyR!) < 1e-9)
    }

    @Test func hairThinStopCapsNetFiguresAtTheSame50to1CeilingEvUses() {
        // entry 100, stop 99.99 (risk 0.01), target 110 (reward 10) → gross 1000:1, a degenerate
        // stop distance. netRR/netExpectancyR/breakEvenWinRate must be derived from the SAME 50:1
        // ceiling ev() applies, not the raw 1000:1 ratio — otherwise the cost gate (clearsCost)
        // becomes toothless (breakEvenWinRate collapsing toward 0) for exactly this setup.
        let e = NE.evaluate(entry: 100, stop: 99.99, target: 110,
                            spreadBps: 8, slippageBps: 5, winProb: 0.5)!
        #expect(abs(e.grossRR - 1000) < 1)          // grossRR itself stays the true uncapped ratio
        #expect(e.netRR < 10)                        // capped netRR ≈ 2.64, nowhere near the uncapped ≈70.5
        #expect(abs(e.netRR - 0.37 / 0.14) < 1e-6)
        #expect(e.netExpectancyR! < 20)               // capped ≈ 11.5, nowhere near the uncapped ≈486.5
        #expect(abs(e.netExpectancyR! - 11.5) < 1e-3)
        #expect(e.breakEvenWinRate! > 0.2)            // capped ≈ 0.275, not an absurd ≈0.014 bar
        #expect(!e.clearsCost(estWinProb: 0.05))      // a 5% win rate must NOT clear a real 50:1-capped bar
    }

    // MARK: - costsDisplayLabel (F-round-j FIX 1: DISPLAY-only band for crypto)

    @Test func costsDisplayLabelShowsFlatPointForNonCrypto() {
        // Hand-derived from the RATIFIED cost table (spec, not the code under test):
        // FX 4+3=7bps; index 5+3=8bps; generic intl 20+10=30bps; US large-cap 8+5=13bps;
        // .SR Tadawul 20+10+30fee=60bps and EM-suffix 20+10+30fee=60bps per the 2026-07-09
        // re-ratification (RESEARCH_2026-07-03_current_era_costs.md §2 + gated-scope §1) —
        // round-J's original fixture predated those tiers (caught by the re-land re-gate).
        #expect(NE.costsDisplayLabel(forSymbol: "EURUSD=X", advDollar: nil) == "~7bps est. FX")
        #expect(NE.costsDisplayLabel(forSymbol: "^GSPC", advDollar: nil) == "~8bps est. index")
        #expect(NE.costsDisplayLabel(forSymbol: "SAP.DE", advDollar: nil) == "~30bps est. intl")
        #expect(NE.costsDisplayLabel(forSymbol: "2222.SR", advDollar: nil) == "~60bps est. intl (Tadawul)")
        #expect(NE.costsDisplayLabel(forSymbol: "RELIANCE.NS", advDollar: nil) == "~60bps est. intl (EM)")
        #expect(NE.costsDisplayLabel(forSymbol: "AAPL", advDollar: nil) == "~13bps est. US large-cap")
    }

    @Test func costsDisplayLabelShowsTierAwareBandForCrypto() {
        // Hand-derived from the literal CryptoCostEstimate band constants (the wave-2 plan's
        // hand-derivation, restated in the source comment above cryptoCosts): major 21–54,
        // large 34–86, mid 70–180, thin 160–440. Tier selection: BTC/ETH → major; else by
        // thinBelow=2_000_000 / deepAbove=50_000_000 on advDollar; nil advDollar → mid (never
        // assumed deep — the honesty floor `cryptoTier` already documents and this test pins).
        #expect(NE.costsDisplayLabel(forSymbol: "BTC-USD", advDollar: nil) == "~21–54bps est. crypto")
        #expect(NE.costsDisplayLabel(forSymbol: "ETH-USD", advDollar: 1) == "~21–54bps est. crypto")   // major overrides ADV
        #expect(NE.costsDisplayLabel(forSymbol: "SOL-USD", advDollar: 60_000_000) == "~34–86bps est. crypto")     // large
        #expect(NE.costsDisplayLabel(forSymbol: "SOL-USD", advDollar: nil) == "~70–180bps est. crypto")           // unknown ADV → mid, not deep
        #expect(NE.costsDisplayLabel(forSymbol: "SOL-USD", advDollar: 10_000_000) == "~70–180bps est. crypto")    // mid
        #expect(NE.costsDisplayLabel(forSymbol: "ALT-USD", advDollar: 500_000) == "~160–440bps est. crypto")      // thin — the honesty-critical case
        // The flat 70bps default must NEVER appear for crypto now that the band exists — this is
        // the whole point of the fix (a thin alt is not the same risk as BTC).
        #expect(!NE.costsDisplayLabel(forSymbol: "ALT-USD", advDollar: 500_000).contains("70bps"))
    }

    @Test func costsDisplayLabelNeverChangesTheUnderlyingGateMath() {
        // FIX 1 is DISPLAY-only: defaultCosts (feeds evaluate/clearsCost/the gate) must stay
        // byte-identical regardless of what costsDisplayLabel renders.
        let before = NE.defaultCosts(forSymbol: "BTC-USD")
        _ = NE.costsDisplayLabel(forSymbol: "BTC-USD", advDollar: 500_000)
        let after = NE.defaultCosts(forSymbol: "BTC-USD")
        #expect(before == after)
        #expect(after.roundTripBps == 70)   // gate math untouched
    }
    // MARK: - F2 per-order commission minimums (OWNER-SIGNED 2026-07-10, "Ship F2" — TRIAGE
    // fastest-dollar UPDATE section; citation: IBKR tiered intl ≈ €1.30/order minimum, 26bps
    // one-way on a €500 XETRA order, RESEARCH_2026-07-03_current_era_costs.md §2).

    // Byte-identity pin: nil orderNotional must be EXACTLY the pre-F2 result even when a
    // minimum is supplied — the entire fence for every existing call site.
    @Test func evaluateWithNilNotionalIsByteIdenticalDespiteAMinimum() throws {
        let base = try #require(NE.evaluate(entry: 100, stop: 90, target: 140,
                                            spreadBps: 20, slippageBps: 10))
        let withMin = try #require(NE.evaluate(entry: 100, stop: 90, target: 140,
                                               spreadBps: 20, slippageBps: 10,
                                               perOrderMinimum: 1.30, orderNotional: nil))
        #expect(base == withMin)
    }

    // Hand-derived boundary straddle (spec, not code output): entry 100, risk 10, reward 40,
    // 30bps ⇒ bps cost 0.30/share; round-trip minimum per share = 2·1.30/shares.
    //   SMALL (4 sh, notional 400): 0.65 > 0.30 ⇒ MINIMUM DOMINATES; cost 0.30+0.65 = 0.95
    //     ⇒ netRR = (40−0.95)/(10+0.95) = 39.05/10.95.
    //   LARGE (1000 sh): 0.0026 ≪ 0.30 ⇒ BPS DOMINATE; cost 0.3026
    //     ⇒ netRR = 39.6974/10.3026 — a hair BELOW the bps-only 39.70/10.30 (increase-only).
    @Test func perOrderMinimumDominatesSmallOrdersAndVanishesOnLarge() throws {
        let small = try #require(NE.evaluate(entry: 100, stop: 90, target: 140,
                                             spreadBps: 20, slippageBps: 10,
                                             perOrderMinimum: 1.30, orderNotional: 400))
        #expect(abs(small.netRR - 39.05 / 10.95) < 1e-12)
        let large = try #require(NE.evaluate(entry: 100, stop: 90, target: 140,
                                             spreadBps: 20, slippageBps: 10,
                                             perOrderMinimum: 1.30, orderNotional: 100_000))
        #expect(abs(large.netRR - 39.6974 / 10.3026) < 1e-12)
        let bpsOnly = try #require(NE.evaluate(entry: 100, stop: 90, target: 140,
                                               spreadBps: 20, slippageBps: 10))
        // Increase-only in both regimes: sized cost can never be BELOW the bps-only cost.
        #expect(small.netRR < large.netRR)
        #expect(large.netRR < bpsOnly.netRR)
    }

    // Tier pins (ratified table + F2): intl tiers carry the cited 1.30 minimum; US/index/FX/
    // crypto are DELIBERATELY 0 (zero-commission era / percentage-fee venues).
    @Test func defaultCostsCarryPerOrderMinimumOnIntlTiersOnly() {
        #expect(NE.defaultCosts(forSymbol: "SAP.DE").perOrderMinimum == 1.30)
        #expect(NE.defaultCosts(forSymbol: "2222.SR").perOrderMinimum == 1.30)
        #expect(NE.defaultCosts(forSymbol: "RELIANCE.NS").perOrderMinimum == 1.30)
        #expect(NE.defaultCosts(forSymbol: "AAPL").perOrderMinimum == 0)
        #expect(NE.defaultCosts(forSymbol: "^GSPC").perOrderMinimum == 0)
        #expect(NE.defaultCosts(forSymbol: "EURUSD=X").perOrderMinimum == 0)
        #expect(NE.defaultCosts(forSymbol: "BTC-USD").perOrderMinimum == 0)
    }
}
