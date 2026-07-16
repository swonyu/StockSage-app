import Foundation

// MARK: - TradeAdvice
//
// A concrete, actionable recommendation derived from a price history — the
// "what / when / how much / when-to-sell" the owner asked for. Honest by
// construction: every field is a RULES-BASED suggestion with a conviction and a
// permanent caveat, never a guarantee. Evidence behind each rule:
// MARKETS_INTELLIGENCE_RESEARCH.md.
struct TradeAdvice: Sendable, Equatable {
    enum Action: String, Sendable {
        case strongBuy = "Strong Buy"
        case buy       = "Buy"
        case hold      = "Hold"
        case avoid     = "Avoid"   // choppy / no edge — stand aside
        case reduce    = "Reduce"
        case sell      = "Sell"
    }
    enum Regime: String, Sendable {
        case bullTrend = "Bullish trend"
        case bearTrend = "Bearish trend"
        case range     = "Range-bound"
    }

    let action: Action
    /// 0–1 rules-based conviction — the strength of the signal confluence, NOT a
    /// probability of profit.
    let conviction: Double
    let regime: Regime
    /// The indicators that fired, in plain language.
    let rationale: [String]
    /// Protective stop price (ATR-based when highs/lows are available), if long-biased.
    let stopPrice: Double?
    /// Profit target at ≥2:1 reward:risk vs the stop, if long-biased.
    let targetPrice: Double?
    /// Suggested fraction of the book to size into this idea (0–1): fixed-fractional
    /// risk ÷ stop distance, scaled by conviction, hard-capped.
    let suggestedWeight: Double
    /// Always present — the honest reminder.
    let caveat: String
    /// The ATR multiple used for the stop: 2.0 by default, widened to 2.5 for high-volatility
    /// names (so normal noise doesn't whipsaw the trade out) and tightened to 1.5 for calm ones.
    var stopMultiplier: Double = 2.0
    /// Plain-language reason for the stop width (e.g. "2.5×ATR — sized for 72% volatility"),
    /// surfaced in the idea detail. nil when volatility wasn't available.
    var stopReason: String? = nil
    /// RANKING_BACKLOG #12 (reframed 2026-07-01, pure observer — see `StockSageIndicators.
    /// timeframeConfluence`): true when the ~1-month (short), daily-resolved (score), and
    /// ~1-year 12-1 (long) trends all agree. NEVER an input to `score`/`conviction`/sizing —
    /// a display-only tie-breaker/badge, false when unknown (short history) or genuinely
    /// disagreeing. Byte-compat: trailing defaulted, so every existing call site is unaffected.
    var timeframeAligned: Bool = false
    /// Plain-language confluence note ("Three-timeframe confluence — 1-month, daily, and
    /// 1-year trends all up"), appended to `rationale` only when `timeframeAligned`. nil
    /// otherwise (including "unknown," e.g. short history — never claims agreement it can't see).
    var confluenceNote: String? = nil
}

// MARK: - StockSageAdvisor
//
// Combines a few complementary, evidence-backed signals (trend, momentum, MACD,
// RSI) UNDER a regime filter (efficiency ratio) into a single `TradeAdvice`. The
// regime decides whether RSI extremes are reversal signals (range) or noise
// (trend) — the meta-rule that stops us fighting the tape. Pure + deterministic.
enum StockSageAdvisor {
    /// Risk budgeted per idea (fraction of equity lost if the stop is hit).
    /// 1% — evidence: smoother equity curve, materially lower max drawdown.
    nonisolated static let riskPerTrade = 0.01
    /// No single idea may be sized above this share of the book, whatever the math says.
    nonisolated static let maxWeight = 0.20
    /// Cap on the SUMMED contribution of the trend-correlated signal family (trend, momentum,
    /// MACD, volume, vol-adjusted-momentum, relative-strength). These all measure ONE underlying
    /// trend factor (stock momentum is largely spanned by factor momentum — Ehsani & Linnainmaa
    /// 2022), so summing them as if independent inflates conviction (raw max ≈ 0.83) and over-
    /// sizes correlated bets — the variance drag Kelly punishes. 0.65 = the CORE trend triad
    /// (trend 0.40 + momentum 0.15 + MACD 0.10); the redundant TERTIARY confirmations
    /// (volume + relative-strength + vol-adjusted-momentum, ≈0.18) can no longer pile on top.
    /// Tuned so a fully-confirmed clean uptrend still clears Strong-Buy after the RSI-extended
    /// nudge (0.65 − 0.10 = 0.55 > 0.50), not just barely reaches it.
    nonisolated static let trendFamilyCap = 0.65

