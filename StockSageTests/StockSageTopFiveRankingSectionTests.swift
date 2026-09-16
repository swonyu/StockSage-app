#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import Testing
@testable import StockSage

/// A lightweight native-render smoke test: constructs the real SwiftUI section with fixture data
/// covering every row kind (qualified, not-qualified/fallback, insider signals, hard-penalty
/// reasons) and confirms it lays out to a non-trivial size without crashing. This is not a full
/// accessibility-tree pass; it catches gross runtime errors in the view body (force-unwraps,
/// missing environment values, infinite layout) that a pure-data test cannot.
@Suite("Top-5 ranking section renders")
@MainActor
struct StockSageTopFiveRankingSectionTests {
    private typealias T = StockSageTopFiveRanking

    private func components(total: Double, hardPenalties: Double = 0) -> T.ScoreComponents {
        .init(horizonFit: 5, technicalConfluence: 10, catalystQuality: 6, liquidity: 7.5,
              evidenceFreshness: 10, insiderRelevance: total - 38.5 - hardPenalties, counterevidence: 0,
              hardPenalties: hardPenalties)
    }

    @Test func rendersQualifiedFallbackAndInsiderRowsWithoutCrashing() throws {
        let qualified = T.Ranked(rank: 1, symbol: "ACME", action: "Buy", status: .qualified,
            components: components(total: 45), insiderSignals: [
                .init(direction: .purchase, ownerName: "Owner A", ageDays: 1, contribution: 6),
                .init(direction: .sale, ownerName: "Owner B", ageDays: 10, contribution: -2)],
            failedGates: [], hardPenaltyReasons: [])
        let fallback = T.Ranked(rank: 5, symbol: "ZETA", action: "Hold", status: .notQualified,
            components: components(total: 20, hardPenalties: -10), insiderSignals: [],
            failedGates: ["Original model opinion is not Buy / Strong Buy."],
            hardPenaltyReasons: ["No dated catalyst record was offered at all."])
        let result = T.Result(version: 1, horizon: "1–7 trading days", ranked: [qualified, fallback],
            concentrationGuardApplied: true)

        let view = StockSageTopFiveRankingSection(result: result)
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        #expect(size.width > 0 && size.height > 0, "The section lays out to a real, non-trivial size")

        // A minimal accessibility check: the row and section identifiers we set are reachable.
        let allElements = collectAccessibilityIdentifiers(host.view)
        #expect(allElements.contains("research.topfive.section"))
        #expect(allElements.contains("research.topfive.row.ACME"))
        #expect(allElements.contains("research.topfive.row.ZETA"))
    }

    private func collectAccessibilityIdentifiers(_ view: NSView) -> Set<String> {
        var found: Set<String> = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if !id.isEmpty { found.insert(id) }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return found
    }
}
#endif
