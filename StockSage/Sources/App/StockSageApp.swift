import SwiftUI
import UserNotifications

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
    // Review 2026-07-27: the App-scope @ObservedObject store was UNUSED in this body yet
    // re-evaluated the whole scene on every store publish (each quote tick). MarketsView
    // owns its own observation; the App struct needs none.
    @AppStorage("stocksage.menubar.enabled") private var menuBarEnabled = true
    #if os(macOS)
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    #endif
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        guard !StockSageStore.isRunningTests else { return }
        #if os(iOS)
        // Set delegate BEFORE the app finishes launching so foreground banners work
        UNUserNotificationCenter.current().delegate = StockSageNotificationDelegate.shared
        // MetricKit field telemetry (external-report item 10) — local-only, nothing transmitted.
        StockSageTelemetry.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup("StockSage", id: "main") {
            // Unit-test hosts must not launch refresh/scan/monitor or write owner state.
            if !StockSageStore.isRunningTests {
                // Review triage 2026-07-27: an Xcode-assistant edit wrapped this in a DEBUG
                // fallback keyed on NSClassFromString("MarketsView") — always nil for a SwiftUI
                // STRUCT, so every Debug build showed the error card instead of the app. Reverted
                // to the direct view; its delegate-timing init() fix above was kept (it's better
                // than the old onAppear wiring).
                Group {
                    #if os(macOS)
                    MarketsView(qaSection: .briefing)
                    #else
                    MarketsView()
                    #endif
                }
                    #if os(macOS)
                    .frame(minWidth: 900, minHeight: 700)   // mac window floor — on iOS this forced
                                                            // a 900pt canvas onto a 430pt phone (clip)
                    #endif
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
                        #if os(macOS)
                        // Autostart is a Settings opt-in (default OFF): the monitor's own honesty
                        // gates (no sample/cached/stale pushes) still apply to every cycle.
                        if monitorAutostart { try? StockSageMonitor.shared.start() }
                        #endif
                    }
                    // Settings' "Show the welcome checklist again" flips onboardingDone to
                    // false — re-present live (the .task above runs once per window; without
                    // this the reopen would silently wait for the next launch).
                    .onChange(of: onboardingDone) {
                        if !onboardingDone { showOnboarding = true }
                    }
                    #if os(iOS)
                    // One lifecycle entry for launch AND return: respect the saved iOS opt-out.
                    // No start after awaiting permission (the app could have backgrounded or
                    // been opted out meanwhile). start() owns the single permission request.
                    .onChange(of: scenePhase, initial: true) {
                        switch scenePhase {
                        case .active:
                            StockSageMonitor.shared.resumeForegroundMonitoring()
                            StockSageMonitor.shared.clearBadge()   // alerts read on return — badge honest again
                        case .background: StockSageMonitor.shared.stop() // pause; retain the user's choice
                        default: break
                        }
                    }
                    #endif
            }
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unifiedCompact)
        #endif

        // MENU BAR PARKED (2026-07-16): with MenuBarExtra present, the main run loop wedges in
        // a nested RunCurrentEventLoopInMode inside SwiftUI's graph-flush observer (sampled) —
        // main-queue starvation: black window, no display updates, force-quit territory. The
        // scene is disabled until the app is signed / the interaction is reworked; the views
        // (StockSageMenuBar.swift) stay compiled for that return.

        #if os(macOS)
        Settings {
            StockSageSettingsView()
                // Same dark commitment as the main window: the Form's DS.Palette
                // captions (white-opacity) were unreadable on a light system Form.
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
