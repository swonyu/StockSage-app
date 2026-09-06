import SwiftUI

// MARK: - CatalystsSection
//
// Owner request (2026-09-06): "a new tab that shows, for the same ideas as the Ideas tab, the
// key catalyst to watch and explains why" — build step C3-view. This file adds ZERO new
// catalyst logic: it is pure display over the pure brief engine (StockSageCatalystWatch,
// build step C1) plus the optional on-device narrator (StockSageCatalystNarrator, build step
// C2). `ideas` is the SAME projected, ordered list the Ideas tab renders — this view never
// re-ranks it, it only asks "what could move each one next, and why".
//
// STANDALONE BY DESIGN: the orchestrator wires `MarketSection.catalysts` and constructs this
// view from MarketsView.swift in a later step — this file must compile (and does) with no
// change to that file.
struct CatalystsSection: View {
    let ideas: [StockSageIdea]
    @ObservedObject var store: StockSageStore
    let onSelect: (StockSageIdea) -> Void

    enum Mode: String, CaseIterable {
        case cards, calendar
        var title: String {
            switch self {
            case .cards:    return "Cards"
            case .calendar: return "Calendar"
            }
        }
    }

    @AppStorage("marketsCatalystsMode") private var mode: Mode = .cards
    @State private var expanded: Set<String> = []
    @State private var narrations: [String: StockSageCatalystNarrator.Result] = [:]
    @State private var narrating: Set<String> = []
    @State private var filings: [String: [StockSageDisclosureService.Filing]] = [:]
    @State private var filingsLoading: Set<String> = []
    @State private var filingsFetched: Set<String> = []

    @ScaledMetric(relativeTo: .caption2) private var font9: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var font11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var font11_5: CGFloat = 11.5
    @ScaledMetric(relativeTo: .caption2) private var font12: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var font13: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var font15: CGFloat = 15

    /// The first 30 symbols, joined — the `.task(id:)` identity that re-runs the earnings
    /// prefetch only when the visible top-30 actually changes (a re-render with the same top
    /// 30 must not re-fire the fetch).
    private var earningsTaskID: String { ideas.prefix(30).map(\.symbol).joined(separator: ",") }

