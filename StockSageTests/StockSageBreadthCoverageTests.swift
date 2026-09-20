import Testing
import Foundation
import Synchronization
@testable import StockSage

// BATCH 7.1 + 7.2 (2026-09-12) — breadth must not report a market-wide fact from a thin sample,
// and `fetchHistories` must not hand back a silent subset.
//
// These two are the same defect at two levels. `StockSageRegime.breadth` excludes names with no
// computable 200DMA from its OWN denominator — correct in itself, since counting them as "below"
// would understate breadth — but it means ANY partial fetch still yields a confident percentage.
// One surviving name of the 14-name sample read as "Broad strength — 100% of names above their
// 200DMA", a sentence the owner reads verbatim, and that breadth multiplies every Deploy-capital
// weight through `sizingBias`. So a thin sample did not merely mislead: it sized.
//
// 7.1 closes the upstream half — a web-access revocation landing mid-fan-out used to produce
// exactly that subset, indistinguishable from "those names had no bars".
@Suite("Breadth coverage floor and fail-closed histories")
struct StockSageBreadthCoverageTests {

    private typealias R = StockSageRegime
    private typealias Q = StockSageQuoteService

    /// A history long enough to HAVE a 200DMA, trending up or down as asked.
    private func history(_ symbol: String, rising: Bool, bars: Int = 260) -> StockSagePriceHistory {
        let closes = (0..<bars).map { i -> Double in
            rising ? 100 + Double(i) * 0.5 : 300 - Double(i) * 0.5
        }
        return Self.bars(symbol, closes: closes)
    }

    /// OHLCV built from closes — only `closes` and `latestClose` matter to breadth.
    private nonisolated static func bars(_ symbol: String, closes: [Double]) -> StockSagePriceHistory {
        StockSagePriceHistory(symbol: symbol,
                              dates: (0..<closes.count).map { Date(timeIntervalSince1970: Double($0) * 86_400) },
                              opens: closes, highs: closes, lows: closes, closes: closes,
                              volumes: Array(repeating: 1_000, count: closes.count))
    }

    /// Too short for a 200DMA — `breadth` drops these from its denominator.
    private func stub(_ symbol: String) -> StockSagePriceHistory {
        Self.bars(symbol, closes: [100, 101, 102])
    }

    // MARK: The defect, stated as a measurement

    @Test func oneSurvivingNameOutOfFourteenIsNotBroadStrength() {
        let sampleSize = R.breadthSample.count
        #expect(sampleSize == 14, "the floor is expressed against this sample; re-derive if it changes")

        // What `breadth` alone reports from a single rising name: a confident 100%.
        let lone = [history("AAPL", rising: true)]
        #expect(R.breadth(lone) == 1.0, "premise: the raw helper still publishes 100% from one name")

        // The coverage gate is what refuses it.
        #expect(R.breadthEligibleCount(lone) == 1)
        #expect(!R.breadthHasCoverage(eligible: 1, requested: sampleSize))
    }

    // Hand-derived against the 14-name sample and the 0.60 floor: 14 * 0.60 = 8.4, so 9 is the
    // first integer that clears it and 8 is the last that does not.
    @Test func theFloorStraddlesNineOfFourteen() {
        #expect(R.minBreadthCoverage == 0.60)
        #expect(!R.breadthHasCoverage(eligible: 8, requested: 14))
        #expect(R.breadthHasCoverage(eligible: 9, requested: 14))
        // Exactly-at-the-floor is INCLUSIVE, pinned so a later >= / > slip is caught.
        #expect(R.breadthHasCoverage(eligible: 6, requested: 10))
        #expect(!R.breadthHasCoverage(eligible: 5, requested: 10))
        #expect(R.breadthHasCoverage(eligible: 14, requested: 14))
        // No sample is not full coverage.
        #expect(!R.breadthHasCoverage(eligible: 0, requested: 0))
        #expect(!R.breadthHasCoverage(eligible: 0, requested: 14))
    }

