import Testing
import Foundation
@testable import StockSage

// MARK: - Key-catalyst engine: exhaustive property sweep (owner: "test it completely", 2026-09-06)
//
// The 9 pinned cases in StockSageCatalystWatchTests check hand-picked scenarios. This file checks
// EVERY combination of the inputs that drive `brief(for:inputs:)` against an independent oracle of
// the documented precedence, plus the honesty-floor and copy invariants, so a future edit that
// breaks one path in one corner of the grid cannot slip through. 157,500 briefs
// (7×5×5×5×5×6×2×3 — the ×3 is the `earningsCheckedAt` axis added for the dated "none known"
// record) run in a few seconds per sweep — the engine is pure and allocation-light.

@Suite("Catalyst watch — exhaustive precedence + honesty sweep")
struct StockSageCatalystWatchPropertyTests {
    typealias W = StockSageCatalystWatch

    /// 2025-09-04 06:00:00 UTC — early in the UTC day so "+0.5 day" is still today and "-0.5 day"
    /// is yesterday evening (both must bucket as Today under the engine's `..<1` rule).
    private static let now = Date(timeIntervalSince1970: 1_756_965_600)
    private func days(_ n: Double) -> Date { Self.now.addingTimeInterval(n * 86_400) }

    // MARK: Grid axes

    enum EarningsCase: CaseIterable { case none, past3d, boundary, imminent2d, soon7d, clear30d, storeDerivedSoon }
    enum VolumeCase: CaseIterable { case none, notable, significant, major, majorMechanical }
    enum ExtremeCase: CaseIterable { case nilExtreme, neither, atHigh63, atLowNoSpan, atHighMomentum }
    enum RegimeCase: CaseIterable { case none, bull, ranging, bear, crisis }
    enum SeasonCase: CaseIterable { case none, reliableStrong, reliableWeak, thinSample, reliableNegative }
    /// `earningsCheckedAt` axis (A3): never asked / asked in the past / asked right now — only
    /// changes output when every other slot is empty (the `.none` primary), so it is orthogonal
    /// to `expectedKinds` but drives the dated-vs-undated shape of the `.none` item itself.
    enum CheckedAtCase: CaseIterable { case never, past, now }
    static let actions: [TradeAdvice.Action] = [.strongBuy, .buy, .hold, .avoid, .reduce, .sell]
    static let rrs: [Double?] = [2.0, nil]

    struct Case {
        let earnings: EarningsCase; let volume: VolumeCase; let extreme: ExtremeCase
        let regime: RegimeCase; let season: SeasonCase; let action: TradeAdvice.Action; let rr: Double?
        var checkedAt: CheckedAtCase = .never
    }

    static var allCases: [Case] {
        var out: [Case] = []
        for e in EarningsCase.allCases { for v in VolumeCase.allCases { for x in ExtremeCase.allCases {
            for r in RegimeCase.allCases { for s in SeasonCase.allCases { for a in actions { for rr in rrs {
                for chk in CheckedAtCase.allCases {
                    out.append(Case(earnings: e, volume: v, extreme: x, regime: r, season: s, action: a, rr: rr, checkedAt: chk))
                }
            } } } } } } }
        return out
    }

    // MARK: Builders

    private func idea(_ c: Case) -> StockSageIdea {
        let base = SageFix.idea("SWEEP", conviction: 0.6, action: c.action, rr: c.rr, price: 100, riskDistance: 10)
        let ext: SparkSeries.Extreme?; let span: Int?; let q: Double?
        switch c.extreme {
        case .nilExtreme:     ext = nil;      span = nil; q = nil
        case .neither:        ext = .neither; span = 63;  q = 0.5
        case .atHigh63:       ext = .atHigh;  span = 63;  q = nil
        case .atLowNoSpan:    ext = .atLow;   span = nil; q = nil
        case .atHighMomentum: ext = .atHigh;  span = 40;  q = 0.42
        }
        return StockSageIdea(symbol: base.symbol, market: base.market, price: base.price, advice: base.advice,
                             spark: base.spark, momentumQuality: q, recentExtreme: ext, recentExtremeSpan: span)
    }

