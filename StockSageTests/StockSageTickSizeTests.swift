import Testing
import Foundation
@testable import StockSage

// First-real-trade review (2026-07-16): Tadawul tick-size placeability. Expected values are
// HAND-DERIVED from the SOURCED band table (Saudi Exchange amended regime effective 2025-06-29;
// two agreeing sources: Argaam #1823880 + Sahm Capital support — never read off the code):
//   < 25.00 → 0.01 · 25.00–49.98 → 0.02 · 50.00–99.95 → 0.05 · 100.00–249.90 → 0.10 ·
//   250.00–499.80 → 0.20 · ≥ 500.00 → 0.50
@MainActor
struct StockSageTickSizeTests {
    typealias T = StockSageTickSize

    // Every band boundary STRADDLED: the last price of one band and the first of the next.
    @Test func tickBandsMatchTheSourcedTableAtEveryBoundary() {
        #expect(T.tadawulTick(forPrice: 24.99) == 0.01)
        #expect(T.tadawulTick(forPrice: 25.00) == 0.02)
        #expect(T.tadawulTick(forPrice: 49.98) == 0.02)
        #expect(T.tadawulTick(forPrice: 50.00) == 0.05)
        #expect(T.tadawulTick(forPrice: 99.95) == 0.05)
        #expect(T.tadawulTick(forPrice: 100.00) == 0.10)
        #expect(T.tadawulTick(forPrice: 249.90) == 0.10)
        #expect(T.tadawulTick(forPrice: 250.00) == 0.20)
        #expect(T.tadawulTick(forPrice: 499.80) == 0.20)
        #expect(T.tadawulTick(forPrice: 500.00) == 0.50)
    }

    // Hand-derived roundings: 28.63 in the 0.02 band → 28.63/0.02 = 1431.5 → nearest even
    // consideration irrelevant (rounded() = 1432) → 28.64. 101.37 in the 0.10 band → 101.4.
    @Test func roundsToTheNearestPlaceableTick() {
        #expect(abs(T.tadawulRounded(28.63) - 28.64) < 1e-9)
        #expect(abs(T.tadawulRounded(101.37) - 101.4) < 1e-9)
        #expect(abs(T.tadawulRounded(9.876) - 9.88) < 1e-9)     // 0.01 band
        #expect(T.tadawulAligned(28.64))
        #expect(!T.tadawulAligned(28.63))
        #expect(T.tadawulAligned(101.4))
    }

    // The advisory fires ONLY for .SR AND only when a leg's DISPLAYED (2-dp) price is off-grid;
    // the engine's own numbers are quoted, the placeable equivalents suggested, drift disclosed.
    @Test func placeabilityNoteFiresOnlyForMisalignedTadawulLegs() {
        // Non-.SR: always nil (US ticks at $0.01 — any 2-dp price places).
        #expect(T.placeabilityNote(symbol: "AAPL", entry: 187.334, stop: 180.111, target: 200.999) == nil)
        // .SR, all legs aligned: nil (no noise on a clean plan).
        #expect(T.placeabilityNote(symbol: "2222.SR", entry: 28.64, stop: 27.50, target: 31.20) == nil)
        // .SR with a misaligned stop: fires, names the leg, suggests 28.64 and the leg's band tick.
        let note = T.placeabilityNote(symbol: "2222.SR", entry: 29.00, stop: 28.63, target: 31.20)
        #expect(note != nil)
        #expect(note!.contains("stop 28.63 → place as 28.64 (0.02 tick)"))
        #expect(!note!.contains("target 31.20 →"))     // aligned legs are not listed
    }

