import SwiftUI

/// Renders `StockSageTopFiveRanking.Result`: always five ranked rows (or fewer only when the
/// eligible pool itself is smaller), each with its rank, real action, qualification status,
/// every named score component, and — for a fallback (not-qualified) row — the exact failed
/// gates from the receipt. This never fabricates a Buy/Strong Buy and never hides an insider
/// signal. Self-contained so it can be dropped into any completed-run surface with one call site.
struct StockSageTopFiveRankingSection: View {
    let result: StockSageTopFiveRanking.Result

    private func priceLabel(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Top 5 · deterministic ranking").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(result.ranked.count) ranked").font(.caption).foregroundStyle(.secondary)
            }
            Text("A fixed, explainable score — never a model call, never a probability. A row that failed the strict screen shows its real action and exact failed gates; it is never shown as Buy or Strong Buy.")
                .font(.caption).foregroundStyle(.secondary)
            if result.concentrationGuardApplied {
                Text("Sector/catalyst concentration guard applied: no more than \(StockSageTopFiveRanking.maximumPerConcentrationKey) of these five share one concentration key without a material score advantage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.ranked, id: \.symbol) { entry in
                row(for: entry)
            }
        }
        .accessibilityIdentifier("research.topfive.section")
    }

    @ViewBuilder private func row(for row: StockSageTopFiveRanking.Ranked) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text("#\(row.rank)").font(.title3.weight(.semibold)).monospacedDigit()
                Text(row.symbol).font(.headline)
                Text(row.action).font(.callout).foregroundStyle(row.status == .qualified ? DS.Palette.successSoft : .secondary)
                Spacer()
                Text(row.status == .qualified ? "Qualified" : "Not qualified")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.status == .qualified ? DS.Palette.successSoft : DS.Palette.accentText)
                Text(priceLabel(row.components.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            // Every named component, always visible — this is the "explainable" part.
            Text("Horizon fit \(priceLabel(row.components.horizonFit)) · Technical \(priceLabel(row.components.technicalConfluence)) · Catalyst \(priceLabel(row.components.catalystQuality)) · Liquidity \(priceLabel(row.components.liquidity)) · Freshness \(priceLabel(row.components.evidenceFreshness)) · Insider \(priceLabel(row.components.insiderRelevance)) · Counterevidence \(priceLabel(row.components.counterevidence))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !row.hardPenaltyReasons.isEmpty {
                ForEach(Array(row.hardPenaltyReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            if !row.insiderSignals.isEmpty {
                DisclosureGroup("Insider evidence · \(row.insiderSignals.count)") {
                    ForEach(Array(row.insiderSignals.enumerated()), id: \.offset) { _, signal in
                        HStack {
                            Text(signal.direction == .purchase ? "Purchase" : "Sale")
                                .foregroundStyle(signal.direction == .purchase ? DS.Palette.successSoft : DS.Palette.accentText)
                            Text(signal.ownerName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(signal.ageDays))d ago").font(.caption).foregroundStyle(.secondary)
                            Text(priceLabel(signal.contribution)).font(.caption).monospacedDigit()
                        }.font(.callout)
                    }
                }.font(.callout)
            }
            if row.status == .notQualified, !row.failedGates.isEmpty {
                DisclosureGroup("Failed gates · \(row.failedGates.count)") {
                    ForEach(Array(row.failedGates.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }.font(.callout)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityIdentifier("research.topfive.row.\(row.symbol)")
        Divider()
    }
}
