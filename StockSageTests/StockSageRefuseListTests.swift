import Testing
import Foundation   // CharacterSet.decimalDigits / rangeOfCharacter(from:) — disclosed deviation: plan's file omitted this import (its Step-12d sibling includes it)
@testable import StockSage

// MARK: - Refuse-list policy (Item A, week-horizon research roadmap #1)
//
// Expected values transcribed from RESEARCH_2026-07-02_week_horizon_velocity.md (the captured,
// adversarially-verified spec) — never from the code under test (spec-fidelity/F40).

struct StockSageRefuseListTests {

    @Test func policyEncodesAllSevenVerifiedRefusals() {
        // Research refuse-list has exactly 7 numbered items.
        #expect(StockSageRefuseList.all.count == 7)
        #expect(Set(StockSageRefuseList.all.map(\.id)).count == 7)   // ids unique
        // Every entry carries load-bearing EVIDENCE, not a bare opinion. Six of the seven
        // spec entries cite a number; item 4 (overnight-roundtrip) is digit-free IN THE SPEC
        // (RESEARCH_2026-07-02_week_horizon_velocity.md:35 — "explicitly cost-unattractive per
        // the source paper; ETF implementations shuttered"), so it is pinned on its load-bearing
        // spec phrases instead. [Amendment A-1, 2026-07-02: the original universal digit-assert
        // contradicted the digit-free spec entry — plan bug, not code bug; adding a figure to
        // the evidence would have fabricated a stat the research corpus does not contain.]
        for setup in StockSageRefuseList.all {
            #expect(!setup.title.isEmpty)
            if setup.id == "overnight-roundtrip" {
                // Both pins are genuine spec phrases: "cost-devoured" (exec summary) and
                // "shuttered" (refuse-list item 4 / roadmap item 2's "NightShares ETF
                // closures") — the code's earlier "shut down" was a paraphrase, aligned
                // to the spec 2026-07-03.
                #expect(setup.evidence.contains("cost-devoured"))
                #expect(setup.evidence.contains("shuttered"))
            } else {
                #expect(setup.evidence.rangeOfCharacter(from: .decimalDigits) != nil)
            }
        }
        // The single most load-bearing verified number: reversal flips to −1.28%/mo NET.
        guard let reversal = StockSageRefuseList.all.first(where: { $0.id == "naive-reversal" }) else {
            Issue.record("naive-reversal entry missing"); return
        }
        #expect(reversal.evidence.contains("−1.28"))
    }

    @Test func publishedEffectHaircutMatchesMcLeanPontiff() {
        // Research: predictors decay 26% out-of-sample / 58% post-publication (verified 3-0 ×3).
        #expect(StockSageRefuseList.outOfSampleDecay == 0.26)
        #expect(StockSageRefuseList.postPublicationDecay == 0.58)
    }

    @Test func policySurfacesStayHonest() {
        let note = StockSageRefuseList.policyNote.lowercased()
        let caveat = StockSageRefuseList.caveat.lowercased()
        #expect(note.contains("refused"))
        #expect(caveat.contains("not alpha") && caveat.contains("never a promise"))
        // Honesty floor: no promise language anywhere in the policy surfaces.
        for banned in ["guarantee", "sure thing", "free money", "risk-free"] {
            #expect(!note.contains(banned))
        }
    }

    // MARK: - Anti-edges (L2, 2026-07-09, DISPLAY-ONLY) — verified 2026-07-03, ANY horizon
    //
    // Load-bearing spec numbers transcribed VERBATIM from
    // RESEARCH_2026-07-03_candidate_edges.md lines 45-47 (never from the code under test).

    @Test func antiEdgesHasExactlyThreeUniqueIdsDisjointFromAll() {
        #expect(StockSageRefuseList.antiEdges.count == 3)
        let antiIds = Set(StockSageRefuseList.antiEdges.map(\.id))
        #expect(antiIds.count == 3)   // unique among themselves
        let allIds = Set(StockSageRefuseList.all.map(\.id))
        #expect(antiIds.isDisjoint(with: allIds))
    }

    @Test func antiEdgesCarryLoadBearingSpecNumbers() {
        for setup in StockSageRefuseList.antiEdges {
            #expect(setup.evidence.rangeOfCharacter(from: .decimalDigits) != nil)
        }
        guard let vol = StockSageRefuseList.antiEdges.first(where: { $0.id == "vol-managed-momentum" }) else {
            Issue.record("vol-managed-momentum entry missing"); return
        }
        #expect(vol.evidence.contains("864"))   // line 45: "~864% leverage at the 99th pct"
        guard let bab = StockSageRefuseList.antiEdges.first(where: { $0.id == "betting-against-beta" }) else {
            Issue.record("betting-against-beta entry missing"); return
        }
        #expect(bab.evidence.contains("60bps"))   // line 46: "realistic BAB trading cost is 60bps/mo"
        guard let max = StockSageRefuseList.antiEdges.first(where: { $0.id == "max-lottery" }) else {
            Issue.record("max-lottery entry missing"); return
        }
        #expect(max.evidence.contains("6.47"))   // line 47: "median-$6.47 ... microcaps"
    }

    @Test func policyNoteSurfacesAllThreeAntiEdgeTitlesAndAnyHorizon() {
        let note = StockSageRefuseList.policyNote
        for setup in StockSageRefuseList.antiEdges {
            #expect(note.contains(setup.title))
        }
        #expect(note.lowercased().contains("any horizon"))
    }
}
