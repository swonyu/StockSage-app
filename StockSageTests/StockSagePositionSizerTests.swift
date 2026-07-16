import Testing
import Foundation
@testable import StockSage

// MARK: - Position-size calculator (pure)

struct StockSagePositionSizerTests {

    typealias PS = StockSagePositionSizer

    @Test func sizeRejectsNonFiniteInputsInsteadOfCrashing() {
        // "inf"/"infinity" in a field parses to +Infinity, passes `> 0`, and would trap at
        // Int(.infinity) — a hard crash that persists via UserDefaults. Now returns nil.
        #expect(PS.size(account: .infinity, riskFraction: 0.01, entry: 100, stop: 90) == nil)
        #expect(PS.size(account: 10_000, riskFraction: .infinity, entry: 100, stop: 90) == nil)
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: .infinity, stop: 90) == nil)
        #expect(PS.size(account: .nan, riskFraction: 0.01, entry: 100, stop: 90) == nil)
        // Boundary: raw == 2^63 (Double(Int.max) rounds UP to 2^63, so the old `<= Double(Int.max)`
        // guard passed and Int(2^63) still trapped). Int(exactly:) returns nil → no trap.
        #expect(PS.size(account: 9_223_372_036_854_775_808.0, riskFraction: 1, entry: 2, stop: 1) == nil)
        // A normal size is unchanged.
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 90)?.shares == 10)
    }

    @Test func summaryLineStatesSharesRiskAndHonestyCaveat() {
        // account 10000 · 1% · entry 100 · stop 90 → risk/share 10, budget 100 → 10 shares, $100 at risk, 10% acct.
        let ps = PS.size(account: 10000, riskFraction: 0.01, entry: 100, stop: 90)!
        #expect(ps.shares == 10)
        #expect(abs(ps.dollarsAtRisk - 100) < 1e-9)
        let line = PS.summaryLine(ps, riskPct: 1)
        #expect(line.contains("10 shares"))
        #expect(line.contains("$100"))
        #expect(line.lowercased().contains("loss"))      // honesty: sizes the loss
    }

    // Audit 2026-07-12 (ideas-card F1): `dollarsAtRisk` is in the SYMBOL's own currency, so a
    // hardcoded "$" mis-stated a non-USD row ~3.75× (SAR) / ~100× (pence). Threading `symbol`
    // renders the amount in its true currency; the default (symbol: "") stays "$" byte-identical.
    @Test func summaryLineLabelsAtRiskInTheSymbolsOwnCurrency() {
        let ps = PS.size(account: 10000, riskFraction: 0.01, entry: 100, stop: 90)!   // dollarsAtRisk == 100
        // No symbol → keeps the "$" form (backward-compatible default).
        #expect(PS.summaryLine(ps, riskPct: 1).contains("$100"))
        // A .SR symbol → the at-risk amount reads in SAR, NOT "$" (the exact bug).
        let sr = PS.summaryLine(ps, riskPct: 1, symbol: "2222.SR")
        #expect(sr.contains("SAR"))
        #expect(!sr.contains("$100"))
        // A USD symbol → still "$".
        #expect(PS.summaryLine(ps, riskPct: 1, symbol: "AAPL").contains("$100"))
        // Pence (.L): still labeled — the currency, never a bare "$" (the ~100× mislabel).
        #expect(PS.summaryLine(ps, riskPct: 1, symbol: "VOD.L").contains("GBP"))
    }

    // F1/F3 (2026-07-09): whole-share flooring can round a real setup to 0 shares while the idea
    // still holds a top rank slot — the sized-order line must say so. Straddle at the 1-share
    // boundary: $100 account, 1% risk → $1 budget. stop-distance 2 → budget/risk = 0.5 → floors
    // to 0 shares (unfundable); stop-distance 1 → budget/risk = 1.0 → exactly 1 share (fundable,
    // right at the boundary) — genuinely brackets the disclosure condition, not just "both sides
    // nonzero".
    // Audit 2026-07-13 (completeness-critic): the "% of acct" figure had the SAME currency-basis
    // bug the F1 fix left behind — `ps.pctOfAccount` is native-notional ÷ USD-account, so a SAR/pence
    // winner read ~3.75×/100× over. The view now passes the wave-2 #2 FX-corrected pct via
    // `pctOverride`; nil (default) keeps the raw figure byte-identical.
    // Hand-derived: account 10000 · 1% · entry 100 · stop 90 → 10 shares, notional 1000,
    // ps.pctOfAccount = 1000/10000·100 = 10%. A SAR name's USD-correct pct ≈ 1000 SAR ÷ 3.75 ÷
    // 10000 · 100 ≈ 2.67% → renders "3% of acct" at %.0f. 10% vs 3% straddle unambiguously.
    @Test func summaryLinePctOfAcctHonorsFXCorrectedOverride() {
        let ps = PS.size(account: 10000, riskFraction: 0.01, entry: 100, stop: 90)!
        #expect(ps.shares == 10)
        #expect(abs(ps.pctOfAccount - 10) < 1e-9)         // native-basis raw figure
        // Default (nil) → the raw 10% renders (backward-compatible / USD / untracked-FX).
        #expect(PS.summaryLine(ps, riskPct: 1).contains("10% of acct"))
        #expect(PS.summaryLine(ps, riskPct: 1, symbol: "AAPL").contains("10% of acct"))
        // Override → the FX-corrected pct renders instead of the ~3.75× native figure.
        let corrected = PS.summaryLine(ps, riskPct: 1, symbol: "2222.SR", pctOverride: 2.67)
        #expect(corrected.contains("3% of acct"))
        #expect(!corrected.contains("10% of acct"))
    }

    @Test func summaryLineDisclosesUnfundableAtZeroSharesButFundableJustAboveIt() {
        let unfundable = PS.size(account: 100, riskFraction: 0.01, entry: 100, stop: 98)!
        #expect(unfundable.shares == 0)
        let unfundableLine = PS.summaryLine(unfundable, riskPct: 1)
        #expect(unfundableLine.contains("0 shares"))
        #expect(unfundableLine.contains("Below the 1-share minimum at your account size"))
        #expect(unfundableLine.contains("not fundable as sized"))

        let fundable = PS.size(account: 100, riskFraction: 0.01, entry: 100, stop: 99)!
        #expect(fundable.shares == 1)
        let fundableLine = PS.summaryLine(fundable, riskPct: 1)
        #expect(fundableLine.contains("1 shares"))
        #expect(!fundableLine.contains("1-share minimum"))
        #expect(!fundableLine.contains("not fundable"))
    }

    @Test func sizesToTheRiskBudget() {
        // $10k account, 1% risk = $100 budget; $10 stop distance → 10 shares.
        let p = PS.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 90)!
        #expect(p.shares == 10)
        #expect(abs(p.dollarsAtRisk - 100) < 1e-9)
        #expect(abs(p.notional - 1000) < 1e-9)
        #expect(abs(p.pctOfAccount - 10) < 1e-9)
    }

    @Test func roundsDownNeverOverRisking() {
        // $100 budget ÷ $12 stop = 8.33 → 8 shares, $96 at risk (≤ budget).
        let p = PS.size(account: 10_000, riskFraction: 0.01, entry: 50, stop: 38)!
        #expect(p.shares == 8)
        #expect(abs(p.dollarsAtRisk - 96) < 1e-9)
        #expect(p.dollarsAtRisk <= 100)
    }

    @Test func worksForAShort() {
        // entry 50, stop 55 → risk/share 5; $100 budget → 20 shares.
        let p = PS.size(account: 10_000, riskFraction: 0.01, entry: 50, stop: 55)!
        #expect(p.shares == 20)
        #expect(abs(p.dollarsAtRisk - 100) < 1e-9)
    }

    @Test func entryEqualsStopIsNil() {
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 100) == nil)
    }

    @Test func invalidInputsAreNil() {
        #expect(PS.size(account: 0, riskFraction: 0.01, entry: 100, stop: 90) == nil)
        #expect(PS.size(account: 10_000, riskFraction: 0, entry: 100, stop: 90) == nil)
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: -1, stop: 90) == nil)
    }

    // ── First-real-trade review F3 (2026-07-16): FX-correct share count ─────────────────
    // Hand-derived from the sizer's own contract ("size so a stop-out loses ≈ riskFraction
    // of account"), never from the implementation.

    @Test func fxOverloadSizesTheStatedRiskFractionInTheSymbolsOwnCurrency() {
        // $10,000 account · 1% risk → $100 budget. 2222.SR entry 29.00, stop 28.50 →
        // risk/share 0.50 SAR. USDSAR = 3.75 → 1 SAR = $0.2666667.
        // Correct: budget 375 SAR ÷ 0.50 = 750 shares; at-risk 375 SAR ≈ $100 = the stated 1%.
        // (The old currency-mixed path gave 200 shares → 100 SAR ≈ $26.67 = 0.27%, not 1%.)
        let ps = PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50,
                         rawUnitToUSD: 1.0 / 3.75)!
        #expect(ps.shares == 750)
        #expect(abs(ps.dollarsAtRisk - 375) < 1e-9)                 // raw SAR — display converts
        #expect(abs(ps.dollarsAtRisk * (1.0 / 3.75) - 100) < 1e-9)  // = the stated 1% of $10k
        // pctOfAccount is now native÷native: notional 750×29 = 21,750 SAR of a 37,500 SAR
        // account = 58% — the same number the view's pctOfAccountUSD computes.
        #expect(abs(ps.pctOfAccount - 58) < 1e-9)
    }

    @Test func fxOverloadWithRateOneIsByteIdenticalToThePlainSizer() {
        let plain = PS.size(account: 10_000, riskFraction: 0.01, entry: 100, stop: 90)!
        let fx = PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 100, stop: 90,
                         rawUnitToUSD: 1)!
        #expect(plain == fx)
    }

    @Test func fxOverloadHandlesMinorUnitQuotesGenerically() {
        // Pence-quoted symbol: rawUnitToUSD = 0.01 GBP × 1.25 GBPUSD = $0.0125/penny.
        // $10,000 · 1% = $100 budget = 8,000 pence. Entry 500p, stop 460p → 40p/share
        // → 200 shares, at-risk 8,000 pence = £80 = $100 = the stated 1%. Hand-derived.
        let ps = PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 500, stop: 460,
                         rawUnitToUSD: 0.0125)!
        #expect(ps.shares == 200)
        #expect(abs(ps.dollarsAtRisk - 8_000) < 1e-9)
    }

    @Test func fxOverloadRejectsUnusableRatesInsteadOfGuessing() {
        // A zero/negative/non-finite rate must nil out — callers fall back to the plain
        // sizer for untracked FX; the overload never invents a conversion.
        #expect(PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 29, stop: 28.5, rawUnitToUSD: 0) == nil)
        #expect(PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 29, stop: 28.5, rawUnitToUSD: -1) == nil)
        #expect(PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 29, stop: 28.5, rawUnitToUSD: .infinity) == nil)
        #expect(PS.size(accountUSD: 10_000, riskFraction: 0.01, entry: 29, stop: 28.5, rawUnitToUSD: .nan) == nil)
    }

    @Test func mapOverloadResolvesTheSymbolsCurrencyFromTheRateMap() {
        // Same hand-derived 2222.SR case as the rawUnitToUSD test, resolved via the map:
        // SAR→USD 1/3.75 ⇒ 750 shares, 375 SAR at risk (= the stated 1% of $10k).
        let ps = PS.size(account: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50,
                         symbol: "2222.SR", fxRatesToUSD: ["SAR": 1.0 / 3.75])!
        #expect(ps.shares == 750)
        #expect(abs(ps.dollarsAtRisk - 375) < 1e-9)
    }

    @Test func mapOverloadFallsBackToThePlainSizerForUSDEmptyMapAndUntrackedCurrencies() {
        let plain = PS.size(account: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50)!
        // USD symbol: map ignored.
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50,
                        symbol: "AAPL", fxRatesToUSD: ["SAR": 1.0 / 3.75]) == plain)
        // Empty map: prior behavior, never guess.
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50,
                        symbol: "2222.SR", fxRatesToUSD: [:]) == plain)
        // Untracked currency (map lacks SAR): prior behavior.
        #expect(PS.size(account: 10_000, riskFraction: 0.01, entry: 29.00, stop: 28.50,
                        symbol: "2222.SR", fxRatesToUSD: ["JPY": 0.0065]) == plain)
    }
}
