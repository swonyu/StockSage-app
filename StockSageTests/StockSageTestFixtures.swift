import Foundation
@testable import StockSage

// MARK: - SageFix — shared, RNG-free StockSage test fixtures
//
// ONE home for the price-history patterns and the per-idea builder that the
// StockSage test suite kept re-deriving inline (and, for `idea(...)`, copy-pasting
// privately into StockSageExpectedValueTests / StockSageAlertsTests). Consolidating
// them here means:
//   * Every golden-vector test draws from the SAME closed-form series, so an
//     expected value derived once stays derivable by hand (no hidden RNG, no
//     drift between files).
//   * The 15h autonomous loop's math-invariant harness has a stable, documented
//     input surface to pin Kelly / TSMOM / calibration math against within ε<1e-6.
//
// This is intentionally a PLAIN enum (NOT a `*Tests` type) so it carries no
// `@Test` methods and is freely importable by every test file. All series are
// newest-LAST (the convention every StockSageIndicators function expects).
enum SageFix {

    /// Explicit unit declarations for the named synthetic fixtures in this suite.
    /// This catalog is test data, not a production symbol parser. Unlisted plain
    /// labels are synthetic USD fixtures; unknown exchange suffixes remain nil.
    nonisolated static func fixtureDenomination(for symbol: String) -> StockSagePriceDenomination? {
        let declarations: [String: (String, Bool)] = [
            "BP.L": ("GBP", true), "SHEL.L": ("GBP", true), "VOD.L": ("GBP", true), "LLOY.L": ("GBP", true),
            "CSPX.L": ("USD", false), "BTC-EUR": ("EUR", false),
            "AGL.JO": ("ZAR", true), "NPN.JO": ("ZAR", true), "SBK.JO": ("ZAR", true), "EXAMPLE.JO": ("ZAR", true),
            "1120.SR": ("SAR", false), "1180.SR": ("SAR", false), "2222.SR": ("SAR", false), "^TASI.SR": ("SAR", false),
            "SAP.DE": ("EUR", false), "EURGBP=X": ("GBP", false), "EURUSD=X": ("USD", false), "GBPUSD=X": ("USD", false),
            "USDJPY=X": ("JPY", false), "USDSAR=X": ("SAR", false),
            "7203.T": ("JPY", false), "0700.HK": ("HKD", false), "600519.SS": ("CNY", false),
            "005930.KS": ("KRW", false), "RELIANCE.NS": ("INR", false), "RY.TO": ("CAD", false),
            "PETR4.SA": ("BRL", false), "COMI.CA": ("EGP", false), "QNBK.QA": ("QAR", false),
            "EMAAR.AE": ("AED", false), "DEWA.AE": ("AED", false), "AMXB.MX": ("MXN", false),
            "2330.TW": ("TWD", false), "BRK.A": ("USD", false)
        ]
        let declared: (String, Bool)
        if let named = declarations[symbol.uppercased()] { declared = named }
        else if !symbol.contains(".") && !symbol.hasSuffix("=X") { declared = ("USD", false) }
        else { return nil }
        return StockSagePriceDenomination(currencyCode: declared.0,
            rawUnitsPerMajor: declared.1 ? .hundredths : .major, provenance: .importedRecord)
    }

    nonisolated static func providerUnit(_ currency: String) -> StockSagePriceDenomination {
        StockSagePriceDenomination(currencyCode: currency, rawUnitsPerMajor: .major,
            provenance: .yahooChartMetadata)!
    }

    // MARK: Series — closed-form price patterns
    //
    // Each case is a DETERMINISTIC, closed-form generator: given `bars` you can
    // write down close[i] in one line, so any indicator's expected output over the
    // series is hand-derivable. No `Double.random`, no `Date()`-seeded noise — the
    // same `bars` always yields byte-identical arrays. `i` runs 0..<bars (oldest→newest).
    //
    //   .cleanUptrend       close[i] = 100 + 1.0·i           (strict +1/bar; ER→1, TSMOM>0)
    //   .momentumCrash      close[i] = 100 + i           for i ≤ 200
    //                       close[i] = 300 − 2·(i − 200)  for i > 200   (ramp to a 300 peak at
    //                                                                    bar 200, then −2/bar crash)
    //   .rangeBound         close[i] = 100 + 5·sin(2π·i/20)  (oscillates 95…105, period 20, mean 100)
    //   .approaching52wHigh close[i] = 100 + 0.2·i           (gentle monotone climb ⇒ the LAST bar
    //                                                         IS the running 52-week high; price/high = 1)
    //   .fallingKnife       close[i] = 300 − 0.5·i           (strict −0.5/bar, stays > 0 for ≤520 bars)
    //   .flat               close[i] = 100                   (constant; zero ATR, zero vol, TSMOM = 0)
    //
    // OHLC framing (so ATR / advisor paths are exercised, not just closes):
    //   open[i]  = close[i]                 (flat-open candle)
    //   high[i]  = close[i] + halfRange     low[i] = close[i] − halfRange
    //   halfRange = max(0.5, |close[i] − close[i−1]|)   (≥0.5 so even .flat has a non-degenerate
    //                                                    bar; first bar uses 0.5)
    // volume[i] = 1_000_000 (constant, non-zero so volumeConfirmation has real data to read).
    enum Series {
        case cleanUptrend
        case momentumCrash
        case rangeBound
        case approaching52wHigh
        case fallingKnife
        case flat

