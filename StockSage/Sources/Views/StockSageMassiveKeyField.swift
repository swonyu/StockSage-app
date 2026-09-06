import SwiftUI

/// Massive API-key rows shared by the macOS Settings scene (`StockSageSettingsView`) and the iOS
/// settings sheet (`StockSageIOSSettingsSheet`) — one implementation, two hosts, so the field, the
/// "Test connection" probe, and the honesty copy cannot drift between platforms.
///
/// Key by NAME only: the field persists under `StockSageMassive.keyDefaultsKey`
/// (`stocksage.massive.key`) and is a `SecureField` so the value never appears on screen, in a
/// screenshot, or in the visual-QA pixel runs. The probe reports HTTP outcome in words, never the key.
struct StockSageMassiveKeyField: View {
    @AppStorage(StockSageMassive.keyDefaultsKey) private var massiveKey = ""
    @State private var probing = false
    @State private var status: String?

    var body: some View {
        SecureField("Massive API key (\(StockSageMassive.keyEnvName))", text: $massiveKey)
            .autocorrectionDisabled()
        HStack(spacing: 8) {
            Button(probing ? "Testing…" : "Test connection") { testConnection() }
                .disabled(probing)
            if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Text("Automatic routing: Massive first for US quotes and daily history when configured; missing or unsupported results use Yahoo, which may be delayed. Saudi quotes use Yahoo. Quote labels show the provider that actually answered, not this setting. The key is stored locally and sent with authenticated Massive requests. Test connection checks snapshot access, not every paid add-on.")
            .font(.system(size: 11))
            .foregroundStyle(DS.Palette.textSecondary)
    }

    private func testConnection() {
        guard !probing else { return }
        probing = true
        Task {
            status = await StockSageMassive.probe()
            probing = false
        }
    }
}
