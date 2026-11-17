import Foundation

// MARK: - US dividend-withholding honesty note (Saudi investor)
//
// A Saudi-resident holder of US shares does not get the headline dividend yield in hand — the
// IRS taxes the payment at source before it ever reaches a foreign broker. This is a plain-text
// disclosure, not a calculation: the app must never compute an after-tax figure per position
// (it has no reliable per-symbol tax-residency/treaty state), so this returns one fixed string
// for any US-domiciled symbol and nil everywhere else (honesty floor — nil, not a guess).
//
// Sources: IRC §871(a) imposes a flat 30% US withholding on FDAP income (incl. dividends) paid
// to nonresident aliens, collected at the paying agent via Form 1042-S/W-8BEN; there is no
// US–Saudi Arabia income-tax treaty in force (2026), so no reduced treaty rate applies — the
// statutory 30% stands. US-source capital gains are generally NOT subject to US tax for a
// nonresident alien with no US trade/business (IRC §871(a)(2) taxes only US-person-equivalent
// gains, inapplicable here).

enum StockSageWithholdingNote {
    /// nil for non-US symbols (`.SR` / any dotted-suffix exchange, incl. index tickers like
    /// `^TASI.SR`) — same suffix logic as `StockSageCurrency.currencyForSymbol`: US names carry
    /// no exchange suffix in this universe.
    nonisolated static func note(for symbol: String) -> String? {
        guard StockSageCurrency.currencyForSymbol(symbol) == "USD" else { return nil }
        let s = symbol.uppercased()
        if s.hasPrefix("^") || s.hasSuffix("-USD") || s.hasSuffix("=X") { return nil }
        return "US dividends paid to Saudi tax residents carry 30% US withholding (no US–Saudi income-tax treaty; IRS nonresident-alien rules) — a dividend yield nets ≈70% of the headline figure. Capital gains on US shares are generally NOT US-taxed for nonresident aliens. Informational only — not tax advice."
    }
}