    // 2026-07-16 review fixes, fixtures derived standalone (derive_tick2.swift, spec = the sourced
    // band table at 2-dp display precision):
    // • 23.456 displays as 23.46; EVERY 2-dp price < 25 SAR sits on the 0.01 grid → NO note.
    //   (The raw-Double check used to fire a self-contradictory "23.46 → place as 23.46" here —
    //   the score-100 review finding.) 19.784→19.78 and 24.999→25.00 (evaluated in the 0.02 band
    //   it displays into) are aligned too.
    // • 28.634 displays as 28.63 → 1431.5 → away-from-zero 1432 → 28.64, 0.02 tick.
    // • Cross-band: 49.97 → 2498.5 → 49.98 (0.02 tick); 52.03 → 1040.6 → 52.05 (0.05 tick) —
    //   ONE note carries BOTH band ticks (the former single-headline tick mislabeled one leg).
    @Test func evaluatesLegsAtDisplayPrecisionWithPerLegTicks() {
        #expect(T.placeabilityNote(symbol: "4001.SR", entry: 23.456, stop: 19.784, target: 24.999) == nil)
        let one = T.placeabilityNote(symbol: "2222.SR", entry: 29.00, stop: 28.634, target: 31.20)
        #expect(one != nil)
        #expect(one!.contains("stop 28.63 → place as 28.64 (0.02 tick)"))
        let cross = T.placeabilityNote(symbol: "1120.SR", entry: 49.97, stop: nil, target: 52.03)
        #expect(cross != nil)
        #expect(cross!.contains("entry 49.97 → place as 49.98 (0.02 tick)"))
        #expect(cross!.contains("target 52.03 → place as 52.05 (0.05 tick)"))
    }

    // The .SR session line in the execution-timing advisory (static exchange schedule,
    // sourced 2026-07-16): fires for a trending .SR buy, absent for US names (which get the
    // measured US numbers instead) and for range regimes.
    @Test func tadawulSessionLineAppearsForTrendingSRNames() {
        let sr = StockSageExecutionTiming.sessionNote(action: .buy, regime: .bullTrend, symbol: "2222.SR")
        #expect(sr != nil)
        #expect(sr!.contains("Sun–Thu"))
        #expect(sr!.contains("10:00–15:00"))
        let usSession = StockSageExecutionTiming.sessionNote(action: .buy, regime: .bullTrend, symbol: "AAPL")
        #expect(usSession != nil && !usSession!.contains("Sun–Thu"))
        #expect(StockSageExecutionTiming.sessionNote(action: .buy, regime: .range, symbol: "2222.SR") == nil)
    }

    // Close-form exit-price placeability (24h-run cycle-2, 2026-07-16). Expected values
    // HAND-DERIVED standalone (swift /tmp/derive_exit.swift), never from the code:
    //   AAPL any → nil (note is .SR-only; US ticks at $0.01);
    //   2222.SR 33.00 → aligned in the 0.02 band (25–50) → nil;
    //   2222.SR 23.456 → 2-dp display 23.46 is on the 0.01 grid (below 25) → nil (score-100 rule);
    //   2222.SR 33.01 → off-grid, (33.01/0.02).rounded()=1650 → 33.00 (0.02 tick);
    //   2222.SR 100.07 → 100–250 band 0.10 tick, off-grid → 100.10.
    @Test func exitPlaceabilityNoteFiresOnlyForOffGridSRExits() {
        #expect(T.exitPlaceabilityNote(symbol: "AAPL", exit: 33.01) == nil)     // not .SR
        #expect(T.exitPlaceabilityNote(symbol: "2222.SR", exit: 33.00) == nil)  // aligned
        #expect(T.exitPlaceabilityNote(symbol: "2222.SR", exit: 23.456) == nil) // 2-dp 23.46 placeable in 0.01 band
        let n1 = T.exitPlaceabilityNote(symbol: "2222.SR", exit: 33.01)
        #expect(n1 != nil)
        #expect(n1!.contains("33.01") && n1!.contains("33.00") && n1!.contains("0.02 tick"))
        let n2 = T.exitPlaceabilityNote(symbol: "2222.SR", exit: 100.07)
        #expect(n2 != nil)
        #expect(n2!.contains("100.07") && n2!.contains("100.10") && n2!.contains("0.10 tick"))
    }
}
