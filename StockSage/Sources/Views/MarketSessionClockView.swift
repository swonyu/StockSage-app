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
        // NO layoutPriority here: giving the phase text priority starved the flag and market
        // name to zero width, so the Tadawul row rendered as a bare "Scheduled open 10:00
        // Riyadh (8m)" with no indication of WHICH market (caught on device 2026-07-28).
        // The whole line shrinks together instead.
        .font(.system(size: 11))
        // One market = one line (2026-07-28). Unbounded, a long phase like "Scheduled open
        // 10:00 Riyadh (1h 4m)" wrapped inside the header's narrow column on iPhone, turning
        // two clocks into four ragged lines and shoving the header taller than the content
        // it labels. Shrink-to-fit rather than truncate: a clipped countdown is useless.
        .lineLimit(1)
        .minimumScaleFactor(0.75)
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
