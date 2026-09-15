import SwiftUI

// iOS Settings: gear top-right next to refresh. Research horizons are selected in Research;
// this sheet controls data, allocation and notification preferences. macOS keeps its
// native Settings scene (StockSageSettingsView) — this file compiles empty there.

// BATCH 12.4 (2026-09-12) — the "Live data" footer, as a pure function.
//
// It used to state a 4.75-minute timer. NO TIMER USES THAT CADENCE: `MarketsView.refreshIntervals`
// returns (streamGap: 30s, full: 900s) at rest and (60s, 1800s) when thermally stressed, and those
// are the only two auto-refresh loops. 285s survived from an owner directive on 2026-07-27 that the
// cadence change later superseded.
//
// It is declared OUTSIDE the `#if os(iOS)` fence deliberately: the test target builds for macOS, so
// a helper inside the fence cannot be pinned. Same shape as `MarketsView.firstScanProgressCaption`.
//
// The manual-only sentence is gated on `liveStream` on purpose. The stream is keyed to
// `liveStreamEnabled` ALONE (MarketsView.swift:512-514) — neither toggle in this sheet touches it —
// so "prices update only when you pull to refresh" is FALSE whenever streaming is on, and would
// contradict the same footer's own first sentence.
enum StockSageLiveDataFooter {
    /// Seconds between background monitor polls. `StockSageMonitor.start(interval:)`'s default;
    /// all three call sites use it.
    static let monitorPollSeconds = 180

    static func text(liveStream: Bool, autoRefresh: Bool, monitorEnabled: Bool,
                     intervals: (streamGap: Int, full: Int)) -> String {
        let lead = liveStream
            ? "US names stream trade-by-trade while the app is open — prices move on their own. Saudi names have no stream (the data vendor carries no Saudi exchange), so they rely on polling."
            : "Streaming off — every price comes from polling."
        let sweep = "A rotating sweep tops up to \(StockSageStore.streamGapMaxPerSweep) tracked names every \(intervals.streamGap)s, and the whole board refreshes every \(intervals.full / 60) minutes."
        if autoRefresh { return lead + " " + sweep }
        if monitorEnabled {
            return lead + " Auto-refresh is off, but Strong-signal monitoring (the Markets alerts row) still polls every \(monitorPollSeconds / 60) minutes."
        }
        // Both polling paths off. Only NOW is a manual-only claim true — and only for the names
        // that are not streaming.
        return lead + (liveStream
            ? " Auto-refresh and Strong-signal monitoring are both off: nothing polls, so non-streaming names update only when you pull to refresh or tap the refresh button."
            : " Auto-refresh and Strong-signal monitoring are both off — prices update only when you pull to refresh or tap the refresh button.")
    }
}

#if os(iOS)
struct StockSageIOSSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("stocksage.autoRefresh") private var autoRefresh = true
    @AppStorage("stocksage.liveStream") private var liveStream = true
    @AppStorage(StockSageNotifyPrefs.strongSignalsKey) private var notifyStrong = true
    @AppStorage(StockSageNotifyPrefs.ideaAlertsKey) private var notifyIdeas = true
    @AppStorage(StockSageNotifyPrefs.priceAlertsKey) private var notifyPrice = true
    @AppStorage("stocksage.allocStrategy") private var allocStrategy = "greedyKnapsack"
    /// Mirrors `StockSageMonitor.foregroundMonitoringEnabled`'s key — the writer is the Markets
    /// alerts row ("Strong-signal monitoring", MarketsView.swift:1234), NOT this sheet's
    /// "Strong Buy / Sell signals" toggle, which only gates pushes and stops no poll.
    @AppStorage("stocksage.monitor.iosEnabled") private var monitorEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                StockSageSettingsView.networkControls(webAccess: $settings.webAccess, offlineOnly: $settings.offlineOnly)
                    .listRowBackground(DS.Bezel.cardFill)
                Section {
                    Toggle("Real-time streaming", isOn: $liveStream)
                    Toggle("Auto-refresh live markets", isOn: $autoRefresh)
                } header: {
                    Text("Live data")
                } footer: {
                    Text(StockSageLiveDataFooter.text(
                        liveStream: liveStream, autoRefresh: autoRefresh, monitorEnabled: monitorEnabled,
                        intervals: MarketsView.refreshIntervals(thermal: ProcessInfo.processInfo.thermalState)))
                }
                .listRowBackground(DS.Bezel.cardFill)

                Section {
                    StockSageMassiveKeyField()
                } header: {
                    Text("Data sources")
                }
                .listRowBackground(DS.Bezel.cardFill)

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
                .listRowBackground(DS.Bezel.cardFill)

                Section {
                    Toggle("Strong Buy / Sell signals", isOn: $notifyStrong)
                    Toggle("Idea stop & target crossings", isOn: $notifyIdeas)
                    Toggle("My price alerts", isOn: $notifyPrice)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Only enabled types send pushes. Disabled price alerts stay armed — they just don't notify until re-enabled.")
                }
                .listRowBackground(DS.Bezel.cardFill)
            }
            .scrollContentBackground(.hidden)
            .background { DSCanvasBackground().ignoresSafeArea() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
    }
}
#endif
