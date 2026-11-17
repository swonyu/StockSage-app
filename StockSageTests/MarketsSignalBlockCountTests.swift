import Testing
@testable import StockSage

// MARK: - signalBlockCount fill-count (F2, 2026-07-07 audit)
//
// Pins MarketsView.signalBlockCount(_:) = Int((min(max(value,0),1) * 5).rounded()).
// Double.rounded() defaults to .toNearestOrAwayFromZero (half AWAY FROM ZERO).
// Every literal below was HAND-DERIVED in a standalone script (not by calling this
// code): scratchpad derive_signalblocks.swift, run via `swift derive_signalblocks.swift`.
// Its printed output (clamp -> scale -> rounded -> filled) is pasted next to each
// assertion so the arithmetic is auditable without re-running anything.

struct MarketsSignalBlockCountTests {
    typealias M = MarketsView

    @Test func straddlesTheHalfBoundaryEachBlockGap() {
        // 0.09 -> clamped 0.09 -> *5 = 0.44999999999999996 (float, just UNDER 0.45) -> rounds DOWN -> 0
        #expect(M.signalBlockCount(0.09) == 0)
        // 0.10 -> clamped 0.10 -> *5 = 0.5 exactly -> half AWAY FROM ZERO -> rounds UP -> 1
        #expect(M.signalBlockCount(0.10) == 1)

        // 0.49 -> clamped 0.49 -> *5 = 2.45 -> rounds DOWN -> 2
        #expect(M.signalBlockCount(0.49) == 2)
        // 0.50 -> clamped 0.50 -> *5 = 2.5 exactly -> half away from zero -> rounds UP -> 3
        #expect(M.signalBlockCount(0.50) == 3)

        // 0.89 -> clamped 0.89 -> *5 = 4.45 -> rounds DOWN -> 4
        #expect(M.signalBlockCount(0.89) == 4)
        // 0.90 -> clamped 0.90 -> *5 = 4.5 exactly -> half away from zero -> rounds UP -> 5
        #expect(M.signalBlockCount(0.90) == 5)
    }

    @Test func clampsOutOfRangeInputsBeforeScaling() {
        // -0.5 -> clamp(max(-0.5,0)=0, min(0,1)=0) -> 0 -> *5 = 0 -> 0
        #expect(M.signalBlockCount(-0.5) == 0)
        // 1.5 -> clamp(max(1.5,0)=1.5, min(1.5,1)=1) -> 1 -> *5 = 5 -> 5
        #expect(M.signalBlockCount(1.5) == 5)
    }

    @Test func boundsAreExact() {
        // 0 -> clamped 0 -> *5 = 0 -> 0
        #expect(M.signalBlockCount(0) == 0)
        // 1 -> clamped 1 -> *5 = 5 -> 5
        #expect(M.signalBlockCount(1) == 5)
    }

    @Test func agreesWithTodaysOnSheetPixelCaptures() {
        // Cross-check against today's (2026-07-07) sheet captures, cited in the audit:
        // "Signal strength 55 -> 3 blocks": 0.55 * 5 = 2.75 -> rounds to 3. Matches.
        #expect(M.signalBlockCount(0.55) == 3)
        // "Signal strength 39 -> 2 blocks": 0.39 * 5 = 1.9500000000000002 -> rounds to 2. Matches.
        #expect(M.signalBlockCount(0.39) == 2)
    }
}
