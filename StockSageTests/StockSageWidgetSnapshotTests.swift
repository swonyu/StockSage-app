import Testing
import Foundation
@testable import StockSage

// The home-screen widget's snapshot (2026-09-11).
//
// WHY THIS FILE EXISTS. Until today `StockSageWidgetSnapshot` had ZERO references across a
// 2,230-test suite while being referenced six times in shipped source. That is how a defect of
// this shape survives: the widget's heat figure summed native-currency legs against a USD
// account, overstating a Saudi leg's risk by 3.75x on the home screen, and no test could notice.
// The FX audit that found every other heat call site grepped callers of
// StockSagePortfolioHeat.compute; the widget's hand-rolled sum matched no such grep.
//
// These tests pin the type's OWN contract — the age and provenance rules the widget face depends
// on — rather than re-testing SwiftUI. `getTimeline` itself is not reachable from a unit test
// (WidgetKit owns it), so what is pinned here is the property that fix relies on: every age
// question must be answerable AGAINST A SUPPLIED DATE, never only against "now".
@Suite("Widget snapshot — age and provenance", .serialized)
struct StockSageWidgetSnapshotTests {

    private let asOf = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(heat: Double? = 4, cap: Double = 8, sample: Bool = false) -> StockSageWidgetSnapshot {
        StockSageWidgetSnapshot(asOf: asOf, bestSymbol: "AAPL", bestAction: "Rules: Buy",
                                bestStrength: 3, openPositions: 2, portfolioHeatPct: heat,
                                heatCapPct: cap, forwardCloses: 1, forwardNeeded: 4,
                                isSampleData: sample, portfolioHeatIsComplete: heat != nil)
    }

    // MARK: The property the widget's frozen-clock fix depends on

    // WidgetKit renders an entry once and keeps showing that bitmap; the view is not re-evaluated
    // while it sits on screen. So the widget must age its figures against the ENTRY's date, and
    // that is only possible if these take a date at all. A regression to "now"-only would make
    // `getTimeline`'s series pointless while leaving every other test green.
    @Test func ageIsAnsweredAgainstTheSuppliedDateNotTheWallClock() {
        let s = snapshot()
        #expect(s.ageText(now: asOf.addingTimeInterval(90)) == "1m ago")
        #expect(s.ageText(now: asOf.addingTimeInterval(3 * 3600)) == "3h ago")
        #expect(s.ageText(now: asOf.addingTimeInterval(26 * 3600)) == "yesterday")
        // Two different supplied dates must not produce the same answer, which is exactly what a
        // frozen render did.
        #expect(s.ageText(now: asOf.addingTimeInterval(90)) != s.ageText(now: asOf.addingTimeInterval(3 * 3600)))
    }

