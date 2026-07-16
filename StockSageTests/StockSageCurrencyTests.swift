import Testing
import Foundation
@testable import StockSage

// MARK: - Multi-currency exposure (pure)

struct StockSageCurrencyTests {
    typealias CC = StockSageCurrency

    private func exp(_ b: CurrencyBreakdown, _ ccy: String) -> CurrencyExposure? {
        b.exposures.first { $0.currency == ccy }
    }

    @Test func majorUnitValueNormalizesLondonPence() {
        // BP.L: 100 shares × 400 pence = 40,000 pence raw → £400, NOT £40,000 (~100× bug).
        #expect(CC.majorUnitValue(symbol: "BP.L", rawValue: 40_000) == 400)
        #expect(CC.majorUnitValue(symbol: "bp.l", rawValue: 40_000) == 400)        // case-insensitive
        // Johannesburg .JO is quoted in SA cents (ZAc) — same minor-unit convention as London.
        // NPN.JO: 300,000 ZAc raw → R3,000, NOT R300,000 (~100× bug).
        #expect(CC.majorUnitValue(symbol: "NPN.JO", rawValue: 300_000) == 3_000)
        #expect(CC.majorUnitValue(symbol: "npn.jo", rawValue: 300_000) == 3_000)   // case-insensitive
        // Non-minor-unit symbols are unchanged.
        #expect(CC.majorUnitValue(symbol: "AAPL", rawValue: 40_000) == 40_000)
        #expect(CC.majorUnitValue(symbol: "SAP.DE", rawValue: 1_000) == 1_000)
    }

    @Test func convertsAndWeightsWithoutFXFlagWhenSpread() {
        let b = CC.breakdown(holdings: [(1000, "USD"), (100, "EUR"), (50, "GBP")],
                             ratesToBase: ["EUR": 1.1, "GBP": 1.25], base: "USD")!
        #expect(abs(b.totalBase - 1172.5) < 1e-9)               // 1000 + 110 + 62.5
        #expect(abs(exp(b, "EUR")!.baseValue - 110) < 1e-9)
        #expect(abs(exp(b, "GBP")!.baseValue - 62.5) < 1e-9)
        #expect(abs(exp(b, "USD")!.weight - 1000.0 / 1172.5) < 1e-9)
        #expect(b.exposures.map(\.currency) == ["USD", "EUR", "GBP"])  // largest first
        #expect(b.concentration == nil && !b.hasFXRisk)         // no non-base > 25%
        #expect(b.unpriced.isEmpty)
    }

    @Test func flagsConcentrationInOneNonBaseCurrency() {
        let b = CC.breakdown(holdings: [(1000, "USD"), (1000, "EUR")],
                             ratesToBase: ["EUR": 1.0], base: "USD")!
        #expect(b.hasFXRisk)
        #expect(b.concentration?.currency == "EUR")
        #expect(abs(b.concentration!.weight - 0.5) < 1e-9)
    }

    @Test func excludesAndNamesUnpricedCurrencies() {
        let b = CC.breakdown(holdings: [(1000, "USD"), (100, "JPY")],
                             ratesToBase: [:], base: "USD")!
        #expect(abs(b.totalBase - 1000) < 1e-9)                 // JPY dropped, not zero-valued
        #expect(b.unpriced == ["JPY"])
        #expect(b.exposures.map(\.currency) == ["USD"])
    }

    @Test func currencyForSymbolFromSuffix() {
        #expect(CC.currencyForSymbol("AAPL") == "USD")       // US-listed
        #expect(CC.currencyForSymbol("BTC-USD") == "USD")    // crypto priced in USD
        #expect(CC.currencyForSymbol("2222.SR") == "SAR")
        #expect(CC.currencyForSymbol("BP.L") == "GBP")
        #expect(CC.currencyForSymbol("7203.T") == "JPY")
        #expect(CC.currencyForSymbol("FOO.ZZ") == "ZZ")      // unknown → suffix (surfaces as unpriced)
    }

    @Test func currencyForSymbolMapsDubaiFinancialMarketSuffix() {
        // EMAAR.AE / DEWA.AE are the app's own curated DFM universe tickers (.AD/.DU don't
        // price on Yahoo). Must resolve to "AED", not fall through to the literal suffix "AE".
        #expect(CC.currencyForSymbol("EMAAR.AE") == "AED")
        #expect(CC.currencyForSymbol("DEWA.AE") == "AED")
        #expect(CC.currencyForSymbol("emaar.ae") == "AED")   // case-insensitive
    }

    @Test func fxPairMapsToItsNonBaseLeg() {
        #expect(CC.currencyForSymbol("EURUSD=X") == "EUR")   // long EUR vs USD → EUR exposure
        #expect(CC.currencyForSymbol("USDJPY=X") == "JPY")   // base USD → the JPY leg
        #expect(CC.currencyForSymbol("USDSAR=X") == "SAR")
        #expect(CC.currencyForSymbol("EURGBP=X") == "EUR")   // cross (no USD) → its base
        #expect(CC.currencyForSymbol("BTC-USD") == "USD")    // crypto unaffected
    }