    /// Relative-strength nudge (±0.08 vs the benchmark) — DISABLED 2026-06-27 on parsimony
    /// (DSR=0, partly redundant w/ the absolute trend term; the documented edge is out-
    /// performance but the ablation showed it added no net drawdown/return improvement).
    /// Code is PRESERVED, not deleted: flip to `true` to re-enable the exact prior behavior.
    /// If revived, consider a LOCAL TASI/sector benchmark rather than the S&P (this app is
    /// Saudi-first). A `var` (not `let`) so a test can temporarily flip it on to prove the
    /// term still works when re-enabled, then reset it; default OFF is the shipped behavior.
    nonisolated(unsafe) static var relativeStrengthEnabled = false

        /// Turn-of-month (TOM) ranking tilt — ACTIVATED 2026-07-09 by explicit owner direction
        /// ("WIRE ACTIVATE"), after the same-day research chain (probe → sweep → max-t → holdout →
        /// LOOMO → nonparam → exact sign-flip → cost-stress → LOSO, all indexed in research/INDEX.md)
        /// recorded the evidence as INTERIM/underpowered on the 1y cache horizon.
        ///
        /// RATIFIED 2026-07-09 (later same day, owner chose option "a" with the powered evidence in
        /// hand): the multi-year panel (10 ETFs × 10y, n=120 — RESEARCH_2026-07-09_tom_etf_multiyear_panel.md)
        /// returned POWERED NULL (locked-config DSR 0.831, effect ≈0 in 2021–26), and the owner ruled
        /// KEEP — the tilt stays on as a deliberate, DISCLOSED owner preference, explicitly NOT an
        /// evidence promotion. It stays harm-bounded by construction: capped ±0.03, ≥3-sample
        /// reliability-weighted, |t|<1 noise-gated, direction-aware, and disclosed in the ideas header.
        /// The TOM research lane's multi-year exit clause is ANSWERED (lane closed).
        ///
        /// Gates ONLY `StockSageExpectedValue.seasonalityRankBonus` — a small additive rank tilt in
        /// `rankByEV` + `bestOpportunity` (velocity surfaces exempt). There is intentionally still NO
        /// TOM branch in `advise(...)`: conviction, stop, target, and sizing are untouched. Flipping
        /// this default is an owner decision (state pinned by StockSageTomGateTests).
        nonisolated(unsafe) static var turnOfMonthEnabled = true

    nonisolated static let caveat = "Rules-based & educational — not a guarantee or financial advice. Markets are uncertain; size small and honor your stop."

    /// Advice straight from a fetched candle history — wires the live OHLC feed
    /// (`StockSageQuoteService.fetchHistory`) to the rules below, ATR stops included.
    nonisolated static func advise(history: StockSagePriceHistory,
                                   benchmark: StockSagePriceHistory? = nil) -> TradeAdvice {
        advise(closes: history.closes, highs: history.highs, lows: history.lows,
               volumes: history.volumes, benchmarkCloses: benchmark?.closes)
    }

