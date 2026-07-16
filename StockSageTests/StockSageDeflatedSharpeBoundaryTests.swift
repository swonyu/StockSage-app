import Testing
import Foundation
@testable import StockSage

// MARK: - Deflated-Sharpe moments() nil-boundary (F05 off-by-one companion)
//
// StockSageDeflatedSharpeTests pins moments() nil BELOW the minimum (3 points) and non-nil
// well above it (10 points), but nothing pinned non-nil AT exactly 4 — so an off-by-one to
// `>= 5` / `> 4` would pass silently. moments() feeds the DSR (the campaign's promotion bar),
// so its minimum-sample boundary is worth an exact pin.

struct StockSageDeflatedSharpeBoundaryTests {

    typealias DS = StockSageDeflatedSharpe

    // Guard is `n >= 4` (StockSageDeflatedSharpe.swift:42), then `m2 > 0` (line 46). A 4-point
    // sample with non-zero variance must compute; a symmetric one has zero skew (odd moment of a
    // symmetric distribution = 0 — hand-derived, not from moments()): mean 0, m2 = (1+0+0+1)/4 =
    // 0.5 > 0; skew = (−1³+0+0+1³)/(4·sd³) = 0.
    @Test func momentsComputeAtExactlyFourPoints() throws {
        let m = try #require(DS.moments([-1, 0, 0, 1]))   // exactly 4 points → non-nil (off-by-one to `>=5` fails HERE)
        #expect(abs(m.skew) < 1e-9)                        // symmetric ⇒ zero skew
        #expect(DS.moments([-1, 0, 1]) == nil)             // 3 points (non-flat) → nil: the COUNT guard, not variance
    }
}
