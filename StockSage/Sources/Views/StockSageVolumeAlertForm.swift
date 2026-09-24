#if os(macOS)
import SwiftUI

/// Adds a one-shot day-volume alert ("notify me once when TICKER trades ≥ N shares today").
/// Checked by `StockSageMonitor` while Price-alert monitoring is on, confirmed from a Massive
/// REST snapshot (`day.v`) during the regular session; rows render in the Price alerts list.
struct StockSageVolumeAlertForm: View {
    @ObservedObject var store: StockSageStore
    @State private var symbol = ""
    @State private var shares = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Day volume ≥").font(.caption).foregroundStyle(.secondary)
                TextField("Ticker", text: $symbol).frame(width: 78)
                TextField("Shares", text: $shares).frame(width: 110)
                Button("Add volume alert", action: add)
            }
            .textFieldStyle(.roundedBorder)
            if !error.isEmpty {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .help("Regular-session volume from Massive, confirmed by a REST snapshot before notifying. Needs a Massive key.")
    }

    private func add() {
        let sym = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard StockSageMassive.covers(sym), sym.count <= 12 else { error = "Enter a US ticker."; return }
        guard let level = StockSageInput.positiveAmount(shares) else { error = "Enter a positive share count."; return }
        guard store.addPriceAlert(symbol: sym, target: level, direction: .above, metric: .dayVolume) else {
            error = store.priceAlertsPersistenceError ?? "Already armed — this alert is already active."
            return
        }
        symbol = ""; shares = ""; error = ""
    }
}
#endif
