import Testing
import Foundation
@testable import StockSage

// BATCH 9.1 (2026-09-12) — a volume spike must say WHEN it happened.
//
// The headline read "6.0x volume, +7.2% on the latest cached bar — Major": it named WHERE the bar
// came from but never WHEN. A freshly fetched history whose newest bar is weeks old — a halted or
// thinly traded name — produced a present-tense headline about a move that finished a month ago,
// and because a .major tier maps to .high weight it outranked a dated, upcoming earnings date for
// the brief's primary slot. So the stale spike did not merely appear: it displaced real news.
//
// Demoted, not hidden. It genuinely happened, and suppressing it would be its own dishonesty.
@Suite("Stale volume catalyst")
struct StockSageStaleVolumeCatalystTests {

    private typealias W = StockSageCatalystWatch
    private typealias C = StockSageCatalyst
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }

    private func signal(barDate: Date?, mechanical: Bool? = false) -> C.Signal {
        C.Signal(symbol: "TST", rvol: 6.0, priceChangePct: 7.2, tier: .major,
                 likelyMechanicalFlow: mechanical, caveat: C.caveat, barDate: barDate)
    }

    private func item(_ s: C.Signal) -> W.Item {
        let idea = SageFix.idea("TST", conviction: 0.5)
        return W.brief(for: idea, inputs: W.Inputs(volumeMove: s, now: now)).primary
    }

    @Test func afreshSpikeKeepsItsTierWeightAndIsDated() {
        let fresh = item(signal(barDate: at(1)))
        #expect(fresh.weight == .high, ".major keeps its weight when the bar is recent")
        #expect(fresh.date == at(1), "the item carries the measured bar's date")
        #expect(!fresh.caveat!.contains("days old"))
    }

    // The defect: a month-old bar, described in the present tense, at the top of the brief.
    @Test func aStaleSpikeIsDatedDemotedAndSaysHowOld() throws {
        let stale = item(signal(barDate: at(30)))
        let caveat = try #require(stale.caveat)
        #expect(caveat.contains("30 days old"))
        #expect(caveat.contains("history, not a move happening now"))
        #expect(stale.weight == .low, "a month-old spike must not outrank a dated upcoming catalyst")
        #expect(stale.date == at(30), "it is still shown, and now carries its real date")
    }

    // The boundary is the history cache's own, so the two cannot disagree about one bar.
    @Test func theDemotionStraddlesTheCacheStalenessBoundary() {
        #expect(item(signal(barDate: at(7))).weight == .high, "exactly 7 days is not yet stale")
        #expect(item(signal(barDate: at(8))).weight == .low)
    }

    // An undated signal must behave EXACTLY as it did before barDate existed — that is what keeps
    // every pre-existing headline pin valid.
    @Test func anUndatedSignalIsUnchanged() {
        let undated = item(signal(barDate: nil))
        #expect(undated.weight == .high)
        #expect(undated.date == nil)
        #expect(undated.headline.contains("on the latest cached bar"))
        #expect(undated.caveat == C.caveat, "byte-identical to the pre-existing caveat")
    }

    // 9.2's UI half: an unknown ADV gets its own bullet. Silence would read as "checked, and it is
    // information" — the opposite of what nil means.
    @Test func anUnknownADVGetsItsOwnBulletRatherThanSilence() {
        #expect(item(signal(barDate: at(1), mechanical: false)).why.count == 1)
        let flagged = item(signal(barDate: at(1), mechanical: true))
        #expect(flagged.why.count == 2 && flagged.why[1].contains("passive/index flow"))
        let unknown = item(signal(barDate: at(1), mechanical: nil))
        #expect(unknown.why.count == 2 && unknown.why[1].contains("not known for this name"))
    }

    // 9.2's engine half: the flag was inert in a normal session because `liquidity` is empty until
    // a detail sheet is opened. ADV now comes from the histories the scan already holds.
    @Test func advIsComputedFromHistoriesAndOnlyForUSDPricedNames() {
        func hist(_ s: String) -> StockSagePriceHistory {
            // 30 flat bars of 50 x 2,000,000 sh = $100,000,000/day — checkable by eye.
            StockSagePriceHistory(symbol: s, dates: [], opens: [], highs: [], lows: [],
                                  closes: Array(repeating: 50, count: 30),
                                  volumes: Array(repeating: 2_000_000, count: 30))
        }
        let out = StockSageLiquidity.advDollarBySymbol(
            histories: ["AAPL": hist("AAPL"), "VOD.L": hist("VOD.L"), "MSFT": hist("MSFT")],
            known: ["MSFT": 7_000_000_000])
        #expect(abs((out["AAPL"] ?? 0) - 100_000_000) < 1e-6)   // computed from the cached history
        #expect(out["MSFT"] == 7_000_000_000)                   // a known profile is never recomputed
        #expect(out["VOD.L"] == nil, "pence x shares is not dollars — a wrong ADV could cross the $5B bar")
        #expect(out.count == 2)
    }
}
