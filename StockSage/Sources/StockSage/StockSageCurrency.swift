import Foundation

// MARK: - Multi-currency exposure
//
// Convert a book of holdings (each in its own currency) into one base currency and show
// how the money is split ACROSS currencies — because a "diversified" book that's 70% in
// one foreign currency carries an FX risk the per-symbol view hides. Pure + deterministic.
// Honest: the rates are a snapshot; real FX moves are an un-modeled risk, and any holding
// whose currency has no rate is EXCLUDED (and named) rather than silently valued at zero.

struct CurrencyExposure: Sendable, Equatable, Identifiable {
    let currency: String
    let baseValue: Double   // converted into the base currency
    let weight: Double      // 0–1 of the (convertible) book
    var id: String { currency }
}

struct CurrencyBreakdown: Sendable, Equatable {
    let base: String
    let totalBase: Double
    let exposures: [CurrencyExposure]      // largest first
    let concentration: CurrencyExposure?   // largest NON-base exposure over the threshold, else nil
    let unpriced: [String]                 // currencies dropped for lack of a rate
    nonisolated var hasFXRisk: Bool { concentration != nil }
}

enum StockSageCurrency {
    /// Roll holdings up by currency, converted to `base` via `ratesToBase` (units of base per
    /// 1 unit of the currency; base itself is implicitly 1). Flags the largest non-base
    /// currency when it exceeds `concentrationThreshold` of the book. nil if nothing convertible.
    nonisolated static func breakdown(holdings: [(value: Double, currency: String)],
                                      ratesToBase: [String: Double], base: String,
                                      concentrationThreshold: Double = 0.25) -> CurrencyBreakdown? {
        var byCcy: [String: Double] = [:]
        var unpriced: Set<String> = []
        for h in holdings {
            let v = Swift.max(0, h.value)
            let rate: Double? = (h.currency == base) ? 1.0 : ratesToBase[h.currency]
            guard let r = rate, r > 0 else { unpriced.insert(h.currency); continue }
            byCcy[h.currency, default: 0] += v * r
        }
        let total = byCcy.values.reduce(0, +)
        guard total > 0 else { return nil }

        let exposures = byCcy
            .map { CurrencyExposure(currency: $0.key, baseValue: $0.value, weight: $0.value / total) }
            .sorted { $0.baseValue != $1.baseValue ? $0.baseValue > $1.baseValue : $0.currency < $1.currency }
        let concentration = exposures.first { $0.currency != base && $0.weight > concentrationThreshold }
        return CurrencyBreakdown(base: base, totalBase: total, exposures: exposures,
                                 concentration: concentration, unpriced: unpriced.sorted())
    }

    /// Best-effort trading currency for a symbol from its market suffix. Crypto (`-USD`),
    /// FX pairs (`=X`), and indices (`^`) map to `base`; an UNKNOWN suffix maps to the suffix
    /// itself, so it surfaces as "unpriced" rather than being silently mislabeled the base.
    /// Yahoo quotes some listings in a MINOR unit: London ".L" in PENCE and Johannesburg ".JO" in
    /// SA cents (ZAc) — a 400 quote is £4 / R4, not £400 / R400. Normalize a raw holding value to the
    /// listing's MAJOR currency unit (÷100 for those, unchanged otherwise) so the holding isn't
    /// inflated ~100× when rolled into the USD total/exposure. Add new cents-quoted exchanges here.
    private nonisolated static let minorUnitSuffixes: Set<String> = [".L", ".JO"]

    nonisolated static func majorUnitValue(symbol: String, rawValue: Double) -> Double {
        let s = symbol.uppercased()
        return minorUnitSuffixes.contains(where: { s.hasSuffix($0) }) ? rawValue / 100 : rawValue
    }

    nonisolated static func currencyForSymbol(_ symbol: String, base: String = "USD") -> String {
        let s = symbol.uppercased()
        if s.hasPrefix("^") || s.hasSuffix("-USD") { return base }   // index level / crypto priced in USD
        // FX pair "BASEQUOTE=X": holding it is exposure to its NON-base leg (long base vs
        // quote). EURUSD=X → EUR; USDJPY=X → JPY; a cross (EURGBP=X) → its base.
        if s.hasSuffix("=X") {
            let pair = String(s.dropLast(2))
            guard pair.count == 6 else { return base }
            let lead = String(pair.prefix(3)), trail = String(pair.suffix(3))
            if lead == base { return trail }
            if trail == base { return lead }
            return lead
        }
        guard let dot = s.lastIndex(of: "."), s.index(after: dot) < s.endIndex else { return base }
        let suffix = String(s[s.index(after: dot)...])
        return currencyForSuffix[suffix] ?? suffix
    }

