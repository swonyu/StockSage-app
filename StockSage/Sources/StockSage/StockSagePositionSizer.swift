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
    let dollarsAtRisk: Double  // RAW quote units lost at the stop (not necessarily USD)
    let notional: Double       // shares × entry, in RAW quote units
    let pctOfAccount: Double    // notional ÷ account, %
    let riskPerShare: Double
    var denomination: StockSagePriceDenomination? = nil

    nonisolated func withDenomination(_ value: StockSagePriceDenomination?) -> Self {
        var copy = self; copy.denomination = value; return copy
    }
}

enum StockSagePositionSizer {
    nonisolated static let unavailableFXMessage = "The price denomination or a required verified FX rate is unavailable. A USD account cannot be sized from a ticker assumption."

    /// Size so a stop-out loses ≈ `riskFraction` of `account`. nil for invalid
    /// inputs (non-positive) or entry == stop (undefined risk → not infinite size).
    /// All money inputs must already use the SAME currency and quote unit.
    nonisolated static func size(account: Double, riskFraction: Double,
                                 entry: Double, stop: Double) -> PositionSize? {
        // .isFinite matters: a field of "inf"/"infinity" parses to +Infinity, which passes `> 0`
        // and would trap at Int(.infinity) below (a hard crash that persists via UserDefaults).
        guard account > 0, riskFraction > 0, entry > 0, stop > 0,
              account.isFinite, riskFraction.isFinite, entry.isFinite, stop.isFinite else { return nil }
        let riskPerShare = abs(entry - stop)
        guard riskPerShare > 0 else { return nil }
        let riskBudget = account * riskFraction
        guard riskBudget.isFinite, riskBudget > 0 else { return nil }
        // Int(exactly:) is the correct overflow guard: `raw <= Double(Int.max)` PASSES at raw == 2^63
        // (Double(Int.max) rounds UP to 2^63), then Int(2^63) still traps. Int(exactly:) returns nil there.
        let raw = (riskBudget / riskPerShare).rounded(.down)
        guard raw.isFinite, raw >= 0, let shares = Int(exactly: raw) else { return nil }
        let notional = Double(shares) * entry
        let atRisk = Double(shares) * riskPerShare
        let pct = notional / account * 100
        guard notional.isFinite, atRisk.isFinite, pct.isFinite,
              shares == 0 || (notional > 0 && atRisk > 0 && pct > 0) else { return nil }
        return PositionSize(
            shares: shares,
            dollarsAtRisk: atRisk,
            notional: notional,
            pctOfAccount: pct,
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
    /// 0.01 × GBPUSD for a pence quote). A value of 1 must be real, never a missing-rate default.
    /// Missing foreign FX means no size; the plain overload requires same-currency inputs.
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
    /// USD symbols need no rate; missing/invalid foreign FX returns nil, never a 1:1 guess.
    /// The caller must supply rates eligible for its use (including freshness for new risk).
    nonisolated static func size(account: Double, riskFraction: Double,
                                 entry: Double, stop: Double,
                                 symbol: String, fxRatesToUSD: [String: Double],
                                 denomination: StockSagePriceDenomination? = nil) -> PositionSize? {
        guard let rawUnit = rawQuoteUnitToUSD(symbol: symbol, fxRatesToUSD: fxRatesToUSD, denomination: denomination) else { return nil }
        return size(accountUSD: account, riskFraction: riskFraction, entry: entry, stop: stop,
                    rawUnitToUSD: rawUnit)?.withDenomination(denomination)
    }

    /// F3 wave-B (2026-07-16): USD value of ONE raw quote unit for `symbol` given a ccy→USD
    /// rate map — the single resolution the map overload and the allocator's USD-normalized
    /// heat ledger both use. USD is explicitly 1; nil is missing/invalid FOREIGN FX.
    nonisolated static func rawQuoteUnitToUSD(symbol: String, fxRatesToUSD: [String: Double],
                                             denomination: StockSagePriceDenomination? = nil) -> Double? {
        // symbol remains an identity only, for source compatibility with callers.
        guard let denomination, let major = denomination.majorValue(rawValue: 1) else { return nil }
        let currency = denomination.currencyCode
        guard let rate = currency == "USD" ? 1 : fxRatesToUSD[currency],
              rate.isFinite, rate > 0 else { return nil }
        let unit = major * rate
        return unit.isFinite && unit > 0 ? unit : nil
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
        let atRisk = StockSageCurrency.approxAmount(ps.dollarsAtRisk, symbol: symbol, denomination: ps.denomination)
        let base = String(format: "%d shares %@ at risk (%.0f%% of acct) at %.1f%%/trade — sizes the LOSS, not a profit promise.",
               ps.shares, atRisk, pctOverride ?? ps.pctOfAccount, riskPct)
        guard ps.shares == 0 else { return base }
        return base + " Below the 1-share minimum at your account size — not fundable as sized."
    }
}

extension StockSagePositionSizer {
    /// Manual educational calculation: account and prices explicitly share a currency.
    /// This performs unit conversion only. There is no inferred FX or broker order.
    nonisolated static func recordedSize(accountMajor: Double, riskFraction: Double,
                                        entry: Double, stop: Double,
                                        denomination: StockSagePriceDenomination?) -> PositionSize? {
        guard accountMajor.isFinite, accountMajor > 0,
              riskFraction.isFinite, riskFraction > 0, riskFraction <= 1,
              let denomination, let majorPerRawUnit = denomination.majorValue(rawValue: 1),
              majorPerRawUnit > 0 else { return nil }
        let rawAccount = accountMajor / majorPerRawUnit
        guard rawAccount.isFinite, rawAccount > 0 else { return nil }
        return size(account: rawAccount, riskFraction: riskFraction, entry: entry, stop: stop)?.withDenomination(denomination)
    }
}