    var body: some View {
        // `now` and `briefs` computed ONCE per body (SWIFT_PITFALLS #11: no per-row recompute)
        // and the narrator availability read once too — it is a small, but non-zero, system
        // property read and up to ~450 rows must not each pay for it separately.
        let now = Date()
        let briefs = buildBriefs(now: now)
        let availability = StockSageCatalystNarrator.availability
        VStack(alignment: .leading, spacing: DS.Space.md) {
            headerCard(briefs: briefs, availability: availability)
            if !ideas.isEmpty {
                switch mode {
                case .cards:
                    // LazyVStack, not VStack — up to ~450 briefs (see `buildBriefs`), and the
                    // Ideas tab this view mirrors already made this call (SWIFT_PITFALLS #10/#11;
                    // fix pass 2026-09-06). The parent MarketsView scroll container is what makes
                    // the laziness real; this view only needs to not defeat it.
                    LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(briefs) { catalystCard($0, availability: availability) }
                    }
                case .calendar:
                    calendarBody(briefs: briefs, now: now)
                }
            }
        }
        .task(id: earningsTaskID) { await fetchEarningsForTopIdeas() }
    }

    // MARK: - Data

    private func buildBriefs(now: Date) -> [StockSageCatalystWatch.Brief] {
        ideas.map { idea in
            let sym = idea.symbol.uppercased()
            let volumeMove = store.catalysts.first { $0.symbol.caseInsensitiveCompare(idea.symbol) == .orderedSame }
            return StockSageCatalystWatch.brief(for: idea, inputs: .init(
                earnings: store.earnings[sym], earningsDate: store.earningsDates[sym],
                volumeMove: volumeMove, regime: store.regime, regimeGaugedAt: store.regimeGaugedAt,
                seasonality: store.seasonality[sym], now: now))
        }
    }

    /// Mirrors `StockSageStore.refreshEarningsForTopIdeas`: 4-parallel chunks, cached-once per
    /// symbol inside the store (`refreshEarnings` no-ops when a date is already known), so
    /// re-entry on every body rebuild is cheap. Checked for cancellation between chunks — a
    /// mode switch or the top-30 changing cancels the previous `.task` before this returns.
    private func fetchEarningsForTopIdeas() async {
        let top = Array(ideas.prefix(30))
        let chunks = stride(from: 0, to: top.count, by: 4).map { Array(top[$0 ..< min($0 + 4, top.count)]) }
        for chunk in chunks {
            if Task.isCancelled { return }
            await withTaskGroup(of: Void.self) { group in
                for idea in chunk { group.addTask { await store.refreshEarnings(symbol: idea.symbol) } }
                for await _ in group { }
            }
        }
    }

    // MARK: - Header card

    @ViewBuilder
    private func headerCard(briefs: [StockSageCatalystWatch.Brief],
                            availability: StockSageCatalystNarrator.Availability) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Catalysts to watch")
                .font(.system(size: font15, weight: .semibold)).foregroundStyle(.white)
            Text("The same ranked ideas as the Ideas tab, in the same order — viewed by what could move each one next.")
                .font(.system(size: font11_5)).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DSSegmentPicker(cases: Mode.allCases, selection: $mode) { $0.title }
                .frame(maxWidth: 260)
            if let regime = store.regime {
                let gaugedStr = store.regimeGaugedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "not yet"
                Text("Regime: \(regime.state.rawValue) · sizing bias ×\(String(format: "%.2f", regime.sizingBias)) · gauged \(gaugedStr)")
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(regime.caveat)
            }
            // Honesty-floor label — always visible, never collapsible.
            Text(StockSageCatalystWatch.caveat)
                .font(.system(size: font11_5)).foregroundStyle(DS.Palette.warningSoft)
                .fixedSize(horizontal: false, vertical: true)
            if store.isSampleData {
                Text("Sample data — nothing here is a real catalyst.")
                    .font(.system(size: font11_5)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .unavailable(let reason) = availability {
                Text(reason).font(.system(size: font9)).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ideas.isEmpty {
                Text("No ideas yet — run a scan on the Ideas tab.")
                    .font(.system(size: font11_5)).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    // MARK: - Cards mode

    @ViewBuilder
    private func catalystCard(_ brief: StockSageCatalystWatch.Brief,
                              availability: StockSageCatalystNarrator.Availability) -> some View {
        let idea = brief.idea
        let primary = brief.primary
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            cardHeader(brief)
            whyBullets(primary.why)
            Text("Watch: \(primary.watch)")
                .font(.system(size: font11)).foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !brief.secondary.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(brief.secondary) { secondaryChip($0) }
                    }
                }
            }
            if let caveat = primary.caveat {
                Text(caveat).font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Source: \(primary.source)")
                .font(.system(size: font9)).foregroundStyle(DS.Palette.textSecondary)
            cardButtons(brief, availability: availability)
            if expanded.contains(idea.symbol) { filingsPanel(idea.symbol) }
            narrationPanel(idea.symbol)
        }
        .padding(DS.Space.lg)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    /// Row 1 (symbol/action/price/weight) + row 2 (kind icon/headline/date) — one tappable
    /// header that also opens the detail sheet, grouped as one accessibility container.
    @ViewBuilder
    private func cardHeader(_ brief: StockSageCatalystWatch.Brief) -> some View {
        let idea = brief.idea
        let primary = brief.primary
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Text(idea.symbol).font(.system(size: font13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                actionCapsule(idea)
                Text(StockSageCurrency.adaptivePrice(idea.price))
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                weightDot(primary.weight)
            }
            HStack(alignment: .top, spacing: DS.Space.xs) {
                Image(systemName: rowIconName(for: brief)).font(.system(size: font11)).foregroundStyle(DS.Palette.accent)
                Text(primary.headline).font(.system(size: font12, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = primary.date {
                    Text(StockSageCatalystWatch.dateStr(date))
                        .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(idea) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(idea.symbol): \(primary.headline)")
    }

    @ViewBuilder
    private func whyBullets(_ why: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(why.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 6) {
                    // Fixed-size decorative bullet (mirrors the idea detail sheet's "Why" list) —
                    // accessibilityHidden since the row-level label below already speaks the text.
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                        .padding(.top, 5).accessibilityHidden(true)
                    Text(bullet).font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Why: \(why.joined(separator: ". "))")
    }

    @ViewBuilder
    private func secondaryChip(_ item: StockSageCatalystWatch.Item) -> some View {
        // `.help` alone is hover-only — invisible on iPhone, where a demoted RVOL move (or
        // regime/seasonality item) would otherwise show its "unvalidated"/caveat text nowhere
        // (fix pass 2026-09-06). The caveat renders below the chip so it's visible on every
        // platform, not only under a mouse cursor.
        VStack(alignment: .leading, spacing: 2) {
            Text(item.headline)
                .font(.system(size: font9)).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(DS.Palette.surfaceStroke, lineWidth: 1))
            if let caveat = item.caveat {
                Text(caveat).font(.system(size: font9)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .help(item.why.joined(separator: " "))
    }

    @ViewBuilder
    private func cardButtons(_ brief: StockSageCatalystWatch.Brief,
                             availability: StockSageCatalystNarrator.Availability) -> some View {
        let idea = brief.idea
        HStack(spacing: DS.Space.md) {
            Button("Details") { onSelect(idea) }
                .buttonStyle(.plain).touchHitArea()
            if StockSageEODHD.covers(idea.symbol) {
                Button(expanded.contains(idea.symbol) ? "Hide filings" : "Filings") { toggleFilings(idea.symbol) }
                    .buttonStyle(.plain).touchHitArea()
            }
            if availability == .available {
                Button("Explain on-device") { explainOnDevice(brief) }
                    .buttonStyle(.plain).touchHitArea()
                    .disabled(narrating.contains(idea.symbol))
            }
        }
        .font(.system(size: font11)).foregroundStyle(DS.Palette.accent)
    }

    @ViewBuilder
    private func filingsPanel(_ symbol: String) -> some View {
        if filingsLoading.contains(symbol) {
            ProgressView().controlSize(.small)
        } else if let items = filings[symbol] {
            if items.isEmpty {
                Text("No 8-K found in the window we looked at — that is not evidence that nothing was filed.")
                    .font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(5)) { filing in
                        let when = StockSageDisclosureService.publicFor(filing)
                            ?? filing.filingDate.formatted(date: .abbreviated, time: .omitted)
                        Text("8-K · \(filing.itemDescriptions.joined(separator: ", ")) · \(when)")
                            .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func narrationPanel(_ symbol: String) -> some View {
        if narrating.contains(symbol) {
            ProgressView().controlSize(.small)
        } else if let result = narrations[symbol] {
            switch result {
            case .text(let text):
                VStack(alignment: .leading, spacing: 3) {
                    Text(text).font(.system(size: font11_5)).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(StockSageCatalystNarrator.label).font(.system(size: font9)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .withheld(let msg), .unavailable(let msg):
                Text(msg).font(.system(size: font11)).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cards mode: row actions

    private func toggleFilings(_ symbol: String) {
        if expanded.contains(symbol) {
            expanded.remove(symbol)
            return
        }
        expanded.insert(symbol)
        guard !filingsFetched.contains(symbol) else { return }
        filingsLoading.insert(symbol)
        Task {
            let found = await StockSageDisclosureService.recentFilings(for: symbol, forms: ["8-K"], limit: 5)
            filings[symbol] = found
            filingsFetched.insert(symbol)
            filingsLoading.remove(symbol)
        }
    }

    private func explainOnDevice(_ brief: StockSageCatalystWatch.Brief) {
        let symbol = brief.idea.symbol
        guard !narrating.contains(symbol) else { return }
        narrating.insert(symbol)
        Task {
            let result = await StockSageCatalystNarrator.explain(brief)
            narrations[symbol] = result
            narrating.remove(symbol)
        }
    }

    /// `.extreme` needs the idea's actual high/low direction, which the pure, testable
    /// `iconName(for:)` (keyed only on `Kind`) can't see — resolved here, in the view, from
    /// `idea.recentExtreme`. Switches rather than `==` (mirrors `StockSageCatalystWatch`'s own
    /// note): `SparkSeries.Extreme`'s synthesized `Equatable` is MainActor-isolated.
    private func rowIconName(for brief: StockSageCatalystWatch.Brief) -> String {
        if brief.primary.kind == .extreme, let extreme = brief.idea.recentExtreme {
            switch extreme {
            case .atLow: return "arrow.down.right.circle"
            default:     return "arrow.up.right.circle"
            }
        }
        return Self.iconName(for: brief.primary.kind)
    }

    // MARK: - Calendar mode

    @ViewBuilder
    private func calendarBody(briefs: [StockSageCatalystWatch.Brief], now: Date) -> some View {
        let entries = StockSageCatalystWatch.calendar(briefs, now: now)
        if !entries.contains(where: { $0.item.date != nil }) {
            Text("No dated catalysts yet — earnings dates load for the top 30 ideas after the first scan.")
                .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(StockSageCatalystWatch.Bucket.allCases, id: \.self) { bucket in
                let rows = entries.filter { $0.bucket == bucket }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(bucket.title).font(.system(size: font12, weight: .semibold)).foregroundStyle(.white)
                        // Same eager-render concern as cards mode (up to ~450 rows combined
                        // across buckets) — LazyVStack here too (fix pass 2026-09-06).
                        LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(rows) { calendarRow($0) }
                        }
                    }
                    .padding(DS.Space.lg)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private func calendarRow(_ entry: StockSageCatalystWatch.CalendarEntry) -> some View {
        HStack(alignment: .top, spacing: DS.Space.xs) {
            Text(entry.item.date.map(StockSageCatalystWatch.dateStr) ?? "—")
                .font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary)
                .frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.xs) {
                    Text(entry.idea.symbol).font(.system(size: font12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(entry.item.headline).font(.system(size: font11)).foregroundStyle(.white)
                }
                if let firstWhy = entry.item.why.first {
                    Text(firstWhy).font(.system(size: font11)).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
                // Honesty floor: the RVOL detector is "unvalidated" and regime/seasonality carry
                // their own caveats — the primary card already shows this (line ~165); the
                // calendar row was the one path that dropped it (fix pass 2026-09-06).
                if let caveat = entry.item.caveat {
                    Text(caveat).font(.system(size: font9)).foregroundStyle(DS.Palette.warningSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            weightDot(entry.item.weight)
        }
        .touchHitArea()
        .contentShape(Rectangle())
        .onTapGesture { onSelect(entry.idea) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.idea.symbol), \(entry.bucket.title), \(entry.item.headline)")
    }

    // MARK: - Shared small pieces

    @ViewBuilder
    private func weightDot(_ weight: StockSageCatalystWatch.Weight) -> some View {
        let pair: (color: Color, label: String) = {
            switch weight {
            case .high:   return (DS.Palette.dangerSoft, "high")
            case .medium: return (DS.Palette.warningSoft, "medium")
            case .low:    return (DS.Palette.textSecondary, "low")
            }
        }()
        Circle().fill(pair.color).frame(width: 7, height: 7)
            .accessibilityLabel("\(pair.label) priority")
    }

    @ViewBuilder
    private func actionCapsule(_ idea: StockSageIdea) -> some View {
        let action = idea.advice.action
        let ink: Color = action == .avoid ? .white : Color(white: 0.06)
        Text(action.rawValue)
            .font(.system(size: font9, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.actionFill(for: action), in: Capsule())
    }

    // MARK: - Pure helpers (nonisolated, unit-tested — CatalystsSectionTests)

    /// One icon per `Kind` (all six cases) — the `.extreme` up/down split needs the idea's own
    /// high/low direction, which lives one level up in `rowIconName(for:)`, so this returns the
    /// "up" glyph as `.extreme`'s single deterministic answer.
    nonisolated static func iconName(for kind: StockSageCatalystWatch.Kind) -> String {
        switch kind {
        case .earnings:    return "calendar.badge.exclamationmark"
        case .volumeMove:  return "bolt.horizontal.circle.fill"
        case .extreme:     return "arrow.up.right.circle"
        case .regime:      return "gauge.with.needle"
        case .seasonality: return "calendar"
        case .none:        return "questionmark.circle"
        }
    }

    /// The action-capsule fill per `TradeAdvice.Action`. Values are `DS.Palette`'s
    /// successSoft/warningSoft/dangerSoft, copied as literals rather than referenced — under
    /// this module's default MainActor isolation `DS.Palette`'s statics are MainActor-isolated,
    /// which a `nonisolated` (unit-testable without a running app, per the build spec) function
    /// cannot read synchronously. Keep byte-identical to `DS.Palette` if that palette ever moves
    /// (`CatalystsSectionTests` pins both sides so a drift fails loudly).
    nonisolated static func actionFill(for action: TradeAdvice.Action) -> Color {
        switch action {
        case .buy, .strongBuy: return Color(red: 0.45, green: 0.85, blue: 0.55)   // DS.Palette.successSoft
        case .hold:             return Color(red: 1.0,  green: 0.72, blue: 0.35) // DS.Palette.warningSoft
        case .avoid:            return Color.white.opacity(0.22)
        case .reduce, .sell:    return Color(red: 1.0,  green: 0.50, blue: 0.50) // DS.Palette.dangerSoft
        }
    }
}
