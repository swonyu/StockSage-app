import SwiftUI

// MARK: - StockSage (standalone app entry)
//
// The Markets/StockSage money engine, extracted from the "Salehman AI" app @ fc8f383 as a
// standalone macOS app. There is no tab bar here — `MarketsView` IS the app: the ideas board,
// best-opportunity card, fast lane, detail sheet, journal, and backtest are the whole product.
//
// The extraction is source-clean: the engine (StockSage/*) and the Markets views depend only on
// the DesignSystem (`DS.*`), `ToolPolicy`, and a 3-member `AppSettings` shim — none of the
// parent app's brain/agents/knowledge/voice/media code came along.
//
// Extension batch (2026-07-16): menu-bar ticker (toggle in Settings, default on), Settings
// scene (launch-at-login, monitor autostart, menu bar), first-run onboarding sheet (the
// first-trade checklist + parent-app data import), App Intents (Shortcuts/Spotlight).
@main
struct StockSageApp: App {
    @ObservedObject private var store = StockSageStore.shared
    @AppStorage("stocksage.menubar.enabled") private var menuBarEnabled = true
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some Scene {
        WindowGroup(id: "main") {
            MarketsView()
                .frame(minWidth: 900, minHeight: 700)
                // Dark-committed brand (macOS 27 overhaul, 2026-07-16): the app paints a
                // dark canvas, so declare dark — otherwise system controls (pickers,
                // Form, menus) follow the OS scheme and render light-on-dark-canvas in
                // light mode, and materials would sample incoherently.
                .preferredColorScheme(.dark)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingSheet(isPresented: $showOnboarding)
                }
                .task {
                    if !onboardingDone { showOnboarding = true }
                    // Autostart is a Settings opt-in (default OFF): the monitor's own honesty
                    // gates (no sample/cached/stale pushes) still apply to every cycle.
                    if monitorAutostart { try? StockSageMonitor.shared.start() }
                }
                // Settings' "Show the welcome checklist again" flips onboardingDone to
                // false — re-present live (the .task above runs once per window; without
                // this the reopen would silently wait for the next launch).
                .onChange(of: onboardingDone) {
                    if !onboardingDone { showOnboarding = true }
                }
        }
        .windowResizability(.contentMinSize)

        // MENU BAR PARKED (2026-07-16): with MenuBarExtra present, the main run loop wedges in
        // a nested RunCurrentEventLoopInMode inside SwiftUI's graph-flush observer (sampled) —
        // main-queue starvation: black window, no display updates, force-quit territory. The
        // scene is disabled until the app is signed / the interaction is reworked; the views
        // (StockSageMenuBar.swift) stay compiled for that return.

        Settings {
            StockSageSettingsView()
                // Same dark commitment as the main window: the Form's DS.Palette
                // captions (white-opacity) were unreadable on a light system Form.
                .preferredColorScheme(.dark)
        }
    }
}