    /// Advice from a daily close history (+ optional highs/lows for ATR stops, optional REAL
    /// volumes for participation confirmation, and optional benchmark closes for relative
    /// strength). Series are newest-last. Conservative "Hold" when history is too short.
    /// HONESTY NOTE: the `volumes` and `benchmarkCloses` terms are gated on those inputs (nil ⇒
    /// not applied). But passing `highs`/`lows` ALSO enables the ATR stop and the volatility-
    /// adjusted-momentum nudge, and the stop width always scales with realized volatility derived
    /// from `closes` — so a close-only call and a highs/lows call are NOT identical, and any
    /// caller that supplies highs/lows (including the backtester) gets the fuller signal. (Only
    /// `stopTarget` with `realizedVol: nil` is byte-identical to the legacy 2-ATR stop.)
    nonisolated static func advise(closes: [Double], highs: [Double]? = nil, lows: [Double]? = nil,
                                   volumes: [Double]? = nil, benchmarkCloses: [Double]? = nil) -> TradeAdvice {
        guard closes.count >= 30, let price = closes.last, price > 0 else {
            return TradeAdvice(action: .hold, conviction: 0, regime: .range,
                               rationale: ["Not enough price history to judge."],
                               stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: caveat)
        }

        // Real periods only — never substitute a shorter window for the 200DMA
        // (with <200 bars `min(200,count)` made the 50DMA and 200DMA identical and
        // silently disabled the heaviest trend signal).
        let sma50  = closes.count >= 50  ? StockSageIndicators.sma(closes, period: 50)  : nil
        let sma200 = closes.count >= 200 ? StockSageIndicators.sma(closes, period: 200) : nil
        let rsi    = StockSageIndicators.rsi(closes) ?? 50
        let macd   = StockSageIndicators.macd(closes)
        let er     = StockSageIndicators.efficiencyRatio(closes) ?? 0
        let momPeriod = min(closes.count - 1, 126)
        let mom    = StockSageIndicators.returnOverPeriod(closes, period: momPeriod) ?? 0
        var atr: Double? = nil
        if let highs, let lows { atr = StockSageIndicators.atr(highs: highs, lows: lows, closes: closes) }

        var rationale: [String] = []
        var score = 0.0   // directional, roughly -1 … +1

        // Trend (heaviest weight — the most robust documented edge).
        if let s50 = sma50, let s200 = sma200 {
            if price > s50, s50 > s200 { score += 0.40; rationale.append("Uptrend — price > 50DMA > 200DMA") }
            else if price < s50, s50 < s200 { score -= 0.40; rationale.append("Downtrend — price < 50DMA < 200DMA") }
            else if price > s200 { score += 0.15; rationale.append("Above the 200DMA (long-term bullish)") }
            else { score -= 0.15; rationale.append("Below the 200DMA (long-term bearish)") }
        } else if let s50 = sma50 {
            // 50–200 bars: a real 50DMA but no true 200DMA — a lighter, honest read.
            if price > s50 { score += 0.20; rationale.append("Above the 50DMA (uptrend, <200 bars history)") }
            else { score -= 0.20; rationale.append("Below the 50DMA (downtrend, <200 bars history)") }
        }
        // Momentum (~6-month when the full 126-bar lookback is available; for shorter histories
        // (closes.count between the 30-bar minimum and 126) `momPeriod` is the true, shorter
        // window actually used above — the rationale must say so honestly rather than always
        // claiming "6-month" (same honesty treatment as the degraded-SMA branch above).
        // F37: threshold raised from 100 to 120. 100 bars ≈ 4.6 months, which is not "6-month";
        // only momPeriod >= 120 (≥ ~5.5 months, ~one trading week short of 126) earns that label.
        let momWindowLabel = momPeriod >= 120 ? "6-month momentum" : "momentum (\(momPeriod)-day window)"
        if mom > 0 { score += 0.15; rationale.append(String(format: "+%.0f%% \(momWindowLabel)", mom)) }
        else if mom < 0 { score -= 0.15; rationale.append(String(format: "%.0f%% \(momWindowLabel)", mom)) }
        // MACD trend confirmation — weighted LIGHTER than independent momentum
        // (±0.10 vs ±0.15): the research calls it a confirmation signal that
        // "over-signals alone" and it's the most redundant with the 0.40 trend term,
        // so it shouldn't stack at equal weight (independent calibration review).
        if let m = macd {
            if m.histogram > 0 { score += 0.10; rationale.append("MACD above signal (bullish)") }
            else if m.histogram < 0 { score -= 0.10; rationale.append("MACD below signal (bearish)") }
        }
        // Trend-FAMILY de-duplication (see `trendFamilyCap`): trend + momentum + MACD here, plus
        // volume / vol-adj-momentum / relative-strength below, are all the SAME trend factor.
        // Track their summed contribution so we can cap it (the RSI mean-reversion / nudge terms
        // and the TSMOM veto are deliberately EXCLUDED — they're independent).
        let trendCore = score   // = trend + momentum + MACD

        // Regime: trending vs choppy decides how to read RSI.
        let trending = er >= 0.30   // 30% trailing excess return separates trending from ranging (TSMOM regime gate; Jegadeesh-Titman 1993)
        var rangeOversoldBounce = false   // a legit mean-reversion buy in a range (vs a trend-follow trap)
        if !trending {
            if rsi < 30 {
                // Buy the DIP only in an intact 12-1 uptrend. An oversold name making fresh lower
                // lows is a falling knife, not a bounce — crediting it averages into a structural
                // decline (negative expectancy). trendOK nil (<253 bars) → preserve legacy behavior.
                if Self.oversoldBounceIsBuyable(closes) {
                    score += 0.25; rangeOversoldBounce = true
                    rationale.append(String(format: "RSI %.0f oversold in an intact uptrend — buy-the-dip", rsi))
                } else {
                    rationale.append(String(format: "RSI %.0f oversold but in a 12-1 downtrend — knife, not a dip (no credit)", rsi))
                }
            }
            else if rsi > 70 { score -= 0.25; rationale.append(String(format: "RSI %.0f overbought in a range — fade setup", rsi)) }
        } else {
            if rsi > 80 { score -= 0.10; rationale.append("RSI > 80 — extended; trail stops") }
            else if rsi < 20 { score += 0.10; rationale.append("RSI < 20 — washed out") }
        }

        // scoreBeforeConfirm anchors the trend-family boundary: RSI is already applied above
        // and is excluded from the trend family. The family contribution is computed as
        // (score - scoreBeforeConfirm) below, capturing RS + volAdjMom (the remaining
        // trend-family terms added after this point).
        // NOTE: the ±0.05 volume-confirmation term was removed (parsimony cut, 2026-06-27,
        // owner-ratified): T2 ablation showed it directionally worsened drawdown and adds
        // complexity inside the already-capped/variance-scaled trend family. RS (±0.08) stays.
        let scoreBeforeConfirm = score   // RSI already applied & excluded from the trend family

        // Volatility-adjusted momentum quality (needs highs/lows for ATR): a move that's
        // large relative to the asset's OWN noise is a clean, risk-efficient trend; a same-%
        // move that's small next to violent swings is a whipsaw trap. Nudges ±0.05 in the
        // momentum's own direction (never flips it); skipped when |vam| is middling or no ATR.
        if let highs, let lows, mom != 0,
           let vam = StockSageIndicators.volAdjustedMomentum(closes: closes, highs: highs, lows: lows) {
            if abs(vam) >= 5 {
                score += vam > 0 ? 0.05 : -0.05
                rationale.append(String(format: "Volatility-efficient trend (momentum ÷ ATR%% ≈ %.0f)", abs(vam)))
            }
        }

        // Relative strength vs the benchmark (real index closes only): the documented
        // momentum edge is OUT-performance, not absolute drift. A name leading the S&P gets
        // a small confirmation; one merely rising with (or lagging) the market is demoted.
        // ±0.08, additive, and skipped entirely when no benchmark is supplied.
        // DISABLED 2026-06-27: gated by relativeStrengthEnabled (default false — parsimony cut;
        // code preserved, flip to true to re-enable exact prior behavior).
        if Self.relativeStrengthEnabled,
           let benchmarkCloses,
           let rs = StockSageIndicators.relativeStrength(symbolCloses: closes, benchmarkCloses: benchmarkCloses) {
            if rs > 0 { score += 0.08; rationale.append(String(format: "Leading the S&P (relative strength +%.0f%%)", rs)) }
            else if rs < 0 { score -= 0.08; rationale.append(String(format: "Lagging the S&P (relative strength %.0f%%)", rs)) }
        }

        // Hoist realized-vol computation here so it is available for the variance scalar
        // (below) AND the stop sizing (further below). Computed ONCE — no duplicate call.
        let realizedVol = StockSageIndicators.annualizedVolatility(closes)

        // ── ITER3: continuous inverse-variance momentum scaling (replaces the binary TSMOM veto).
        // Barroso & Santa-Clara 2015: scale momentum exposure INVERSELY by realized variance to hold
        // risk constant — attenuates conviction in high-vol (crash) regimes. The scalar is computed
        // ONCE from `realizedVol` (hoisted above) and CLAMPED to ≤ 1.0 (calm must not amplify).
        let varScalar = Self.varianceScalar(realizedVol: realizedVol)   // ∈ (0, 1]; 1.0 = no-op

        // The scalar multiplies ONLY the trend-family contribution (the correlated momentum bucket
        // the research targets), NOT the independent RSI mean-reversion / nudge terms. Decompose:
        let rawTrendFamily = trendCore + (score - scoreBeforeConfirm)   // trend+mom+MACD+RS+volAdjMom (vol term removed 2026-06-27)
        let nonFamily      = score - rawTrendFamily                     // RSI bounce / fade / extended nudges

        // 1) SCALE the trend family inversely by variance (attenuation-only).
        var scaledFamily = rawTrendFamily * varScalar

        // 2) RE-ASSERT the 0.65 trend-family cap on the POST-SCALED family (Guardrails 1 & 2):
        //    correlated-trend conviction stays bounded entering Kelly, regardless of the scalar.
        //    (Attenuation-only ⇒ scaledFamily can only ever shrink the cap pressure, never inflate it.)
        if abs(scaledFamily) > Self.trendFamilyCap {
            scaledFamily = (scaledFamily >= 0 ? 1.0 : -1.0) * Self.trendFamilyCap
        }

        // 3) Reassemble: scaled+capped family + untouched independent terms.
        score = scaledFamily + nonFamily

        // Rationale (only when the scalar actually bit — keeps calm-regime strings/byte-output stable):
        // realizedVol is non-nil here when varScalar < 1.0 (the scalar only attenuates when
        // realizedVol is present, finite, and > 0 — the guard in varianceScalar() ensures this).
        if varScalar < 1.0, let vol = realizedVol {
            rationale.append(String(format: "High-vol regime — momentum scaled ×%.2f (target %.0f%% / realized %.0f%%)",
                                    varScalar, Self.varianceScalarTargetVol * 100, vol * 100))
        } else if abs(rawTrendFamily) > Self.trendFamilyCap {
            rationale.append(String(format: "Correlated trend signals capped at %.2f (raw ≈ %.2f) — one trend, not many",
                                    Self.trendFamilyCap, abs(rawTrendFamily)))
        }

        let regime: TradeAdvice.Regime = trending ? (score >= 0 ? .bullTrend : .bearTrend) : .range

        // ── 52-WEEK-HIGH PROXIMITY (continuous, anchoring-driven — Byun & Jeon 2023, FAJ 79(2)).
        // PRIMARY VALUE = CRASH-ATTENUATION: neutralizing momentum w.r.t. the 52wk-high lifted Sharpe
        // ~50–80%, moved skewness −1.73 → +0.48, and cut the worst monthly return −69.3% → −26.87%.
        // Mechanism is anchoring-driven continuation — PARTIALLY INDEPENDENT of trend/momentum, so it
        // is INTENTIONALLY OUTSIDE the 0.65 trend-family cap (it is not the same correlated factor; the
        // roadmap invariant "new non-trend terms don't count toward the cap" applies). Replaces the
        // dormant binary isBreakout intent — a continuous distance subsumes the binary trigger
        // (Avramov 2018). Because it is OUTSIDE the family it is NOT scaled by the iter3 varScalar and
        // NOT capped at 0.65; it is an independent additive term like the RSI nudges.
        //
        // LONG-SIDE-ONLY (Guardrail 1): contribution = max(0, w·(pth − neutralAnchor)). A mid/low pth
        // yields 0 — the term can ONLY add on genuine proximity, never subtract, so it can NEVER
        // manufacture a sell/avoid. REGIME GATE (Guardrail 3): zeroed in a bearTrend regime, where a
        // near-high is suspect (about to roll over). Caveats honored with a MODEST weight: the effect
        // is small-cap-concentrated, significant in only 10/20 international markets, and net of
        // transaction costs can erode — hence w = 0.10 (mid of the ±0.08–0.12 band) and anchor 0.90.
        // NOTE: the proximity term requires REAL intraday/closing highs. When only closes are
        // supplied (highs == nil), the term is DISABLED entirely — using closes as a highs
        // proxy makes pth = closes.last/max(closes) = 1.0 for any monotone uptrend, inflating
        // the bonus to maximum on every bull-trend bar regardless of true 52wk-high distance.
        if regime != .bearTrend,                                                   // [AUDIT] Guardrail 3: bull/range only
           let highs,                                                              // [AUDIT] nil-guard: disabled for close-only callers
           let hp = StockSageIndicators.highProximity(price: price, highs: highs) {
            let w = Self.highProximityWeight                                       // [AUDIT] 0.10 (∈[0.08,0.12])
            // Clamp pth to 1.0 before computing contribution so that a live intraday print
            // above the prior-close 52wk high cannot push prox above the documented 0.010 ceiling.
            let clampedPth = Swift.min(hp.pth, 1.0)
            let prox = Swift.max(0.0, w * (clampedPth - Self.highProximityNeutralAnchor)) // [AUDIT] max(0, 0.10·(pth−0.90)); long-side-only; ceiling 0.010
            if prox > 0 {                                                          // only emit when genuinely near the high
                score += prox                                                      // [AUDIT] OUTSIDE family ⇒ added post-reassembly, un-scaled, un-capped; max +0.010
                let honest = hp.effectiveWindow >= 252
                    ? String(format: "Near the 52-week high (%.0f%% of it) — anchoring continuation", hp.pth * 100)
                    : String(format: "Near its %d-bar high (%.0f%%, <252 bars — not a full 52wk high)", hp.effectiveWindow, hp.pth * 100) // [AUDIT] Guardrail 4
                rationale.append(honest)
            }
        }

        // Score → action. In a choppy regime with no edge, prefer "Avoid" (stand
        // aside) over "Hold" — the research is clear that forcing trades in chop loses.
        //
        // BOUNDARY ASYMMETRY (deliberate, F34 2026-07-02):
        //   +0.5 → .strongBuy (inclusive ≥ 0.5)  vs  −0.5 → .reduce (exclusive < −0.5 for .sell)
        // The long side uses ≥ 0.5 (inclusive threshold) so a borderline strong signal is
        // actionable as a long; the short side uses a STRICTER < −0.5 (i.e. −0.5 itself falls in
        // the .reduce bucket, not .sell) because shorts carry:
        //   (a) daily financing cost (short borrow/margin rate),
        //   (b) unlimited theoretical loss potential (no floor on how far a name can rally).
        // A score right at −0.5 doesn't yet merit the full .sell commitment — it warrants a
        // .reduce first. This is a conscious, research-backed long-side bias. Do NOT mirror to
        // symmetric boundaries without revisiting the short-financing and loss-asymmetry rationale.
        // The mapping lives in actionForScore(_:trending:) — advise() CALLS it (single source
        // of truth) and the boundary tests pin that same function, so a threshold change here
        // is impossible without the pins seeing it.
        var action = Self.actionForScore(score, trending: trending)
        // Chop has no trend edge — the design (above) prefers Avoid in a range. A trend-DRIVEN buy
        // in a non-trending regime becomes Avoid (stand aside); only an oversold mean-reversion
        // bounce may buy there, and never as a STRONG call. Stops a "Range-bound" card from
        // showing Strong Buy + a full trade plan, which contradicted its own regime label.
        if !trending {
            if case .strongBuy = action { action = rangeOversoldBounce ? .buy : .avoid }
            else if case .buy = action, !rangeOversoldBounce { action = .avoid }
        }
        let conviction = Swift.min(abs(score), 1.0)

        // Only a buy-family verdict gets an actionable trade plan. Gating on the
        // ACTION (not raw score>0) stops a "Hold"/"Avoid" card from also showing a
        // stop, target, and position size — which contradicted the recommendation.
        let isBuy = action == .buy || action == .strongBuy

        let isSell = action == .sell || action == .reduce

        // RANKING_BACKLOG #12 (reframed, pure observer): three-timeframe confluence, computed
        // from the FINAL resolved score (after every term, the trend-family cap, and the iter3
        // variance-scalar have already applied) — this NEVER changes score/action/conviction/
        // sizing above, it only reads them. See `StockSageIndicators.timeframeConfluence`.
        // Gated on `isBuy`/`isSell` (the POST-chop-downgrade action), the exact same discipline
        // as the stop/target gate below: `score`'s raw sign can still read "up"/"down" even after
        // the chop-regime block above demoted the verdict to .avoid/.hold (no edge, stand aside) —
        // without this gate, an Avoid card could show a bullish-styled confluence badge that
        // contradicts its own "stand aside" verdict (2026-07-01 adversarial-review finding).
        var timeframeAligned = false
        var confluenceNote: String? = nil
        if isBuy || isSell {
            let dailyDirection = score > 0 ? 1 : (score < 0 ? -1 : 0)
            if let tf = StockSageIndicators.timeframeConfluence(closes: closes, dailyDirection: dailyDirection), tf.aligned {
                timeframeAligned = true
                let word = tf.direction > 0 ? "up" : "down"
                confluenceNote = "Three-timeframe confluence — 1-month, daily, and 1-year trends all \(word)"
                rationale.append(confluenceNote!)
            }
        }

        // Stop & target — symmetric: a long stops BELOW / targets ABOVE; a short mirrors it.
        // The ATR multiple now scales with the name's realized volatility (wider for crypto,
        // tighter for calm equities) so the stop fits the asset, not a one-size guess.
        // `realizedVol` was hoisted above the cap block (ITER3) — reused here, not recomputed.
        let (stop, target) = Self.stopTarget(action: action, price: price, atr: atr, realizedVol: realizedVol)
        let stopMult = Self.stopMultiple(forVol: realizedVol)
        let stopReason = realizedVol.map { String(format: "%.1f×ATR stop — sized for %.0f%% annualized volatility", stopMult, $0 * 100) }

        // Position size — KELLY-shaped off the win prob (see `suggestedWeight`). advise() passes
        // NO calibration ⇒ the conservative linear prior, byte-identical to before. The calibrated
        // win-prob is applied at the runtime build site (StockSageStore.buildIdeas), which alone
        // can see the fitted calibration — keeping advise() pure/deterministic for the backtester.
        let weight = Self.suggestedWeight(action: action, conviction: conviction, price: price,
                                          stop: stop, target: target, realizedVol: realizedVol,
                                          calibration: nil)

        return TradeAdvice(action: action, conviction: conviction, regime: regime,
                           rationale: rationale, stopPrice: stop, targetPrice: target,
                           suggestedWeight: weight, caveat: caveat,
                           stopMultiplier: stopMult, stopReason: stopReason,
                           timeframeAligned: timeframeAligned, confluenceNote: confluenceNote)
    }

