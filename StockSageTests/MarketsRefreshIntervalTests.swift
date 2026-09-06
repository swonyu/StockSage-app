import Testing
import Foundation
@testable import StockSage

// MARK: - MarketsView.refreshIntervals(thermal:) — B3 auto-refresh timer split
//
// Hand-derived (2026-09-06, revised W3): the two owner-facing cadences at rest are 30s for the
// `.streamGap` top-up (owner: "update automatically every 30 seconds" — dropped from this
// commit's prior 60s pin so a polled row heals within the stated window) and 900s for the
// `.full` sweep (unchanged — no owner cadence requirement, and doubling its rate would double
// the API budget for the whole-board + catalyst-rescan pass with no benefit).
// The thermal brake mirrors StockSageMonitor's own ×2 back-off under `.serious`/`.critical`
// ProcessInfo.thermalState (StockSageMonitor.swift ~126-129: `stressed ? interval * 2 : interval`)
// applied to BOTH cadences here: 30×2 = 60, 900×2 = 1800. `.nominal`/`.fair` are the two
// UNstressed states, `.serious`/`.critical` the two stressed ones — every case of the enum is
// covered by one of the four tests below.
struct MarketsRefreshIntervalTests {
    @Test func nominalThermalUsesRestIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .nominal)
        #expect(result.streamGap == 30)
        #expect(result.full == 900)
    }

    @Test func fairThermalUsesRestIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .fair)
        #expect(result.streamGap == 30)
        #expect(result.full == 900)
    }

    @Test func seriousThermalDoublesBothIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .serious)
        #expect(result.streamGap == 60)
        #expect(result.full == 1800)
    }

    @Test func criticalThermalDoublesBothIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .critical)
        #expect(result.streamGap == 60)
        #expect(result.full == 1800)
    }
}
