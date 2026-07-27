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
/// TEMP DIAGNOSTIC (2026-07-27, iOS 27-beta black-screen hunt): checkpoint trail, dual channel
/// (NSLog → device syslog; Documents/boot.log → Files app + afc pull). Remove once the wedge
/// is found — the last mark that appears is the boundary where boot stops.
func bootlog(_ mark: String) {
    NSLog("STOCKSAGE-BOOT %@", mark)
    #if os(iOS)
    if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let f = dir.appendingPathComponent("boot.log")
        let line = "\(Date()) \(mark)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: f)
        }
    }
    #endif
}

@main
struct StockSageApp: App {
    private let bootA: Void = bootlog("A-props-begin")
    @ObservedObject private var store = StockSageStore.shared
    private let bootB: Void = bootlog("B-store-inited")
    @AppStorage("stocksage.menubar.enabled") private var menuBarEnabled = true
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    @State private var showOnboarding = false
    
    init() {
        bootlog("C-init-body")
        #if os(iOS)
        // Set delegate BEFORE the app finishes launching so foreground banners work
        UNUserNotificationCenter.current().delegate = StockSageNotificationDelegate.shared
        #endif
        bootlog("D-init-done")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            let _ = bootlog("E-scene-eval")
            // Review triage 2026-07-27: an Xcode-assistant edit wrapped this in a DEBUG
            // fallback keyed on NSClassFromString("MarketsView") — always nil for a SwiftUI
            // STRUCT, so every Debug build showed the error card instead of the app. Reverted
            // to the direct view; its delegate-timing init() fix above was kept (it's better
            // than the old onAppear wiring).
            if ProcessInfo.processInfo.arguments.contains("--stocksage-minimal") {
                // Diagnostic seam (2026-07-27, iOS 27 black-screen hunt): bare view with NONE
                // of the app chrome (no sheet/task/monitor) — isolates toolchain vs view tree.
                Text("MINIMAL OK — scene rendered").font(.title).padding().onAppear { bootlog("F-minimal-appeared") }
            } else {
            MarketsView()
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 700)   // mac window floor — on iOS this forced
                                                        // a 900pt canvas onto a 430pt phone (clip)
                #endif
                .onAppear { bootlog("F-markets-appeared") }
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
                    #if os(iOS)
                    // iOS (2026-07-27, owner: "make it also send notifications"): the monitor's
                    // only start switch lives in the macOS-fenced Settings scene, and iOS has no
                    // background daemon anyway — foreground polling IS the iOS monitor model, so
                    // it starts with the app. Request permission with proper error handling.
                    await requestNotificationAuthorization()
                    try? StockSageMonitor.shared.start()
                    #endif
                }
                // Settings' "Show the welcome checklist again" flips onboardingDone to
                // false — re-present live (the .task above runs once per window; without
                // this the reopen would silently wait for the next launch).
                .onChange(of: onboardingDone) {
                    if !onboardingDone { showOnboarding = true }
                }
            }
        }
        #if os(macOS)
        .windowResizability(.contentMinSize)
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
    
    #if os(iOS)
    /// Request notification authorization and log the result for debugging
    private func requestNotificationAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                print("⚠️ StockSage: Notification permission denied - alerts will not appear")
            }
        } catch {
            print("⚠️ StockSage: Failed to request notification authorization: \(error)")
        }
    }
    #endif
}