    private func earningsInputs(_ e: EarningsCase) -> (EarningsProximity?, Date?) {
        switch e {
        case .none:             return (nil, nil)
        case .past3d:           return (nil, days(-3))
        case .boundary:         return (nil, Self.now.addingTimeInterval(-86_400))   // exactly the F32 boundary: still counts
        case .imminent2d:       return (nil, days(2))
        case .soon7d:           return (nil, days(7))
        case .clear30d:         return (nil, days(30))
        case .storeDerivedSoon: return (EarningsProximity(daysUntil: 7, severity: .soon), days(7))
        }
    }

    private func volume(_ v: VolumeCase) -> StockSageCatalyst.Signal? {
        func sig(_ rvol: Double, _ tier: StockSageCatalyst.Tier, _ mech: Bool) -> StockSageCatalyst.Signal {
            StockSageCatalyst.Signal(symbol: "SWEEP", rvol: rvol, priceChangePct: 6.5, tier: tier,
                                     likelyMechanicalFlow: mech, caveat: StockSageCatalyst.caveat)
        }
        switch v {
        case .none:            return nil
        case .notable:         return sig(2.5, .notable, false)
        case .significant:     return sig(6.0, .significant, false)
        case .major:           return sig(12.0, .major, false)
        case .majorMechanical: return sig(12.0, .major, true)
        }
    }

    private func regime(_ r: RegimeCase) -> MarketRegime? {
        func mk(_ s: MarketRegime.State, _ bias: Double) -> MarketRegime {
            MarketRegime(state: s, riskScore: 0, signals: ["sweep"], sizingBias: bias, caveat: StockSageRegime.caveat)
        }
        switch r {
        case .none:    return nil
        case .bull:    return mk(.trendingBull, 1.2)
        case .ranging: return mk(.ranging, 1.0)
        case .bear:    return mk(.trendingBear, 0.6)
        case .crisis:  return mk(.crisis, 0.25)
        }
    }

    private func season(_ s: SeasonCase) -> MonthlySeasonality? {
        let month = StockSageSeasonality.currentMonth(asOf: Self.now)
        func mk(avg: Double, samples: Int) -> MonthlySeasonality {
            let months = (1...12).map { m in
                MonthlySeasonality.MonthStat(month: m, avgReturn: m == month ? avg : 0, samples: m == month ? samples : 0)
            }
            return MonthlySeasonality(months: months, years: Double(samples))
        }
        switch s {
        case .none:             return nil
        case .reliableStrong:   return mk(avg: 0.03, samples: 8)
        case .reliableWeak:     return mk(avg: 0.005, samples: 8)   // below the 1% floor → no item
        case .thinSample:       return mk(avg: 0.05, samples: 2)    // not reliable → no item
        case .reliableNegative: return mk(avg: -0.02, samples: 5)
        }
    }

    private func checkedAt(_ c: CheckedAtCase) -> Date? {
        switch c {
        case .never: return nil
        case .past:  return days(-2)
        case .now:   return Self.now
        }
    }

    private func inputs(_ c: Case) -> W.Inputs {
        let (prox, date) = earningsInputs(c.earnings)
        let chk = checkedAt(c.checkedAt)
        // A `checkedAt` in the real flow is always paired with a non-empty `sourcesAsked` (that's
        // what the store's chain always stamps together) — major fix 2026-09-06 made an empty
        // `sourcesAsked` the fail-closed default, so the grid must mirror the real pairing to
        // still exercise the dated-negative shape it was built to check.
        return W.Inputs(earnings: prox, earningsDate: date, earningsCheckedAt: chk,
                        volumeMove: volume(c.volume), regime: regime(c.regime),
                        regimeGaugedAt: days(-0.1), seasonality: season(c.season), now: Self.now,
                        catalystSourcesAsked: chk != nil ? ["yahoo calendarEvents"] : [])
    }

