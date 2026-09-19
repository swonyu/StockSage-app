import SwiftUI

/// Renders `StockSageTopFiveRanking.Result`: always five ranked rows (or fewer only when the
/// eligible pool itself is smaller), each with its rank, real action, qualification status,
/// every named score component, and — for a fallback (not-qualified) row — the exact failed
/// gates from the receipt. This never fabricates a Buy/Strong Buy and never hides an insider
/// signal. Self-contained so it can be dropped into any completed-run surface with one call site.
struct StockSageTopFiveRankingSection: View {
    let result: StockSageTopFiveRanking.Result
    var openDetails: ((String) -> Void)? = nil

    private func priceLabel(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Top 5 · deterministic ranking").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(result.ranked.count) ranked").font(.caption).foregroundStyle(.secondary)
            }
            Text("A fixed, explainable score, not a probability. Model opinions are shown unchanged. Ranked rows can fail the strict screen; only rows marked Qualified passed every required gate. Open a stock to review its captured evidence.")
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
            let opinion = Text("Model opinion: \(row.action)").font(.callout).foregroundStyle(.secondary)
            let status = Text(row.status == .qualified ? "Qualified" : "Not qualified")
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.status == .qualified ? DS.Palette.successSoft : DS.Palette.accentText)
            let score = Text("Score \(priceLabel(row.components.total))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            let header = VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("#\(row.rank)").font(.title3.weight(.semibold)).monospacedDigit()
                    Text(row.symbol).font(.headline)
                    Spacer()
                    if openDetails != nil {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        opinion.fixedSize(); Spacer(minLength: DS.Space.sm)
                        status.fixedSize(); score.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) { opinion; status; score }
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            if let openDetails {
                Button { openDetails(row.symbol) } label: { header }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rank \(row.rank), \(row.symbol), Model opinion: \(row.action), \(row.status == .qualified ? "Qualified" : "Not qualified"), score \(priceLabel(row.components.total))")
                    .accessibilityHint("Open captured research, evidence and failed gates")
                    .accessibilityIdentifier("research.topfive.open.\(row.symbol)")
            } else {
                header
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
