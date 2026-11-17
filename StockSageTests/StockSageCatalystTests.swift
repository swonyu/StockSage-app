import Testing
import Foundation
@testable import StockSage

// Volume-confirmed catalyst detector (external-report item 9, owner-signed 2026-07-28).
// Fixtures hand-built so every RVOL and percentage below is arithmetic you can check by eye.

@Suite("Catalyst detector (volume-confirmed)")
struct StockSageCatalystTests {

    typealias C = StockSageCatalyst

    /// 21 closes + 21 volumes: a flat 100-volume baseline of 20 bars, then a spike bar.
    /// closes are flat at 100 except the final bar, so the price move is exactly `movePct`.
    private func series(spikeMultiple: Double, movePct: Double) -> ([Double], [Double]) {
        var closes = [Double](repeating: 100, count: 21)
        var volumes = [Double](repeating: 100, count: 21)
        closes[20] = 100 * (1 + movePct / 100)
        volumes[20] = 100 * spikeMultiple
        // one extra leading bar so count >= baselineBars + 2
        return ([100] + closes, [100] + volumes)
    }

    // MARK: tiers — pure threshold arithmetic

    @Test("tiers sit exactly on 2x / 5x / 10x")
    func tierBoundaries() {
        #expect(C.Tier.forRVOL(1.99) == nil)
        #expect(C.Tier.forRVOL(2.0) == .notable)
        #expect(C.Tier.forRVOL(4.99) == .notable)
        #expect(C.Tier.forRVOL(5.0) == .significant)
        #expect(C.Tier.forRVOL(9.99) == .significant)
        #expect(C.Tier.forRVOL(10.0) == .major)
        #expect(C.Tier.forRVOL(250) == .major)
    }

    // MARK: dual confirmation — the whole point is that ONE leg is never enough

    @Test("volume spike WITHOUT a price move raises nothing")
    func volumeAloneIsNotACatalyst() {
        let (closes, volumes) = series(spikeMultiple: 12, movePct: 0.5)   // huge RVOL, 0.5% move
        #expect(C.detect(symbol: "X", closes: closes, volumes: volumes) == nil)
    }

    @Test("price move WITHOUT volume confirmation raises nothing")
    func priceAloneIsNotACatalyst() {
        let (closes, volumes) = series(spikeMultiple: 1.2, movePct: 9)    // big move, RVOL 1.2
        #expect(C.detect(symbol: "X", closes: closes, volumes: volumes) == nil)
    }

    @Test("both legs firing produces a signal with exact RVOL and move")
    func dualConfirmationFires() throws {
        // baseline mean = 100 (20 bars of 100); spike bar = 600 → RVOL = 6.0 exactly.
        // closes 100 → 106 → +6.00% exactly.
        let (closes, volumes) = series(spikeMultiple: 6, movePct: 6)
        let s = try #require(C.detect(symbol: "ACME", closes: closes, volumes: volumes))
        #expect(abs(s.rvol - 6.0) < 1e-12)
        #expect(abs(s.priceChangePct - 6.0) < 1e-12)
        #expect(s.tier == .significant)           // 6x sits in [5,10)
        #expect(s.symbol == "ACME")
        #expect(s.caveat.contains("UNVALIDATED"))  // honesty floor travels with the signal
    }

    @Test("a downside dislocation is a catalyst too — direction is not a verdict")
    func downsideFires() throws {
        let (closes, volumes) = series(spikeMultiple: 11, movePct: -8)
        let s = try #require(C.detect(symbol: "DROP", closes: closes, volumes: volumes))
        #expect(s.priceChangePct < 0)
        #expect(abs(s.priceChangePct + 8.0) < 1e-12)
        #expect(s.tier == .major)
    }

