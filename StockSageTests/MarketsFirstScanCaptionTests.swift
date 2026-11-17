import Testing
import Foundation
@testable import StockSage

// MARK: - firstScanProgressCaption (rotation-3 triage item F7, 2026-07-10)
//
// Pins MarketsView.firstScanProgressCaption(isLoadingIdeas:ideasUpdated:progress:) — non-nil
// ONLY during the first-ever scan (isLoadingIdeas true AND ideasUpdated nil AND a positive-total
// progress tuple). A later re-scan (ideasUpdated already committed) must render nothing here —
// that case is covered by the existing "re-scan in progress" line, not this caption. Pure string
// substitution against the source template, no numeric derivation needed.

struct MarketsFirstScanCaptionTests {
    typealias M = MarketsView

    @Test func firesOnlyDuringTheFirstEverScanWithPositiveProgress() {
        let text = M.firstScanProgressCaption(isLoadingIdeas: true, ideasUpdated: nil, progress: (current: 5, total: 20))
        #expect(text == "First scan in progress — 5 of 20 names analyzed; best-so-far, order may change.")
    }

    @Test func nilWhenNotLoading() {
        #expect(M.firstScanProgressCaption(isLoadingIdeas: false, ideasUpdated: nil, progress: (current: 5, total: 20)) == nil)
    }

    @Test func nilOnceABoardHasEverCommitted() {
        // ideasUpdated non-nil = a re-scan, not the first-ever scan — the "re-scan in progress"
        // line (MarketsView's ideasUpdated block) already covers this case; this caption must
        // stay silent so the two never say the same thing twice.
        let committed = Date(timeIntervalSince1970: 1_000_000)
        #expect(M.firstScanProgressCaption(isLoadingIdeas: true, ideasUpdated: committed, progress: (current: 5, total: 20)) == nil)
    }

    @Test func nilWithNoProgressTuple() {
        #expect(M.firstScanProgressCaption(isLoadingIdeas: true, ideasUpdated: nil, progress: nil) == nil)
    }

    @Test func nilWhenTotalIsZero() {
        // Guarded `p.total > 0` — a (0, 0) tuple (never genuinely emitted by the store, but the
        // guard exists) must not render "0 of 0 names analyzed" as if that meant anything.
        #expect(M.firstScanProgressCaption(isLoadingIdeas: true, ideasUpdated: nil, progress: (current: 0, total: 0)) == nil)
    }
}