    // MARK: - L10N-01: approxAmount currency-suffix rendering
    //
    // Hand-derived per L10N-01 (critique fleet #2): a figure in a symbol's own quote currency
    // must not always render with "$" — a 1120.SR risk number in raw SAR read as USD misreads
    // ~3.75× (SAR/USD). USD keeps the "≈$" prefix form; every other currency uses a code suffix.

    @Test func approxAmountKeepsDollarPrefixForUSDSymbols() {
        #expect(CC.approxAmount(188, symbol: "AAPL") == "≈$188")
        #expect(CC.approxAmount(188.4, symbol: "BTC-USD") == "≈$188")   // crypto → USD, rounds to whole
    }

    @Test func approxAmountUsesCurrencyCodeSuffixForNonUSDSymbols() {
        #expect(CC.approxAmount(188, symbol: "1120.SR") == "≈188 SAR")  // the exact misread case (SAR: no pence)
        // Audit 2026-07-12 (wave-2 #3): a .L listing is quoted in PENCE, so a raw 400p at-risk amount
        // is £4, NOT £400. The prior assertion "≈400 GBP" ENCODED the ~100× bug — re-derived from the
        // spec (StockSageCurrency minorUnitSuffixes ÷100 for .L/.JO), not edited toward the old output.
        #expect(CC.approxAmount(400, symbol: "BP.L") == "≈4 GBP")
        #expect(CC.approxAmount(1000, symbol: "7203.T") == "≈1000 JPY")   // JPY: no minor-unit ÷100
    }

    @Test func guardsNothingConvertible() {
        #expect(CC.breakdown(holdings: [], ratesToBase: ["EUR": 1.1], base: "USD") == nil)
        #expect(CC.breakdown(holdings: [(100, "JPY")], ratesToBase: [:], base: "USD") == nil)
    }

    @Test func exposuresTieBreakDeterministicByCurrencyCode() {
        // GBP and EUR land on the exact same baseValue (500) — Dictionary iteration order is
        // randomized per-process, so without a secondary sort key the tie order (and thus which
        // one `concentration` would pick, if both were flagged) would be nondeterministic.
        let b = CC.breakdown(holdings: [(1000, "USD"), (500, "GBP"), (500, "EUR")],
                             ratesToBase: ["GBP": 1.0, "EUR": 1.0], base: "USD")!
        #expect(b.exposures.map(\.currency) == ["USD", "EUR", "GBP"])  // USD largest, then alphabetical tie-break

        // Same tie, but both non-base legs above threshold — `concentration` must deterministically
        // pick the alphabetically-first currency ("EUR"), not whichever the dictionary happened to yield.
        let b2 = CC.breakdown(holdings: [(100, "USD"), (500, "GBP"), (500, "EUR")],
                              ratesToBase: ["GBP": 1.0, "EUR": 1.0], base: "USD")!
        #expect(b2.concentration?.currency == "EUR")
    }

    @Test func concentrationJustUnder25PercentNotFlagged() {
        let b = StockSageCurrency.breakdown(
            holdings: [(1000, "USD"), (333.33, "EUR")],
            ratesToBase: ["EUR": 1.0], base: "USD", concentrationThreshold: 0.25)!
        #expect(b.concentration == nil)
        #expect(!b.hasFXRisk)
    }

    // MARK: - ALERT-FMT-1: shared adaptive price formatter (3-tier)
    //
    // Hand-derived from the SPEC shared by all four former duplicate sites (MarketsView,
    // MarketsTodayActionsCard, StockSageTodayPlan, StockSageTradePlan — now aliases onto this):
    // |v| >= 1 or == 0 -> %.2f ; |v| >= 0.01 -> %.4f ; else -> %.6f. Derived standalone via
    // `swift /tmp/derive_adaptive_price.swift` (not by calling this function):
    //   0.104 -> "0.1040", 0.099 -> "0.0990" (bare %.2f collapses BOTH to "0.10" — the bug
    //   ALERT-FMT-1 fixes: a DOGE-USD-class stop/target pair reading identical in an alert push).

    @Test func adaptivePriceSubDollarTierKeepsDogeStopAndTargetDistinct() {
        // The exact hand-derived case named in the finding.
        #expect(StockSageCurrency.adaptivePrice(0.104) == "0.1040")
        #expect(StockSageCurrency.adaptivePrice(0.099) == "0.0990")
        // Bare %.2f (the pre-fix behavior) collapses both to the same string — confirms the bug
        // this formatter exists to avoid, without re-deriving from the implementation.
        #expect(String(format: "%.2f", 0.104) == "0.10")
        #expect(String(format: "%.2f", 0.099) == "0.10")
        #expect(StockSageCurrency.adaptivePrice(0.104) != StockSageCurrency.adaptivePrice(0.099))
    }

