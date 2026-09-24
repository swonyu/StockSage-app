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
        SidebarGroup(title: "Trading research", sections: [.sameDay, .microcap, .largecap, .weekResearch, .fortnightResearch]),
        SidebarGroup(title: "Your workspace", sections: [.watchlist, .all, .screener, .library]),
    ]
    static let sections: [MarketSection] = groups.flatMap(\.sections)
    static let berry = DS.Palette.accentText
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
        case .briefing: "Latest completed picks and saved predictions ready for review."
        case .watchlist: "The companies you choose to follow."
        case .ideas: "Compare the setup, the evidence and the risk."
        case .all: "Explore the tracked market."
        case .catalysts: "What is scheduled. What has changed."
        case .heatmap: "The shape of the market, at a glance."
        case .portfolio: "Your holdings, journal and forward record."
        case .alerts: "Choose what deserves your attention."
        case .chat: "Ask about your data. No automatic orders."
        case .research: "All checks and top picks for 1–7 or 7–14 trading days."
        case .paper: "Recorded simulation. New runs are retired; open positions are not monitored after relaunch."
        case .microcap: "Micro cap momentum, fresh same-day setups and Astra alerts."
        case .largecap: "Large cap momentum, fresh same-day setups and Astra alerts."
        case .screener: "Filter stocks using dated market cap and company-quality ratios."
        case .sameDay: "One manual pick with a buy entry, stop and target."
        case .weekResearch: "Top 5 for positions held 1–7 trading days."
        case .fortnightResearch: "Top 5 for positions held 7–14 trading days."
        case .library: "Saved research, your records and supporting market tools."
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
        case .chat, .research, .paper, .microcap, .largecap, .screener, .sameDay, .weekResearch, .fortnightResearch, .library: section.icon
        }
    }
    enum PortfolioPage: String, CaseIterable, Identifiable {
        case holdings = "Holdings", journal = "Journal", paper = "Paper", analytics = "Analytics"
        var id: Self { self }
        var title: String { self == .paper ? "Forward record" : rawValue }
    }
}

/// Observe progress here so a arriving result does not rebuild the entire workspace.
struct StockSageResearchActivityNavigation: View {
    let destination: MarketSection
    let open: (MarketSection) -> Void
    @ObservedObject private var horizons: StockSageHorizonResearch
    @ObservedObject private var sameDay = StockSageSameDayResearch.shared
    @ObservedObject private var microcap = StockSageSameDayResearch.microcap
    @ObservedObject private var largecap = StockSageSameDayResearch.largecap

    init(destination: MarketSection, horizons: StockSageHorizonResearch = .shared,
         open: @escaping (MarketSection) -> Void) {
        self.destination = destination
        self.open = open
        _horizons = ObservedObject(wrappedValue: horizons)
    }

    var body: some View {
        Group {
            if let running = horizons.running, destination.researchHorizon == nil {
                StockSageResearchModesPanel.runningScanControls(running: running,
                    show: { open(.researchDestination(running)) }, stop: { horizons.stop() })
                    .padding(12)
            } else if microcap.isRunning, destination != .microcap {
                activity("Micro cap", destination: .microcap, stopLabel: "Stop Micro cap research and watching") {
                    StockSageMicrocapMonitor.shared.stop(); microcap.stop()
                }
            } else if largecap.isRunning, destination != .largecap {
                activity("Large cap", destination: .largecap, stopLabel: "Stop Large cap research and watching") {
                    StockSageMicrocapMonitor.largecap.stop(); largecap.stop()
                }
            } else if sameDay.isRunning, destination != .sameDay {
                activity("Same-day", destination: .sameDay, stopLabel: "Stop same-day research") { sameDay.stop() }
            }
        }
    }

    private func activity(_ title: String, destination: MarketSection, stopLabel: String,
                          stop: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label("\(title) research is running", systemImage: "circle.dotted")
                Spacer(minLength: 12)
                activityActions(title, destination: destination, stopLabel: stopLabel, stop: stop)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("\(title) research is running", systemImage: "circle.dotted")
                activityActions(title, destination: destination, stopLabel: stopLabel, stop: stop)
            }
        }
        .font(.callout).controlSize(.small)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .help("Switching pages does not stop research.")
    }

    private func activityActions(_ title: String, destination: MarketSection, stopLabel: String,
                                 stop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("Show \(title == "Same-day" ? "same-day" : title) research") { open(destination) }
            Button(stopLabel, systemImage: "stop.fill", action: stop)
        }.buttonStyle(.bordered)
    }
}

/// Native selection, keyboard navigation and sidebar accessibility; no market-tick observation.
#if os(macOS)
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
        .environment(\.defaultMinListRowHeight, 36)
        .navigationTitle("StockSage")
        .safeAreaInset(edge: .bottom) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
            Label {
                Text(StockSageDesktop.title(for: destination))
                    .font(.system(size: 13, weight: selection == destination ? .semibold : .regular))
            } icon: {
                Image(systemName: StockSageDesktop.icon(for: destination))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selection == destination ? StockSageDesktop.berry : Color.secondary)
                    .symbolRenderingMode(.monochrome)
            }
                .tag(destination)
                .help(StockSageDesktop.help(for: destination))
                .accessibilityIdentifier("desktop.nav.\(destination.rawValue)")
        }
    }
}
#endif
