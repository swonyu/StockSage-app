import Foundation

/// Probabilistic & Deflated Sharpe Ratio (Bailey & López de Prado). A backtest Sharpe is biased
/// UPWARD two ways: (1) short, skewed, fat-tailed return streams overstate it, and (2) when you scan
/// many symbols and surface the BEST, the winner's Sharpe is a selection-bias artifact. PSR haircuts
/// for (1); DSR additionally haircuts for (2) using how many strategies were tried. The honest bar is
/// DSR > 0.95. Every formula here is pure and python-verified against the reference before coding.
enum StockSageDeflatedSharpe {

    /// Standard normal CDF via erf.
    nonisolated static func normalCDF(_ x: Double) -> Double {
        0.5 * (1 + erf(x / 2.0.squareRoot()))
    }

    /// Inverse standard normal CDF — Acklam's rational approximation. Clamps p to the open interval
    /// (0,1) so the boundary doesn't blow up.
    nonisolated static func inverseNormalCDF(_ p: Double) -> Double {
        let pc = Swift.min(Swift.max(p, 1e-12), 1 - 1e-12)
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let pLow = 0.02425, pHigh = 1 - pLow
        if pc < pLow {
            let q = (-2 * Foundation.log(pc)).squareRoot()
            return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
        } else if pc <= pHigh {
            let q = pc - 0.5, r = q*q
            return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5]) * q / (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)
        } else {
            let q = (-2 * Foundation.log(1 - pc)).squareRoot()
            return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
        }
    }

    /// Skewness + NON-excess kurtosis (normal = 3) of a sample. nil if < 4 points or zero variance.
    nonisolated static func moments(_ xs: [Double]) -> (skew: Double, kurtosis: Double)? {
        let n = xs.count
        guard n >= 4 else { return nil }
        let mean = xs.reduce(0, +) / Double(n)
        let devs = xs.map { $0 - mean }
        let m2 = devs.map { $0*$0 }.reduce(0, +) / Double(n)
        guard m2 > 0 else { return nil }
        let m3 = devs.map { $0*$0*$0 }.reduce(0, +) / Double(n)
        let m4 = devs.map { $0*$0*$0*$0 }.reduce(0, +) / Double(n)
        let sd = m2.squareRoot()
        return (skew: m3 / (sd*sd*sd), kurtosis: m4 / (m2*m2))
    }

    /// PSR = P(true Sharpe > `benchmarkSharpe`) given the observed per-trade Sharpe, sample size,
    /// skew and non-excess kurtosis. 0 for < 2 observations.
    nonisolated static func probabilisticSharpe(observedSharpe sr: Double, nTrades n: Int,
                                                skew: Double, kurtosis: Double,
                                                benchmarkSharpe bench: Double = 0) -> Double {
        guard n >= 2 else { return 0 }
        let denom = Swift.max(1e-12, 1 - skew*sr + ((kurtosis - 1)/4)*sr*sr).squareRoot()
        return normalCDF((sr - bench) * Double(n - 1).squareRoot() / denom)
    }

    /// Expected MAXIMUM per-trade Sharpe across `trials` strategies whose Sharpes have variance
    /// `varTrialSharpe` — the bar a backtest winner must clear just to beat luck. 0 for ≤ 1 trial.
    nonisolated static func expectedMaxSharpe(trials N: Int, varTrialSharpe V: Double) -> Double {
        guard N > 1, V > 0 else { return 0 }
        let g = 0.5772156649015329   // Euler–Mascheroni
        let e = 2.718281828459045
        return V.squareRoot() * ((1 - g) * inverseNormalCDF(1 - 1.0/Double(N))
                                 + g * inverseNormalCDF(1 - 1.0/(Double(N) * e)))
    }

    nonisolated struct Result: Sendable, Equatable {
        let psr: Double          // P(Sharpe > 0), haircut for sample/skew/kurtosis
        let dsr: Double          // PSR vs the expected-max-Sharpe of `trials` (the selection-bias bar)
        let trials: Int
        nonisolated var passes: Bool { dsr > 0.95 }   // the honest "real edge" bar
    }

    /// Full deflated Sharpe. `varTrialSharpe` is the variance of the Sharpes across the `trials`
    /// scanned (0 or 1 trial → DSR == PSR, i.e. no selection-bias haircut).
    nonisolated static func deflated(observedSharpe sr: Double, nTrades n: Int,
                                     skew: Double, kurtosis: Double,
                                     trials: Int, varTrialSharpe: Double) -> Result {
        let psr = probabilisticSharpe(observedSharpe: sr, nTrades: n, skew: skew, kurtosis: kurtosis)
        let bar = expectedMaxSharpe(trials: trials, varTrialSharpe: varTrialSharpe)
        let dsr = probabilisticSharpe(observedSharpe: sr, nTrades: n, skew: skew, kurtosis: kurtosis,
                                      benchmarkSharpe: bar)
        return Result(psr: psr, dsr: dsr, trials: trials)
    }

    nonisolated static let caveat =
        "PSR/DSR haircut the Sharpe for short samples, skew/fat tails, and how many strategies were scanned to find this one — but they ASSUME the trials are roughly independent. A scan over correlated names violates that, so DSR is itself optimistic: it corrects the direction of the bias, not its exact size."
}
