import Testing
import Foundation
@testable import StockSage

// BATCH 6.2 + 6.3 (2026-09-12).
//
// 6.2 — five pure helpers lived inside `#if os(macOS)`, so on iOS `cardHeadline` returned
// `item.headline` verbatim for an event whose date had already passed. `StockSageCatalystWatch`
// admits any date with `timeIntervalSince(now) >= -86_400`, so a report 0-24h in the past that
// fell on an EARLIER UTC civil day rendered as "Earnings in ~0 days", present tense, under the
// "Today" heading — while macOS showed "Earnings date · Date passed — outcome unverified".
//
// 6.3 — a superseded or aborted "Explain" published nothing and left the PREVIOUS paragraph on
// screen unmarked, so an abandoned press looked like a finished, current explanation.
@Suite("Catalysts — iOS dating and narration aborts")
struct CatalystsNarrationAndIOSDatingTests {

    private typealias S = CatalystsSection
    /// A fixed UTC instant; the helpers bucket by UTC civil day.
    private let now = Date(timeIntervalSince1970: 1_757_500_000)

    private func item(_ kind: StockSageCatalystWatch.Kind, date: Date?,
                      headline: String = "Earnings in ~0 days") -> StockSageCatalystWatch.Item {
        StockSageCatalystWatch.Item(symbol: "TST", kind: kind, headline: headline, date: date,
                                    why: ["why"], watch: "watch", weight: .medium,
                                    source: "test source", caveat: nil)
    }

    // MARK: 6.2 — the headline must not stay present-tense after the date passes

    @Test func apastDatedEarningsIsRelabelledOnEveryPlatform() {
        // 45,000s ago is inside the watch's -86,400s admission window but on the PREVIOUS UTC day.
        let yesterday = now.addingTimeInterval(-45_000)
        #expect(S.catalystCalendar.startOfDay(for: yesterday) < S.catalystCalendar.startOfDay(for: now),
                "premise: this instant really is an earlier UTC civil day")
        #expect(S.periodHeadline(item(.earnings, date: yesterday), now: now) == "Earnings date")
        #expect(S.periodHeadline(item(.projectedEarnings, date: yesterday), now: now) == "Projected earnings date")
        // cardHeadline is the call the iOS card actually makes — it used to gate this away.
        #expect(S.cardHeadline(item(.earnings, date: yesterday), displayNow: now) == "Earnings date")
    }

    @Test func afutureOrUndatedEventKeepsItsOwnHeadline() {
        let tomorrow = now.addingTimeInterval(45_000)
        #expect(S.periodHeadline(item(.earnings, date: tomorrow), now: now) == "Earnings in ~0 days")
        #expect(S.periodHeadline(item(.earnings, date: nil), now: now) == "Earnings in ~0 days")
        // No clock supplied ⇒ byte-identical to the pre-change behaviour.
        #expect(S.cardHeadline(item(.earnings, date: tomorrow), displayNow: nil) == "Earnings in ~0 days")
    }

    // THE REFUTED EDIT, pinned. The iOS bucket list includes `.undated`; for a dateless entry
    // `eventStatus` falls through every guard and returns "Scheduled / estimated" — a schedule
    // claim about an item with no date. macOS never hit it because `periodEntries` filters on
    // `guard let date` upstream, which the un-gated iOS path has not got.
    @Test func eventStatusStillClaimsAScheduleForAnUndatedEntry() {
        let undated = StockSageCatalystWatch.CalendarEntry(
            bucket: .undated, item: item(.earnings, date: nil),
            idea: SageFix.idea("TST", conviction: 0.5), isNegativeRecord: false, isProjected: false)
        #expect(S.eventStatus(undated, now: now) == "Scheduled / estimated",
                "the helper itself is unchanged — the CALLER must not show it for a dateless row")
    }

    @Test func aPassedDateIsReportedAsUnverifiedNotAsScheduled() {
        func entry(_ date: Date?, _ projected: Bool,
                   _ kind: StockSageCatalystWatch.Kind) -> StockSageCatalystWatch.CalendarEntry {
            StockSageCatalystWatch.CalendarEntry(bucket: .thisWeek, item: item(kind, date: date),
                                                 idea: SageFix.idea("TST", conviction: 0.5),
                                                 isNegativeRecord: false, isProjected: projected)
        }
        let past = now.addingTimeInterval(-45_000), future = now.addingTimeInterval(45_000)
        #expect(S.eventStatus(entry(past, false, .earnings), now: now) == "Date passed — outcome unverified")
        #expect(S.eventStatus(entry(future, false, .earnings), now: now) == "Scheduled / estimated")
        #expect(S.eventStatus(entry(past, true, .earnings), now: now)
                == "Projected from history — not announced · Date passed — outcome unverified")
        // A filed/announced record is REPORTED regardless of date — it already happened.
        #expect(S.eventStatus(entry(past, false, .filing8K), now: now) == "Reported")
    }

    // MARK: 6.3 — an abandoned Explain must say so

    @Test func anAbortedExplanationNamesItsCauseAndKeepsThePriorParagraphHonest() {
        let superseded = S.narrationAbortReason(settingsChanged: true)
        let other = S.narrationAbortReason(settingsChanged: false)
        #expect(superseded != other, "a settings change and a lost source are different facts")
        #expect(superseded.contains("model settings changed"))
        // Every other abort must NOT be reported as a settings change it wasn't.
        #expect(!other.contains("settings changed"))
        #expect(other.contains("cited sources or external access changed"))
        // Neither claims the paragraph below is gone — it is retained on purpose, so the copy
        // has to name it as the PREVIOUS one rather than let it read as current.
        for reason in [superseded, other] {
            #expect(reason.contains("PREVIOUS one"))
            #expect(reason.contains("Tap Explain"), "an aborted press must offer the retry")
        }
    }
}
