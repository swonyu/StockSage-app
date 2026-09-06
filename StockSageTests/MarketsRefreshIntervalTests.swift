import Testing
import Foundation
@testable import StockSage

// MARK: - MarketsView.refreshIntervals(thermal:) — B3 auto-refresh timer split
//
// Hand-derived (2026-09-06): the two owner-facing cadences at rest are 60s for the `.streamGap`
// top-up and 900s for the `.full` sweep (this commit's numbers, replacing the single 285s timer).
// The thermal brake mirrors StockSageMonitor's own ×2 back-off under `.serious`/`.critical`
// ProcessInfo.thermalState (StockSageMonitor.swift ~126-129: `stressed ? interval * 2 : interval`)
// applied to BOTH cadences here: 60×2 = 120, 900×2 = 1800. `.nominal`/`.fair` are the two
// UNstressed states, `.serious`/`.critical` the two stressed ones — every case of the enum is
// covered by one of the four tests below.
struct MarketsRefreshIntervalTests {
    @Test func nominalThermalUsesRestIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .nominal)
        #expect(result.streamGap == 60)
        #expect(result.full == 900)
    }

    @Test func fairThermalUsesRestIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .fair)
        #expect(result.streamGap == 60)
        #expect(result.full == 900)
    }

    @Test func seriousThermalDoublesBothIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .serious)
        #expect(result.streamGap == 120)
        #expect(result.full == 1800)
    }

    @Test func criticalThermalDoublesBothIntervals() {
        let result = MarketsView.refreshIntervals(thermal: .critical)
        #expect(result.streamGap == 120)
        #expect(result.full == 1800)
    }
}
