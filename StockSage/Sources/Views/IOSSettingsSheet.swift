import SwiftUI

// iOS Settings: gear top-right next to refresh. Trading windows have their own primary tabs;
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
        let lead = (liveStream
            ? "US names stream qualified trade prices while the app is open — prices move on their own. Non-streaming names rely on polling."
            : "Streaming off — prices come from polling.")
            + " Quotes also refresh when StockSage opens and when newly tracked names need a price."
        let alerts = monitorEnabled
            ? " Saved price alerts are checked normally every \(monitorPollSeconds / 60) minutes while the app is active, or every \(monitorPollSeconds * 2 / 60) minutes under thermal pressure; control this in Library → Alerts → Price-alert monitoring."
            : " Price-alert monitoring is off."
        if autoRefresh {
            return lead + " A rotating sweep tops up to \(StockSageStore.streamGapMaxPerSweep) tracked names every \(intervals.streamGap)s, and the whole board refreshes every \(intervals.full / 60) minutes." + alerts
        }
        return lead + " Periodic market refresh is off. Pull to refresh or tap Refresh for an extra update." + alerts

    }
}

#if os(iOS)
struct StockSageIOSSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var settings: AppSettings
    @AppStorage("stocksage.autoRefresh") private var autoRefresh = true
    @AppStorage("stocksage.liveStream") private var liveStream = true
    @AppStorage(StockSageNotifyPrefs.priceAlertsKey) private var notifyPrice = true
    @AppStorage("stocksage.allocStrategy") private var allocStrategy = "greedyKnapsack"
    /// Mirrors `StockSageMonitor.foregroundMonitoringEnabled`'s key — the writer is the Markets
    /// alerts row ("Strong-signal monitoring", MarketsView.swift:1234), NOT this sheet's
    /// "Strong Buy / Sell signals" toggle, which only gates pushes and stops no poll.
    @AppStorage("stocksage.monitor.iosEnabled") private var monitorEnabled = true

    init(settings: AppSettings = .shared) { self.settings = settings }

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
                    let allocation = Picker("Deploy-capital allocation", selection: $allocStrategy) {
                        Text("Concentrated").tag("greedyKnapsack")
                        Text("Balanced").tag("uniformScale")
                    }
                    .accessibilityIdentifier("settings.ios.allocation")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deploy-capital allocation").font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                        if typeSize.isAccessibilitySize {
                            allocation.pickerStyle(.menu).labelsHidden()
                                .frame(minHeight: 44, alignment: .leading)
                        } else {
                            allocation.pickerStyle(.segmented)
                        }
                    }.padding(.vertical, 4)
                } header: {
                    Text("Allocation")
                } footer: {
                    Text(allocStrategy == "greedyKnapsack"
                         ? "Full size to the fastest expected payoffs first; stops cold at the 8% heat cap. Fewer, bigger positions."
                         : "Every qualifying idea gets a share, all scaled down together to fit the 8% heat cap. More, smaller positions.")
                }
                .listRowBackground(DS.Bezel.cardFill)

                Section {
                    Toggle("My price alerts", isOn: $notifyPrice)
                        .accessibilityIdentifier("settings.ios.priceAlerts")
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
                        .accessibilityIdentifier("settings.ios.done")
                }
            }
        }
        .tint(DS.Palette.accent)
        .preferredColorScheme(.dark)
    }
}
#endif
