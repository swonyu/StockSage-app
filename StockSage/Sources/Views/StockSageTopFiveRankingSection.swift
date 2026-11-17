import SwiftUI

/// Renders `StockSageTopFiveRanking.Result`: always five ranked rows (or fewer only when the
/// eligible pool itself is smaller), each with its rank, real action, qualification status,
/// every named score component, and — for a fallback (not-qualified) row — the exact failed
/// gates from the receipt. This never fabricates a Buy/Strong Buy and never hides an insider
/// signal. Self-contained so it can be dropped into any completed-run surface with one call site.
struct StockSageTopFiveRankingSection: View {
    let result: StockSageTopFiveRanking.Result
    var openDetails: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func priceLabel(_ value: Double) -> String {
        // Zero contrary checks can produce IEEE negative zero; preserve every nonzero score.
        (value == 0 ? 0 : value).formatted(.number.precision(.fractionLength(1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Top 5").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("research.topfive.section")
    }

    @ViewBuilder private func row(for row: StockSageTopFiveRanking.Ranked) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let opinion = Text("Model opinion: \(row.action)").font(.callout).foregroundStyle(.secondary)
            let status = Text(row.status == .qualified ? "Qualified" : "Not qualified")
                .font(.caption.weight(.semibold))
                .foregroundStyle(row.status == .qualified ? DS.Palette.successSoft : DS.Palette.warningSoft)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((row.status == .qualified ? DS.Palette.successSoft : DS.Palette.warningSoft).opacity(0.10), in: Capsule())
            let score = Text("Score \(priceLabel(row.components.total))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            let header = VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text("#\(row.rank)").font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(DS.Palette.accentText)
                        .padding(8)
                        .background(DS.Palette.accent.opacity(0.12), in: .rect(cornerRadius: DS.Radius.small))
                    Text(row.symbol).font(.title3.weight(.semibold))
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
            let components = [("Horizon fit", row.components.horizonFit), ("Technical", row.components.technicalConfluence),
                ("Catalyst", row.components.catalystQuality), ("Liquidity", row.components.liquidity),
                ("Freshness", row.components.evidenceFreshness), ("Insider", row.components.insiderRelevance),
                ("Counterevidence", row.components.counterevidence)]
            LazyVGrid(columns: [dynamicTypeSize.isAccessibilitySize ? GridItem(.flexible(), alignment: .leading)
                : GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(components, id: \.0) { title, value in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                        Text(priceLabel(value)).font(.callout.weight(.medium)).monospacedDigit()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 6)
            if !row.hardPenaltyReasons.isEmpty {
                ForEach(Array(row.hardPenaltyReasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(DS.Palette.warningSoft)
                }
            }
            if !row.insiderSignals.isEmpty {
                DisclosureGroup("Insider evidence · \(row.insiderSignals.count)") {
                    ForEach(Array(row.insiderSignals.enumerated()), id: \.offset) { _, signal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(signal.direction == .purchase ? "Purchase" : "Sale") · \(signal.ownerName)")
                                .foregroundStyle(signal.direction == .purchase ? DS.Palette.successSoft : DS.Palette.accentText)
                            Text("\(Int(signal.ageDays))d old when scored · contribution \(priceLabel(signal.contribution))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
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
        .padding(DS.Space.lg)
        .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Bezel.coreInnerHighlight, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("research.topfive.row.\(row.symbol)")
    }
}
