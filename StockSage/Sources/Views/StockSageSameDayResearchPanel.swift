import SwiftUI

struct StockSageSameDayResearchPanel: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var research = StockSageSameDayResearch.shared
    @ObservedObject var horizons = StockSageHorizonResearch.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var identifier: String { research.isAstra ? "research." + research.mode.rawValue : "research.sameDay" }

    init(store: StockSageStore, research: StockSageSameDayResearch = .shared) {
        self.store = store
        self.research = research
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(research.isAstra ? "\(research.title) · same-day setups" : "Same-day · one pick", systemImage: research.isAstra ? "waveform.path" : "scope")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(research.isAstra ? "Track market and \(research.title.lowercased()) momentum Monday–Friday, 11 AM–11 PM Riyadh. Fresh regular-session setups go to Astra through your Codex subscription; a qualified pick can reach your phone." : "A fresh, manual check during the regular US session. One app-ranked, Gemma-qualified candidate when its evidence and observed scenario pass.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                let actions = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                actions {
                    Button(research.isAstra ? "Run one \(research.title) check" : "Run same-day research", systemImage: "play.fill") { research.start(store: store) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(research.isRunning || horizons.running != nil)
                        .accessibilityIdentifier(identifier + ".run")
                    if research.isRunning {
                        Button("Stop", systemImage: "stop.fill") {
                            if research.mode == .microcap { StockSageMicrocapMonitor.shared.stop() }
                            if research.mode == .largecap { StockSageMicrocapMonitor.largecap.stop() }
                            research.stop()
                        }
                            .accessibilityIdentifier(identifier + ".stop")
                    }
                }
                if horizons.running != nil { Text("Finish or stop the current Top 5 run before starting same-day research.").font(.caption) }
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    VStack(alignment: .leading, spacing: 8) {
                        if let receipt = research.receipt, receipt.selectedSymbol != nil, !research.isRunning,
                           research.restored || !StockSageSameDayResearch.current(receipt, at: tick.date) {
                            Label("Dated pick · Run again before considering a new entry", systemImage: "clock.badge.exclamationmark")
                                .font(.headline).foregroundStyle(DS.Palette.warningSoft)
                                .accessibilityIdentifier(identifier + ".dated")
                        }
                        Text(research.status).font(.callout).textSelection(.enabled)
                            .accessibilityIdentifier(identifier + ".status")
                        if let blocker = research.receipt?.blocker {
                            Label("Displayed run: \(blocker)", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(DS.Palette.warningSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
                }
                #if os(macOS)
                if research.isAstra { StockSageMicrocapActivityView(store: store, research: research) }
                #endif
                if let receipt = research.receipt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.selection)
                        Text("Requested \(receipt.startedAt.formatted(date: .abbreviated, time: .standard))")
                    }.font(.caption).foregroundStyle(.secondary)
                    if let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }), let plan = check.scenario {
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.symbol).font(.system(.largeTitle, design: .rounded, weight: .bold))
                                    if check.name != check.symbol { Text(check.name).font(.callout).foregroundStyle(.secondary) }
                                }
                                Text(!research.isRunning && !research.restored && StockSageSameDayResearch.current(receipt, at: tick.date)
                                    ? "Passed at the recorded quote time · research only"
                                    : "Dated research · current entry is not verified. Run again for a fresh check.")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(!research.restored && StockSageSameDayResearch.current(receipt, at: tick.date)
                                        ? DS.Palette.textSecondary : DS.Palette.warningSoft)
                                LazyVGrid(columns: [dynamicTypeSize.isAccessibilitySize
                                    ? GridItem(.flexible()) : GridItem(.adaptive(minimum: 220))], spacing: DS.Space.sm) {
                                    level("Buy entry (ceiling)", plan.entry, tint: DS.Palette.accentText)
                                    level("Stop-loss reference", plan.stop, tint: DS.Palette.dangerSoft)
                                    level("Target reference", plan.target, tint: DS.Palette.successSoft)
                                }
                                .accessibilityIdentifier(identifier + ".levels")
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
                                if research.isAstra, let fundamentals = check.fundamentals {
                                    StockSageFundamentalsView(snapshot: fundamentals)
                                }
                                Text("Observed reference levels, not guaranteed execution or future prices. No order is created.").font(.caption)
                            }
                            .padding(DS.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.card))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                                .stroke(DS.Bezel.coreInnerHighlight, lineWidth: 1))
                        }
                    }
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
                    .accessibilityIdentifier(identifier + ".history")
                }
                #if os(macOS)
                DisclosureGroup("Research method and limits") {
                    Text(StockSageSameDayResearch.policy).font(.callout)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, DS.Space.sm)
                }.font(.callout)
                #else
                Text(StockSageSameDayResearch.policy).font(.caption).foregroundStyle(.secondary)
                #endif
            }
            #if os(macOS)
            .padding(24)
            .frame(maxWidth: 1200, alignment: .leading)
            #else
            .padding(16)
            .frame(maxWidth: 1000, alignment: .leading)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func level(_ label: String, _ value: Double, tint: Color = DS.Palette.textPrimary) -> some View {
        let title = Text(label).font(.subheadline).foregroundStyle(.secondary)
        let price = Text(value.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
            .font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
            .foregroundStyle(tint)
        return VStack(alignment: .leading, spacing: 8) {
            title
            price
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.md)
        .background(tint.opacity(0.06), in: .rect(cornerRadius: DS.Radius.small))
        .accessibilityElement(children: .combine)
        .textSelection(.enabled)
    }

    private func evidence(_ receipt: StockSageSameDayResearch.Receipt) -> some View {
        DisclosureGroup("All \(receipt.checks.count) checks and captured evidence") {
            #if os(macOS)
            if let market = receipt.marketMomentum { StockSageMomentumView(market: market) }
            #endif
            ForEach(receipt.checks, id: \.symbol) { check in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(check.symbol) · \(check.action ?? "No opinion")").font(.headline)
                    if check.momentumTrigger != nil {
                        Label("Momentum review · not a qualified trade", systemImage: "waveform.path.ecg")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(check.note).font(.callout)
                    if let audit = check.codexAudit {
                        Text("Codex · \(audit.requestedModel) · \(audit.requestedEffort) · \(audit.terminalStatus)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let raw = check.rawModelOutput {
                        DisclosureGroup("Original Astra response") { Text(raw).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    if let reason = check.reason { Text("Case: " + reason) }
                    if let risk = check.risk { Text("Risk: " + risk) }
                    if receipt.mode?.isAstra == true, let fundamentals = check.fundamentals {
                        StockSageFundamentalsView(snapshot: fundamentals)
                    }
                    #if os(macOS)
                    if let momentum = check.momentum { StockSageMomentumView(stock: momentum) }
                    #endif
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

/// The same saved business evidence is visible in screening and historical research.
struct StockSageFundamentalsView: View {
    let snapshot: StockSageFundamentals.Snapshot
    @State private var expanded: Bool

    init(snapshot: StockSageFundamentals.Snapshot, initiallyExpanded: Bool = false) {
        self.snapshot = snapshot
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("Collected \(snapshot.retrievedAt.formatted(date: .abbreviated, time: .standard)). Each metric retains its own financial period; these figures do not establish a same-day entry.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(snapshot.metrics, id: \.key) { metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metric.label).font(.subheadline.weight(.semibold))
                            Text(metric.displayValue).font(.title3.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(metric.value == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                            Text(metric.period).font(.caption).foregroundStyle(.secondary)
                            if !metric.note.isEmpty { Text(metric.note).font(.caption) }
                            DisclosureGroup("Formula and sources") {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(metric.origin).font(.caption.weight(.semibold))
                                    Text(metric.formula).font(.caption)
                                    if let url = publicURL(metric.sourceURL) { Link("Source", destination: url).font(.caption) }
                                    ForEach(Array(metric.inputs.enumerated()), id: \.offset) { _, input in
                                        Text("\(input.name): \(input.value.formatted()) \(input.unit) · \(input.period)")
                                            .font(.caption).textSelection(.enabled)
                                    }
                                }.padding(.top, 4)
                            }.font(.caption)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.md)
                        .background(DS.Bezel.cardFill, in: .rect(cornerRadius: DS.Radius.small))
                        .accessibilityElement(children: .contain)
                    }
                }
                ForEach(Array((snapshot.flags + snapshot.notes).enumerated()), id: \.offset) { _, note in
                    Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Collection coverage and statement inputs") {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(Array(snapshot.sources.enumerated()), id: \.offset) { _, source in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(source.name) · \(source.status) · \(source.recordCount) records").font(.caption.weight(.semibold))
                                if !source.note.isEmpty { Text(source.note).font(.caption) }
                                if let url = publicURL(source.url) { Link("Provider source", destination: url).font(.caption) }
                            }
                        }
                        ForEach(Array(snapshot.statements.enumerated()), id: \.offset) { _, statement in
                            DisclosureGroup("\(statement.kind) · \(statement.timeframe) · \(statement.periodEnd)") {
                                Text("Filed \(statement.filingDate). Units: \(statement.unit).").font(.caption)
                                ForEach(statement.amounts.keys.sorted(), id: \.self) { key in
                                    Text("\(key): \(statement.amounts[key]!.formatted())").font(.caption).textSelection(.enabled)
                                }
                            }.font(.caption)
                        }
                    }.padding(.top, DS.Space.sm)
                }.font(.caption)
            }.padding(.top, DS.Space.sm)
        } label: {
            Label("Company quality · \(snapshot.symbol)", systemImage: "building.2.crop.circle")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("research.companyQuality")
    }

    private func publicURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              ["massive.com", "www.massive.com", "api.massive.com", "www.sec.gov", "data.sec.gov"].contains(url.host?.lowercased() ?? ""),
              !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name.lowercased() == "apikey" } ?? false) else { return nil }
        return url
    }
}
