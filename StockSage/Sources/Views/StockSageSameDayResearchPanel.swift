import SwiftUI

struct StockSageSameDayResearchPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research = StockSageSameDayResearch.shared
    @ObservedObject var horizons = StockSageHorizonResearch.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Same-day · one pick").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("A fresh, manual check during the regular US session. One app-ranked, Gemma-qualified candidate when its evidence and observed scenario pass.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Run same-day research", systemImage: "play.fill") { research.start(store: store) }
                        .buttonStyle(.borderedProminent)
                        .disabled(research.isRunning || horizons.running != nil)
                        .accessibilityIdentifier("research.sameDay.run")
                    if research.isRunning {
                        Button("Stop", systemImage: "stop.fill") { research.stop() }
                            .accessibilityIdentifier("research.sameDay.stop")
                    }
                }
                if horizons.running != nil { Text("Finish or stop the current Top 5 run before starting same-day research.").font(.caption) }
                Text(research.status).font(.callout).textSelection(.enabled)
                if let receipt = research.receipt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.selection)
                        Text("Requested \(receipt.startedAt.formatted(date: .abbreviated, time: .standard))")
                    }.font(.caption).foregroundStyle(.secondary)
                    if let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }), let plan = check.scenario {
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.symbol).font(.title2.bold())
                                    if check.name != check.symbol { Text(check.name).font(.callout).foregroundStyle(.secondary) }
                                }
                                Text(!research.isRunning && !research.restored && StockSageSameDayResearch.current(receipt, at: tick.date)
                                    ? "Passed at the recorded quote time · research only"
                                    : "Dated research · current entry is not verified. Run again for a fresh check.")
                                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 8) {
                                    level("Buy entry (ceiling)", plan.entry)
                                    level("Stop-loss reference", plan.stop)
                                    level("Target reference", plan.target)
                                }
                                .accessibilityIdentifier("research.sameDay.levels")
                                .padding(.vertical, 4)
                                Divider()
                                Text("Frozen \(plan.at.formatted(date: .abbreviated, time: .standard)) · completed minutes through \(plan.barsAsOf.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                if let quote = check.verifiedQuote {
                                    Text("Final bid/ask check \(quote.at.formatted(date: .abbreviated, time: .standard)); quote freshness ends \(quote.at.addingTimeInterval(5).formatted(date: .omitted, time: .standard)).")
                                        .font(.caption)
                                }
                                if let expiry = check.expiresAt {
                                    Text("Evidence expires by \(expiry.formatted(date: .omitted, time: .standard)). New entries stop five minutes before the scheduled regular close; no automatic exit.")
                                        .font(.caption)
                                }
                                Text(check.reason ?? "").font(.body)
                                Text("Invalidation / risk: " + (check.risk ?? "Unrecorded")).foregroundStyle(.secondary)
                                Text("Observed reference levels, not guaranteed execution or future prices. No order is created.").font(.caption)
                            }
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if let blocker = receipt.blocker { Label(blocker, systemImage: "info.circle").foregroundStyle(.secondary) }
                    evidence(receipt)
                }
                let history = research.savedReceipts.filter { $0.id != research.receipt?.id }
                if !history.isEmpty {
                    DisclosureGroup("Earlier saved research · \(history.count) runs") {
                        ForEach(history, id: \.id) { saved in
                            DisclosureGroup("\(saved.startedAt.formatted(date: .abbreviated, time: .standard)) · \(saved.selectedSymbol ?? "No pick")") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Historical research only; this is not the current Run result.").font(.callout.weight(.semibold))
                                    Text(saved.selection).font(.caption)
                                    if let check = saved.checks.first(where: { $0.symbol == saved.selectedSymbol }), let plan = check.scenario {
                                        level("Buy entry (ceiling)", plan.entry)
                                        level("Stop-loss reference", plan.stop)
                                        level("Target reference", plan.target)
                                        Text("Frozen \(plan.at.formatted(date: .abbreviated, time: .standard))").font(.caption)
                                        if let expiry = check.expiresAt {
                                            Text("Original evidence expiry: \(expiry.formatted(date: .abbreviated, time: .standard))").font(.caption)
                                        }
                                    }
                                    if let blocker = saved.blocker { Text(blocker).foregroundStyle(.secondary) }
                                    evidence(saved)
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                    .accessibilityIdentifier("research.sameDay.history")
                }
                Text(StockSageSameDayResearch.policy).font(.caption).foregroundStyle(.secondary)
            }
            .padding(20).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func level(_ label: String, _ value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: 440, alignment: .leading)
        .accessibilityElement(children: .combine)
        .textSelection(.enabled)
    }

    private func evidence(_ receipt: StockSageSameDayResearch.Receipt) -> some View {
        DisclosureGroup("All \(receipt.checks.count) checks and captured evidence") {
            ForEach(receipt.checks, id: \.symbol) { check in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(check.symbol) · \(check.action ?? "No opinion")").font(.headline)
                    Text(check.note).font(.callout)
                    if let reason = check.reason { Text("Case: " + reason) }
                    if let risk = check.risk { Text("Risk: " + risk) }
                    if let packet = check.packet {
                        ForEach(Array(packet.facts.enumerated()), id: \.offset) { index, fact in
                            Text("F\(index + 1)\(check.evidence.contains("F\(index + 1)") ? " · cited" : ""): \(fact.text)")
                                .font(.caption).textSelection(.enabled)
                        }
                        if packet.prePromptOmittedRecordCount > 0 {
                            Text("\(packet.prePromptOmittedRecordCount) source or optional prompt records omitted by bounded collection/fitting.").font(.caption)
                        }
                    }
                }.padding(.vertical, 8)
            }
        }
    }
}
