import SwiftUI

// MARK: - SparkSeries (pure, testable)
//
// Helpers for the inline sparklines: downsample a long close history to a handful
// of evenly-spaced points, and normalize a series into 0…1 for drawing. Pure +
// deterministic so they're unit-tested without any view.
enum SparkSeries {

    /// Downsample to at most `maxPoints` evenly-spaced samples (keeps first+last).
    /// Series already short enough are returned unchanged. `nonisolated` so the
    /// nonisolated `Sparkline.path(in:)` (a Shape requirement) can call it.
    nonisolated static func downsample(_ values: [Double], maxPoints: Int = 32) -> [Double] {
        guard maxPoints >= 2, values.count > maxPoints else { return values }
        let step = Double(values.count - 1) / Double(maxPoints - 1)
        var out: [Double] = []
        out.reserveCapacity(maxPoints)
        for i in 0..<maxPoints {
            let idx = Int((Double(i) * step).rounded())
            out.append(values[min(idx, values.count - 1)])
        }
        return out
    }

    /// Map values to 0…1 (min→0, max→1). A flat series renders as a mid-line (0.5).
    nonisolated static func normalize(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        guard hi > lo else { return values.map { _ in 0.5 } }
        return values.map { ($0 - lo) / (hi - lo) }
    }

    /// Map values to 0…1 against an EXPLICIT domain (not the series' own min/max) — the
    /// registration primitive an overlay needs to land on the same y-mapping the Shape draws.
    /// Same flat/degenerate fallback as `normalize(_:)` (mid-line 0.5) when `domain.hi == domain.lo`.
    nonisolated static func normalize(_ values: [Double], in domain: (lo: Double, hi: Double)) -> [Double] {
        guard domain.hi > domain.lo else { return values.map { _ in 0.5 } }
        return values.map { fraction($0, in: domain) }
    }

    /// The y-domain [lo, hi] the Sparkline shape actually draws against, EXTENDED to
    /// include `extra` prices (e.g. a stop/target that fall outside the series' own
    /// min/max) so an overlay line can be positioned in the same normalized space the
    /// Shape uses. Never clamps — a price outside [lo, hi] before extension is folded
    /// into the domain, not silently pinned to the nearest edge (a mis-placed stop/target
    /// line would be a fabricated visual claim; OSS-borrow B2).
    /// nil when there is no meaningful range (empty series, or every point + extra identical).
    nonisolated static func domain(_ values: [Double], extending extra: [Double] = []) -> (lo: Double, hi: Double)? {
        var lo = values.min()
        var hi = values.max()
        for e in extra {
            lo = min(lo ?? e, e)
            hi = max(hi ?? e, e)
        }
        guard let lo, let hi, hi > lo else { return nil }
        return (lo, hi)
    }

    /// Fraction (0 = bottom/lo, 1 = top/hi) of `price` within `domain`. Domain must have
    /// hi > lo (call `domain(_:extending:)` first and guard its nil case — never derive a
    /// domain from `price` itself, that would trivially always be in-range).
    nonisolated static func fraction(_ price: Double, in domain: (lo: Double, hi: Double)) -> Double {
        (price - domain.lo) / (domain.hi - domain.lo)
    }

    /// Whether the series' LAST value sits at the running max, min, or neither — the pure
    /// primitive behind the "At {N}-day high/low" chip (OSS-borrow B3, Ghostfolio holding-detail
    /// min/max highlight). Degenerate-series guard: a flat series (min == max) is ALWAYS
    /// `.neither` — Ghostfolio's own guard against a flat line claiming to be both a high and a
    /// low. Equality is EXACT `==` on the raw Double, not epsilon-fuzzed: `last` is one of
    /// `values`' own elements (or excluded by the nil/short/degenerate guards below), so `==`
    /// is well-defined and an epsilon would risk false-flagging a near-high as the high itself.
    /// CALLER CONVENTION (L1 honesty fix, 2026-07-07): the chip's `.recentExtreme` field is
    /// computed by `StockSageStore.buildIdeas` over the RAW last-63-close window, NOT the
    /// downsampled `spark` array this Shape draws — the downsample can skip the true extreme
    /// (only ≤32 of up to 63 points survive), so checking the sampled series risked a false
    /// "at high/low" claim vs the actual close history. This function itself is a pure predicate
    /// over whatever array it's given; it is the CALLER's job to pass the honest window.
    nonisolated static func extreme(_ values: [Double]) -> Extreme {
        guard values.count >= 2, let last = values.last,
              let lo = values.min(), let hi = values.max(), hi > lo else { return .neither }
        if last == hi { return .atHigh }
        if last == lo { return .atLow }
        return .neither
    }