        /// close[i] for this pattern at bar `i` (0-based, oldest→newest).
        func close(_ i: Int) -> Double {
            switch self {
            case .cleanUptrend:       return 100.0 + 1.0 * Double(i)
            case .momentumCrash:      return i <= 200 ? 100.0 + Double(i)
                                                      : 300.0 - 2.0 * Double(i - 200)
            case .rangeBound:         return 100.0 + 5.0 * sin(2.0 * Double.pi * Double(i) / 20.0)
            case .approaching52wHigh: return 100.0 + 0.2 * Double(i)
            case .fallingKnife:       return 300.0 - 0.5 * Double(i)
            case .flat:               return 100.0
            }
        }
    }

    /// Deterministic OHLC history for `pattern` over `bars` bars (newest LAST). No RNG.
    /// `dates` are evenly spaced one calendar day apart ending at a FIXED epoch anchor
    /// (not `Date()`), so the whole struct is reproducible across runs and machines.
    static func history(_ pattern: Series, bars: Int) -> StockSagePriceHistory {
        precondition(bars >= 0, "bars must be non-negative")
        let closes = (0..<bars).map { pattern.close($0) }
        // Per-bar half-range = max(0.5, |Δclose|); first bar has no prior Δ → 0.5 floor.
        let highs: [Double] = closes.enumerated().map { i, c in
            let delta = i == 0 ? 0.0 : abs(c - closes[i - 1])
            return c + Swift.max(0.5, delta)
        }
        let lows: [Double] = closes.enumerated().map { i, c in
            let delta = i == 0 ? 0.0 : abs(c - closes[i - 1])
            return c - Swift.max(0.5, delta)
        }
        let opens = closes                                   // flat-open candle
        let volumes = Array(repeating: 1_000_000.0, count: bars)
        // Fixed anchor: 2025-01-01 00:00:00 UTC + one day per bar. Deterministic, never Date().
        let anchor = Date(timeIntervalSince1970: 1_735_689_600)
        let dates = (0..<bars).map { anchor.addingTimeInterval(Double($0) * 86_400) }
        return StockSagePriceHistory(symbol: "FIX",
                                     dates: dates, opens: opens, highs: highs,
                                     lows: lows, closes: closes, volumes: volumes)
    }

    // MARK: idea — closed-form per-idea builder
    //
    // Builds a `StockSageIdea` from the knobs tests vary (symbol, conviction, action,
    // regime) and derives a GEOMETRICALLY-CORRECT stop/target for the direction:
    //
    //   LONG  (.buy / .strongBuy / .hold):
    //     stop   = price − riskDistance    (below entry)
    //     target = price + rr·riskDistance (above entry)
    //
    //   SHORT (.sell / .reduce):
    //     stop   = price + riskDistance    (ABOVE entry — a stop-out is price rising)
    //     target = price − rr·riskDistance (BELOW entry — profit on the down move)
    //
    // In both cases |(target−price)/(price−stop)| == rr exactly.
    // Pass `rr: nil` for a no-defined-risk idea (stop/target nil).
    //
    // `spark` defaults to `[]` (review 2026-07-28 P2-fixture): every EXISTING caller that
    // doesn't pass it keeps the prior byte-identical behaviour (empty spark ⇒ dailyMove nil,
    // dailyReturns([]) ⇒ [] ⇒ correlationAdjustedWeights' `minLen >= 2` guard short-circuits).
    // Callers measuring StockSageCapitalAllocator.allocate's correlation stage should pass a
    // real spark, else that stage is silently skipped and the measurement is not the
    // production cost (see StockSagePerfProbeTests' whole-render probes).
    //
    // NOTE on `market` field: this helper sets `market: symbol` (matching the convention
    // in StockSageAlertsTests). StockSageExpectedValueTests uses `market: "M"` in its
    // own private helper, but asset-class dispatch (velocity / fast-lane) reads
    // `.symbol`, NOT `.market`, so the difference is inconsequential for classification.
    // Both conventions are preserved in their respective files until a future migration
    // aligns them; `SageFix.idea()` is not yet wired into those files.
    static func idea(_ symbol: String,
                     conviction: Double,
                     action: TradeAdvice.Action = .buy,
                     regime: TradeAdvice.Regime = .bullTrend,
                     rr: Double? = 2.0,
                     price: Double = 100.0,
                     riskDistance: Double = 10.0,
                     spark: [Double] = []) -> StockSageIdea {
        let stop: Double?
        let target: Double?
        if let rr {
            let isShort = (action == .sell || action == .reduce)
            if isShort {
                // Short: stop ABOVE entry, target BELOW entry
                stop   = price + riskDistance
                target = price - rr * riskDistance
            } else {
                // Long/hold: stop below entry, target above entry
                stop   = price - riskDistance
                target = price + rr * riskDistance
            }
        } else {
            stop = nil
            target = nil
        }
        return StockSageIdea(
            symbol: symbol, market: symbol, price: price,
            advice: TradeAdvice(action: action, conviction: conviction, regime: regime,
                                rationale: [], stopPrice: stop, targetPrice: target,
                                suggestedWeight: 0.05, caveat: "x"),
            spark: spark, denomination: SageFix.fixtureDenomination(for: symbol))
    }
}