    /// Target annualized volatility (20%) the variance scalar normalizes momentum exposure to —
    /// the same baseline cryptoRiskScaler sizes risk against (StockSageExpectedValue baseline 0.20).
    /// Barroso & Santa-Clara 2015: scaling momentum exposure INVERSELY by realized variance
    /// targets a constant risk level; we normalize to this baseline and CLAMP to attenuation-only.
    nonisolated static let varianceScalarTargetVol = 0.20

    /// Epsilon floor for the realized-vol denominator — belt-and-suspenders guard against
    /// any sub-epsilon positive value slipping past the `v > 0` guard.
    nonisolated static let varianceScalarEps = 1e-8

    /// 52-week-high proximity weight (Byun & Jeon 2023). MODEST by design — the effect is
    /// small-cap-concentrated and significant in only 10/20 international markets, and net of
    /// transaction costs can erode — so 0.10 (mid of the research's ±0.08–0.12 band), OUTSIDE the
    /// trend-family cap. At pth = 1 (price exactly at the high) the max contribution is
    /// 0.10·(1 − 0.90) = 0.010. This term CAN promote a borderline Buy to Strong Buy (by at most
    /// the weight 0.010) — e.g. a high-vol name with varScalar ≈ 0.755 lands scaledFamily ≈ 0.491;
    /// adding prox = 0.010 yields 0.501, crossing the 0.5 Strong Buy threshold. This is intentional:
    /// genuine proximity to the 52wk high is a meaningful continuation signal. The boundary case is
    /// covered by the `highProximity_borderlineBuy_canPromoteToStrongBuy` golden-vector test.
    nonisolated static let highProximityWeight = 0.10                  // [AUDIT] ∈ [0.08, 0.12]

