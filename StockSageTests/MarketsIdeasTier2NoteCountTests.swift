import Testing
import Foundation
@testable import StockSage

// MARK: - ideasTier2NoteCount (UI#15, 2026-07-28 review: "ideasHeader: two tiers of notes")
//
// Pins MarketsView.ideasTier2NoteCount(...) — the count backing the ideasHeader Tier-2
// DisclosureGroup's "How this board is built (N notes)" label. The universe subtitle and
// StockSageAdvisor.caveat always count (2); the scan-duration note and the TOM tilt line each
// add 1 only under their own guard, mirrored from ideasHeader's body so the label can never
// claim a note count that doesn't match what's actually inside the disclosure.

struct MarketsIdeasTier2NoteCountTests {
    typealias M = MarketsView

    @Test func baselineIsSubtitlePlusCaveatOnly() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: false, progress: nil, universeCount: 2000,
                                       isEVSort: false, turnOfMonthEnabled: false, hasSeasonality: false)
        #expect(n == 2)
    }

    @Test func scanDurationNoteAddsOneDuringAFullScan() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: true, progress: (current: 100, total: 2000),
                                       universeCount: 2000, isEVSort: false, turnOfMonthEnabled: false,
                                       hasSeasonality: false)
        #expect(n == 3)
    }

    @Test func scanDurationNoteAbsentOnARetryBelowUniverseSize() {
        // A retry's progress.total is ideasMissing.count — always well under the full universe.
        let n = M.ideasTier2NoteCount(isLoadingIdeas: true, progress: (current: 3, total: 12),
                                       universeCount: 2000, isEVSort: false, turnOfMonthEnabled: false,
                                       hasSeasonality: false)
        #expect(n == 2)
    }

    @Test func scanDurationNoteAbsentWhenNotLoading() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: false, progress: (current: 2000, total: 2000),
                                       universeCount: 2000, isEVSort: false, turnOfMonthEnabled: false,
                                       hasSeasonality: false)
        #expect(n == 2)
    }

    @Test func tomTiltAddsOneOnlyWhenEVSortFlagAndSeasonalityAllHold() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: false, progress: nil, universeCount: 2000,
                                       isEVSort: true, turnOfMonthEnabled: true, hasSeasonality: true)
        #expect(n == 3)
    }

    @Test func tomTiltAbsentWhenSortIsNotEV() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: false, progress: nil, universeCount: 2000,
                                       isEVSort: false, turnOfMonthEnabled: true, hasSeasonality: true)
        #expect(n == 2)
    }

    @Test func tomTiltAbsentWhenNoNameHasSeasonalityData() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: false, progress: nil, universeCount: 2000,
                                       isEVSort: true, turnOfMonthEnabled: true, hasSeasonality: false)
        #expect(n == 2)
    }

    @Test func bothOptionalNotesTogetherMakeFour() {
        let n = M.ideasTier2NoteCount(isLoadingIdeas: true, progress: (current: 500, total: 2000),
                                       universeCount: 2000, isEVSort: true, turnOfMonthEnabled: true,
                                       hasSeasonality: true)
        #expect(n == 4)
    }
}