    // MARK: Independent oracle of the documented precedence

    private func isLongBiased(_ a: TradeAdvice.Action) -> Bool { a == .buy || a == .strongBuy || a == .hold }

    private func expectedKinds(_ c: Case) -> [W.Kind] {
        var slots: [W.Kind?] = [nil, nil, nil, nil, nil, nil]
        switch c.earnings {
        case .imminent2d, .soon7d, .storeDerivedSoon, .boundary: slots[0] = .earnings   // boundary: 0 days → imminent
        case .clear30d: slots[2] = .earnings
        case .none, .past3d: break
        }
        if c.volume != .none { slots[1] = .volumeMove }
        if c.extreme == .atHigh63 || c.extreme == .atLowNoSpan || c.extreme == .atHighMomentum { slots[3] = .extreme }
        if (c.regime == .bear || c.regime == .crisis) && isLongBiased(c.action) { slots[4] = .regime }
        if c.season == .reliableStrong || c.season == .reliableNegative { slots[5] = .seasonality }
        let kinds = slots.compactMap { $0 }
        return kinds.isEmpty ? [.none] : kinds
    }

    /// Forecast language the honesty floor forbids. Negated, allowed phrases are removed first.
    private func forecastViolations(_ text: String) -> [String] {
        var t = text.lowercased()
        for allowed in ["does not predict", "doesn't predict", "not predict", "not a forecast", "not a probability", "never what happens next"] {
            t = t.replacingOccurrences(of: allowed, with: "")
        }
        let banned = ["will rise", "will fall", "will go", "expect", "likely", "guarantee", "should rise", "should fall",
                      "buy now", "sell now", "predict", "sure thing", "can't lose", "bound to"]
        return banned.filter { t.contains($0) }
    }

    // MARK: Tests

    @Test("every input combination yields exactly the documented precedence (n=157,500 briefs)")
    func precedenceMatchesOracleAcrossTheWholeGrid() {
        let cases = Self.allCases
        #expect(cases.count == 157_500)
        var mismatches: [String] = []
        for c in cases {
            let b = W.brief(for: idea(c), inputs: inputs(c))
            let got = b.all.map(\.kind)
            let want = expectedKinds(c)
            if got != want, mismatches.count < 10 {
                mismatches.append("\(c) got \(got) want \(want)")
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches)")
    }

    @Test("structural invariants hold for every brief: unique kinds/ids, none ⇒ no secondaries, dates only on earnings or a dated 'none known' record")
    func structuralInvariants() {
        var checked = 0
        for c in Self.allCases {
            let b = W.brief(for: idea(c), inputs: inputs(c))
            let chk = checkedAt(c.checkedAt)
            checked += 1
            #expect(b.all.count == b.secondary.count + 1)
            #expect(Set(b.all.map(\.kind)).count == b.all.count, "duplicate kind in \(c)")
            #expect(Set(b.all.map(\.id)).count == b.all.count, "duplicate id in \(c)")
            if b.primary.kind == .none {
                #expect(b.secondary.isEmpty)
                if let chk {
                    #expect(b.primary.why == ["Next earnings date requested from yahoo calendarEvents — none returned"])
                    #expect(b.primary.date == chk)
                    #expect(b.primary.source == "yahoo calendarEvents (no date returned)")
                } else {
                    #expect(b.primary.why == ["Next earnings date not available for this name — not fetched yet, or the source declined.",
                                              "No volume-confirmed move on the latest cached bar."])
                    #expect(b.primary.date == nil)
                    #expect(b.primary.source == "—")
                }
            }
            for item in b.all {
                #expect(item.symbol == "SWEEP")
                let expectDate = item.kind == .earnings || (item.kind == .none && chk != nil)
                #expect((item.date != nil) == expectDate, "date on an unexpected item in \(c)")
                #expect(!item.headline.isEmpty && !item.watch.isEmpty && !item.why.isEmpty && !item.source.isEmpty)
                #expect(item.why.count <= 3)
            }
            // A report that already happened (>24h ago) must never surface anywhere.
            if c.earnings == .past3d { #expect(!b.all.contains { $0.kind == .earnings }, "past earnings resurrected in \(c)") }
        }
        #expect(checked == 157_500)
    }