    /// Neutral anchor: pth at/below which the proximity term contributes ZERO. 0.90 ⇒ only the top
    /// ~10% of the 52-week range adds, so a mid-range name is genuinely neutral (contribution ≈ 0)
    /// and the additive convention "every term ±weight; mid ⇒ 0" is preserved.
    nonisolated static let highProximityNeutralAnchor = 0.90          // [AUDIT] ∈ [0.85, 0.90]

    /// Inverse-variance momentum scalar (Barroso & Santa-Clara 2015): target_vol / realized_vol,
    /// CLAMPED to ≤ 1.0 (attenuation-only — a calm regime must NOT amplify a momentum bet).
    /// Returns 1.0 (no-op) when realized vol is missing/non-finite/≤0, preserving pure-caller
    /// byte-identity. Pure + deterministic.
    nonisolated static func varianceScalar(realizedVol: Double?) -> Double {
        guard let v = realizedVol, v.isFinite, v > 0 else { return 1.0 }   // missing/NaN/Inf/≤0 → no-op
        let raw = varianceScalarTargetVol / Swift.max(v, varianceScalarEps) // target_vol / max(rv, ε)
        guard raw.isFinite else { return 1.0 }                              // belt-and-suspenders
        return Swift.min(1.0, raw)                                          // attenuation-only clamp ≤ 1
    }

