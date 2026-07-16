import Foundation

// MARK: - Position-size calculator
//
// The one habit that separates survivors: size by the LOSS, not the hope. Decide
// how much of the account you'll lose if the stop is hit (e.g. 1%), and the share
// count falls out of the stop distance. This makes risk the input and size the
// output — never the reverse. Pure + tested. It sizes the loss; it promises nothing
// about the gain.

struct PositionSize: Sendable, Equatable {
    let shares: Int            // whole shares (rounded DOWN — never over-risk)
    let dollarsAtRisk: Double  // actual $ lost on a stop-out (floored shares × risk/share)
    let notional: Double       // shares × entry
    let pctOfAccount: Double    // notional ÷ account, %
    let riskPerShare: Double
}

enum StockSagePositionSizer {
    /// Size so a stop-out loses ≈ `riskFraction` of `account`. nil for invalid
    /// inputs (non-positive) or entry == stop (undefined risk → not infinite size).
    nonisolated static func size(account: Double, riskFraction: Double,
                                 entry: Double, stop: Double) -> PositionSize? {
        // .isFinite matters: a field of "inf"/"infinity" parses to +Infinity, which passes `> 0`
        // and would trap at Int(.infinity) below (a hard crash that persists via UserDefaults).
        guard account > 0, riskFraction > 0, entry > 0, stop > 0,
              account.isFinite, riskFraction.isFinite, entry.isFinite, stop.isFinite else { return nil }
        let riskPerShare = abs(entry - stop)
        guard riskPerShare > 0 else { return nil }
        let riskBudget = account * riskFraction
        // Int(exactly:) is the correct overflow guard: `raw <= Double(Int.max)` PASSES at raw == 2^63
        // (Double(Int.max) rounds UP to 2^63), then Int(2^63) still traps. Int(exactly:) returns nil there.
        let raw = (riskBudget / riskPerShare).rounded(.down)
        guard raw.isFinite, raw >= 0, let shares = Int(exactly: raw) else { return nil }
        let notional = Double(shares) * entry
        return PositionSize(
            shares: shares,
            dollarsAtRisk: Double(shares) * riskPerShare,
            notional: notional,
            pctOfAccount: notional / account * 100,
            riskPerShare: riskPerShare)
    }

    /// First-real-trade review F3 (2026-07-16): the share COUNT itself was currency-mixed —
    /// `size()` divides a USD risk budget by a risk-per-share in the symbol's RAW quote unit
    /// (SAR for .SR, pence for .L), so a 1%-of-account .SR plan floored to ~3.75× fewer shares
    /// and actually risked ~0.27% — the "at 1%/trade" claim was false by the FX rate. (The
    /// 2026-07-12/13 audits fixed only the LABELS; `ps` itself was documented unchanged.)
    /// This overload converts the account into raw quote units first, making every derived
    /// field self-consistent: shares hit the stated risk fraction, `dollarsAtRisk`/`notional`
    /// stay raw-native (displays already render them via `approxAmount`), and `pctOfAccount`
    /// becomes native÷native — now AGREEING with the view's FX-corrected `pctOfAccountUSD`.
    ///
    /// `rawUnitToUSD` = USD value of ONE raw quote unit (e.g. ~0.2667 for a SAR quote;
    /// 0.01 × GBPUSD for a pence quote). Pass 1 → byte-identical to `size()`. Callers with
    /// no tracked FX rate must call the plain `size()` (prior behavior), never guess a rate.
    nonisolated static func size(accountUSD: Double, riskFraction: Double,
                                 entry: Double, stop: Double,
                                 rawUnitToUSD: Double) -> PositionSize? {
        guard rawUnitToUSD > 0, rawUnitToUSD.isFinite else { return nil }
        return size(account: accountUSD / rawUnitToUSD, riskFraction: riskFraction,
                    entry: entry, stop: stop)
    }

