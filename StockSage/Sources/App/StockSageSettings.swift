import SwiftUI
#if os(macOS)
import ServiceManagement
import AppKit
#endif

// MARK: - Settings scene: launch-at-login and monitor autostart
//
// Two independent switches. WHY separate: "launch at login" is an OS-level registration
// (SMAppService) that only opens the app window — it does NOT itself start network polling.
// "Start the monitor on launch" is the app-level opt-in for that polling, kept off by default
// so a fresh install never silently calls the quote feed.
//
// Honesty floor: the login-item toggle never claims a state the OS hasn't confirmed — it reads
// `SMAppService.mainApp.status` on appear and after every toggle, rather than trusting its own
// last write. register()/unregister() can throw (sandboxing, user denial in System Settings);
// failures surface as inline caption text, never silently swallowed.
struct StockSageSettingsView: View {
    @ObservedObject private var settings: AppSettings
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false

    @State private var loginItemOn = false
    @State private var loginItemRequiresApproval = false
    @State private var loginItemError: String?

    init(settings: AppSettings = .shared) { self.settings = settings }

    var body: some View {
        Form {
            Self.networkControls(webAccess: $settings.webAccess, offlineOnly: $settings.offlineOnly)
            Section("Startup") {
                #if os(macOS)
                Toggle("Launch StockSage at login", isOn: Binding(
                    get: { loginItemOn },
                    set: { setLoginItem($0) }
                ))
                if loginItemRequiresApproval {
                    Text("Launch at login is waiting for approval in System Settings.")
                        .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(DS.Palette.dangerSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif

                Toggle("Check saved price alerts on launch", isOn: $monitorAutostart)
                Text("Checks only your saved price levels while StockSage is open. Research always requires an explicit action.")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Getting started") {
                // OnboardingSheet's header comment promised "reopenable from Settings"
                // since the extension batch — this is that affordance (auto-shift
                // backlog #2, 2026-07-16). The main window re-presents live via
                // StockSageApp's onChange; a closed window shows it on next open.
                Button("Show the welcome checklist again") { onboardingDone = false }
                Text("Reopens the manual research and records walkthrough in the main window.")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                StockSageMassiveKeyField()
            } header: {
                Text("Data sources")
            }

            Section("Explanation model") {
                Text("Configure your model in Library → Events & model setup → Explanation model. Opening Settings does not start a model server.")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.modelGuidance")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .navigationTitle("StockSage settings")
        #if os(macOS)
        .onAppear { refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItemStatus()
        }
        #endif
    }

    #if os(macOS)
    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginItemOn = status == .enabled
        loginItemRequiresApproval = status == .requiresApproval
    }

    private func setLoginItem(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        // Never trust our own write — reflect whatever the OS actually confirms.
        refreshLoginItemStatus()
    }
    #endif

    /// Shared native rows; explicit bindings keep isolated render fixtures away from owner settings.
    static func networkControls(webAccess: Binding<Bool>, offlineOnly: Binding<Bool>) -> some View {
        Section("Network access") {
            Toggle("Web access", isOn: webAccess)
            Toggle("Offline Mode", isOn: offlineOnly)
            Text(offlineOnly.wrappedValue
                 ? "Offline Mode takes priority over Web access. External market-data requests are blocked."
                 : webAccess.wrappedValue
                    ? "Web access is enabled. Existing refresh and monitoring settings still apply."
                    : "Web access is off. Turn it on to allow external market-data requests.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    StockSageSettingsView()
}