    /// Half-Kelly position size as a fraction of the book, off the win probability for this
    /// conviction. Extracted from advise() VERBATIM so advise(…) (calibration nil) is byte-
    /// identical to the prior inline math. Pass a fitted `calibration` to size on the MEASURED,
    /// conservative win rate (Wilson-LCB + isotonic) instead of the invented linear prior — used
    /// by the runtime build site, which alone sees the calibration. Pure + deterministic.
    ///
    /// f* = W − (1−W)/R  (1 unit risked = the stop distance), then ×0.5 (half-Kelly), then:
    ///   • capped by the fixed `riskPerTrade` (1%) budget,
    ///   • shrunk for realized vol via `cryptoRiskScaler` (leverage management; floored at 1× ⇒ only reduces),
    ///   • divided by the stop-distance % to convert stop-RISK into a book WEIGHT,
    ///   • clamped to [0, maxWeight].
    /// Returns 0 for a non-buy/sell action, a missing stop/target, or a non-positive stop distance.
    nonisolated static func suggestedWeight(action: TradeAdvice.Action, conviction: Double,
                                            price: Double, stop: Double?, target: Double?,
                                            realizedVol: Double?,
                                            calibration: StockSageConvictionCalibration? = nil) -> Double {
        let isBuy = action == .buy || action == .strongBuy
        let isSell = action == .sell || action == .reduce
        guard (isBuy || isSell), let stop, let target, price > 0 else { return 0 }
        let stopDistPct = abs(price - stop) / price
        guard stopDistPct > 0 else { return 0 }
        let rr = Swift.min(abs(target - price) / abs(price - stop), 50)
        let w = StockSageExpectedValue.winProbEstimate(conviction: conviction, calibration: calibration)
        let fStar = Swift.max(0, w - (1 - w) / rr)              // Kelly stop-risk fraction
        var riskFraction = Swift.min(fStar / 2, riskPerTrade)   // half-Kelly, ≤ the 1% budget
        if let v = realizedVol { riskFraction /= StockSageExpectedValue.cryptoRiskScaler(annualizedVol: v) }
        return Swift.min(riskFraction / stopDistPct, maxWeight)
    }