    @Test("no item in the whole grid contains forecast language (honesty floor)")
    func noForecastLanguageAnywhere() {
        var violations: [String] = []
        for c in Self.allCases {
            for item in W.brief(for: idea(c), inputs: inputs(c)).all {
                for text in [item.headline, item.watch] + item.why + [item.caveat ?? ""] {
                    let v = forecastViolations(text)
                    if !v.isEmpty, violations.count < 10 { violations.append("\(item.kind): \(v) in “\(text.prefix(80))”") }
                }
            }
        }
        #expect(violations.isEmpty, "\(violations)")
        #expect(forecastViolations(W.caveat).isEmpty)
        // The check itself must be able to fail: a forbidden phrase is caught.
        #expect(forecastViolations("This stock will rise after earnings.") == ["will rise"])
    }

    @Test("weights, caveats and sources are exactly the documented mapping for every kind")
    func weightsCaveatsSources() {
        for c in Self.allCases {
            let ins = inputs(c)
            for item in W.brief(for: idea(c), inputs: ins).all {
                switch item.kind {
                case .earnings:
                    let daysUntil = ins.earnings?.daysUntil
                        ?? StockSageEarnings.proximity(now: Self.now, earnings: ins.earningsDate!).daysUntil
                    let sev = ins.earnings?.severity ?? StockSageEarnings.severity(daysUntil: daysUntil)
                    let want: W.Weight = sev == .imminent ? .high : (sev == .soon ? .medium : .low)
                    #expect(item.weight == want, "\(c)")
                    #expect(item.caveat == nil && item.source == "Yahoo calendarEvents")
                    #expect(item.headline.hasPrefix("Earnings in ~\(daysUntil) day"))
                case .volumeMove:
                    let tier = ins.volumeMove!.tier
                    let want: W.Weight = tier == .major ? .high : (tier == .significant ? .medium : .low)
                    #expect(item.weight == want && item.caveat == StockSageCatalyst.caveat)
                    #expect(item.source == "on-disk history (latest bar)")
                    #expect(item.headline.contains("× volume") && item.headline.contains("+6.5%"))
                case .extreme:
                    #expect(item.weight == .medium && item.caveat == nil && item.source == "1-year history")
                case .regime:
                    let want: W.Weight = ins.regime!.state == .crisis ? .high : .medium
                    #expect(item.weight == want && item.caveat == StockSageRegime.caveat && item.source == "regime gauge")
                    #expect(item.headline == ins.regime!.state.rawValue)
                case .seasonality:
                    #expect(item.weight == .low && item.caveat == "Not a forecast." && item.source == "1-year+ history")
                    #expect(item.headline.contains("(n=") && item.headline.contains("tendency"))
                case .none:
                    #expect(item.weight == .low && item.caveat == nil)
                    if let chk = ins.earningsCheckedAt {
                        #expect(item.source == "yahoo calendarEvents (no date returned)" && item.date == chk)
                    } else {
                        #expect(item.source == "—" && item.date == nil)
                    }
                case .projectedEarnings:
                    // This sweep's `Case`/`inputs()` doesn't drive the W1 projected-date axis
                    // (`catalystProjectedDate`/`catalystProjectionBasis` stay nil for every case
                    // here) — StockSageCatalystWatchTests pins `.projectedEarnings` copy verbatim.
                    Issue.record("unreachable: this sweep never sets catalystProjectedDate")
                case .filing8K, .ratingChange, .guidanceChange, .exDividend, .insiderTrade:
                    Issue.record("unreachable: legacy grid has no company feeds; M6 grid covers every new axis")
                }
            }
        }
    }

