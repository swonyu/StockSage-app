import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit

@MainActor final class StockSageQuitDelegate: NSObject, NSApplicationDelegate {
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StockSageLocalModelStartup.shared.startFromSavedSettings()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !StockSageStore.isRunningTests else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        let defaults = UserDefaults.standard
        let pendingLoad = StockSageLocalModelStartup.shared.pendingConfig
        let backend = StockSageCatalystNarrator.selectedBackend(defaults.string(forKey: StockSageLocalModelServer.backendKey))
        guard pendingLoad != nil || ((backend == .auto || backend == .localServerOnly)
              && defaults.string(forKey: StockSageLocalModelServer.modelKey) != nil) else { return .terminateNow }
        quitting = true
        let config = pendingLoad ?? StockSageLocalModelServer.config(
            url: UserDefaults.standard.string(forKey: StockSageLocalModelServer.urlKey) ?? StockSageLocalModelServer.defaultURL,
            model: UserDefaults.standard.string(forKey: StockSageLocalModelServer.modelKey) ?? StockSageLocalModelServer.defaultModel)
        Task {
            let wasBusy = await StockSageLocalModelServer.beginShutdown()
            let unloaded: Bool
            if let config, config.supportsLocalUnload {
                unloaded = await StockSageLocalModelServer.unloadOnQuit(config, inferenceWasActive: wasBusy)
            }
            else { unloaded = true }
            var shouldQuit = true
            if !unloaded {
                let alert = NSAlert()
                alert.messageText = "Model unload could not be confirmed"
                alert.informativeText = "StockSage stopped sending AI requests, but the model server did not confirm unloading. You can unload it in LM Studio or Ollama. Model files and your records are kept."
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Keep StockSage Open")
                shouldQuit = alert.runModal() == .alertFirstButtonReturn
            }
            if !shouldQuit { StockSageLocalModelServer.cancelShutdown(); quitting = false }
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
}
#endif

/// Reject the retired capture flag before SwiftUI constructs any preference-backed
/// App properties, scenes or shared stores. Component fixtures run in the test host.
@main
enum StockSageLauncher {
    static let unsupportedQAMessage = "The former --qa capture mode is unavailable. Use isolated component fixture tests; full-app QA is not configured.\n"

    @MainActor static func main() {
        if CommandLine.arguments.contains("--qa") {
            FileHandle.standardError.write(Data(unsupportedQAMessage.utf8))
            exit(64)
        }
        StockSageApp.main()
    }
}

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
// Settings provides launch-at-login and monitor autostart. The first-run onboarding
// sheet introduces research, paper trading and journal records, with parent-app data
// import on Mac. App Intents provide Shortcuts/Spotlight actions.
struct StockSageApp: App {
    @StateObject private var chatSession = StockSageChatSession(
        historyURL: StockSageStore.isRunningTests ? nil : StockSageChatSession.localHistoryURL)
    // Review 2026-07-27: the App-scope @ObservedObject store was UNUSED in this body yet
    // re-evaluated the whole scene on every store publish (each quote tick). MarketsView
    // owns its own observation; the App struct needs none.
    #if os(macOS)
    @NSApplicationDelegateAdaptor(StockSageQuitDelegate.self) private var quitDelegate
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    #endif
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        guard !StockSageStore.isRunningTests else { return }
        // Readback precedes legacy deletion. Settings surfaces any Keychain failure and
        // permits retry; a failed migration must not destroy a working credential.
        try? StockSageMassiveCredential.beginLaunch(defaults: .standard, storage: StockSageMassiveCredential.keychain,
            environment: ProcessInfo.processInfo.environment[StockSageMassive.keyEnvName])
        #if os(iOS)
        // Set delegate BEFORE the app finishes launching so foreground banners work
        UNUserNotificationCenter.current().delegate = StockSageNotificationDelegate.shared
        // MetricKit field telemetry (external-report item 10) — local-only, nothing transmitted.
        StockSageTelemetry.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(StockSageStore.isRunningTests ? "StockSage — Automated Tests" : "StockSage", id: "main") {
            // Unit-test hosts must not launch refresh/scan/monitor or write owner state.
            if !StockSageStore.isRunningTests {
                // Review triage 2026-07-27: an Xcode-assistant edit wrapped this in a DEBUG
                // fallback keyed on NSClassFromString("MarketsView") — always nil for a SwiftUI
                // STRUCT, so every Debug build showed the error card instead of the app. Reverted
                // to the direct view; its delegate-timing init() fix above was kept (it's better
                // than the old onAppear wiring).
                // Home summarizes completed research and due reviews on both platforms.
                Group { MarketsView(chatSession: chatSession) }
                    .tint(DS.Palette.accent)
                    #if os(macOS)
                    .frame(minWidth: 900, minHeight: 700)   // mac window floor — on iOS this forced
                                                            // a 900pt canvas onto a 430pt phone (clip)
                    #endif
                    // Dark-committed brand (macOS 27 overhaul, 2026-07-16): the app paints a
                    // dark canvas, so declare dark — otherwise system controls (pickers,
                    // Form, menus) follow the OS scheme and render light-on-dark-canvas in
                    // light mode, and materials would sample incoherently.
                    .preferredColorScheme(.dark)
                    #if os(macOS)
                    .safeAreaInset(edge: .bottom) {
                        let startup = StockSageLocalModelStartup.shared
                        if !startup.ready, let message = startup.message {
                            HStack {
                                if startup.isWorking { ProgressView().controlSize(.small) }
                                Text(message).font(.callout).textSelection(.enabled)
                                Spacer()
                                if !startup.isWorking {
                                    Button("Retry model") { startup.startFromSavedSettings() }
                                }
                            }
                            .padding().background(.bar)
                        }
                    }
                    #endif
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
            } else {
                Text("Automated test host. App startup services are disabled.")
                    .padding()
            }
        }
        #if os(macOS)
        // XCTest uses this app as a host, not as the owner's visible workspace.
        // Disable restoration too: launch suppression alone allows a saved empty window back.
        .defaultLaunchBehavior(StockSageStore.isRunningTests ? .suppressed : .automatic)
        .restorationBehavior(StockSageStore.isRunningTests ? .disabled : .automatic)
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
                .tint(DS.Palette.accent)
                // Same dark commitment as the main window: the Form's DS.Palette
                // captions (white-opacity) were unreadable on a light system Form.
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
