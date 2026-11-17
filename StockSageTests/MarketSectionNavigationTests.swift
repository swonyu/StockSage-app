import Testing
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import StockSage

#if os(macOS)
@MainActor private final class NavigationFixtureWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}

@MainActor private final class SidebarSelectionModel {
    var binding: Binding<MarketSection>?
    var transitions: [MarketSection] = []
    var section: MarketSection {
        get { binding?.wrappedValue ?? .sameDay }
        set { binding?.wrappedValue = newValue }
    }
}

@MainActor private struct SidebarSelectionFixture: View {
    let model: SidebarSelectionModel
    // Match MarketsView's actual route ownership. A separate @Published fixture model
    // is not part of the production sidebar's native selection transaction.
    @State private var section: MarketSection = .sameDay
    var body: some View {
        StockSageDesktopNavigation(selection: Binding(get: { section.primaryDestination },
            set: { section = $0.resolved(legacyHorizon: .week) })).frame(width: 220, height: 700)
            .onAppear { model.binding = $section }
            .onChange(of: section) { _, value in model.transitions.append(value) }
            .onDisappear { model.binding = nil }
    }
}
#endif

// Native navigation (2026-09-10): route identity, sidebar order and grouping, the original
// Command-digit mapping and the native selection host are pinned here. The iPhone swipe
// gesture and its neighbour order no longer exist.

@Suite("Section navigation")
struct MarketSectionNavigationTests {

    @Test func primaryNavigationMatchesTheThreeManualTradingGoals() {
        let routes = ["watchlist", "portfolio", "chat", "library"] // Phone scope now requires no research server.
        #expect(MarketSection.phoneSections.map(\.rawValue) == routes)
        #expect(StockSageDesktop.sections == [.sameDay, .microcap, .largecap, .weekResearch, .fortnightResearch, .watchlist, .all, .screener, .library])
    }

    @Test func researchAndLegacyPaperKeepDistinctRawDestinations() {
        #expect(MarketSection(rawValue: "research") != nil)
        #expect(MarketSection(rawValue: "paper") != nil)
    }

