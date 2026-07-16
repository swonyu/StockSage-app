import SwiftUI

// MARK: - Browse all markets
//
// The discovery surface over the full `StockSageUniverse.catalog` — this is the SAME set as
// `worldwide`, the analyzed universe (no separate un-scanned long-tail remains). Since the
// 2026-07-16 Tadawul+NASDAQ restriction that set is ~901 names (29 .SR + 872 NASDAQ); the
// displayed count reads `StockSageUniverse.catalog.count` live, so it never goes stale like this
// comment did. Sectioned by market group,
// searchable, asset-class filterable, with one-tap add-to-watchlist (a UI/tracking action
// distinct from the scan itself). The add path lazily fetches a SINGLE quote (store.addSymbol)
// for immediate board display — the bulk history/ideas scan covers the full catalog regardless
// of whether a symbol has been individually added.

struct BrowseMarketsView: View {
    @ObservedObject var store: StockSageStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var asset: AssetFilter = .all
    /// The symbol currently being added (nil when idle). Drives the per-row spinner so
    /// only the tapped row shows a ProgressView, not every untracked row simultaneously.
    @State private var addingSymbol: String? = nil
    /// Local copy of the add-symbol error, seeded only from adds performed in THIS sheet.
    /// Prevents stale errors from the watchlist add box in MarketsView (which shares the
    /// same store.addSymbolError) from appearing on sheet open (and vice versa on dismiss).
    @State private var localAddError: String? = nil

    // Dynamic-Type-aware small fonts: each equals its base size at the default text
    // setting (bmFont13 == 13), so the dense layout is unchanged, but they scale up when
    // the user enlarges system text — fixing the "tiny fixed size" a11y finding.
    // (Matches MarketsView's mvFont7/8/9 / RuneScapeMarketView's rsFont8/9 convention.)
    @ScaledMetric(relativeTo: .caption2) private var bmFont11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var bmFont12: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var bmFont13: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var bmFont14: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var bmFont15: CGFloat = 15

    enum AssetFilter: String, CaseIterable, Identifiable {
        case all = "All", stocks = "Stocks", etf = "ETFs", crypto = "Crypto", fx = "Forex", index = "Indices"
        var id: String { rawValue }
    }

    /// The set the engine validates against in `addSymbol` (StockSageStore.validateNewSymbol):
    /// store.symbols ∪ userSymbols ∪ worldwide. Using the SAME union here prevents showing
    /// a '+' button for any symbol the engine would immediately refuse as "already tracked."
    /// NOTE (2026-07-16): post-promotion `catalog` == `worldwide`, so every browsed row is in this
    /// set ⇒ the '+'/spinner branches in `row(_for:)` are currently unreachable (all rows show the
    /// tracked checkmark). They are kept, not deleted: they self-reactivate the moment `catalog`
    /// re-gains an un-promoted long-tail beyond `worldwide`. The header copy no longer advertises
    /// "+ to track" precisely because it cannot fire today.
    private var tracked: Set<String> {
        Set(store.symbols.map { $0.symbol.uppercased() })
            .union(store.userSymbols.map { $0.uppercased() })
            .union(StockSageUniverse.worldwide.map { $0.symbol.uppercased() })
    }

    /// Pure classifier (static so the data-driven filter list below is testable — the instance
    /// method delegates). One rule per asset class, mirroring StockSageAllocation's suffix rules.
    static func matches(_ s: StockSageSymbol, filter: AssetFilter) -> Bool {
        let sym = s.symbol.uppercased()
        switch filter {
        case .all:    return true
        case .crypto: return sym.hasSuffix("-USD")
        case .fx:     return sym.hasSuffix("=X")
        case .index:  return sym.hasPrefix("^")
        case .etf:    return s.market.localizedCaseInsensitiveContains("ETF")
        case .stocks: return !sym.hasSuffix("-USD") && !sym.hasSuffix("=X") && !sym.hasPrefix("^")
                          && !s.market.localizedCaseInsensitiveContains("ETF")
        }
    }

    private func matches(_ s: StockSageSymbol) -> Bool { Self.matches(s, filter: asset) }

