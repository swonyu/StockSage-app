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
        #expect(brief.primary.why == [
            "Next earnings date not available for this name — not fetched yet, or the source declined.",
            "No volume-confirmed move on the latest cached bar.",
        ])                                                        // n=2 bullets, pinned verbatim
        #expect(brief.secondary.isEmpty)
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
}
