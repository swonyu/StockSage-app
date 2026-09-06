import Testing
@testable import StockSage

// Swipe navigation between board sections (iPhone, 2026-07-28). The gesture itself is UI,
// but the ORDER and the end-wall behaviour are pure logic — pinned here.

@Suite("Section swipe navigation")
struct MarketSectionNavigationTests {

    @Test("neighbours follow tab order exactly")
    func neighboursFollowTabOrder() {
        // Tab order is watchlist, ideas, catalysts, all, heatmap, portfolio, alerts, briefing
        // (Catalysts added 2026-09-06 beside Ideas — it shows the same ideas through a different lens).
        #expect(MarketSection.watchlist.neighbour(after: true) == .ideas)
        #expect(MarketSection.ideas.neighbour(after: true) == .catalysts)
        #expect(MarketSection.catalysts.neighbour(after: true) == .all)
        #expect(MarketSection.all.neighbour(after: true) == .heatmap)
        #expect(MarketSection.heatmap.neighbour(after: true) == .portfolio)
        #expect(MarketSection.portfolio.neighbour(after: true) == .alerts)
        #expect(MarketSection.alerts.neighbour(after: true) == .briefing)

        #expect(MarketSection.briefing.neighbour(after: false) == .alerts)
        #expect(MarketSection.ideas.neighbour(after: false) == .watchlist)
        #expect(MarketSection.catalysts.neighbour(after: false) == .ideas)
    }

    @Test("the ends are walls, never a wrap-around")
    func endsDoNotWrap() {
        // Wrapping would teleport Briefing -> Watchlist and lose the user's sense of position.
        #expect(MarketSection.watchlist.neighbour(after: false) == nil)
        #expect(MarketSection.briefing.neighbour(after: true) == nil)
    }

    @Test("every section is reachable by stepping forward from the first")
    func fullTraversal() {
        var visited: [MarketSection] = [.watchlist]
        var cur = MarketSection.watchlist
        while let next = cur.neighbour(after: true) {
            visited.append(next); cur = next
            if visited.count > 20 { break }        // cycle guard — must never trip
        }
        #expect(visited.count == MarketSection.allCases.count)
        #expect(visited == MarketSection.allCases)
    }
}
