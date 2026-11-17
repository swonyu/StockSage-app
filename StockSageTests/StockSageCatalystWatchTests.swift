import Testing
import Foundation
@testable import StockSage

// Catalyst-brief engine behind the catalysts tab (owner request 2026-09-06, build step
// C1-engine). Every fixture is hand-built with the injected epoch below so severity/day-diff
// arithmetic and every pinned string are checkable by eye — no `Date()`, no RNG.

@Suite("Catalyst watch (brief engine + calendar)")
struct StockSageCatalystWatchTests {

    typealias W = StockSageCatalystWatch

    /// Fixed instant every test builds against — 2026-09-06T09:33:20Z region, matching the
    /// suite-wide convention for deterministic date math.
    static let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func days(_ n: Double) -> Date { Self.now.addingTimeInterval(n * 86_400) }

    private func volSignal(symbol: String = "V", rvol: Double = 12.0, movePct: Double = 8.0,
                           tier: StockSageCatalyst.Tier = .major,
                           mechanical: Bool = false) -> StockSageCatalyst.Signal {
        StockSageCatalyst.Signal(symbol: symbol, rvol: rvol, priceChangePct: movePct, tier: tier,
                                 likelyMechanicalFlow: mechanical, caveat: StockSageCatalyst.caveat)
    }

    private func bearRegime() -> MarketRegime {
        MarketRegime(state: .trendingBear, riskScore: -0.5, signals: ["S&P 500 below its 200-day average (downtrend)"],
                    sizingBias: 0.6, caveat: StockSageRegime.caveat)
    }

    // MARK: (a) precedence

