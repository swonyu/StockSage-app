import Testing
import Foundation
@testable import StockSage

// BATCH 12.4 — the iOS "Live data" footer must describe the timers that actually run.
//
// It stated a 4.75-minute cadence NO TIMER USES. The only auto-refresh loops consume
// `MarketsView.refreshIntervals` — (30s, 900s) at rest, (60s, 1800s) when thermally stressed —
// and the background monitor polls every 180s.
//
// The second defect is subtler and is why this suite exists rather than a one-line copy edit: the
// obvious rewrite ("both toggles off ⇒ manual refresh only") is FALSE while streaming is on,
// because the live stream is gated on `liveStreamEnabled` alone and neither toggle in that sheet
// touches it. The footer would have contradicted its own first sentence.
@Suite("iOS Live data footer")
struct StockSageLiveDataFooterTests {

    private typealias F = StockSageLiveDataFooter
    private let rest = (streamGap: 30, full: 900)
    private let hot = (streamGap: 60, full: 1800)

    // The premise: these are the real numbers, read from the shipped source of truth.
    @Test func theCadenceComesFromTheShippedIntervals() {
        #expect(MarketsView.refreshIntervals(thermal: .nominal) == (streamGap: 30, full: 900))
        #expect(MarketsView.refreshIntervals(thermal: .critical) == (streamGap: 60, full: 1800))
    }

    @Test func noStateEverClaimsTheRetiredCadence() {
        for live in [true, false] {
            for auto in [true, false] {
                for monitor in [true, false] {
                    for iv in [rest, hot] {
                        let s = F.text(liveStream: live, autoRefresh: auto, monitorEnabled: monitor, intervals: iv)
                        #expect(!s.contains("4.75"), "the retired cadence came back: \(s)")
                        #expect(!s.contains("285"))
                    }
                }
            }
        }
    }

    @Test func theStatedCadenceTracksTheThermalState() {
        let cool = F.text(liveStream: true, autoRefresh: true, monitorEnabled: true, intervals: rest)
        #expect(cool.contains("every 30s") && cool.contains("every 15 minutes"))
        let stressed = F.text(liveStream: true, autoRefresh: true, monitorEnabled: true, intervals: hot)
        #expect(stressed.contains("every 60s") && stressed.contains("every 30 minutes"))
        // The sweep cap is the shipped constant, not a copy of it.
        #expect(cool.contains("up to \(StockSageStore.streamGapMaxPerSweep) tracked names"))
    }

    @Test func disabledPollingStillDisclosesStartupAndTrackedQuoteRequests() {
        for live in [false, true] {
            let copy = F.text(liveStream: live, autoRefresh: false, monitorEnabled: false, intervals: rest)
            #expect(copy.contains("when StockSage opens") && copy.contains("newly tracked names"))
            #expect(copy.contains("Periodic market refresh is off"))
            #expect(!copy.contains("only when you pull to refresh"))
            #expect(copy.contains("prices move on their own") == live)
        }
    }

    @Test(arguments: [false, true])
    func theBackgroundMonitorDescribesOnlySavedPriceAlerts(autoRefresh: Bool) {
        let copy = F.text(liveStream: false, autoRefresh: autoRefresh, monitorEnabled: true, intervals: hot)
        #expect(copy.contains("normally every 3 minutes"))
        #expect(copy.contains("every 6 minutes under thermal pressure"))
        #expect(copy.contains("Library → Alerts → Price-alert monitoring"))
        #expect(!copy.contains("Strong-signal"))
    }
}
