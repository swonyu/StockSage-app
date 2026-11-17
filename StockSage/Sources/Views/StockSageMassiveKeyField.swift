import SwiftUI

/// Massive API-key rows shared by the macOS Settings scene (`StockSageSettingsView`) and the iOS
/// settings sheet (`StockSageIOSSettingsSheet`) — one implementation, two hosts, so the field, the
/// "Test connection" probe, and the honesty copy cannot drift between platforms.
///
/// Secure edit buffer; only an explicit Save writes the device Keychain. Existing values are
/// never copied into the field. The probe reports outcomes, not credential values.
struct StockSageMassiveKeyField: View {
    @State private var massiveKey = ""
    @State private var probing = false
    @State private var status: String?

    var body: some View {
        SecureField("New Massive API key (\(StockSageMassive.keyEnvName))", text: $massiveKey)
            .autocorrectionDisabled()
        ViewThatFits(in: .horizontal) {
            HStack { keyActions }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { keyActions }
        }
        .onAppear {
            guard !StockSageStore.isRunningTests else { return }
            do {
                try StockSageMassiveCredential.migrate(defaults: .standard, storage: StockSageMassiveCredential.keychain)
                let key = try StockSageMassiveCredential.resolve(defaults: .standard,
                    storage: StockSageMassiveCredential.keychain,
                    environment: ProcessInfo.processInfo.environment[StockSageMassive.keyEnvName])
                status = key.isEmpty ? "No credential configured." : "Credential configured."
            } catch { status = "Keychain unavailable. The previous saved key has not been deleted; unlock your device and try Save again." }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { probeButton; probeStatus }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { probeButton; probeStatus }
        }
        Text("Automatic routing: Massive first for US quotes and daily history when configured; missing or unsupported results use Yahoo, which may be delayed. Saudi quotes use Yahoo. Quote labels show the provider that actually answered, not this setting. The saved key stays in this device’s Keychain without syncing. Removing it does not remove a separately configured environment key. Test connection checks snapshot access, not every paid add-on.")
            .font(.caption)
            .foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.massive.disclosure")
    }

    @ViewBuilder private var keyActions: some View {
        Button { saveKey(massiveKey) } label: {
            Text("Save key")
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
        .disabled(massiveKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("settings.massive.save")
        Button(role: .destructive) { saveKey("") } label: {
            Text("Remove saved key")
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
        .accessibilityIdentifier("settings.massive.remove")
    }

    private var probeButton: some View {
        Button { testConnection() } label: {
            Text(probing ? "Testing…" : "Test connection")
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
        .disabled(probing)
        .accessibilityIdentifier("settings.massive.test")
    }

    @ViewBuilder private var probeStatus: some View {
        if let status {
            Text(status).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.massive.status")
        }
    }

    private func saveKey(_ value: String) {
        do {
            _ = try StockSageMassive.setAPIKey(value)
            massiveKey = ""
            status = value.isEmpty ? "Saved key removed. Environment fallback is unchanged." : "Key saved in this device’s Keychain."
        } catch { status = "Could not verify the key change. Credentials may have changed; unlock your device and try again. Legacy preferences were preserved." }
    }

    private func testConnection() {
        guard !probing else { return }
        probing = true
        let revision = StockSageMassive.credentialRevision()
        let key = StockSageMassive.apiKey
        Task {
            defer { probing = false }
            guard revision == StockSageMassive.credentialRevision(), key == StockSageMassive.apiKey else { return }
            StockSageBenzingaClient.shared.clearAuthorizationFailures()
            let result = await StockSageMassive.probe()
            guard !Task.isCancelled, revision == StockSageMassive.credentialRevision(),
                  key == StockSageMassive.apiKey else { return }
            status = result
        }
    }
}