    // The eligible count must agree with `breadth`'s own denominator, or the gate would be judging
    // a different quantity than the one it gates.
    @Test func eligibleCountMatchesTheHelpersOwnDenominator() {
        let mixed = [history("A", rising: true), history("B", rising: false), stub("C"), stub("D")]
        #expect(R.breadthEligibleCount(mixed) == 2)
        #expect(R.breadth(mixed) == 0.5, "1 of the 2 ELIGIBLE names is above its 200DMA")
        #expect(R.breadthEligibleCount([]) == 0)
        #expect(R.breadth([]) == nil)
    }

    // A nil breadth must abstain, not read as zero breadth — that is what makes the floor safe.
    @Test func aNilBreadthAbstainsRatherThanScoringZero() {
        let closes = (0..<260).map { 100 + Double($0) * 0.5 }
        let withBreadth = R.assess(indexCloses: closes, vix: 18, breadthAbove200: 0)
        let without = R.assess(indexCloses: closes, vix: 18, breadthAbove200: nil)
        #expect(withBreadth != without, "0% breadth and unknown breadth must not produce the same regime")
    }

    // MARK: 7.1 — a revocation mid-fan-out returns [:], not a subset

    @Test func aRevocationMidFanOutReturnsNothingRatherThanASubset() async {
        // 14 symbols at concurrency 6 is three chunks, so the loop-top re-check runs twice.
        let symbols = (0..<14).map { "S\($0)" }
        let box = Counter()
        let out = await Q.fetchHistories(
            for: symbols, range: "1y", concurrency: 6, onProgress: nil,
            allowed: { box.allowed },          // flips false after the first fetch lands
            fetch: { sym, _ in
                box.revoke()
                return Self.bars(sym, closes: [1, 2, 3])
            })
        #expect(box.count == 1, "Paced workers must recheck access after sleeping, before dispatch")
        #expect(out.isEmpty, "a partial map is indistinguishable from 'those names had no bars'")
    }

    @Test func cancellationPreservesBarsAlreadyCollectedByTheHistoryWatchdog() async {
        let task = Task {
            await Q.fetchHistories(for: ["AAPL", "MSFT"], range: "1y", concurrency: 1,
                onProgress: { count in if count == 1 { withUnsafeCurrentTask { $0?.cancel() } } },
                allowed: { true }, fetch: { symbol, _ in
                    guard !Task.isCancelled else { return nil }
                    return Self.bars(symbol, closes: [1, 2, 3])
                })
        }
        let result = await task.value
        #expect(Set(result.keys) == ["AAPL"], "Cancellation retains completed bars; access invalidation does not")
    }

    @Test func aPermissionDenialAtEntryFetchesNothingAtAll() async {
        let box = Counter()
        let out = await Q.fetchHistories(
            for: ["AAPL"], range: "1y", concurrency: 6, onProgress: nil,
            allowed: { false },
            fetch: { sym, _ in
                box.revoke()
                return Self.bars(sym, closes: [1])
            })
        #expect(out.isEmpty)
        #expect(box.count == 0, "nothing may be requested once permission is refused")
    }

    // The happy path is unchanged — the guards must not cost a legitimate full fetch.
    @Test func afullyPermittedFetchStillReturnsEverything() async {
        let symbols = ["AAPL", "MSFT", "NVDA"]
        let out = await Q.fetchHistories(
            for: symbols, range: "1y", concurrency: 6, onProgress: nil,
            allowed: { true },
            fetch: { sym, _ in Self.bars(sym, closes: [1, 2, 3]) })
        #expect(Set(out.keys) == Set(symbols))
    }
}

/// Counts fetches and flips permission off after the first one lands, so the loop-top re-check
/// fires on the next chunk. Lock-guarded rather than an actor: `allowed` is a synchronous
/// `@Sendable () -> Bool` and cannot await.
/// `nonisolated` is required: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor would otherwise isolate
/// every member to the main actor, and `allowed` is called from inside the fan-out's task group.
private nonisolated final class Counter: Sendable {
    private let state = Mutex((count: 0, allowed: true))
    var count: Int { state.withLock { $0.count } }
    var allowed: Bool { state.withLock { $0.allowed } }
    func revoke() { state.withLock { $0.count += 1; $0.allowed = false } }
}