    @Test func adaptivePriceTierBoundaries() {
        #expect(StockSageCurrency.adaptivePrice(0.0) == "0.00")        // == 0 → 2dp tier
        #expect(StockSageCurrency.adaptivePrice(1.0) == "1.00")        // >= 1 → 2dp tier
        #expect(StockSageCurrency.adaptivePrice(188.4) == "188.40")    // >= 1 → 2dp tier
        #expect(StockSageCurrency.adaptivePrice(0.9999) == "0.9999")   // < 1, >= 0.01 → 4dp tier
        #expect(StockSageCurrency.adaptivePrice(0.01) == "0.0100")     // boundary of 4dp tier (inclusive)
        #expect(StockSageCurrency.adaptivePrice(0.0099) == "0.009900") // just under 0.01 → 6dp tier
        #expect(StockSageCurrency.adaptivePrice(-0.104) == "-0.1040")  // sign preserved, tier by magnitude
    }

    // MARK: - Audit 2026-07-12 pass-2 — conversionCurrencyForSymbol (the rate² FX-pair fix)
    //
    // The DENOMINATION (quote) leg is the correct key for converting a holding TO USD. For a
    // `…USD=X` pair the price is ALREADY in USD (quote leg), so it must key as "USD" (rate 1) — the
    // EXPOSURE leg (currencyForSymbol) would key it as the base currency and re-multiply by the
    // pair rate (rate²), inflating the value ~8–27%. This pins the contract for all 5 valuation
    // call sites (headline total, allocation, currency-exposure, rebalance, open-heat).
    @Test func conversionCurrencyKeysOnQuoteLegNotExposureLeg() {
        // The bug's exact shape: EURUSD=X exposure leg is EUR, but its price is in USD.
        #expect(StockSageCurrency.currencyForSymbol("EURUSD=X") == "EUR")          // exposure leg (risk)
        #expect(StockSageCurrency.conversionCurrencyForSymbol("EURUSD=X") == "USD") // quote leg (valuation)
        #expect(StockSageCurrency.conversionCurrencyForSymbol("GBPUSD=X") == "USD")
        // USD-leading pair: quote leg is the non-USD currency, so it DOES need conversion (not rate²).
        #expect(StockSageCurrency.conversionCurrencyForSymbol("USDJPY=X") == "JPY")
        #expect(StockSageCurrency.conversionCurrencyForSymbol("USDSAR=X") == "SAR")
        // A cross (no USD leg) keys on its quote leg.
        #expect(StockSageCurrency.conversionCurrencyForSymbol("EURGBP=X") == "GBP")
        // Non-FX symbols fall through to currencyForSymbol unchanged (the two agree).
        for sym in ["AAPL", "1120.SR", "VOD.L", "BTC-USD", "^GSPC"] {
            #expect(StockSageCurrency.conversionCurrencyForSymbol(sym) == StockSageCurrency.currencyForSymbol(sym))
        }
        // Malformed =X (not a 6-char pair) is safe: base.
        #expect(StockSageCurrency.conversionCurrencyForSymbol("XYZ=X") == "USD")
    }

    // The honesty invariant the whole fix exists for: a single EURUSD=X holding priced at 1.08
    // must value at price×shares in USD (rate 1), NOT price×shares×1.08 (rate²). Proven at the
    // accessor level — the rate the valuation path looks up is keyed by conversionCurrencyForSymbol,
    // and "USD" is subtracted from the FX-rate set / maps to 1.0, so no second multiply happens.
    @Test func usdQuotedFXPairValuesAtRateOneNotRateSquared() {
        let holding = "EURUSD=X"
        // The valuation key is USD → the FX-rate table (which excludes/1.0-maps USD) applies rate 1.
        #expect(StockSageCurrency.conversionCurrencyForSymbol(holding) == "USD")
        // Contrast: the OLD (buggy) key was the exposure leg EUR, which the FX table would have
        // multiplied by the EURUSD rate — the rate² inflation. This assertion documents the bug's
        // signature so a regression (reverting the key) fails here.
        #expect(StockSageCurrency.currencyForSymbol(holding) != StockSageCurrency.conversionCurrencyForSymbol(holding))
    }

    // Journal leg of the first-real-trade review (2026-07-16). Hand-derived from the L10N-01
    // rule, never the implementation: USD rows keep the exact bare signed format the journal
    // always showed; non-USD suffixes the quote-currency code; pence raw amounts normalize
    // to major units (−4000 raw pence = −£40.00).
    @Test func signedAmountLabelsNonUSDAndKeepsUSDByteIdentical() {
        #expect(StockSageCurrency.signedAmount(150, symbol: "AAPL") == "+150.00")
        #expect(StockSageCurrency.signedAmount(-27.5, symbol: "AAPL") == "-27.50")
        #expect(StockSageCurrency.signedAmount(150, symbol: "2222.SR") == "+150.00 SAR")
        #expect(StockSageCurrency.signedAmount(-4000, symbol: "SHEL.L") == "-40.00 GBP")
    }
}