    @Test("earnings copy is idea-specific: stop/target/percent for long ideas, no-stop and short-tape variants")
    func earningsCopyVariants() {
        for action in Self.actions { for rr in Self.rrs {
            let c = Case(earnings: .imminent2d, volume: .none, extreme: .nilExtreme, regime: .none, season: .none, action: action, rr: rr)
            let i = idea(c)
            let item = W.brief(for: i, inputs: inputs(c)).primary
            #expect(item.kind == .earnings)
            #expect(item.headline == "Earnings in ~2 days (Sep 6, 2025)")
            if isLongBiased(action) {
                if let stop = i.advice.stopPrice {
                    #expect(item.why[0].contains(StockSageCurrency.adaptivePrice(stop)))
                    #expect(item.why[0].contains("-10.0%"))                       // (90 − 100) / 100
                    #expect(item.why.count == 2 && item.why[1].contains(StockSageCurrency.adaptivePrice(i.advice.targetPrice!)))
                    #expect(item.watch.hasSuffix("does the first close respect the stop?"))
                } else {
                    #expect(item.why == ["No stop is attached to this idea, so an overnight gap has no defined exit — size for that or wait."])
                    #expect(item.watch.contains("there is no stop level to test it against"))
                }
            } else {
                #expect(item.why == ["A report can reverse a weak tape as easily as extend it; the \(action.rawValue) read describes the trend, not the print."])
            }
        } }
    }

    @Test("volume-move copy: mechanical-flow bullet appears only when flagged; stop clause only when a stop exists")
    func volumeCopyVariants() {
        for v in [VolumeCase.major, .majorMechanical] { for rr in Self.rrs {
            let c = Case(earnings: .none, volume: v, extreme: .nilExtreme, regime: .none, season: .none, action: .buy, rr: rr)
            let item = W.brief(for: idea(c), inputs: inputs(c)).primary
            #expect(item.kind == .volumeMove)
            #expect(item.why.count == (v == .majorMechanical ? 2 : 1))
            #expect(item.watch.contains("stop") == (rr != nil))
            #expect(item.headline == "12.0× volume, +6.5% on the latest cached bar — Major")
        } }
    }

    @Test("extreme copy: span or 'recent', high/low wording, momentum bullet only when known")
    func extremeCopyVariants() {
        func primary(_ x: ExtremeCase) -> W.Item {
            let c = Case(earnings: .none, volume: .none, extreme: x, regime: .none, season: .none, action: .buy, rr: 2.0)
            return W.brief(for: idea(c), inputs: inputs(c)).primary
        }
        #expect(primary(.atHigh63).headline == "At the 63-day high")
        #expect(primary(.atLowNoSpan).headline == "At the recent low")
        #expect(primary(.atLowNoSpan).watch.hasPrefix("A new low"))
        #expect(primary(.atHigh63).why.count == 1)
        #expect(primary(.atHighMomentum).why.count == 2 && primary(.atHighMomentum).why[1].contains("0.42/1"))
        #expect(primary(.neither).kind == .none)
    }

    @Test("seasonality gate: reliable and ≥1% only; the current UTC month is named; sign is preserved")
    func seasonalityGate() {
        let month = StockSageSeasonality.currentMonth(asOf: Self.now)
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        func primary(_ s: SeasonCase) -> W.Item {
            let c = Case(earnings: .none, volume: .none, extreme: .nilExtreme, regime: .none, season: s, action: .buy, rr: 2.0)
            return W.brief(for: idea(c), inputs: inputs(c)).primary
        }
        #expect(primary(.reliableStrong).headline == "\(names[month - 1]) tendency +3.0% (n=8)")
        #expect(primary(.reliableNegative).headline == "\(names[month - 1]) tendency -2.0% (n=5)")
        #expect(primary(.reliableWeak).kind == .none)
        #expect(primary(.thinSample).kind == .none)
    }

