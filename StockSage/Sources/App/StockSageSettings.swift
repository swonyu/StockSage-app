import SwiftUI
#if os(macOS)
import ServiceManagement
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
    @State private var loginItemError: String?

    init(settings: AppSettings = .shared) { self.settings = settings }

    var body: some View {
        Form {
            Self.networkControls(webAccess: $settings.webAccess, offlineOnly: $settings.offlineOnly)
            Section("General") {
                #if os(macOS)
                Toggle("Launch StockSage at login", isOn: Binding(
                    get: { loginItemOn },
                    set: { setLoginItem($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Palette.dangerSoft)
                }
                #endif

                Toggle("Start the market monitor on launch", isOn: $monitorAutostart)
                Text("Polls prices in the background as soon as StockSage opens.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Section("Getting started") {
                // OnboardingSheet's header comment promised "reopenable from Settings"
                // since the extension batch — this is that affordance (auto-shift
                // backlog #2, 2026-07-16). The main window re-presents live via
                // StockSageApp's onChange; a closed window shows it on next open.
                Button("Show the welcome checklist again") { onboardingDone = false }
                Text("Reopens the research and paper-trading walkthrough, including the Salehman AI import, in the main window.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Section {
                StockSageMassiveKeyField()
            } header: {
                Text("Data sources")
            }

            Section {
                Text("Market data uses your configured providers. Local model serving is configured in Catalysts → Explanation model. These settings do not start a model server.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .navigationTitle("StockSage settings")
        #if os(macOS)
        .onAppear { refreshLoginItemStatus() }
        #endif
    }

    #if os(macOS)
    private func refreshLoginItemStatus() {
        loginItemOn = SMAppService.mainApp.status == .enabled
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
