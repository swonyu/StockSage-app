import Testing
import SwiftUI
@testable import StockSage

// Pure-helper pins for the catalysts tab view (owner request 2026-09-06, build step
// C3-view). Everything else in CatalystsSection needs a running app (it renders
// StockSageIdea/StockSageStore state); these three are the only parts pulled out as
// `nonisolated static func`/plain values specifically so they're checkable here.

@Suite("CatalystsSection — pure view helpers")
struct CatalystsSectionTests {

    @Test("one icon per catalyst Kind — all seven cases")
    func iconPerKind() {
        #expect(CatalystsSection.iconName(for: .earnings) == "calendar.badge.exclamationmark")
        #expect(CatalystsSection.iconName(for: .volumeMove) == "bolt.horizontal.circle.fill")
        #expect(CatalystsSection.iconName(for: .extreme) == "arrow.up.right.circle")
        #expect(CatalystsSection.iconName(for: .regime) == "gauge.with.needle")
        #expect(CatalystsSection.iconName(for: .seasonality) == "calendar")
        #expect(CatalystsSection.iconName(for: .none) == "questionmark.circle")
        #expect(CatalystsSection.iconName(for: .projectedEarnings) == "calendar.badge.clock")   // W1, 2026-09-06
    }

    @Test("action capsule fill matches the DS palette token per action")
    func actionFillMatchesPalette() {
        #expect(CatalystsSection.actionFill(for: .buy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .strongBuy) == DS.Palette.successSoft)
        #expect(CatalystsSection.actionFill(for: .hold) == DS.Palette.warningSoft)
        #expect(CatalystsSection.actionFill(for: .avoid) == Color.white.opacity(0.22))
        #expect(CatalystsSection.actionFill(for: .reduce) == DS.Palette.dangerSoft)
        #expect(CatalystsSection.actionFill(for: .sell) == DS.Palette.dangerSoft)
        // The gate must actually distinguish avoid from the two pastel tones it sits between.
        #expect(CatalystsSection.actionFill(for: .avoid) != DS.Palette.warningSoft)
    }

    @Test("Mode titles are Cards / Calendar, in that order")
    func modeTitles() {
        #expect(CatalystsSection.Mode.allCases.map(\.title) == ["Cards", "Calendar"])
    }

    // MARK: A5 — negative-record calendar row styling (keyed ONLY on the engine's isNegativeRecord flag)

    @Test("negative-record badge reads 'No known catalyst'; a real catalyst gets no badge")
    func negativeRecordBadge() {
        #expect(CatalystsSection.negativeRecordBadge(isNegativeRecord: true) == "No known catalyst")
        #expect(CatalystsSection.negativeRecordBadge(isNegativeRecord: false) == nil)
    }

    @Test("negative-record row color is the dimmer DS.Palette.textSecondary; a real row is textPrimary")
    func negativeRecordRowColor() {
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) == DS.Palette.textSecondary)
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: false) == DS.Palette.textPrimary)
        // The gate must actually dim, not merely differ — pin against the raw danger tones too so
        // a future edit can't quietly swap in a warning/danger tint for "no catalyst" (neutral).
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) != DS.Palette.danger)
        #expect(CatalystsSection.calendarRowColor(isNegativeRecord: true) != DS.Palette.dangerSoft)
    }

    @Test("negative-record row opacity dims below full; a real row stays at full opacity")
    func negativeRecordRowOpacity() {
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: true) == 0.6)
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: false) == 1.0)
        #expect(CatalystsSection.calendarRowOpacity(isNegativeRecord: true) < CatalystsSection.calendarRowOpacity(isNegativeRecord: false))
    }

    // MARK: Major fix 2026-09-06 — the empty state must not be fooled by negative records alone

    private static let now = Date(timeIntervalSince1970: 1_757_000_000)

    @Test("a calendar of ONLY dated 'none known' negative records reports no dated catalysts")
    func hasDatedCatalystsIsFalseForOnlyNegativeRecords() {
        let checked = StockSageCatalystWatch.brief(for: SageFix.idea("CHKD", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsCheckedAt: Self.now, now: Self.now,
                                                  catalystSourcesAsked: ["yahoo calendarEvents"]))
        let entries = StockSageCatalystWatch.calendar([checked], now: Self.now)
        #expect(!entries.isEmpty)                                     // the record IS on the calendar...
        #expect(!CatalystsSection.hasDatedCatalysts(entries))         // ...but it's not a REAL dated catalyst
    }

    @Test("a real earnings date makes hasDatedCatalysts true even alongside a negative record")
    func hasDatedCatalystsIsTrueWithARealCatalystPresent() {
        let checked = StockSageCatalystWatch.brief(for: SageFix.idea("CHKD", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsCheckedAt: Self.now, now: Self.now,
                                                  catalystSourcesAsked: ["yahoo calendarEvents"]))
        let real = StockSageCatalystWatch.brief(for: SageFix.idea("EARN", conviction: 0.5),
            inputs: StockSageCatalystWatch.Inputs(earningsDate: Self.now.addingTimeInterval(2 * 86_400), now: Self.now))
        let entries = StockSageCatalystWatch.calendar([checked, real], now: Self.now)
        #expect(CatalystsSection.hasDatedCatalysts(entries))
    }

    @Test("an empty calendar reports no dated catalysts")
    func hasDatedCatalystsIsFalseWhenEmpty() {
        #expect(!CatalystsSection.hasDatedCatalysts([]))
    }
}
