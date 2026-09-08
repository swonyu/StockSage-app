import SwiftUI

/// Same primary badge on Ideas, Catalysts and detail. Technical action remains explicit.
struct StockSageAIBadge: View {
    let idea: StockSageIdea
    @ObservedObject var store: StockSageStore
    @ObservedObject private var ai = StockSageAIAssessments.shared

    var body: some View {
        let record = ai.record(for: idea, store: store)
        let action = record?.verdict.action ?? .avoid
        VStack(alignment: .leading, spacing: 2) {
            Text(ai.label(for: idea, store: store))
                .font(.caption2.bold())
                .foregroundStyle(MarketsView.actionTextColorForTest(action))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(MarketsView.actionColorForTest(action), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
            Text("Rules: \(idea.advice.action.rawValue)").font(.caption2).foregroundStyle(.secondary)
            if let record {
                Text("Snapshot \(record.timeLabel)").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ai.accessibility(for: idea, store: store))
    }
}

/// Readable audit trail next to the immutable rules-derived plan, with an explicit retry.
struct StockSageAIAssessmentPanel: View {
    let idea: StockSageIdea
    @ObservedObject var store: StockSageStore
    @ObservedObject private var ai = StockSageAIAssessments.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI assessment · next trading week").font(.headline)
                Spacer()
                Button(ai.records[idea.symbol] == nil ? "Assess with Qwen" : "Reassess") {
                    Task { await ai.assess(idea, store: store, force: true) }
                }
                .disabled(ai.activeSymbol != nil || store.isSampleData)
                .touchHitArea()
            }
            Text("Unvalidated AI opinion; can misstate. Not a probability or permission to execute. Levels, sizing, rankings and trade controls below remain Rules-based.")
                .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("Assessing retrieves up to three recent news excerpts via Massive, with EODHD fallback when external access is enabled. Missing coverage stays explicit.")
                .font(.caption).foregroundStyle(.secondary)
            if ai.activeSymbol == idea.symbol {
                ProgressView("Qwen is assessing the dated facts…")
            } else if let error = ai.errors[idea.symbol] {
                Text(error).font(.callout).foregroundStyle(DS.Palette.warningSoft)
            }
            if let draft = ai.drafts[idea.symbol] {
                Text("Unverified Qwen draft — not a validated badge").font(.subheadline.bold())
                    .foregroundStyle(DS.Palette.warningSoft)
                Text(verbatim: draft.displayText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Model: \(draft.config.model) · snapshot \(draft.context.asOf.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Original model response and supplied facts") {
                    Text(verbatim: draft.text).textSelection(.enabled).font(.caption)
                    ForEach(Array(draft.context.facts.enumerated()), id: \.offset) { index, fact in
                        Text(verbatim: "F\(index + 1): \(fact)").font(.caption).textSelection(.enabled)
                    }
                    if let research = draft.context.research, !research.messages.isEmpty {
                        Text(verbatim: research.prompt).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if let record = ai.records[idea.symbol] {
                if ai.record(for: idea, store: store) == nil {
                    Text("Previous assessment — stale or unavailable; not the current badge.")
                        .font(.caption.bold()).foregroundStyle(DS.Palette.warningSoft)
                }
                Text("\(record.verdict.action.rawValue) · snapshot \(record.timeLabel)").font(.subheadline.bold())
                Text(record.verdict.reason).fixedSize(horizontal: false, vertical: true)
                Text("Counter-case: " + record.verdict.risk).fixedSize(horizontal: false, vertical: true)
                Text("Model: " + record.config.model).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Cited facts: " + record.verdict.evidence.joined(separator: ", ")).font(.caption)
                DisclosureGroup("Facts supplied to this assessment") {
                    ForEach(Array(record.context.facts.enumerated()), id: \.offset) { index, fact in
                        Text("F\(index + 1): \(fact)").font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let news = record.context.news, !news.isEmpty {
                    DisclosureGroup("News sources used for this snapshot") {
                        CatalystsSection.sourceList(news.map { .init(news: $0) })
                    }
                }
                if let research = record.context.research {
                    DisclosureGroup("WhatsApp research leads · \(research.messages.count) · unverified export snapshot") {
                        Text("Not live. Reimport newer exports to update the feed. Dates use \(research.timezone).")
                            .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                        ForEach(research.messages, id: \.id) { message in
                            Text(verbatim: "\(message.source) · \(message.date.ISO8601Format())\n\(message.text)")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Text("The quote above is the original snapshot, not a refreshed execution price.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if ai.activeSymbol != idea.symbol {
                Text("No accepted AI assessment yet. The badge will not fall back to a rules verdict.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(DS.Bezel.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}
