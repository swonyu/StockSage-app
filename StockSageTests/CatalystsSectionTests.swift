import Testing
import SwiftUI
@testable import StockSage

// Pure-helper pins for the catalysts tab view (owner request 2026-09-06, build step
// C3-view). Everything else in CatalystsSection needs a running app (it renders
// StockSageIdea/StockSageStore state); helpers and connection lifecycle transitions
// are plain values so they can be checked without owner settings or real network calls.

@Suite("CatalystsSection — pure view helpers")
struct CatalystsSectionTests {

    @Test("late connection probes cannot publish for new settings or clear a newer spinner")
    @MainActor func connectionProbeCompletionBelongsToItsRequest() async {
        let a = ["localServerOnly", "http://127.0.0.1:8765", "model-A"]
        let b = ["localServerOnly", "http://127.0.0.1:8765", "model-B"]
        let reachable = StockSageLocalModelServer.Probe(reachable: true, isOllama: false,
            models: ["model-A"], hasModel: true, detail: "model-A present")
        var state = CatalystsSection.ConnectionProbeState()
        let old = state.begin(settings: a)
        let latest = state.begin(settings: b)
        state.finish(reachable, request: old, currentSettings: b, cancelled: false)
        #expect(state.current(for: b) == nil)
        #expect(state.probing)
        #expect(!StockSageCatalystNarrator.explainAvailable(backend: .localServerOnly,
            onDevice: .unavailable("fixture"), probe: state.current(for: b)))
        state.finish(nil, request: latest, currentSettings: b, cancelled: false)
        #expect(!state.probing && state.current(for: b) == nil)

        // A single matching request works; a settings edit hides it BEFORE another task starts.
        let matching = state.begin(settings: a)
        state.finish(reachable, request: matching, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == reachable)
        for settings in [b, ["localServerOnly", "http://127.0.0.1:11434", "model-A"],
                         ["off", a[1], a[2]], ["onDeviceOnly", a[1], a[2]]] {
            #expect(state.current(for: settings) == nil && !state.isProbing(for: settings))
        }

        // Same-settings overlap still needs request identity, not only settings equality.
        let sameOld = state.begin(settings: a)
        let sameNew = state.begin(settings: a)
        #expect(state.current(for: a) == nil)
        state.finish(reachable, request: sameOld, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && state.isProbing(for: a))
        state.finish(nil, request: sameNew, currentSettings: a, cancelled: false)
        state.finish(reachable, request: sameOld, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && !state.probing)

        // Cancellation, a settings edit during await, and disappearance all reject late replies.
        for cancelled in [false, true] {
            let id = state.begin(settings: a)
            state.finish(reachable, request: id, currentSettings: cancelled ? a : b, cancelled: cancelled)
            #expect(state.current(for: a) == nil && !state.probing)
        }
        let disappeared = state.begin(settings: a)
        state = .init()
        state.finish(reachable, request: disappeared, currentSettings: a, cancelled: false)
        #expect(state.current(for: a) == nil && !state.probing)
        #expect(await StockSageCatalystNarrator.probeServer(config: nil) == nil)

        // Equal values after A→B→A still carry a new in-app revision.
        let firstRevision = a + ["revision-1"]
        let nextRevision = a + ["revision-2"]
        let roundTrip = state.begin(settings: firstRevision)
        state.finish(reachable, request: roundTrip, currentSettings: nextRevision, cancelled: false)
        #expect(state.current(for: nextRevision) == nil && !state.probing)
    }

    @Test("an explanation is current only for the facts AND settings that requested it")
    func narrationSettingsAndFactsMustMatch() {
        let saved = ["localServerOnly", "http://127.0.0.1:8765", "model-A"]
        let facts = ["Price: 100"]
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
            savedSettings: saved, currentSettings: saved) == nil)
        for (index, value) in [(0, "off"), (0, "onDeviceOnly"), (0, "auto"),
                                (1, "http://127.0.0.1:11434"), (2, "model-B")] {
            var current = saved
            current[index] = value
            #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
                savedSettings: saved, currentSettings: current) != nil)
        }
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: facts,
            savedSettings: nil, currentSettings: saved) != nil)
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: facts, currentFacts: ["Price: 101"],
            savedSettings: saved, currentSettings: saved) != nil)
        #expect(CatalystsSection.narrationRefreshReason(savedFacts: nil, currentFacts: facts,
            savedSettings: saved, currentSettings: saved) != nil)
    }

    @Test("one icon per catalyst Kind — all twelve cases")
    func iconPerKind() {
        #expect(CatalystsSection.iconName(for: .earnings) == "calendar.badge.exclamationmark")
        #expect(CatalystsSection.iconName(for: .volumeMove) == "bolt.horizontal.circle.fill")
        #expect(CatalystsSection.iconName(for: .extreme) == "arrow.up.right.circle")
        #expect(CatalystsSection.iconName(for: .regime) == "gauge.with.needle")
        #expect(CatalystsSection.iconName(for: .seasonality) == "calendar")
        #expect(CatalystsSection.iconName(for: .none) == "questionmark.circle")
        #expect(CatalystsSection.iconName(for: .projectedEarnings) == "calendar.badge.clock")   // W1, 2026-09-06
        #expect(CatalystsSection.iconName(for: .filing8K) == "doc.text.magnifyingglass")
        #expect(CatalystsSection.iconName(for: .ratingChange) == "person.text.rectangle")
        #expect(CatalystsSection.iconName(for: .guidanceChange) == "text.bubble")
        #expect(CatalystsSection.iconName(for: .exDividend) == "calendar.badge.plus")
        #expect(CatalystsSection.iconName(for: .insiderTrade) == "person.crop.circle.badge.clock")
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