    enum Extreme { case atHigh, atLow, neither }

    // MARK: Trade-plan label placement (OSS-borrow B2/B2-fix)
    //
    // Pure helpers behind tradePlanOverlay's stop/target label positioning — extracted so the
    // edge-clamping and de-collision math is unit-testable without a view. `nonisolated` for the
    // same reason as the rest of this enum: callable from non-MainActor test/Shape contexts.

    /// Clamps a label's y-position so its chip (height `labelHeight`, centered on `y`) renders
    /// fully inside `[0, height]`. Degenerate frame (`height <= labelHeight`): centers it.
    nonisolated static func clampedLabelY(_ y: CGFloat, height: CGFloat, labelHeight: CGFloat) -> CGFloat {
        let half = labelHeight / 2
        guard height > labelHeight else { return height / 2 }
        return min(max(y, half), height - half)
    }

    /// If two already-clamped label y's are within `labelHeight` of each other (including the
    /// degenerate case where clamping folded both onto the same edge), separate them by exactly
    /// `labelHeight` while keeping both inside `[labelHeight/2, height - labelHeight/2]`.
    ///
    /// Direction-aware: the lower of the pair ("first", smaller y) stays put; the other ("second")
    /// is pushed DOWN by `labelHeight` when there's room below, else pushed UP instead. A naive
    /// one-directional offset (always down, then clamp) folds back onto itself when both labels
    /// clamp to the bottom edge — `min(57.5 + 13, height-half) == 57.5`, i.e. no separation at all
    /// (the bug this replaces). Pushing up when down has no room fixes the bottom-edge case; the
    /// top-edge case never needed the down-push to begin with (room is always below there).
    nonisolated static func deconflictedLabelYs(_ a: CGFloat, _ b: CGFloat, labelHeight: CGFloat, height: CGFloat) -> (CGFloat, CGFloat) {
        guard abs(a - b) < labelHeight else { return (a, b) }
        let half = labelHeight / 2
        let aIsFirst = a <= b
        let first = aIsFirst ? a : b
        let second = aIsFirst ? b : a
        let pushed: (CGFloat, CGFloat)
        if second + labelHeight <= height - half {
            pushed = (first, min(first + labelHeight, height - half))
        } else {
            pushed = (max(first - labelHeight, half), first)
        }
        return aIsFirst ? pushed : (pushed.1, pushed.0)
    }
}

// MARK: - Sparkline (pure SwiftUI Shape)

/// A tiny inline line chart over a raw value series (normalized internally).
/// Snapshot-safe: no animation, no onAppear — it just draws.
struct Sparkline: Shape {
    let values: [Double]
    /// Explicit y-domain to normalize against (e.g. extended to fit a stop/target overlay).
    /// nil (default) preserves the original self-normalizing behavior byte-for-byte — every
    /// existing call site is unchanged unless it opts in (OSS-borrow B2 registration fix).
    var domain: (lo: Double, hi: Double)? = nil

    // `nonisolated` — Shape.path(in:) is a nonisolated protocol requirement, but the
    // project defaults every type to MainActor isolation; without this the conformance
    // "crosses into main actor-isolated code" (a Swift 6 data-race error in Xcode).
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let norm = domain.map { SparkSeries.normalize(values, in: $0) } ?? SparkSeries.normalize(values)
        guard norm.count >= 2, rect.width > 0, rect.height > 0 else { return path }
        let stepX = rect.width / CGFloat(norm.count - 1)
        for (i, v) in norm.enumerated() {
            let x = rect.minX + CGFloat(i) * stepX
            let y = rect.maxY - CGFloat(v) * rect.height   // 0 → bottom, 1 → top
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