    @Test func primaryAndLibraryRoutesPreserveLegacyDestinations() {
        #expect(MarketSection.phoneSections == [.watchlist, .portfolio, .chat, .library])
        let support = MarketSection.recordSections + MarketSection.contextSections
        #expect(Set(support).count == support.count)
        #if os(macOS)
        #expect(Set(support + StockSageDesktop.sections) == Set(MarketSection.allCases.filter { $0 != .research }))
        #else
        let phoneSupport = support.filter { $0.phoneDestination == $0 && !MarketSection.phoneSections.contains($0) }
        #expect(Set(phoneSupport) == Set(MarketSection.phoneSupportingSections))
        #expect(Set(phoneSupport + MarketSection.phoneSections).count == 6) // Four core tabs plus two stored-evidence destinations.
        #endif
        #expect(Array(MarketSection.allCases.prefix(11)) == [
            .watchlist, .ideas, .catalysts, .all, .heatmap, .portfolio, .alerts, .chat, .briefing, .research, .paper
        ], "Old raw routes and command-digit positions must remain compatible")
        for route in MarketSection.allCases {
            for horizon in StockSageHorizonResearch.Horizon.allCases {
                let resolved = route.resolved(legacyHorizon: horizon)
                #if os(macOS)
                let primary = StockSageDesktop.sections
                #else
                let primary = MarketSection.phoneSections
                #endif
                #expect(primary.contains(resolved.primaryDestination))
                #expect(resolved.libraryPath == (primary.contains(resolved) ? [] : [resolved]))
                #if os(macOS)
                if route == .research { #expect(resolved.researchHorizon == horizon) }
                #else
                #expect(resolved.researchHorizon == nil)
                #expect(resolved == route.phoneDestination)
                #endif
            }
            #if os(macOS)
            #expect(NSImage(systemSymbolName: route.icon, accessibilityDescription: nil) != nil)
            #else
            #expect(UIImage(systemName: route.icon) != nil)
            #endif
        }
        #expect(MarketSection.sameDay.researchHorizon == nil)
        #expect(MarketSection.weekResearch.researchHorizon == .week)
        #expect(MarketSection.fortnightResearch.researchHorizon == .fortnight)
        #expect(MarketSection.briefing.workspaceTitle == "Saved research")
    }

    @Test func phoneRestorationAcceptsOnlySupportedPrimaryTabs() {
        for tab in MarketSection.phoneSections {
            #expect(MarketSection.phoneInitialSection(savedRawValue: tab.rawValue) == tab)
        }
        for raw in [String?.none, "", "unknown", "research", "sameDay", "weekResearch", "fortnightResearch", "microcap", "largecap", "paper", "screener"] {
            #expect(MarketSection.phoneInitialSection(savedRawValue: raw) == .watchlist)
        }
    }

    @Test func phoneDestinationsExcludeServerResearchAndRetainLocalTools() {
        for route in [MarketSection.research, .sameDay, .weekResearch, .fortnightResearch, .microcap, .largecap, .paper, .screener] {
            #expect(route.phoneDestination == .watchlist)
        }
        for route in MarketSection.phoneSupportingSections + MarketSection.phoneSections {
            #expect(route.phoneDestination == route)
        }
        #expect(MarketSection.portfolio.tabTitle == "Portfolio")
    }

    @Test func phoneEventsCopyDoesNotSendUsersToModelServerSetup() {
        #if os(iOS)
        #expect(MarketSection.catalysts.workspaceTitle == "Events & explanations")
        #else
        #expect(MarketSection.catalysts.workspaceTitle == "Events & model setup")
        #endif
        #expect(MarketSection.briefing.phoneSubtitle.contains("original dates"))
    }

    #if os(macOS)
    @Test @MainActor func sidebarUsesNativeSelectionList() async throws {
        let host = NSHostingController(rootView: StockSageDesktopNavigation(selection: .constant(.sameDay))
            .frame(width: 220, height: 700))
        let window = NavigationFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 220, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while table(in: host.view) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(table(in: host.view) != nil, "Navigation must use the native List selection/keyboard behavior")
    }

    @Test @MainActor func testHostDoesNotPresentAnApplicationWindow() async {
        await Task.yield()
        // Inspect only this XCTest-host process, never the owner's installed app.
        let mainWindows = NSApplication.shared.windows.filter { $0.isVisible && $0.canBecomeMain }
        #expect(mainWindows.isEmpty, "Automated tests must not present an empty StockSage window")
    }

    @Test @MainActor func desktopDestinationsKeepEveryExistingRoute() {
        #expect(StockSageDesktop.sections == [.sameDay, .microcap, .largecap, .weekResearch, .fortnightResearch, .watchlist, .all, .screener, .library])
        #expect(StockSageDesktop.sections == StockSageDesktop.groups.flatMap(\.sections))
        #expect(StockSageDesktop.groups.first?.sections == [.sameDay, .microcap, .largecap, .weekResearch, .fortnightResearch])
        #expect(StockSageDesktop.help(for: .watchlist) == "Watchlist · ⌘1")
        #expect(StockSageDesktop.help(for: .briefing) == "Saved research · ⌘9")
        #expect(StockSageDesktop.help(for: .research) == "Research", "Legacy appended routes carry no digit")
        #expect(StockSageDesktop.title(for: .all) == "Markets")
        let shortcuts: [(MarketSection, Int)] = [
            (.watchlist, 1), (.ideas, 2), (.catalysts, 3), (.all, 4), (.heatmap, 5),
            (.portfolio, 6), (.alerts, 7), (.chat, 8), (.briefing, 9)
        ]
        for (section, key) in shortcuts {
            #expect(StockSageDesktop.shortcut(for: section) == key)
        }
        #expect(StockSageDesktop.shortcut(for: .research) == nil)
        #expect(StockSageDesktop.shortcut(for: .paper) == nil)
        #expect(StockSageDesktop.PortfolioPage.paper.rawValue == "Paper")
        #expect(StockSageDesktop.PortfolioPage.paper.title == "Forward record")
    }

    @Test @MainActor func desktopGlyphsUseOutlinesAndPreserveChat() {
        let glyphs: [(MarketSection, String)] = [
            (.briefing, "house"), (.watchlist, "star"), (.ideas, "lightbulb"),
            (.all, "chart.bar"), (.catalysts, "calendar"), (.heatmap, "square.grid.3x3"),
            (.portfolio, "briefcase"), (.alerts, "bell"), (.chat, "bubble.left.and.bubble.right.fill")
        ]
        for (section, glyph) in glyphs {
            #expect(StockSageDesktop.icon(for: section) == glyph)
            #expect(NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil)
        }
        #expect(StockSageDesktop.icon(for: .chat) == MarketSection.chat.icon)
    }

    @Test @MainActor func sidebarSelectionFollowsTheBindingBothWays() async throws {
        let model = SidebarSelectionModel()
        let host = NSHostingController(rootView: SidebarSelectionFixture(model: model))
        let window = NavigationFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 220, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        func waitFor(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(ready())
        }
        try await waitFor { model.binding != nil && table(in: host.view)?.selectedRowIndexes.count == 1 }
        let sidebar = try #require(table(in: host.view))
        #expect(sidebar.numberOfRows >= StockSageDesktop.sections.count, "Every primary destination needs a native row")
        let sameDayRow = sidebar.selectedRow
        model.section = .weekResearch
        try await waitFor { sidebar.selectedRowIndexes.count == 1 && sidebar.selectedRow != sameDayRow }
        let weekRow = sidebar.selectedRow
        model.section = .library
        try await waitFor { sidebar.selectedRowIndexes.count == 1 && ![sameDayRow, weekRow].contains(sidebar.selectedRow) }
        let libraryRow = sidebar.selectedRow
        model.section = .chat
        try await waitFor { model.section == .chat && model.transitions.last == .chat && sidebar.selectedRow == libraryRow }
        sidebar.selectRowIndexes(IndexSet(integer: sameDayRow), byExtendingSelection: false)
        try await waitFor { model.section == .sameDay }
        sidebar.selectRowIndexes(IndexSet(integer: weekRow), byExtendingSelection: false)
        try await waitFor { model.section == .weekResearch }
        #expect(sidebar.selectedRow == weekRow)
        try await waitFor { model.transitions.count >= 5 }
        #expect(model.transitions == [.weekResearch, .library, .chat, .sameDay, .weekResearch])
        var visitedRows = [sameDayRow, weekRow, libraryRow]
        for destination in [MarketSection.watchlist, .all] {
            model.section = destination
            try await waitFor { sidebar.selectedRowIndexes.count == 1 && !visitedRows.contains(sidebar.selectedRow) }
            let destinationRow = sidebar.selectedRow
            visitedRows.append(destinationRow)
            model.section = .library
            try await waitFor { sidebar.selectedRow == libraryRow }
            sidebar.selectRowIndexes(IndexSet(integer: destinationRow), byExtendingSelection: false)
            try await waitFor { model.section == destination }
        }
        #expect(!window.isKeyWindow, "The offscreen host must never become an application window")
    }

    @Test @MainActor func commandDigitShortcutsRouteThroughTheNativeSidebar() async throws {
        let model = SidebarSelectionModel()
        let host = NSHostingController(rootView: SidebarSelectionFixture(model: model))
        let window = NavigationFixtureWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 220, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        func waitFor(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(ready())
        }
        try await waitFor { model.binding != nil && host.view.window != nil && host.view.frame.width > 0 }
        // Original mapping: ⌘1 = Watchlist … ⌘9 = Home, independent of the visible sidebar order.
        for (digit, code, section) in [("1", UInt16(18), MarketSection.watchlist), ("9", UInt16(25), .briefing), ("8", UInt16(28), .chat)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: digit, charactersIgnoringModifiers: digit, isARepeat: false, keyCode: code))
            _ = window.performKeyEquivalent(with: event)
            try await waitFor { model.section == section }
        }
        #expect(!window.isKeyWindow)
    }
    #endif

}
