import Combine
import SwiftUI

// MARK: - MarketSessionClockView
//
// Compact, one-line-per-market readout of StockSageMarketHours' SCHEDULE state — not a
// live feed. Ticks every 60s off a plain Timer (phase boundaries are minute-granular, so
// 60s is plenty; no need for anything finer). Secondary/caption styling to match the
// freshness banner it sits beside (see MarketsView.swift `feedBanner`).
struct MarketSessionClockView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @ScaledMetric(relativeTo: .caption2) private var font11: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line(icon: "🇸🇦", label: "Tadawul", state: StockSageMarketHours.tadawulState(at: now, calendar: .current))
            line(icon: "🇺🇸", label: "NASDAQ", state: StockSageMarketHours.nasdaqState(at: now, calendar: .current))
        }
        .onReceive(timer) { now = $0 }
    }

    private func line(icon: String, label: String, state: StockSageMarketHours.SessionState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if typeSize.isAccessibilitySize {
                Text("\(icon) \(label)").fontWeight(.medium)
                Text(state.phaseLabel + countdownSuffix(state.nextTransition))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 4) {
                    Text(icon)
                    Text(label).fontWeight(.medium)
                    Text("·")
                    Text(state.phaseLabel + countdownSuffix(state.nextTransition))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .font(.system(size: font11))
        .foregroundStyle(DS.Palette.textSecondary)
        .help(state.caveat)
        // Both markets read as one status group to VoiceOver instead of four fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(state.phaseLabel)")
    }

    private func countdownSuffix(_ next: Date?) -> String {
        guard let next, next > now else { return "" }
        let mins = Int(next.timeIntervalSince(now) / 60) + 1 // round up so "closes in 0m" never shows
        let h = mins / 60, m = mins % 60
        let countdown = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return " (\(countdown))"
    }
}
