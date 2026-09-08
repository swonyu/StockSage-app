#if os(macOS)
import SwiftUI

/// Desktop presentation only. Raw routes and keyboard assignments remain shared with iPhone.
enum StockSageDesktop {
    static let sections: [MarketSection] = [
        .briefing, .watchlist, .ideas, .all, .catalysts, .heatmap, .portfolio, .alerts, .chat
    ]
    static let berry = Color(red: 0.85, green: 0.294, blue: 0.439)
    static let selection = Color(red: 0.239, green: 0.149, blue: 0.188)
    static func sidebarWidth(collapsed: Bool) -> CGFloat { collapsed ? 64 : 220 }
    static func shortcut(for section: MarketSection) -> Int {
        (MarketSection.allCases.firstIndex(of: section) ?? 0) + 1
    }
    static func title(for section: MarketSection) -> String {
        switch section {
        case .briefing: "Home"
        case .all: "Markets"
        default: section.title
        }
    }
    static func subtitle(for section: MarketSection) -> String {
        switch section {
        case .briefing: "Your briefing, followed by the wider market."
        case .watchlist: "The companies you choose to follow."
        case .ideas: "Compare the setup, the evidence and the risk."
        case .all: "Explore the tracked market."
        case .catalysts: "What is scheduled. What has changed."
        case .heatmap: "The shape of the market, at a glance."
        case .portfolio: "Your holdings, journal and research record."
        case .alerts: "Choose what deserves your attention."
        case .chat: "Start with your data. Ask when you want to go deeper."
        }
    }
    static func icon(for section: MarketSection) -> String {
        section == .briefing ? "house" : section.icon
    }
    enum PortfolioPage: String, CaseIterable, Identifiable {
        case holdings = "Holdings", journal = "Journal", paper = "Paper", analytics = "Analytics"
        var id: Self { self }
    }
}

/// No store observation: market ticks cannot change the navigation's identity or selection.
struct StockSageDesktopNavigation: View {
    @Binding var selection: MarketSection
    @AppStorage("stocksage.mac.sidebar.collapsed") private var collapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(StockSageDesktop.berry)
                    .frame(width: 32, height: 36)
                if !collapsed {
                    Text("StockSage").font(.system(size: 19, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16).padding(.top, 25).padding(.bottom, 20)
            .accessibilityElement(children: .ignore).accessibilityLabel("StockSage navigation")

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(StockSageDesktop.sections) { section in
                        if section == .all || section == .portfolio {
                            if !collapsed {
                                Text(section == .all ? "EXPLORE" : "YOUR WORKSPACE")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.8).foregroundStyle(.secondary)
                                    .padding(.leading, 12).padding(.top, 20).padding(.bottom, 6)
                            } else {
                                Divider().padding(.vertical, 8)
                            }
                        }
                        Button { selection = section } label: {
                            navigationRow(section)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(String(StockSageDesktop.shortcut(for: section)))), modifiers: .command)
                        .help("\(StockSageDesktop.title(for: section)) · ⌘\(StockSageDesktop.shortcut(for: section))")
                        .accessibilityLabel(StockSageDesktop.title(for: section))
                        .accessibilityAddTraits(selection == section ? .isSelected : [])
                        .accessibilityIdentifier("desktop.nav.\(section.rawValue)")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 12)
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 6) {
                SettingsLink {
                    utilityRow("Settings", icon: "gearshape")
                }
                .buttonStyle(.plain).help("Settings · ⌘,")
                .accessibilityLabel("Settings").accessibilityIdentifier("desktop.settings")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { collapsed.toggle() }
                } label: {
                    utilityRow(collapsed ? "Expand sidebar" : "Collapse sidebar", icon: "sidebar.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(collapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityIdentifier("desktop.sidebar.toggle")
            }
            .padding(10).padding(.bottom, 10)
        }
        .frame(width: StockSageDesktop.sidebarWidth(collapsed: collapsed))
        .frame(maxHeight: .infinity)
        .background {
            if reduceTransparency { Color(white: 0.12) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
        .accessibilityElement(children: .contain)
    }

    private func navigationRow(_ section: MarketSection) -> some View {
        let selected = selection == section
        return HStack(spacing: 10) {
            Image(systemName: StockSageDesktop.icon(for: section))
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? StockSageDesktop.berry : .secondary)
                .frame(width: 24)
            if !collapsed {
                Text(StockSageDesktop.title(for: section))
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? StockSageDesktop.selection : .clear, in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(StockSageDesktop.berry).frame(width: 3, height: 18).padding(.leading, 2) }
        }
        .contentShape(.rect)
    }

    private func utilityRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 24)
            if !collapsed { Text(title).font(.system(size: 13)); Spacer(minLength: 0) }
        }
        .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
}
#endif
