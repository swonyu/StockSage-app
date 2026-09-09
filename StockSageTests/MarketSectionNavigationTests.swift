import Testing
import Foundation
#if os(macOS)
import AppKit
#endif
@testable import StockSage

// Swipe navigation between board sections (iPhone, 2026-07-28). The gesture itself is UI,
// but the ORDER and the end-wall behaviour are pure logic — pinned here.

@Suite("Section swipe navigation")
struct MarketSectionNavigationTests {

    #if os(macOS)
    @Test @MainActor func testHostDoesNotPresentAnApplicationWindow() async {
        await Task.yield()
        // Inspect only this XCTest-host process, never the owner's installed app.
        let mainWindows = NSApplication.shared.windows.filter { $0.isVisible && $0.canBecomeMain }
        #expect(mainWindows.isEmpty, "Automated tests must not present an empty StockSage window")
    }

    @Test @MainActor func desktopDestinationsKeepEveryExistingRoute() {
        #expect(Set(StockSageDesktop.sections) == Set(MarketSection.allCases))
        #expect(StockSageDesktop.sections.count == MarketSection.allCases.count)
        #expect(StockSageDesktop.sections.first == .briefing)
        #expect(StockSageDesktop.title(for: .briefing) == "Home")
        #expect(StockSageDesktop.title(for: .all) == "Markets")
        for (index, section) in MarketSection.allCases.enumerated() {
            #expect(StockSageDesktop.shortcut(for: section) == index + 1)
        }
        #expect(StockSageDesktop.sidebarWidth(collapsed: true) == 64)
        #expect(StockSageDesktop.sidebarWidth(collapsed: false) == 220)
    }
    #endif

    @Test("neighbours follow tab order exactly")
    func neighboursFollowTabOrder() {
        // Tab order is watchlist, ideas, catalysts, all, heatmap, portfolio, alerts, chat, briefing
        // (Catalysts added 2026-09-06 beside Ideas — it shows the same ideas through a different lens).
        #expect(MarketSection.watchlist.neighbour(after: true) == .ideas)
        #expect(MarketSection.ideas.neighbour(after: true) == .catalysts)
        #expect(MarketSection.catalysts.neighbour(after: true) == .all)
        #expect(MarketSection.all.neighbour(after: true) == .heatmap)
        #expect(MarketSection.heatmap.neighbour(after: true) == .portfolio)
        #expect(MarketSection.portfolio.neighbour(after: true) == .alerts)
        #expect(MarketSection.alerts.neighbour(after: true) == .chat)
        #expect(MarketSection.chat.neighbour(after: true) == .briefing)

        #expect(MarketSection.briefing.neighbour(after: false) == .chat)
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
