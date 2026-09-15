import Testing
import Foundation
import Combine
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

@MainActor private final class SidebarSelectionModel: ObservableObject {
    @Published var section: MarketSection = .chat
}

@MainActor private struct SidebarSelectionFixture: View {
    @ObservedObject var model: SidebarSelectionModel
    var body: some View {
        StockSageDesktopNavigation(selection: $model.section).frame(width: 220, height: 700)
    }
}
#endif

// Native navigation (2026-09-10): route identity, sidebar order and grouping, the original
// Command-digit mapping and the native selection host are pinned here. The iPhone swipe
// gesture and its neighbour order no longer exist.

@Suite("Section navigation")
struct MarketSectionNavigationTests {

    @Test func researchAndLegacyPaperKeepDistinctRawDestinations() {
        #expect(MarketSection(rawValue: "research") != nil)
        #expect(MarketSection(rawValue: "paper") != nil)
    }

    @Test func phoneTabsPutTheFourPrimaryWorkspacesFirstAndKeepEveryRoute() {
        #expect(Array(MarketSection.phoneSections.prefix(4)) == [.briefing, .research, .watchlist, .chat])
        #expect(Set(MarketSection.phoneSections) == Set(MarketSection.allCases))
        #expect(MarketSection.phoneSections.count == MarketSection.allCases.count)
        #expect(Array(MarketSection.allCases.suffix(2)) == [.research, .paper], "New routes append after the original nine")
        #expect(MarketSection.allCases.count == 11)
        #expect(MarketSection.research.title == "Research" && MarketSection.paper.title == "Legacy paper history")
        #expect(MarketSection.research.workspaceTitle == "Research" && MarketSection.paper.workspaceTitle == "Legacy paper history")
        #expect(MarketSection.briefing.workspaceTitle == "Home" && MarketSection.all.workspaceTitle == "Markets")
        for section in [MarketSection.research, .paper] {
            #if os(macOS)
            #expect(NSImage(systemSymbolName: section.icon, accessibilityDescription: nil) != nil, "\(section.icon) must be a real SF Symbol")
            #expect(StockSageDesktop.icon(for: section) == section.icon)
            #else
            #expect(UIImage(systemName: section.icon) != nil, "\(section.icon) must be a real SF Symbol")
            #endif
        }
    }

    #if os(macOS)
    @Test @MainActor func sidebarUsesNativeSelectionList() async throws {
        let host = NSHostingController(rootView: StockSageDesktopNavigation(selection: .constant(.chat))
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
        #expect(Set(StockSageDesktop.sections) == Set(MarketSection.allCases))
        #expect(StockSageDesktop.sections.count == MarketSection.allCases.count)
        #expect(StockSageDesktop.sections == [
            .briefing, .research, .watchlist, .chat, .ideas, .all, .catalysts, .heatmap, .portfolio, .paper, .alerts
        ])
        #expect(StockSageDesktop.sections == StockSageDesktop.groups.flatMap(\.sections),
                "The rendered groups are the only source of sidebar order")
        #expect(StockSageDesktop.groups.first?.sections == [.briefing, .research, .watchlist, .chat])
        let records = StockSageDesktop.groups.first { $0.title == "Your records" }
        #expect(records?.sections == [.portfolio, .paper, .alerts],
                "Legacy paper history remains accessible with the records, outside the main research workflow")
        #expect(StockSageDesktop.help(for: .watchlist) == "Watchlist · ⌘1")
        #expect(StockSageDesktop.help(for: .briefing) == "Home · ⌘9")
        #expect(StockSageDesktop.help(for: .research) == "Research", "Appended routes carry no digit")
        #expect(StockSageDesktop.title(for: .briefing) == "Home")
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
        try await waitFor { table(in: host.view)?.selectedRowIndexes.count == 1 }
        let sidebar = try #require(table(in: host.view))
        #expect(sidebar.numberOfRows >= MarketSection.allCases.count, "Every destination needs a native row")
        let chatRow = sidebar.selectedRow
        model.section = .briefing
        try await waitFor { sidebar.selectedRowIndexes.count == 1 && sidebar.selectedRow != chatRow }
        let briefingRow = sidebar.selectedRow
        model.section = .paper
        try await waitFor { sidebar.selectedRowIndexes.count == 1 && ![chatRow, briefingRow].contains(sidebar.selectedRow) }
        // Native selection must write back through the List binding; rows were learned above, never guessed.
        sidebar.selectRowIndexes(IndexSet(integer: chatRow), byExtendingSelection: false)
        try await waitFor { model.section == .chat }
        sidebar.selectRowIndexes(IndexSet(integer: briefingRow), byExtendingSelection: false)
        try await waitFor { model.section == .briefing }
        #expect(sidebar.selectedRow == briefingRow)
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
        try await waitFor { host.view.window != nil && host.view.frame.width > 0 }
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
