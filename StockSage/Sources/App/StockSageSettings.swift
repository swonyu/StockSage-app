import SwiftUI
import ServiceManagement

// MARK: - Settings scene: launch-at-login, monitor autostart, menu-bar toggle
//
// Three independent switches. WHY separate: "launch at login" is an OS-level registration
// (SMAppService) that only opens the app window — it does NOT itself start network polling.
// "Start the monitor on launch" is the app-level opt-in for that polling, kept off by default
// so a fresh install never silently calls the quote feed. The menu-bar toggle just hides/shows
// the (separately-wired) MenuBarExtra scene.
//
// Honesty floor: the login-item toggle never claims a state the OS hasn't confirmed — it reads
// `SMAppService.mainApp.status` on appear and after every toggle, rather than trusting its own
// last write. register()/unregister() can throw (sandboxing, user denial in System Settings);
// failures surface as inline caption text, never silently swallowed.
struct StockSageSettingsView: View {
    @AppStorage("stocksage.monitor.autostart") private var monitorAutostart = false
    @AppStorage("stocksage.menubar.enabled") private var menuBarEnabled = true
    @AppStorage("stocksage.onboarding.done") private var onboardingDone = false

    @State private var loginItemOn = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch StockSage at login", isOn: Binding(
                    get: { loginItemOn },
                    set: { setLoginItem($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Palette.dangerSoft)
                }

                Toggle("Start the market monitor on launch", isOn: $monitorAutostart)
                Text("Polls prices in the background as soon as StockSage opens.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)

                Toggle("Show menu-bar ticker", isOn: $menuBarEnabled)
            }

            Section {
                // OnboardingSheet's header comment promised "reopenable from Settings"
                // since the extension batch — this is that affordance (auto-shift
                // backlog #2, 2026-07-16). The main window re-presents live via
                // StockSageApp's onChange; a closed window shows it on next open.
                Button("Show the welcome checklist again") { onboardingDone = false }
                Text("Reopens the first-trade checklist (and the Salehman AI import) in the main window.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Section {
                Text("Free · no accounts · data stays on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { refreshLoginItemStatus() }
    }

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
}

#Preview {
    StockSageSettingsView()
}
