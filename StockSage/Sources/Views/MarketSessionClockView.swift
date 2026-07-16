import Combine
import SwiftUI

// MARK: - MarketSessionClockView
//
// Compact, one-line-per-market readout of StockSageMarketHours' SCHEDULE state — not a
// live feed. Ticks every 60s off a plain Timer (phase boundaries are minute-granular, so
// 60s is plenty; no need for anything finer). Secondary/caption styling to match the
// header subtitle it sits beside (see MarketsView.swift `headerSubtitle`).
struct MarketSessionClockView: View {
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line(icon: "🇸🇦", label: "Tadawul", state: StockSageMarketHours.tadawulState(at: now, calendar: .current))
            line(icon: "🇺🇸", label: "NASDAQ", state: StockSageMarketHours.nasdaqState(at: now, calendar: .current))
        }
        .onReceive(timer) { now = $0 }
    }

    private func line(icon: String, label: String, state: StockSageMarketHours.SessionState) -> some View {
        HStack(spacing: 4) {
            Text(icon)
            Text(label).fontWeight(.medium)
            Text("·")
            Text(state.phaseLabel + countdownSuffix(state.nextTransition))
        }
        .font(.system(size: 11))
        .foregroundStyle(DS.Palette.textSecondary)
        .help(state.caveat)
    }

    private func countdownSuffix(_ next: Date?) -> String {
        guard let next, next > now else { return "" }
        let mins = Int(next.timeIntervalSince(now) / 60) + 1 // round up so "closes in 0m" never shows
        let h = mins / 60, m = mins % 60
        let countdown = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return " (\(countdown))"
    }
}
