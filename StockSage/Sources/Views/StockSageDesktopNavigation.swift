#if os(macOS)
import SwiftUI

/// Presentation only. Existing raw routes and Command-1...9 assignments stay stable.
enum StockSageDesktop {
    struct SidebarGroup {
        let title: String
        let sections: [MarketSection]
    }
    /// The sidebar's single source of order and grouping; `sections` is derived from it, so a
    /// route can only disappear from the sidebar by disappearing from this list.
    static let groups: [SidebarGroup] = [
        SidebarGroup(title: "Workspace", sections: [.briefing, .research, .paper, .chat]),
        SidebarGroup(title: "Explore", sections: [.watchlist, .ideas, .all, .catalysts, .heatmap]),
        SidebarGroup(title: "Your records", sections: [.portfolio, .alerts]),
    ]
    static let sections: [MarketSection] = groups.flatMap(\.sections)
    static let berry = Color(red: 0.85, green: 0.294, blue: 0.439)
    /// Command-1…9 follow the ORIGINAL raw order (watchlist=1 … briefing=9); appended routes get none.
    static func shortcut(for section: MarketSection) -> Int? {
        guard let index = MarketSection.allCases.firstIndex(of: section), index < 9 else { return nil }
        return index + 1
    }
    static func title(for section: MarketSection) -> String {
        section.workspaceTitle
    }
    /// Row tooltip: the visible order is not the ⌘-digit order, so the hint is the only discovery path.
    static func help(for section: MarketSection) -> String {
        shortcut(for: section).map { "\(title(for: section)) · ⌘\($0)" } ?? title(for: section)
    }
    static func subtitle(for section: MarketSection) -> String {
        switch section {
        case .briefing: "Your briefing, followed by the wider market."
        case .watchlist: "The companies you choose to follow."
        case .ideas: "Compare the setup, the evidence and the risk."
        case .all: "Explore the tracked market."
        case .catalysts: "What is scheduled. What has changed."
        case .heatmap: "The shape of the market, at a glance."
        case .portfolio: "Your holdings, journal and forward record."
        case .alerts: "Choose what deserves your attention."
        case .chat: "Ask about your data. No automatic orders."
        case .research: "One-time research. Separate from day trading."
        case .paper: "Continuous same-day simulation. No real orders."
        }
    }
    static func icon(for section: MarketSection) -> String {
        switch section {
        case .briefing: "house"
        case .watchlist: "star"
        case .ideas: "lightbulb"
        case .all: "chart.bar"
        case .catalysts: "calendar"
        case .heatmap: "square.grid.3x3"
        case .portfolio: "briefcase"
        case .alerts: "bell"
        case .chat, .research, .paper: section.icon
        }
    }
    enum PortfolioPage: String, CaseIterable, Identifiable {
        case holdings = "Holdings", journal = "Journal", paper = "Paper", analytics = "Analytics"
        var id: Self { self }
        var title: String { self == .paper ? "Forward record" : rawValue }
    }
}

/// Native selection, keyboard navigation and sidebar accessibility; no market-tick observation.
struct StockSageDesktopNavigation: View {
    @Binding var selection: MarketSection

    var body: some View {
        // Required selection (macOS 13+): a native deselect cannot leave the sidebar with no
        // highlighted row while the detail column still shows that page.
        List(selection: $selection) {
            ForEach(StockSageDesktop.groups, id: \.title) { group in
                Section(group.title) { rows(group.sections) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("StockSage")
        .safeAreaInset(edge: .bottom) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .help("Settings · ⌘,")
                .accessibilityIdentifier("desktop.settings")
        }
        .background {
            ForEach(MarketSection.allCases.prefix(9)) { destination in
                if let key = StockSageDesktop.shortcut(for: destination) {
                    Button("") { selection = destination }
                        .keyboardShortcut(KeyEquivalent(Character(String(key))), modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
            }
        }
    }

    private func rows(_ destinations: [MarketSection]) -> some View {
        ForEach(destinations) { destination in
            Label(StockSageDesktop.title(for: destination),
                  systemImage: StockSageDesktop.icon(for: destination))
                .tag(destination)
                .help(StockSageDesktop.help(for: destination))
                .accessibilityIdentifier("desktop.nav.\(destination.rawValue)")
        }
    }
}
#endif