    /// Symmetric 2-ATR swing stop + 2:1 target for an actionable buy/sell. Long: stop
    /// below, target above. Short (sell/reduce): stop ABOVE entry, target BELOW. 8% stop
    /// fallback when no ATR. (nil, nil) for hold/avoid or a non-positive price. Pure.
    /// ATR multiple for the stop, by realized volatility: a 70%-vol crypto needs a WIDER stop
    /// (2.5×) so ordinary daily noise doesn't whipsaw it out; a calm name can run a tighter
    /// 1.5×. nil vol → the documented 2.0× default (so existing callers are unchanged).
    nonisolated static func stopMultiple(forVol realizedVol: Double?) -> Double {
        // .isFinite guard (not just nil): NaN fails BOTH ">=" comparisons below (NaN comparisons
        // are always false), which would otherwise fall through to the tightest 1.5× "calm" stop —
        // the opposite of the honest neutral default. Mirrors the same guard on `varianceScalar`.
        guard let v = realizedVol, v.isFinite else { return 2.0 }
        if v >= 0.70 { return 2.5 } else if v >= 0.40 { return 2.0 } else { return 1.5 }
    }

    /// Is an oversold-in-range bounce actually buyable? Only when the name's own 12-1 trend is
    /// intact (buy-the-dip); an oversold name making fresh lower lows is a falling knife. Trend
    /// undefined (<253 closes) → true, preserving short-history behavior byte-for-byte.
    nonisolated static func oversoldBounceIsBuyable(_ closes: [Double]) -> Bool {
        StockSageIndicators.trendOK(closes) ?? true
    }

