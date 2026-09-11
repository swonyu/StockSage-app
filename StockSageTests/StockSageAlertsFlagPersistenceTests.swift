import Testing
import Foundation
@testable import StockSage

// BATCH 12.1 (2026-09-12) — the Signal-alerts toggle survives a relaunch, and Chat stops
// contradicting it.
//
// TWO HALVES THAT MUST LAND TOGETHER. Persisting the flag without the Chat fix would make the
// contradiction survive relaunch instead of dying with the process: Chat tested `alerts.isEmpty`
// BEFORE the flag, so a retained log from a session where the toggle was later switched off still
// rendered under a live-sounding header, while MarketsView.alertsPanel tested the flag first.
//
// The LOG is deliberately NOT persisted. After a relaunch with the flag on, Chat reads "No events
// recorded in the app log" — that means "nothing recorded this session", not "nothing happened",
// and the copy says so.
@Suite("Signal alerts — flag persistence and Chat precedence", .serialized)
@MainActor
struct StockSageAlertsFlagPersistenceTests {

    private typealias C = StockSageChatSection

    private func freshDefaults() throws -> UserDefaults {
        let suite = "stocksage.tests.alertsflag." + UUID().uuidString
        return try #require(UserDefaults(suiteName: suite))
    }

    // The defect: a second store on the same suite read `false` no matter what the owner chose.
    @Test func theToggleSurvivesARelaunch() throws {
        let defaults = try freshDefaults()
        let first = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(!first.alertsEnabled, "opt-in default must be off on a first run")

        first.alertsEnabled = true
        let second = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(second.alertsEnabled, "the owner's choice must survive relaunch")

        // And off must persist as off, not merely fall back to the default and look correct.
        second.alertsEnabled = false
        let third = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(!third.alertsEnabled)
    }

    // A store on an untouched suite must not inherit another suite's choice.
    @Test func anAbsentKeyKeepsTheOptInDefault() throws {
        let store = StockSageStore(defaults: try freshDefaults(), heldSymbols: { [] })
        #expect(!store.alertsEnabled)
    }

    // The log is memory-only by design. Pinned so nobody "fixes" the relaunch-empty log by
    // persisting events and quietly turns a session log into a durable claim.
    @Test func theEventLogItselfIsNotPersisted() throws {
        let defaults = try freshDefaults()
        let first = StockSageStore(defaults: defaults, heldSymbols: { [] })
        first.alertsEnabled = true
        let second = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(second.alerts.isEmpty)
        #expect(C.eventLogHeader(C.eventLog(enabled: second.alertsEnabled, count: second.alerts.count))
                    .contains("No events recorded in the app log"))
    }

    // MARK: The precedence the Chat branch had backwards

    @Test func theFlagIsTestedBeforeEmptiness() {
        // Off with a retained log: visible, but never labelled live.
        let retained = C.eventLog(enabled: false, count: 3)
        #expect(retained == .off(retained: 3))
        #expect(retained.shownCount == 3)
        let header = C.eventLogHeader(retained)
        #expect(header.contains("Event logging is off"))
        #expect(header.contains("3 recorded before it was turned off"))
        #expect(header.contains("no longer updating"))
        // The live header must NOT be reachable while the flag is off — that was the defect.
        #expect(!header.contains("Recent app events"))

        // Off with nothing retained: no list at all, just the caption.
        let plainOff = C.eventLog(enabled: false, count: 0)
        #expect(plainOff.shownCount == nil)
        #expect(C.eventLogHeader(plainOff) == "Event logging is off. Chat does not enable alerts or background monitoring.")

        // On and empty: a caption, not an empty disclosure group.
        #expect(C.eventLog(enabled: true, count: 0) == .onEmpty)
        #expect(C.eventLog(enabled: true, count: 0).shownCount == nil)

        // On with events: byte-identical to the previous behaviour, capped at 5.
        #expect(C.eventLog(enabled: true, count: 3) == .recorded(shown: 3))
        #expect(C.eventLog(enabled: true, count: 12) == .recorded(shown: 5))
        #expect(C.eventLogHeader(.recorded(shown: 5)) == "Recent app events · 5 shown")
        // A retained log is capped the same way, so a 50-event log cannot render 50 rows.
        #expect(C.eventLog(enabled: false, count: 50).shownCount == 5)
    }
}
