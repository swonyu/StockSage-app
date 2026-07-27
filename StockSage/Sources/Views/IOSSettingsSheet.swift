import SwiftUI

// iOS Settings (owner directive 2026-07-27): gear top-right next to refresh. Three concerns:
// auto-refresh cadence, trading horizon, and per-type notification control. macOS keeps its
// native Settings scene (StockSageSettingsView) — this file compiles empty there.

#if os(iOS)
struct StockSageIOSSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stocksage.autoRefresh") private var autoRefresh = true
    @AppStorage("stocksage.horizon") private var horizon = "short"
    @AppStorage(StockSageNotifyPrefs.strongSignalsKey) private var notifyStrong = true
    @AppStorage(StockSageNotifyPrefs.ideaAlertsKey) private var notifyIdeas = true
    @AppStorage(StockSageNotifyPrefs.priceAlertsKey) private var notifyPrice = true
    /// The board's sort identity key — horizon selects the default lens (raw values are
    /// StockSageIdeaProjection.Sort's STABLE storage identities; never rename).
    @AppStorage("marketsIdeaSort") private var ideaSortRaw = "EV / day"
    @AppStorage("stocksage.allocStrategy") private var allocStrategy = "greedyKnapsack"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-refresh live markets", isOn: $autoRefresh)
                } header: {
                    Text("Live data")
                } footer: {
                    Text("Refreshes quotes every 4.75 minutes while the app is open. The refresh button always works regardless.")
                }

                Section {
                    Picker("Horizon", selection: $horizon) {
                        Text("Short term").tag("short")
                        Text("Long term").tag("long")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Trading horizon")
                } footer: {
                    Text(horizon == "short"
                         ? "Ideas ranked by EV per day — fast setups that pay soonest rank first."
                         : "Ideas ranked by total expected value — the biggest edges rank first, regardless of holding time.")
                }
                .onChange(of: horizon) {
                    // Both are existing, tested engine rankings — the horizon picks the lens;
                    // the board's own sort picker can still override at any time.
                    ideaSortRaw = horizon == "short" ? "EV / day" : "Expected value"
                }

                Section {
                    Picker("Deploy-capital allocation", selection: $allocStrategy) {
                        Text("Concentrated").tag("greedyKnapsack")
                        Text("Balanced").tag("uniformScale")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Allocation")
                } footer: {
                    Text(allocStrategy == "greedyKnapsack"
                         ? "Full size to the fastest expected payoffs first; stops cold at the 8% heat cap. Fewer, bigger positions."
                         : "Every qualifying idea gets a share, all scaled down together to fit the 8% heat cap. More, smaller positions.")
                }

                Section {
                    Toggle("Strong Buy / Sell signals", isOn: $notifyStrong)
                    Toggle("Idea stop & target crossings", isOn: $notifyIdeas)
                    Toggle("My price alerts", isOn: $notifyPrice)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Only enabled types send pushes. Disabled price alerts stay armed — they just don't notify until re-enabled.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