    /// Post-restriction (2026-07-16, "only keep Tadawul and NASDAQ"): offer ONLY the asset-class
    /// filters that match ≥1 catalog name — the Crypto/Forex segments became permanently empty
    /// when those markets left the universe, and a filter that can never match is a stale
    /// affordance. Data-driven (computed once off the static catalog): if the universe changes
    /// again, the filter row follows automatically.
    static let availableFilters: [AssetFilter] = AssetFilter.allCases.filter { f in
        f == .all || StockSageUniverse.catalog.contains { matches($0, filter: f) }
    }

    private var sections: [(market: String, rows: [StockSageSymbol])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? StockSageUniverse.catalog : StockSageUniverse.search(q, limit: 500)
        let filtered = base.filter(matches)
        return Dictionary(grouping: filtered, by: { $0.market })
            .map { (market: $0.key, rows: $0.value.sorted { $0.symbol < $1.symbol }) }
            .sorted { $0.market < $1.market }
    }

    var body: some View {
        VStack(spacing: DS.Space.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Browse markets").font(DS.Typography.titleM).foregroundStyle(.white)
                    Text("\(StockSageUniverse.catalog.count) instruments — the full analyzed universe, all covered by Find ideas. Browse and search here.")
                        .font(.system(size: bmFont12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain).foregroundStyle(DS.Palette.accent)
                    .keyboardShortcut(.cancelAction).help("Close (Esc)")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: bmFont12)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search symbol or market…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: bmFont13))
                    .accessibilityLabel("Search markets")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Asset class").font(.caption2).foregroundStyle(.secondary)
                DSSegmentPicker(cases: Self.availableFilters, selection: $asset) { $0.rawValue }
                    .accessibilityLabel("Asset class")
            }

            if let err = localAddError {
                Text(err).font(.caption2).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.market) { section in
                        Section {
                            ForEach(section.rows) { row(_for: $0) }
                        } header: {
                            Text(section.market).font(.system(size: bmFont11, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3).padding(.horizontal, 4)
                                .background(.ultraThinMaterial)
                        }
                    }
                    if sections.isEmpty {
                        Text("No matches.").font(.caption).foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minWidth: 420, minHeight: 520)
        // System sheet chrome (macOS 27 overhaul): the opaque modalBG panel fought
        // the native sheet material and mismatched OnboardingSheet, which already
        // (correctly) defers to the system background. Dark is guaranteed by the
        // app-level .preferredColorScheme(.dark).
        // localAddError is seeded only by adds performed inside this sheet (see row Task),
        // so it never shows a stale error from the watchlist box in MarketsView.
        // Reset on appear so reopening the sheet starts clean.
        .onAppear { localAddError = nil }
    }

    @ViewBuilder private func row(_for s: StockSageSymbol) -> some View {
        let isTracked = tracked.contains(s.symbol.uppercased())
        let isAdding = addingSymbol == s.symbol
        HStack(spacing: 10) {
            Text(s.symbol).font(.system(size: bmFont13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 96, alignment: .leading).lineLimit(1)
            Text(s.market).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            // Tadawul numeric tickers get their bilingual company name (owner, 2026-07-16).
            if let n = StockSageTadawulNames.displayLine(for: s.symbol) {
                Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isTracked {
                Image(systemName: "checkmark.circle.fill").font(.system(size: bmFont14)).foregroundStyle(DS.Palette.successSoft)
                    .accessibilityLabel("\(s.symbol) already tracked")
            } else if isAdding {
                // Per-row spinner: only the symbol being added shows a ProgressView.
                // Other untracked rows show a disabled '+' while an add is in flight, so
                // tapping '+' on AAPL no longer spins hundreds of unrelated rows.
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Adding \(s.symbol)")
            } else {
                Button {
                    Task {
                        localAddError = nil
                        addingSymbol = s.symbol
                        await store.addSymbol(s.symbol)
                        addingSymbol = nil
                        // Capture the error result locally so it's attributed to this sheet,
                        // not shared with the watchlist add box in MarketsView.
                        localAddError = store.addSymbolError
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: bmFont15)).foregroundStyle(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(store.isAddingSymbol)   // disable other '+' buttons while one add is in flight
                .accessibilityLabel("Add \(s.symbol), \(s.market)")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .background(DS.Palette.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.Radius.small))
    }
}
