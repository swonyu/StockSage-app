import SwiftUI

// MARK: - Execution quality — "your measured fills vs the assumptions"
//
// The journal already captures planned/fill prices per leg (StockSageJournal.measuredSlippage).
// This surfaces it: the ONE number no dataset can hand the owner — their own real execution
// cost, vs. the flat bps assumption the engine's cost table uses for that same symbol. Display
// only; feeds nothing (see the fence comment above `measuredSlippage` itself). Below the 5-leg
// floor the panel shows ONLY the honest empty state (gated on `meetsFloor`, not nil-ness —
// measuredSlippage returns nil solely for ZERO legs; review fix 2026-07-16: the old nil-only
// check headlined a median off as little as one fill while claiming a 5-leg floor).

/// Worst (most cost-positive) single leg among the owner's measured slippage — pure aggregation
/// beyond what `measuredSlippage` itself returns, so it gets its own hand-derived test.
enum ExecutionQualityMath {
    /// Scans CLOSED trades' entry/exit legs and returns the single worst (highest, i.e. most
    /// costly) signed slippage bps, if any leg is measured. Mirrors `measuredSlippage`'s own
    /// leg-collection exactly (same two optionals, same trades filter) so the "worst" reported
    /// here is always a leg counted in the same `legs` total shown alongside it.
    static func worstLegBps(_ trades: [TradeRecord]) -> Double? {
        var worst: Double?
        for t in trades where !t.isOpen {
            if let s = t.entrySlippageBps { worst = max(worst ?? s, s) }
            if let s = t.exitSlippageBps { worst = max(worst ?? s, s) }
        }
        return worst
    }
}

struct ExecutionQualityPanel: View {
    let trades: [TradeRecord]

    private var measured: MeasuredSlippage? { StockSageJournal.measuredSlippage(trades) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "target").font(.system(size: 16)).foregroundStyle(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution quality").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("Your measured fills vs. the assumptions the engine costs your trades at.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if let m = measured, m.meetsFloor {
                let worst = ExecutionQualityMath.worstLegBps(trades)
                HStack(spacing: DS.Space.sm) {
                    statCell(title: "Median slippage", value: String(format: "%+.1f bps", m.medianBps),
                             tint: m.medianBps <= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                        .help("Median signed slippage per leg. Positive = you paid WORSE than planned (a buy filled higher, or a sell filled lower); negative = price improvement.")
                    statCell(title: "Assumed (this book)", value: String(format: "%+.1f bps", m.assumedMedianBpsPerLeg),
                             tint: .secondary)
                        .help("The engine's flat per-leg cost assumption for the SAME legs (half the symbol's round-trip table) — apples-to-apples with the median at left.")
                    statCell(title: "Legs measured", value: "\(m.legs)", tint: .white)
                        .help("Entry + exit legs across closed trades with both a planned price and a fill logged. Floor: \(m.minLegs) legs before this panel trusts the median.")
                    if let worst {
                        statCell(title: "Worst leg", value: String(format: "%+.1f bps", worst),
                                 tint: worst <= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                            .help("The single costliest measured leg — one bad fill, not your typical execution.")
                    }
                    // Cost in R (2026-07-17, owner "improve"): bps is abstract; R is the unit the rest
                    // of the journal reasons in, so "execution shaved 0.15R off your average trade" is
                    // the actionable discipline number. Reuses each leg's own price + risk-per-share.
                    statCell(title: "Cost / trade", value: String(format: "%+.2fR", m.perTradeR),
                             tint: m.perTradeR <= 0 ? DS.Palette.successSoft : DS.Palette.danger)
                        .help(String(format: "Execution cost per trade in R (%.2fR total across %d legs) — subtract it from your expectancy to see the fills' real drag. Positive = cost. Same slippage as the bps at left, expressed in the journal's own R unit.", m.totalR, m.legs))
                    Spacer(minLength: 0)
                }
                Text("Broker-choice execution dispersion is real and measured: 0.07%–0.46% round-trip across brokers for the identical order (Schwarz, Barber, Huang, Jorion & Odean, \u{201C}Retail Broker Execution Quality,\u{201D} Journal of Finance, 2025). Your number above is YOUR own fills — a record, not a forecast of future fills.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let n = StockSageJournal.measuredSlippage(trades, minLegs: 1)?.legs ?? 0
                Text("Fewer than 5 measured legs (\(n) so far) — log planned + fill prices when you enter and exit a trade to measure YOUR real execution cost. This is the one number no dataset can give you.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private func statCell(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}