    @Test func stalenessFlipsExactlyAtTheBoundary() {
        let s = snapshot()
        let cutoff = StockSageWidgetSnapshot.staleAfter
        #expect(!s.isStale(now: asOf.addingTimeInterval(cutoff - 1)))
        #expect(s.isStale(now: asOf.addingTimeInterval(cutoff)),
                "The explicitly scheduled stale-boundary timeline entry must already render stale")
        #expect(s.isStale(now: asOf.addingTimeInterval(cutoff + 1)))
    }

    // "Somehow newer than now" is not evidence of freshness — a changed clock is the likeliest
    // cause, and the widget must not present the figures as current.
    @Test func aFutureStampIsStaleAndNeverRendersNegativeTime() {
        let s = snapshot()
        #expect(s.isStale(now: asOf.addingTimeInterval(-3600)))
        #expect(s.ageText(now: asOf.addingTimeInterval(-3600)) == "clock changed")
    }

    @Test func invalidClockCannotLookFresh() {
        for offset in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let invalid = Date(timeIntervalSince1970: offset)
            #expect(snapshot().isStale(now: invalid))
            #expect(snapshot().ageText(now: invalid) == "time unverified")
        }
    }

    @Test func corruptedFiniteSnapshotDateCannotOverflowTheWidgetAgeLabel() throws {
        let data = Data(#"{"asOf":-1e300,"heatCapPct":8,"forwardNeeded":4,"isSampleData":false}"#.utf8)
        let decoded = try JSONDecoder().decode(StockSageWidgetSnapshot.self, from: data)
        #expect(decoded.isStale(now: asOf))
        #expect(decoded.ageText(now: asOf) == "time unverified")
    }

    // MARK: The bar must not make "undrawable" look like "empty"

    @Test func heatFractionRefusesToDrawWhatItCannotKnow() {
        #expect(snapshot(heat: 4, cap: 8).heatFractionOfCap == 0.5)
        #expect(snapshot(heat: nil).heatFractionOfCap == nil, "no heat must not render as an empty bar")
        #expect(snapshot(heat: 4, cap: 0).heatFractionOfCap == nil, "a degenerate cap must not render")
        #expect(snapshot(heat: .nan).heatFractionOfCap == nil)
        #expect(snapshot(heat: -1).heatFractionOfCap == nil)
        // Clamped, so an over-cap book fills the bar rather than overflowing it.
        #expect(snapshot(heat: 99, cap: 8).heatFractionOfCap == 1)
    }

    // The snapshot's own documentation forbids publishing a reassuring zero: "Writing 0 when it is
    // unknown would render '0.0% of 8%' — a specific, reassuring, and false claim." nil is the
    // only honest representation, and the writer now withholds it when the paper book fails to
    // load rather than reporting an empty book as an empty risk.
    @Test func unknownHeatIsNilRatherThanZero() {
        let unknown = snapshot(heat: nil)
        #expect(unknown.portfolioHeatPct == nil)
        #expect(unknown.heatFractionOfCap == nil)
        let zero = snapshot(heat: 0)
        #expect(zero.heatFractionOfCap == 0, "a genuine zero is drawable and must not be confused with unknown")
        #expect(zero.paperHeatText == "Paper stop risk 0.0% of account; cap 8.0%")
    }

    @Test func unavailablePaperBookAndCacheProvenanceRemainExplicitAfterRoundTrip() throws {
        var unknown = StockSageWidgetSnapshot(asOf: asOf, bestSymbol: nil, bestAction: nil,
            bestStrength: nil, openPositions: nil, portfolioHeatPct: nil, heatCapPct: 8,
            forwardCloses: nil, forwardNeeded: 4, isSampleData: false, isCachedData: true)
        let restored = try JSONDecoder().decode(StockSageWidgetSnapshot.self, from: JSONEncoder().encode(unknown))
        #expect(restored == unknown)
        #expect(restored.paperPositionsText == "Paper records unavailable")
        #expect(restored.forwardProgressText == "Forward record unavailable")
        #expect(restored.sourceText == "CACHED")
        unknown.isCachedData = false
        #expect(unknown.sourceText == "LAST SCAN")
        #expect(snapshot(sample: true).sourceText == "SAMPLE")
        #expect(snapshot().paperPositionsText == "Paper · 2 open")
        #expect(snapshot().forwardProgressText == "Paper forward test 1/4")
    }

    @Test func olderSnapshotsKeepCountsWithoutInventingLiveProvenance() throws {
        let old = Data(#"{"asOf":721692800,"bestSymbol":"AAPL","bestAction":"Rules: Buy","bestStrength":3,"openPositions":2,"portfolioHeatPct":4,"heatCapPct":8,"forwardCloses":1,"forwardNeeded":4,"isSampleData":false}"#.utf8)
        let restored = try JSONDecoder().decode(StockSageWidgetSnapshot.self, from: old)
        #expect(restored.openPositions == 2 && restored.forwardCloses == 1)
        #expect(restored.isCachedData == nil && restored.sourceText == "SNAPSHOT")
        #expect(restored.portfolioHeatPct == 4, "Preserve the old stored value as evidence; do not repair it silently")
        #expect(restored.portfolioHeatIsComplete == nil)
        #expect(restored.paperHeatText == "Paper stop risk unavailable")
        #expect(restored.heatFractionOfCap == nil && !restored.isAtHeatCap)
    }

    @Test func correctedCompleteHeatRemainsKnownAfterRoundTrip() throws {
        let complete = snapshot(heat: 4)
        let restored = try JSONDecoder().decode(StockSageWidgetSnapshot.self, from: JSONEncoder().encode(complete))
        #expect(restored == complete && restored.portfolioHeatIsComplete == true)
        #expect(restored.paperHeatText == "Paper stop risk 4.0% of account; cap 8.0%")
        #expect(restored.heatFractionOfCap == 0.5)
        var incomplete = complete
        incomplete.portfolioHeatIsComplete = false
        #expect(incomplete.paperHeatText == "Paper stop risk unavailable")
        #expect(incomplete.heatFractionOfCap == nil && !incomplete.isAtHeatCap)
    }
}