    @Test("the brief is a pure function: same inputs, identical output, twice")
    func determinism() {
        for c in Self.allCases.prefix(2_000) {
            let a = W.brief(for: idea(c), inputs: inputs(c))
            let b = W.brief(for: idea(c), inputs: inputs(c))
            #expect(a == b)
        }
    }

    // MARK: Calendar

    private func brief(_ symbol: String, earningsDays: Double?, volume: VolumeCase = .none, action: TradeAdvice.Action = .buy) -> W.Brief {
        let base = SageFix.idea(symbol, conviction: 0.6, action: action, rr: 2.0, price: 100, riskDistance: 10)
        let ins = W.Inputs(earningsDate: earningsDays.map(days), volumeMove: self.volume(volume), now: Self.now)
        return W.brief(for: base, inputs: ins)
    }

    @Test("calendar: dated entries sorted by date then symbol, buckets in order, undated tail by weight, no 'none' rows")
    func calendarOrderingAndBuckets() {
        let briefs = [
            brief("LATER", earningsDays: 20),
            brief("WEEK2", earningsDays: 5),
            brief("TMRW", earningsDays: 1),
            brief("TODAYB", earningsDays: 0.5),
            brief("TODAYA", earningsDays: 0.5),           // same instant as TODAYB → symbol tie-break
            brief("YDAY", earningsDays: -0.5),            // within 24h, buckets as Today
            brief("WEEK7", earningsDays: 7),
            brief("EIGHT", earningsDays: 8),
            brief("UNDLOW", earningsDays: nil, volume: .notable),
            brief("UNDHIGH", earningsDays: nil, volume: .major),
            brief("UNDMED", earningsDays: nil, volume: .significant),
            brief("NONE", earningsDays: nil),
        ]
        let entries = W.calendar(briefs, now: Self.now)
        let dated = entries.filter { $0.item.date != nil }
        let undated = entries.filter { $0.item.date == nil }
        #expect(dated.count == 8 && undated.count == 3, "n=\(entries.count) entries")
        #expect(!entries.contains { $0.item.kind == .none })
        // dated first, then undated
        #expect(entries.prefix(8).allSatisfy { $0.item.date != nil })
        // sorted by (date, symbol)
        let keys = dated.map { ($0.item.date!, $0.idea.symbol) }
        for i in 1..<keys.count { #expect(keys[i - 1].0 < keys[i].0 || (keys[i - 1].0 == keys[i].0 && keys[i - 1].1 < keys[i].1)) }
        #expect(dated.map(\.idea.symbol) == ["YDAY", "TODAYA", "TODAYB", "TMRW", "WEEK2", "WEEK7", "EIGHT", "LATER"])
        #expect(dated.map(\.bucket) == [.today, .today, .today, .tomorrow, .thisWeek, .thisWeek, .later, .later])
        // bucket order is monotonic
        let order: [W.Bucket] = [.today, .tomorrow, .thisWeek, .later, .undated]
        let idx = entries.map { order.firstIndex(of: $0.bucket)! }
        #expect(idx == idx.sorted())
        // undated by weight desc, then symbol
        #expect(undated.map(\.idea.symbol) == ["UNDHIGH", "UNDMED", "UNDLOW"])
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test("dateStr is UTC + en_US_POSIX regardless of the process locale/time zone")
    func dateStrIsFixed() {
        #expect(W.dateStr(Self.now) == "Sep 4, 2025")
        #expect(W.dateStr(days(0.5)) == "Sep 4, 2025")       // 18:00 UTC still Sep 4 (would be Sep 5 in UTC+7 local)
        #expect(W.dateStr(days(-0.5)) == "Sep 3, 2025")
    }
}
