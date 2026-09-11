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

    // THE REFUTED EDIT, pinned. "Manual only" is a claim about the whole board, and it is false
    // whenever the stream is running — no toggle in that sheet stops the stream.
    @Test func manualOnlyIsNeverClaimedWhileStreaming() {
        let streamingAllOff = F.text(liveStream: true, autoRefresh: false, monitorEnabled: false, intervals: rest)
        #expect(streamingAllOff.contains("prices move on their own"))
        #expect(streamingAllOff.contains("non-streaming names update only when you pull to refresh"))
        // The unqualified sentence must NOT appear beside "prices move on their own".
        #expect(!streamingAllOff.contains("prices update only when you pull to refresh"))

        // With the stream off and both polls off, the unqualified claim is finally true.
        let darkBoard = F.text(liveStream: false, autoRefresh: false, monitorEnabled: false, intervals: rest)
        #expect(darkBoard.contains("prices update only when you pull to refresh or tap the refresh button"))
        #expect(!darkBoard.contains("prices move on their own"))
    }

    // Auto-refresh off does not mean nothing polls: the monitor is on by default and keeps going.
    @Test func theBackgroundMonitorIsNotMistakenForSilence() {
        let s = F.text(liveStream: false, autoRefresh: false, monitorEnabled: true, intervals: rest)
        #expect(s.contains("Strong-signal monitoring"))
        #expect(s.contains("every 3 minutes"))
        #expect(!s.contains("only when you pull to refresh"), "something still polls; manual-only would be false")
        // It names the control by its SHIPPED label so the reader can find it. The sheet's own
        // "Strong Buy / Sell signals" toggle is a different key and stops no poll.
        #expect(s.contains("the Markets alerts row"))
    }
}