    /// Maps a raw score to an Action. This IS the mapping `advise()` uses — advise() calls
    /// this function (single source of truth; F34 2026-07-02), so the boundary tests that pin
    /// this function pin the live path, and a threshold change cannot drift past the pins.
    /// The `trending` flag is advise()'s in-body `trending` (efficiencyRatio >= 0.30),
    /// controlling the hold-vs-avoid split at score ∈ (-0.2, 0.2).
    nonisolated static func actionForScore(_ score: Double, trending: Bool) -> TradeAdvice.Action {
        switch score {
        case 0.5...:        return .strongBuy
        case 0.2..<0.5:     return .buy
        case -0.2..<0.2:    return trending ? .hold : .avoid
        case -0.5 ..< -0.2: return .reduce
        default:            return .sell
        }
    }

    nonisolated static func stopTarget(action: TradeAdvice.Action, price: Double, atr: Double?,
                                       realizedVol: Double? = nil)
        -> (stop: Double?, target: Double?) {
        let isBuy = action == .buy || action == .strongBuy
        let isSell = action == .sell || action == .reduce
        guard (isBuy || isSell), price > 0 else { return (nil, nil) }
        // realizedVol nil → 2×ATR / 8% fallback, BYTE-IDENTICAL to before. When supplied, the
        // ATR multiple scales with vol, and the no-ATR fallback widens for volatile names
        // (≈12% at 75% vol vs 8% baseline) — never tighter than 8%.
        let mult = stopMultiple(forVol: realizedVol)
        let fallbackPct = realizedVol.map { 0.08 * Swift.max(1.0, $0 / 0.50) } ?? 0.08
        let dist = (atr.map { $0 > 0 ? mult * $0 : price * fallbackPct }) ?? price * fallbackPct
        if isBuy {
            let s = price - dist
            guard s > 0 else { return (nil, nil) }   // ATR ≥ price ⇒ no sane long stop — untradeable
            return (s, price + 2 * (price - s))
        } else {
            let s = price + dist
            let t = price - 2 * (s - price)
            return (s, t > 0 ? t : nil)        // a degenerate (huge-ATR) negative target is dropped
        }
    }
}