    /// The DENOMINATION currency of a symbol's price×shares — the correct key for converting a
    /// holding's value TO `base` (USD). Differs from `currencyForSymbol` (the EXPOSURE leg, right
    /// for risk semantics) ONLY for FX pairs: a `…USD=X` pair's price is ALREADY in USD (its quote
    /// leg), so it must key as USD (rate 1) — using the exposure leg there re-multiplies an
    /// already-USD amount by the pair rate (rate²), inflating the value ~8–27%. Every
    /// portfolio-VALUATION path (headline total, allocation, currency-exposure, rebalance, open-heat)
    /// must key on THIS, not `currencyForSymbol`. Non-FX symbols fall through to `currencyForSymbol`.
    /// (Audit 2026-07-12 pass-2: extracted here from MarketsView so the 5 call sites share one tested
    /// accessor and can't drift — the bug was exactly one caller keying off the exposure leg.)
    nonisolated static func conversionCurrencyForSymbol(_ symbol: String, base: String = "USD") -> String {
        let s = symbol.uppercased()
        if s.hasSuffix("=X") {
            let pair = String(s.dropLast(2))
            guard pair.count == 6 else { return base }
            return String(pair.suffix(3))   // quote leg = trailing 3 chars (EURUSD=X → USD; USDJPY=X → JPY)
        }
        return currencyForSymbol(symbol, base: base)
    }

    /// L10N-01: format a figure in a SYMBOL's own quote currency (not converted) so it never
    /// misreads as USD. USD keeps the familiar "≈$188" prefix; any other currency renders
    /// "≈188 SAR"-style (code suffix) — a 1120.SR risk number in raw SAR shown with a bare "$"
    /// misreads ~3.75× (SAR/USD).
    nonisolated static func approxAmount(_ v: Double, symbol: String) -> String {
        let ccy = currencyForSymbol(symbol)
        // Audit 2026-07-12 (ideas-card wave-2 #3): every caller passes a RAW native-currency amount
        // (dollarsAtRisk / notional = shares × native price), so a pence-quoted listing (.L/.JO) arrives
        // in PENCE — normalize to the major unit (÷100) before formatting, or "4000p" renders as
        // "≈4000 GBP" (~100× overstated) instead of "≈40 GBP". Non-pence symbols are unaffected
        // (majorUnitValue is identity for them).
        let mv = majorUnitValue(symbol: symbol, rawValue: v)
        return ccy == "USD" ? String(format: "≈$%.0f", mv) : String(format: "≈%.0f %@", mv, ccy)
    }

    /// First-real-trade review journal leg (2026-07-16): signed P&L figure in the symbol's own
    /// quote currency — the same L10N-01 rule as `approxAmount` (a bare number beside USD-labeled
    /// surfaces misreads as dollars; a 2222.SR fill's "+150.00" is SAR), keeping the journal's
    /// signed 2-dp format. USD stays the familiar bare "+150.00" (byte-identical for the whole
    /// US universe); non-USD suffixes the code ("+150.00 SAR"). Pence-quoted raw amounts are
    /// normalized to major units exactly like `approxAmount` (a pence P&L labeled GBP must be pounds).
    nonisolated static func signedAmount(_ v: Double, symbol: String) -> String {
        let ccy = currencyForSymbol(symbol)
        let mv = majorUnitValue(symbol: symbol, rawValue: v)
        return ccy == "USD" ? String(format: "%+.2f", mv) : String(format: "%+.2f %@", mv, ccy)
    }

    /// ALERT-FMT-1: single shared adaptive price formatter — was quadruplicated byte-identically
    /// across `MarketsView.adaptivePrice`, `MarketsTodayActionsCard.adaptivePrice`,
    /// `StockSageTodayPlan.fmt`, and `StockSageTradePlan.adaptivePrice`. A SUB-DOLLAR value never
    /// rounds to "0.00" (a $0.0023 micro-cap/coin basis shows "0.0023") and two nearby sub-dollar
    /// levels never collapse to the same string (DOGE-USD stop 0.099 / target 0.104 must NOT both
    /// read "0.10", which bare `%.2f` does). ≥ $1 (or exactly 0) keeps the familiar 2 dp.
    nonisolated static func adaptivePrice(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1 || a == 0 { return String(format: "%.2f", v) }
        if a >= 0.01 { return String(format: "%.4f", v) }
        return String(format: "%.6f", v)                          // sub-cent → show real magnitude
    }

    private nonisolated static let currencyForSuffix: [String: String] = [
        "SR": "SAR", "L": "GBP", "DE": "EUR", "PA": "EUR", "T": "JPY", "HK": "HKD",
        "SS": "CNY", "KS": "KRW", "NS": "INR", "AX": "AUD", "SA": "BRL", "TO": "CAD",
        "SW": "CHF", "AS": "EUR", "MC": "EUR", "MI": "EUR", "ST": "SEK", "AD": "AED",
        "DU": "AED", "AE": "AED", "QA": "QAR", "CA": "EGP", "JO": "ZAR", "TW": "TWD", "SI": "SGD", "MX": "MXN",
    ]
}