    @Test("the RVOL floor is exactly 3.0 and the move floor exactly 4%")
    func thresholdsAreExact() {
        // Just under each floor ⇒ nothing; exactly on both ⇒ signal.
        let (c1, v1) = series(spikeMultiple: 2.99, movePct: 5)
        #expect(C.detect(symbol: "A", closes: c1, volumes: v1) == nil)
        let (c2, v2) = series(spikeMultiple: 5, movePct: 3.99)
        #expect(C.detect(symbol: "B", closes: c2, volumes: v2) == nil)
        let (c3, v3) = series(spikeMultiple: 3, movePct: 4)
        #expect(C.detect(symbol: "C", closes: c3, volumes: v3) != nil)
    }

    // MARK: guards — never judge what can't be measured

    @Test("exactly baselineBars+1 history is enough; one fewer is not")
    func minimumHistoryBoundary() {
        // 21 bars = 20-bar baseline + the spike bar. The prior close lives inside that window,
        // so 21 is sufficient and 20 is not. (This boundary was off by one until the external
        // review lane caught it — the old guard demanded 22 and skipped minimum-history names.)
        func bars(_ n: Int) -> ([Double], [Double]) {
            var c = [Double](repeating: 100, count: n)
            var v = [Double](repeating: 100, count: n)
            c[n - 1] = 106            // +6%
            v[n - 1] = 600            // RVOL 6.0
            return (c, v)
        }
        let (c21, v21) = bars(21)
        #expect(C.detect(symbol: "MIN", closes: c21, volumes: v21) != nil,
                "21 bars must be enough for a 20-bar baseline plus the spike bar")
        let (c20, v20) = bars(20)
        #expect(C.detect(symbol: "TOOTHIN", closes: c20, volumes: v20) == nil)
    }

    @Test("zero-volume assets (FX, indices) and thin history are never judged")
    func guardsHoldForUnmeasurableInput() {
        let flatZero = [Double](repeating: 0, count: 22)
        let closes = [Double](repeating: 100, count: 22)
        #expect(C.detect(symbol: "EURUSD=X", closes: closes, volumes: flatZero) == nil)
        // too little history
        #expect(C.detect(symbol: "NEW", closes: Array(repeating: 100, count: 5),
                         volumes: Array(repeating: 100, count: 5)) == nil)
        // ragged input
        #expect(C.detect(symbol: "BAD", closes: Array(repeating: 100, count: 22),
                         volumes: Array(repeating: 100, count: 10)) == nil)
    }

    @Test("the baseline excludes the spike bar — otherwise the spike dilutes itself")
    func baselineExcludesTheLatestBar() throws {
        // If the latest bar were included, mean would be (20·100 + 2000)/21 ≈ 190.5 and RVOL
        // would read ≈10.5 instead of the true 20.0. Pin the true value.
        let (closes, volumes) = series(spikeMultiple: 20, movePct: 7)
        let s = try #require(C.detect(symbol: "SPIKE", closes: closes, volumes: volumes))
        #expect(abs(s.rvol - 20.0) < 1e-12)
    }

    // MARK: mechanical-flow flag

    // DELIBERATE CONTRACT CHANGE (2026-09-12): `likelyMechanicalFlow` is now `Bool?`, so these two
    // assertions become explicit `== true` / `== false`. They previously read as bare Bools, which
    // is exactly what hid the defect: `(advDollar ?? 0) >= threshold` collapsed "never measured"
    // into "measured, below the bar", and the whole-board path measures nothing.
    @Test("mega-cap spikes are flagged as possibly mechanical, not silently trusted")
    func mechanicalFlowFlag() throws {
        let (closes, volumes) = series(spikeMultiple: 6, movePct: 6)
        let mega = try #require(C.detect(symbol: "MEGA", closes: closes, volumes: volumes,
                                         advDollar: 8_000_000_000))
        #expect(mega.likelyMechanicalFlow == true)
        let small = try #require(C.detect(symbol: "SMALL", closes: closes, volumes: volumes,
                                          advDollar: 40_000_000))
        #expect(small.likelyMechanicalFlow == false)
        // The threshold stays INCLUSIVE and still decides whenever the number is real.
        let atFloor = try #require(C.detect(symbol: "AT", closes: closes, volumes: volumes,
                                            advDollar: C.mechanicalFlowADVDollar))
        #expect(atFloor.likelyMechanicalFlow == true)
        let underFloor = try #require(C.detect(symbol: "UNDER", closes: closes, volumes: volumes,
                                               advDollar: C.mechanicalFlowADVDollar.nextDown))
        #expect(underFloor.likelyMechanicalFlow == false)
    }

    @Test("an unknown or non-finite ADV is nil — never a confident 'not mechanical'")
    func unknownADVIsNotAVerdict() throws {
        let (closes, volumes) = series(spikeMultiple: 6, movePct: 6)
        // The whole-board path passed NO ADV at all; that must not read as "checked: information".
        let unknown = try #require(C.detect(symbol: "UNK", closes: closes, volumes: volumes))
        #expect(unknown.likelyMechanicalFlow == nil)
        for bad in [Double.nan, .infinity, -.infinity] {
            let s = try #require(C.detect(symbol: "BAD", closes: closes, volumes: volumes, advDollar: bad))
            #expect(s.likelyMechanicalFlow == nil, "non-finite ADV is unknown, not 'below the bar'")
        }
    }

    // MARK: barDate — a measured bar must say WHEN

    @Test("detect dates the bar only when dates align with closes")
    func barDateRequiresAlignedDates() throws {
        let (closes, volumes) = series(spikeMultiple: 6, movePct: 6)
        let days = (0..<closes.count).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        let dated = try #require(C.detect(symbol: "D", closes: closes, volumes: volumes, dates: days))
        #expect(dated.barDate == days.last)
        // No dates at all: still detects, undated. A guard-return-nil here would kill the
        // detector for every caller that has no dates.
        let undated = try #require(C.detect(symbol: "U", closes: closes, volumes: volumes))
        #expect(undated.barDate == nil)
        // Ragged dates cannot be aligned to closes, so they are not trusted.
        let ragged = try #require(C.detect(symbol: "R", closes: closes, volumes: volumes,
                                           dates: Array(days.dropLast())))
        #expect(ragged.barDate == nil)
    }

    @Test("staleness mirrors the history cache's own 7-day truncating arithmetic")
    func staleBarStraddlesTheBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }
        // The arithmetic is TRUNCATING, exactly like StockSageHistoryCache.isStale:
        // stale iff Int(seconds / 86_400) > 7, so the first stale age is 8 full days, not 7.0001.
        #expect(C.staleBarDays == 7)
        #expect(!C.isStaleBar(at(7), now: now))
        #expect(!C.isStaleBar(at(7.9), now: now), "still 7 whole days after truncation")
        #expect(C.isStaleBar(at(8), now: now), "the first stale age")
        #expect(C.isStaleBar(at(30), now: now))
        #expect(!C.isStaleBar(at(0), now: now))
        // Unknown and forward-dated are not stale — unknown is not a finding either way.
        #expect(!C.isStaleBar(nil, now: now))
        #expect(!C.isStaleBar(at(-1), now: now))
    }

    // MARK: scan ordering

    @Test("scan returns strongest volume confirmation first")
    func scanSortsByRVOL() {
        let (c1, v1) = series(spikeMultiple: 4, movePct: 5)
        let (c2, v2) = series(spikeMultiple: 15, movePct: 5)
        let hs = ["LOW": StockSagePriceHistory(symbol: "LOW", dates: [], opens: [], highs: [],
                                               lows: [], closes: c1, volumes: v1),
                  "HIGH": StockSagePriceHistory(symbol: "HIGH", dates: [], opens: [], highs: [],
                                                lows: [], closes: c2, volumes: v2)]
        let out = C.scan(hs)
        #expect(out.count == 2)
        #expect(out.first?.symbol == "HIGH")
        #expect(out.first!.rvol > out.last!.rvol)
    }
}