    /// F3 wave-A (2026-07-16): map-convenience form for the PURE engine callers (TodayPlan,
    /// DecisionSnapshot, ExpectedValue's unfundable-row qualifier) that can't reach the view's
    /// FX resolver. Resolves the symbol's quote currency and per-raw-unit USD value here — ONE
    /// place — from a caller-supplied ccy→USD rate map (the view's `fxRatesToUSD` idiom).
    /// USD symbols, an empty map, or an untracked currency → the plain `size()` byte-identical
    /// (same never-guess-a-rate rule as the view helper).
    nonisolated static func size(account: Double, riskFraction: Double,
                                 entry: Double, stop: Double,
                                 symbol: String, fxRatesToUSD: [String: Double]) -> PositionSize? {
        if let rawUnit = rawQuoteUnitToUSD(symbol: symbol, fxRatesToUSD: fxRatesToUSD) {
            return size(accountUSD: account, riskFraction: riskFraction, entry: entry, stop: stop,
                        rawUnitToUSD: rawUnit)
        }
        return size(account: account, riskFraction: riskFraction, entry: entry, stop: stop)
    }

    /// F3 wave-B (2026-07-16): USD value of ONE raw quote unit for `symbol` given a ccy→USD
    /// rate map — the single resolution the map overload and the allocator's USD-normalized
    /// heat ledger both use. nil when the symbol quotes in USD or its currency isn't in the
    /// map (callers take the plain path / treat the ledger entry as already-USD — never guess).
    nonisolated static func rawQuoteUnitToUSD(symbol: String, fxRatesToUSD: [String: Double]) -> Double? {
        let ccy = StockSageCurrency.conversionCurrencyForSymbol(symbol)
        guard ccy != "USD", let rate = fxRatesToUSD[ccy] else { return nil }
        return StockSageCurrency.majorUnitValue(symbol: symbol, rawValue: 1) * rate
    }

    /// One-line "size it now" summary — shares, at-risk amount, % of account — with the
    /// honesty caveat that this sizes the LOSS at the stop, not a profit.
    /// F1/F3 (2026-07-09): whole-share flooring can round a real setup down to 0 shares at a
    /// small account (crypto rows especially — a $50k+ entry floors to 0 at a $10k account) while
    /// the idea still holds a #1 rank slot on the board — that was silent before this. `shares==0`
    /// now says so explicitly, in this SAME string every "Size it now" surface already renders
    /// (idea card, best-opportunity CTA, detail sheet) — no ranking/demotion change, display-only.
    /// Audit 2026-07-12 (ideas-card F1): `dollarsAtRisk` is in the SYMBOL's own currency (SAR for
    /// 2222.SR, pence for .L), so a hardcoded "$" over-/under-stated it ~3.75×/100×. `symbol` is now
    /// threaded so the amount renders in its true currency via the same tested `approxAmount` the
    /// idea-card "At risk" metric uses. `symbol` defaults to "" (→ "$") so any un-updated caller is
    /// byte-identical; every real caller passes it.
    ///
    /// Audit 2026-07-13 (completeness-critic): the neighbouring "% of acct" figure had the SAME
    /// currency-basis bug the F1 fix left behind — `ps.pctOfAccount` is native-notional ÷ USD-account
    /// (~3.75×/100× wrong for SAR/pence), and the wave-2 #2 FX-corrected `pctOfAccountUSD` was wired
    /// only into the leverage-warning FLAGS, never this rendered string. `pctOverride` lets the view
    /// pass the already-computed USD-correct pct; nil (default) keeps `ps.pctOfAccount` so USD /
    /// untracked-FX callers and the test-lock are byte-identical.
    nonisolated static func summaryLine(_ ps: PositionSize, riskPct: Double, symbol: String = "",
                                        pctOverride: Double? = nil) -> String {
        let atRisk = symbol.isEmpty ? String(format: "≈$%.0f", ps.dollarsAtRisk)
                                    : StockSageCurrency.approxAmount(ps.dollarsAtRisk, symbol: symbol)
        let base = String(format: "%d shares %@ at risk (%.0f%% of acct) at %.1f%%/trade — sizes the LOSS, not a profit promise.",
               ps.shares, atRisk, pctOverride ?? ps.pctOfAccount, riskPct)
        guard ps.shares == 0 else { return base }
        return base + " Below the 1-share minimum at your account size — not fundable as sized."
    }
}