    @Test(arguments: [-1.0, 0.0, 86399.0, 86400.0, 1209600.0])
    func earningsConfirmationDisclosesExpiredOrFutureCheck(_ age: Double) {
        let idea = SageFix.idea("CHECK", conviction: 0.6)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2),
            earningsCheckedAt: Self.now.addingTimeInterval(-age), now: Self.now, catalystConfirmed: true))
        let item = brief.primary
        if (0..<86400).contains(age) {
            #expect(item.headline.contains("(confirmed)"))
        } else {
            #expect(!item.headline.contains("(confirmed)"))
            #expect(item.caveat?.contains("recheck") == true)
            #expect(StockSageCatalystNarrator.facts(for: brief).joined().contains("recheck"))
        }
    }

    @Test("earnings soon (rank 1) beats a major volume move (rank 2)")
    func earningsSoonBeatsVolumeMove() {
        let idea = SageFix.idea("SOON", conviction: 0.6)
        let inputs = W.Inputs(earningsDate: days(6), volumeMove: volSignal(), now: Self.now)   // 6d ⇒ .soon
        let brief = W.brief(for: idea, inputs: inputs)
        #expect(brief.primary.kind == .earnings)
        #expect(brief.secondary.count == 1)                       // n=1: only the volume move demotes
        #expect(brief.secondary.first?.kind == .volumeMove)
    }

    @Test("a volume move (rank 2) beats a clear-dated earnings (rank 3)")
    func volumeMoveBeatsClearEarnings() {
        let idea = SageFix.idea("CLEAR", conviction: 0.6)
        let inputs = W.Inputs(earningsDate: days(30), volumeMove: volSignal(), now: Self.now)  // 30d ⇒ .clear
        let brief = W.brief(for: idea, inputs: inputs)
        #expect(brief.primary.kind == .volumeMove)
        #expect(brief.secondary.count == 1)                       // n=1: only the earnings item demotes
        #expect(brief.secondary.first?.kind == .earnings)
    }

    @Test("regime is primary only when risk-off AND the idea is long-biased")
    func regimePrimaryOnlyWhenLongBiasedAgainstRiskOff() {
        let longIdea = SageFix.idea("LONG", conviction: 0.6, action: .buy)
        let longBrief = W.brief(for: longIdea, inputs: W.Inputs(regime: bearRegime(), regimeGaugedAt: Self.now, now: Self.now))
        #expect(longBrief.primary.kind == .regime)

        let shortIdea = SageFix.idea("SHORT", conviction: 0.6, action: .sell, rr: nil)
        let shortBrief = W.brief(for: shortIdea, inputs: W.Inputs(regime: bearRegime(), regimeGaugedAt: Self.now, now: Self.now))
        #expect(shortBrief.primary.kind == .none)                 // not long-biased ⇒ regime never applies here
        #expect(shortBrief.secondary.isEmpty)                     // n=0: nothing else applies either
    }

    @Test("none, with the exact two why bullets, when nothing applies")
    func noneWhenNothingApplies() {
        let idea = SageFix.idea("NADA", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now))
        #expect(brief.primary.kind == .none)
        #expect(brief.primary.headline == "No dated catalyst on file")     // pinned verbatim (never-checked shape)
        #expect(brief.primary.date == nil)
        #expect(brief.primary.why == [
            "Next earnings date not available for this name — not fetched yet, or the source declined.",
            "No volume-confirmed move on the latest cached bar.",
        ])                                                        // n=2 bullets, pinned verbatim
        #expect(brief.primary.source == "—")
        #expect(brief.secondary.isEmpty)
    }

    // MARK: (a3) dated "none known" record — the store ASKED Yahoo calendarEvents and got
    // nothing back, so the honesty floor requires a real, DATED negative record (`date:
    // checkedAt`, never `Date()`) instead of the "not checked yet" wording above.

    @Test("none WITH earningsCheckedAt + sourcesAsked: dated negative record, exact headline/why/source, pinned verbatim")
    func noneWithCheckedAtIsADatedNegativeRecord() {
        let idea = SageFix.idea("ASKED", conviction: 0.5)
        let checkedAt = Self.now
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsCheckedAt: checkedAt, now: Self.now,
                                                        catalystSourcesAsked: ["yahoo calendarEvents"]))
        #expect(brief.primary.kind == .none)
        #expect(brief.primary.headline == "No known catalyst as of \(W.dateStr(checkedAt))")   // pinned verbatim
        #expect(brief.primary.date == checkedAt)                    // the time we ASKED — never a fabricated date
        #expect(brief.primary.why == [
            "Next earnings date requested from yahoo calendarEvents — none returned",
        ])                                                          // n=1 bullet, pinned verbatim
        #expect(brief.primary.source == "yahoo calendarEvents (no date returned)")
        #expect(brief.primary.watch == "Re-check after the next full refresh.")   // watch unchanged in spirit
        #expect(brief.secondary.isEmpty)
    }

    @Test("checkedAt WITHOUT any provable sourcesAsked falls back to the undated 'not fetched yet' shape")
    func checkedAtAloneWithoutSourcesAskedIsTreatedAsUnchecked() {
        // Major fix 2026-09-06: `sourcesAsked` is the fail-closed half of the guard — a
        // `checkedAt` with no provable source (shouldn't happen post-fix, but must degrade
        // safely if it ever does) must never render as a dated negative.
        let idea = SageFix.idea("NOSRC", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsCheckedAt: Self.now, now: Self.now))
        #expect(brief.primary.headline == "No dated catalyst on file")
        #expect(brief.primary.date == nil)
    }

    @Test("a dated 'none known' record appears in the calendar; an undated (never-checked) one never does")
    func noneRecordCalendarPresenceHingesOnCheckedAt() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let calNow = utc.startOfDay(for: Self.now)

        let uncheckedBrief = W.brief(for: SageFix.idea("UNCHK", conviction: 0.5), inputs: W.Inputs(now: calNow))
        let checkedBrief = W.brief(for: SageFix.idea("CHKD", conviction: 0.5),
                                   inputs: W.Inputs(earningsCheckedAt: calNow, now: calNow,
                                                    catalystSourcesAsked: ["yahoo calendarEvents"]))   // checked today
        #expect(uncheckedBrief.primary.kind == .none && checkedBrief.primary.kind == .none)

        let entries = W.calendar([uncheckedBrief, checkedBrief], now: calNow, calendar: utc)
        #expect(entries.count == 1)                                       // n=1: only the dated (checked) one
        #expect(entries[0].idea.symbol == "CHKD")
        // Major fix 2026-09-06: a dated "none known" record's date is WHEN WE ASKED, not an
        // event — it must land in its own dedicated bucket, never `.today` (where it would sort
        // ahead of a real catalyst also due today).
        #expect(entries[0].bucket == .checkedNoCatalyst)
        #expect(entries[0].isNegativeRecord)                              // distinct in the pure data from a real catalyst
        #expect(!entries.contains { $0.idea.symbol == "UNCHK" })          // never checked ⇒ never on the calendar
    }

    @Test("a real earnings date straddling the thisWeek/later boundary (day 7 vs day 8) buckets correctly")
    func earningsDateBoundaryStraddle() {
        // Genuine straddle of `bucket(for:)`'s `case 2...7` / `default` boundary: day 7 is the
        // LAST day still `.thisWeek`, day 8 is the FIRST day that falls to `.later`. Re-pointed
        // (major fix 2026-09-06) from `earningsCheckedAt` to a real `earningsDate` — a checkedAt
        // "none known" record no longer occupies `bucket(for:)`'s real-event buckets at all (see
        // `noneRecordCalendarPresenceHingesOnCheckedAt` above), so this straddle now pins the
        // `.earnings` item it was always really testing.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let calNow = utc.startOfDay(for: Self.now)

        func earningsBrief(_ symbol: String, dayOffset: Double) -> W.Brief {
            W.brief(for: SageFix.idea(symbol, conviction: 0.5),
                   inputs: W.Inputs(earningsDate: calNow.addingTimeInterval(dayOffset * 86_400), now: calNow))
        }
        let atSeven = earningsBrief("WK7", dayOffset: 7)     // still `.thisWeek`
        let atEight = earningsBrief("D8", dayOffset: 8)      // first day that is `.later`
        let entries = W.calendar([atSeven, atEight], now: calNow, calendar: utc)
        #expect(entries.map(\.idea.symbol) == ["WK7", "D8"])              // sorted by date
        #expect(entries.map(\.bucket) == [.thisWeek, .later])
    }

    // MARK: (a2) a past earnings date is not resurrected as an imminent catalyst — fix pass
    // 2026-09-06, blocker: the raw `earningsDate` fallback path used to re-derive severity from
    // ANY non-nil date with no age check, so a date the store's F32 eviction had already dropped
    // from the derived `earnings` dict came back as `.imminent`/"~0 days" via this fallback.

    @Test("a >24h-past earnings date yields no catalyst, not a resurrected 'imminent' one")
    func pastEarningsDateIsNotResurrected() {
        let idea = SageFix.idea("PAST", conviction: 0.5)
        let inputs = W.Inputs(earningsDate: days(-3), now: Self.now)   // reported 3 days ago
        let brief = W.brief(for: idea, inputs: inputs)
        #expect(brief.primary.kind == .none)                          // n=1 past-date case
        #expect(brief.secondary.isEmpty)
        let entries = W.calendar([brief], now: Self.now)
        #expect(entries.isEmpty)                                      // no `.today` (or any) row
    }

    @Test("an earnings date exactly at the F32 boundary (-86400s) still counts, one instant later doesn't")
    func earningsBoundaryMatchesStoreEviction() {
        // Mirrors StockSageStore.deriveEarningsProximity's own boundary comment verbatim: the
        // derive guard is `>= -86_400` (non-strict), so exactly -86400s is kept.
        let atBoundary = SageFix.idea("ATB", conviction: 0.5)
        let atBoundaryBrief = W.brief(for: atBoundary, inputs: W.Inputs(earningsDate: Self.now.addingTimeInterval(-86_400), now: Self.now))
        #expect(atBoundaryBrief.primary.kind == .earnings)

        let pastBoundary = SageFix.idea("PSTB", conviction: 0.5)
        let pastBoundaryBrief = W.brief(for: pastBoundary, inputs: W.Inputs(earningsDate: Self.now.addingTimeInterval(-86_400.001), now: Self.now))
        #expect(pastBoundaryBrief.primary.kind == .none)
    }

    // MARK: (b) earnings why — stop math and the no-stop sentence

    @Test("earnings why cites the stop price and the exact -x.x% move when a stop exists")
    func earningsWhyMentionsStopAndPercent() {
        // price 100, riskDistance 10, rr 2.0 (SageFix default) ⇒ stop 90.00, target 120.00,
        // pct = (90-100)/100*100 = -10.0 exactly.
        let idea = SageFix.idea("STOP", conviction: 0.6, price: 100, riskDistance: 10)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), now: Self.now))  // 2d ⇒ .imminent
        #expect(brief.primary.kind == .earnings)
        let why = brief.primary.why.joined(separator: " ")
        #expect(why.contains("90.00"))
        #expect(why.contains("-10.0%"))
        #expect(why.contains("120.00"))                            // the target bullet, since target exists
    }

    @Test("earnings why uses the no-stop sentence when rr is nil")
    func earningsWhyNoStopSentence() {
        let idea = SageFix.idea("NOSTOP", conviction: 0.6, rr: nil)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), now: Self.now))
        #expect(brief.primary.why == [
            "No stop is attached to this idea, so an overnight gap has no defined exit — size for that or wait.",
        ])                                                          // n=1 bullet
    }

    // MARK: (c) volumeMove caveat + headline

    @Test("volumeMove item carries StockSageCatalyst.caveat verbatim and a '× volume' headline")
    func volumeMoveCaveatAndHeadline() {
        let idea = SageFix.idea("NOTABLE", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(volumeMove: volSignal(rvol: 2.5, movePct: -4.5, tier: .notable), now: Self.now))
        #expect(brief.primary.kind == .volumeMove)
        #expect(brief.primary.caveat == StockSageCatalyst.caveat)
        #expect(brief.primary.headline.contains("× volume"))
    }

    // MARK: (d) calendar — dated buckets + undated tail, deterministic order

    @Test("calendar buckets today/tomorrow/thisWeek/later/undated in that order, sorted by date")
    func calendarBucketsInOrder() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let calNow = utc.startOfDay(for: Self.now)

        func earningsBrief(_ symbol: String, offsetDays: Double) -> W.Brief {
            let idea = SageFix.idea(symbol, conviction: 0.5)
            return W.brief(for: idea, inputs: W.Inputs(earningsDate: calNow.addingTimeInterval(offsetDays * 86_400), now: calNow))
        }
        let undatedBrief = W.brief(for: SageFix.idea("D4", conviction: 0.5),
                                   inputs: W.Inputs(volumeMove: volSignal(symbol: "D4"), now: calNow))

        let briefs = [
            earningsBrief("D0", offsetDays: 0.5),
            earningsBrief("D1", offsetDays: 1.2),
            earningsBrief("D2", offsetDays: 5),
            earningsBrief("D3", offsetDays: 20),
            undatedBrief,
        ]
        let entries = W.calendar(briefs, now: calNow, calendar: utc)
        #expect(entries.count == 5)                                        // n=5: one per brief
        #expect(entries.map(\.bucket) == [.today, .tomorrow, .thisWeek, .later, .undated])
        #expect(entries.map(\.item.symbol) == ["D0", "D1", "D2", "D3", "D4"])
        #expect(Set(entries.map(\.id)).count == 5)                         // n=5 unique ids
    }

    // MARK: (e) weights

    @Test("imminent earnings weighs high; a notable volume move weighs low")
    func weightsMapCorrectly() {
        let imminent = W.brief(for: SageFix.idea("IMM", conviction: 0.5),
                               inputs: W.Inputs(earningsDate: days(1), now: Self.now))   // 1d ⇒ .imminent
        #expect(imminent.primary.weight == .high)

        let notable = W.brief(for: SageFix.idea("NOT", conviction: 0.5),
                              inputs: W.Inputs(volumeMove: volSignal(tier: .notable), now: Self.now))
        #expect(notable.primary.weight == .low)
    }

    // MARK: (f) date strings are UTC-fixed — fix pass 2026-09-06, major: bucketing already used a
    // UTC calendar, but the headline/watch date strings were formatted in the viewer's local time
    // zone, so a "Today" row could show a date one day off the UTC day that put it there.

    @Test("earnings headline/watch dates are formatted UTC-fixed, independent of the viewer's locale/TZ")
    func earningsDateStringsAreUTCFixed() {
        // A literal, not a call to `W.dateStr` — pinning the FORMATTED STRING is what catches a
        // revert to `date.formatted(date:time:)` (local TZ/locale); calling the same helper the
        // production code calls would pass even after such a revert. Self.now = 1_757_000_000
        // (2025-09-04T15:33:20Z); +2 days = 2025-09-06T15:33:20Z ⇒ "Sep 6, 2025" in a fixed
        // en_US_POSIX/UTC style, verified against a standalone compile+run of the exact
        // Date.FormatStyle this file uses (fix pass 2026-09-06).
        let idea = SageFix.idea("TZFIX", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), now: Self.now))
        #expect(brief.primary.headline.hasSuffix("(Sep 6, 2025)"))
        #expect(brief.primary.watch.contains("Sep 6, 2025"))
    }

    // MARK: (g) extreme slot — review minor (d), fix pass 2026-09-06.

    @Test("recentExtreme .atHigh yields kind .extreme with 'At the N-day high'")
    func extremeSlotAtHighYieldsHeadline() {
        // Built directly (not SageFix.idea, which doesn't forward recentExtreme/Span) with no
        // earnings/volume/regime/seasonality input, so the extreme slot is what wins as primary.
        let idea = StockSageIdea(
            symbol: "EXT", market: "EXT", price: 100,
            advice: TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend, rationale: [],
                                stopPrice: nil, targetPrice: nil, suggestedWeight: 0.05, caveat: "x"),
            spark: [], recentExtreme: .atHigh, recentExtremeSpan: 63)
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now))
        #expect(brief.primary.kind == .extreme)
        #expect(brief.primary.headline == "At the 63-day high")
    }

    // MARK: (h) seasonality gate — review minor (d).

    @Test("seasonality requires isReliable AND |avgReturn| >= 0.01; a thin sample yields none")
    func seasonalityGateRequiresReliableAndNontrivial() {
        let month = StockSageSeasonality.currentMonth(asOf: Self.now)
        func seasonality(samples: Int, avgReturn: Double) -> MonthlySeasonality {
            var stats = (1...12).map { MonthlySeasonality.MonthStat(month: $0, avgReturn: 0, samples: 0) }
            stats[month - 1] = MonthlySeasonality.MonthStat(month: month, avgReturn: avgReturn, samples: samples)
            return MonthlySeasonality(months: stats, years: Double(samples))
        }

        // n=5 samples (>= 3, reliable) and |+2.0%| >= 1.0% ⇒ seasonality IS the primary item.
        let strongBrief = W.brief(for: SageFix.idea("SEAS1", conviction: 0.5),
                                  inputs: W.Inputs(seasonality: seasonality(samples: 5, avgReturn: 0.02), now: Self.now))
        #expect(strongBrief.primary.kind == .seasonality)

        // n=2 samples (< 3, NOT reliable) even with a large |+5.0%| return ⇒ no seasonality item.
        let thinBrief = W.brief(for: SageFix.idea("SEAS2", conviction: 0.5),
                                inputs: W.Inputs(seasonality: seasonality(samples: 2, avgReturn: 0.05), now: Self.now))
        #expect(thinBrief.primary.kind == .none)
    }

    // MARK: (i) undated calendar tail — weight-descending order — review minor (d).

    @Test("the undated calendar tail sorts weight-descending: high, medium, low")
    func undatedCalendarTailSortsByWeightDescending() {
        let briefs = [
            W.brief(for: SageFix.idea("LOWW", conviction: 0.5),
                   inputs: W.Inputs(volumeMove: volSignal(symbol: "LOWW", tier: .notable), now: Self.now)),
            W.brief(for: SageFix.idea("HIGH", conviction: 0.5),
                   inputs: W.Inputs(volumeMove: volSignal(symbol: "HIGH", tier: .major), now: Self.now)),
            W.brief(for: SageFix.idea("MEDI", conviction: 0.5),
                   inputs: W.Inputs(volumeMove: volSignal(symbol: "MEDI", tier: .significant), now: Self.now)),
        ]
        let entries = W.calendar(briefs, now: Self.now)
        #expect(entries.count == 3)                                        // n=3 undated primaries
        #expect(entries.allSatisfy { $0.bucket == .undated })
        #expect(entries.map(\.item.symbol) == ["HIGH", "MEDI", "LOWW"])     // high, medium, low
    }

    // MARK: (j) W1 (2026-09-06) — status rendering: confirmed suffix, projected, notApplicable

    @Test("dateKnown + confirmed:true appends '(confirmed)' to the existing earnings headline")
    func confirmedTrueAppendsConfirmedSuffix() {
        let idea = SageFix.idea("CONF", conviction: 0.6)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), earningsCheckedAt: Self.now, now: Self.now,
                                                        catalystConfirmed: true))
        #expect(brief.primary.kind == .earnings)
        #expect(brief.primary.headline == "Earnings in ~2 days (Sep 6, 2025) (confirmed)")
    }

    @Test("dateKnown + confirmed:false appends '(estimated)'")
    func confirmedFalseAppendsEstimatedSuffix() {
        let idea = SageFix.idea("EST", conviction: 0.6)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), earningsCheckedAt: Self.now, now: Self.now,
                                                        catalystConfirmed: false))
        #expect(brief.primary.headline == "Earnings in ~2 days (Sep 6, 2025) (estimated)")
    }

    @Test("confirmed:nil (no source supplied a flag) appends nothing — byte-identical to pre-W1")
    func confirmedNilAppendsNoSuffix() {
        let idea = SageFix.idea("NOFLAG", conviction: 0.6)
        let brief = W.brief(for: idea, inputs: W.Inputs(earningsDate: days(2), now: Self.now))
        #expect(brief.primary.headline == "Earnings in ~2 days (Sep 6, 2025)")
    }

    @Test("projected earnings: exact headline/why/source/kind, pinned verbatim")
    func projectedEarningsExactCopy() {
        let idea = SageFix.idea("PROJ", conviction: 0.5)
        let projectedDate = days(45)
        let basis = "median gap of last 3 reports = 91 d from 2026-07-30"
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now,
                                                        catalystProjectedDate: projectedDate,
                                                        catalystProjectionBasis: basis))
        #expect(brief.primary.kind == .projectedEarnings)
        #expect(brief.primary.date == projectedDate)
        #expect(brief.primary.headline
                == "Earnings expected ~\(W.dateStr(projectedDate)) (projected from recorded history, not announced)")
        #expect(brief.primary.why == [basis])
        #expect(brief.primary.source == "projection: \(basis)")
        #expect(brief.primary.watch == "Not an announced date — re-check after the next full refresh.")
    }

    @Test("precedence: projected sits below earnings-clear and above extreme")
    func projectedPrecedenceBetweenClearEarningsAndExtreme() {
        // No KNOWN earnings date (dateKnown and projected are mutually exclusive per the store's
        // chain) but a recent-high extreme IS present — projected must still win as primary.
        let idea = StockSageIdea(
            symbol: "PPREC", market: "PPREC", price: 100,
            advice: TradeAdvice(action: .buy, conviction: 0.5, regime: .bullTrend, rationale: [],
                                stopPrice: nil, targetPrice: nil, suggestedWeight: 0.05, caveat: "x"),
            spark: [], recentExtreme: .atHigh, recentExtremeSpan: 63)
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now,
                                                        catalystProjectedDate: days(45),
                                                        catalystProjectionBasis: "median gap of last 3 reports = 91 d from 2026-07-30"))
        #expect(brief.primary.kind == .projectedEarnings)
        #expect(brief.secondary.count == 1)
        #expect(brief.secondary.first?.kind == .extreme)
    }

    @Test("a lapsed projected date (>24h in the past) never surfaces — defense in depth against a stale cached record")
    func lapsedProjectedDateIsSuppressed() {
        // Major fix 2026-09-06: the chain itself now refuses to emit a lapsed projection, but a
        // record written before that fix could still be sitting on disk. This mirrors that guard
        // at the view layer so a stale cached `.projected` date can never resurrect itself.
        let idea = SageFix.idea("STALEPROJ", conviction: 0.5)
        let lapsedDate = days(-3)   // well past the -86_400 boundary
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now,
                                                        catalystProjectedDate: lapsedDate,
                                                        catalystProjectionBasis: "median gap of last 3 reports = 91 d from 2026-07-30"))
        #expect(brief.primary.kind != .projectedEarnings, "a lapsed projection must never be reported as an upcoming catalyst")
        #expect(!brief.all.contains { $0.kind == .projectedEarnings })
    }

    @Test("notApplicable: exact fallback headline/why/source, undated — only when nothing else applies")
    func notApplicableExactCopy() {
        let idea = SageFix.idea("IDX", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(now: Self.now, catalystNotApplicable: true))
        #expect(brief.primary.kind == .none)
        #expect(brief.primary.date == nil)
        #expect(brief.primary.headline == "No earnings: index/fund")
        #expect(brief.primary.why == ["This symbol is an index or fund — it has no company earnings to report."])
        #expect(brief.primary.source == "—")
        #expect(brief.secondary.isEmpty)
    }

    @Test("notApplicable never suppresses another real catalyst — a volume move still wins primary")
    func notApplicableDoesNotSuppressOtherCatalysts() {
        let idea = SageFix.idea("IDXVOL", conviction: 0.5)
        let brief = W.brief(for: idea, inputs: W.Inputs(volumeMove: volSignal(symbol: "IDXVOL"), now: Self.now,
                                                        catalystNotApplicable: true))
        #expect(brief.primary.kind == .volumeMove, "notApplicable only changes the NO-OTHER-CATALYST fallback")
    }

    @Test("a projected date buckets normally in the calendar, flagged isProjected — never checkedNoCatalyst")
    func projectedDateBucketsNormallyAndIsFlagged() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let calNow = utc.startOfDay(for: Self.now)
        let projectedDate = calNow.addingTimeInterval(3 * 86_400)   // ⇒ .thisWeek bucket
        let brief = W.brief(for: SageFix.idea("PCAL", conviction: 0.5),
                            inputs: W.Inputs(now: calNow, catalystProjectedDate: projectedDate,
                                             catalystProjectionBasis: "median gap of last 3 reports = 91 d from 2026-07-30"))
        let entries = W.calendar([brief], now: calNow, calendar: utc)
        #expect(entries.count == 1)
        #expect(entries[0].bucket == .thisWeek, "a projected date is a real event date — not the checkedNoCatalyst bucket")
        #expect(entries[0].isProjected)
        #expect(!entries[0].isNegativeRecord)
    }
}


extension StockSageCatalystWatchTests {
    @Test func lapsedPositiveScheduleIsNeverAnAnsweredEmptyCheck() {
        let prior = Self.now.addingTimeInterval(-3 * 86_400)
        let brief = W.brief(for: SageFix.idea("PAST", conviction: 0.5),
            inputs: W.Inputs(earningsDate: prior, earningsCheckedAt: prior.addingTimeInterval(-86_400),
                             now: Self.now, catalystSourcesAsked: ["calendar fixture"]))
        #expect(brief.primary.kind == .none && brief.primary.date == nil)
        #expect(brief.primary.headline.contains("Previous schedule passed"))
        #expect(!brief.primary.why.joined().contains("none returned"))
        #expect(brief.primary.why.joined().contains("Prior check:"))
    }
}
