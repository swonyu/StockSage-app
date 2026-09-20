import Combine
import Foundation
import SwiftUI

/// Holdings layout, entry interaction and removal confirmation live at this boundary.
/// Market ticks update the marks here; entry edits are observed only by this child.
struct StockSagePortfolioHoldingsView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var portfolio: StockSagePortfolio
    @ObservedObject var draft: EntryDraft

    /// MarketsView retains this reference across workspace changes without observing its
    /// fields. Only this child redraws while typing; an unfinished entry survives navigation.
    @MainActor final class EntryDraft: ObservableObject {
        @Published var symbol = ""
        @Published var shares = ""
        @Published var cost = ""
    }
    @Environment(\.dynamicTypeSize) private var workspaceTypeSize
    @ScaledMetric(relativeTo: .callout) private var mvFont12: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var mvFont14: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var mvFont15: CGFloat = 15
    @ScaledMetric(relativeTo: .title2) private var mvFont22: CGFloat = 22
    @State private var pendingPositionRemoval: PortfolioPosition?
    @State private var hoveredPositionID: UUID?
    private enum AddField: Hashable { case symbol, shares, cost }
    @FocusState private var focusedAddField: AddField?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            portfolioHoldings(asOf: context.date)
        }
    }

    private func currentPrice(_ symbol: String, asOf now: Date) -> Double? {
        store.latestQuote(symbol)?.usableHoldingPrice(isSampleData: store.isSampleData, now: now)
    }

    private func holdingValue(_ symbol: String, perShare: Double, shares: Double) -> Double {
        StockSageCurrency.majorUnitValue(symbol: symbol, rawValue: perShare * shares)
    }

    private func adaptivePrice(_ value: Double) -> String { StockSageCurrency.adaptivePrice(value) }
    private func conversionCurrencyForSymbol(_ symbol: String) -> String {
        StockSageCurrency.conversionCurrencyForSymbol(symbol)
    }

    private func fxRatesToUSD(asOf now: Date) -> [String: Double] {
        var rates: [String: Double] = ["USD": 1]
        for currency in Set(portfolio.positions.map { conversionCurrencyForSymbol($0.symbol) }) where currency != "USD" {
            if let rate = store.fxConversionToUSD(currency, now: now)?.rate { rates[currency] = rate }
        }
        return rates
    }

    /// Portfolio cost & value in USD. Each holding's value AND cost go through holdingValue (so the
    /// .L-pence ÷100 is applied to BOTH — the P&L unit matches) then × its CCY→USD rate, so we never
    /// sum GBP + USD at 1:1. Holdings whose currency has no tracked rate are EXCLUDED (see
    /// untrackedFXCurrencies), not counted at par. (Cost uses the selected FX rate; P&L blends asset + FX.)
    ///
    /// FX-pair positions (…=X): price×shares is already denominated in the pair's QUOTE currency
    /// (e.g. EURUSD=X price is in USD), so we convert by the quote leg, not the exposure leg that
    /// currencyForSymbol returns. Using the exposure leg for …USD=X pairs would multiply an
    /// already-USD amount by the EURUSD rate again → rate², inflating value ~8–27%.
    private func portfolioTotals(asOf now: Date) -> (cost: Double, value: Double) {
        var cost = 0.0, value = 0.0
        let rates = fxRatesToUSD(asOf: now)
        for p in portfolio.positions {
            // Exclude untracked-FX AND unpriced holdings. Crucially, NO `?? costBasis` fallback for
            // value — substituting cost basis would fabricate value == cost ⇒ a fake green $0 P&L.
            // Use the quote-leg currency for =X pairs (already-USD when quote = "USD"),
            // and the exposure-based currencyForSymbol for all other instruments.
            let ccyKey = conversionCurrencyForSymbol(p.symbol)
            guard let rate = rates[ccyKey], let px = currentPrice(p.symbol, asOf: now) else { continue }
            cost += holdingValue(p.symbol, perShare: p.costBasis, shares: p.shares) * rate
            value += holdingValue(p.symbol, perShare: px, shares: p.shares) * rate
        }
        return (cost, value)
    }

    /// Held symbols with NO live price — EXCLUDED from the USD total (never valued at cost basis),
    /// surfaced in the summary so the headline value/P&L is honestly "priced holdings only".
    private func unpricedHoldings(asOf now: Date) -> [String] {
        Array(Set(portfolio.positions.filter { currentPrice($0.symbol, asOf: now) == nil }.map(\.symbol))).sorted()
    }

    private func staleHoldingMarks(asOf now: Date) -> [String] {
        Array(Set(portfolio.positions.compactMap { position in
            guard currentPrice(position.symbol, asOf: now) != nil,
                  StockSageQuoteFreshness.isStale(symbol: position.symbol,
                    marketTime: store.latestQuote(position.symbol)?.marketTime, asOf: now) else { return nil }
            return position.symbol
        })).sorted()
    }

    private func portfolioHoldings(asOf now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let error = portfolio.lastError {
                Text(error).font(.callout).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if portfolio.hasLoadedRecords { portfolioSummary(asOf: now) }
            addPositionForm
            if !portfolio.hasLoadedRecords {
                Text("Holdings and totals unavailable until the saved portfolio can be read. This is not an empty account.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if portfolio.positions.isEmpty {
                Text("No holdings yet — add one above to track value & P&L.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .transition(.opacity)
            } else {
                VStack(spacing: 1) {
                    ForEach(portfolio.positions) {
                        positionRow($0, asOf: now)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(DS.Motion.smooth, value: portfolio.positions.count)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Bezel.cardFill)
                        .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
                )
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
                .transition(.opacity)
            }
        }
    }

    private func portfolioSummary(asOf now: Date) -> some View {
        let t = portfolioTotals(asOf: now)
        let unpricedHoldings = unpricedHoldings(asOf: now)
        let currencies = Set(portfolio.positions.map { conversionCurrencyForSymbol($0.symbol) })
        let rates = fxRatesToUSD(asOf: now)
        let untrackedFXCurrencies = currencies.filter { rates[$0] == nil }.sorted()
        let unverifiedFXCurrencies = currencies.filter {
            $0 != "USD" && store.fxConversionToUSD($0, now: now)?.isFresh == false
        }.sorted()
        let staleHoldingMarks = staleHoldingMarks(asOf: now)
        let pl = t.value - t.cost
        let plPct = t.cost > 0 ? pl / t.cost * 100 : 0
        let up = pl >= 0
        let summaryLayout = workspaceTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 6) {
            summaryLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portfolio value (USD)").font(.caption).foregroundStyle(.secondary)
                    Text(!portfolio.positions.isEmpty && t.value == 0 && t.cost == 0 ? "—" : String(format: "$%.2f", t.value))
                        .font(.system(size: mvFont22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(DS.Motion.smooth, value: t.value)
                }
                if !workspaceTypeSize.isAccessibilitySize { Spacer() }
                VStack(alignment: workspaceTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    Text("Total P&L (USD)").font(.caption).foregroundStyle(.secondary)
                    if portfolio.positions.isEmpty {
                        Text("No holdings yet").font(.callout).foregroundStyle(.secondary)
                    } else if t.value == 0, t.cost == 0 {
                        // Nothing priced/convertible → don't paint a fake green +$0.00 P&L.
                        Text("— no priced holdings").font(.system(size: mvFont15, weight: .semibold)).foregroundStyle(.secondary)
                    } else {
                        // Percent return is undefined when cost basis is 0 (e.g. gifted/0-cost lots) —
                        // show the real dollar P&L but "—%" instead of a fabricated +0.0%.
                        Text((up ? "+" : "") + String(format: "$%.2f", pl)
                             + (t.cost > 0 ? String(format: " (%+.1f%%)", plPct) : " (—%)"))
                            .font(.system(size: mvFont15, weight: .semibold))
                            .foregroundStyle(MarketsView.signedMetricColor(positive: up))
                            .contentTransition(.numericText())
                            .animation(DS.Motion.smooth, value: pl)
                    }
                }
            }
            if !unpricedHoldings.isEmpty {
                Text("\(unpricedHoldings.count) symbol\(unpricedHoldings.count == 1 ? "" : "s") with no usable real quote (\(unpricedHoldings.prefix(3).joined(separator: ", "))) — excluded; value/P&L is priced holdings only.")
                    .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !portfolio.positions.isEmpty {
                Text("Valued at last observed quotes. See each holding’s source and age; this is not a live account balance.")
                    .font(.caption).foregroundStyle(.secondary)
                if !staleHoldingMarks.isEmpty {
                    Text("Old or undated quotes: \(staleHoldingMarks.joined(separator: ", ")). Value and P&L may have changed.")
                        .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                }
            }
            if !untrackedFXCurrencies.isEmpty {
                Text("Excludes \(untrackedFXCurrencies.joined(separator: ", ")) holdings — no usable FX rate to convert to USD. Refresh market data and verify the FX feed. P&L at the selected rate blends asset and currency moves.")
                    .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !unverifiedFXCurrencies.isEmpty {
                Text("FX valuation for \(unverifiedFXCurrencies.joined(separator: ", ")) uses an old or unverified rate (over \(Int(StockSageCurrency.maxSizingFXAge / 3600))h old, or market time/source unknown). The total may be off; this rate cannot size a new trade.")
                    .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Bezel.cardFill)
                .strokeBorder(DS.Bezel.coreInnerHighlight, lineWidth: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Palette.surfaceStroke, lineWidth: 1))
    }

    private var addPositionForm: some View {
        // Persistent field labels stay legible after entry; narrow layouts stack naturally.
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a holding").font(.headline)
            #if os(iOS)
            VStack(alignment: .leading, spacing: 12) { addPositionFormFields }
            #else
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) { addPositionFormFields }
                VStack(alignment: .leading, spacing: 12) { addPositionFormFields }
            }
            #endif
            Text(draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Cost per share is entered in the instrument’s quoted units."
                : "Cost unit: " + StockSageCurrency.quoteUnitLabel(forSymbol: draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private var addPositionFormFields: some View {
        field($draft.symbol, "Symbol", width: 84, focus: .symbol)
        field($draft.shares, "Shares", width: 66, focus: .shares, numeric: true)
        field($draft.cost, "Cost per share", width: 112, focus: .cost, numeric: true)
        Button(action: addHolding) {
            Label("Add holding", systemImage: "plus")
                #if os(iOS)
                .frame(minHeight: 32)
                #endif
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .help("Add holding").accessibilityLabel("Add holding")
        .disabled(draft.symbol.trimmingCharacters(in: .whitespaces).isEmpty
                  || StockSageInput.positiveAmount(draft.shares) == nil
                  || StockSageInput.nonNegativeAmount(draft.cost) == nil)
    }

    private func addHolding() {
        guard let shares = StockSageInput.positiveAmount(draft.shares),
              let cost = StockSageInput.nonNegativeAmount(draft.cost),
              portfolio.add(symbol: draft.symbol, shares: shares, costBasis: cost) else { return }
        draft.symbol = ""; draft.shares = ""; draft.cost = ""
        focusedAddField = .symbol
    }

    private func field(_ text: Binding<String>, _ placeholder: String, width: CGFloat, focus: AddField, numeric: Bool = false) -> some View {
        let active = focusedAddField == focus
        return VStack(alignment: .leading, spacing: 6) {
            Text(placeholder).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.body)
            .decimalKeyboardOnIOS(numeric)
            .focused($focusedAddField, equals: focus)
            .submitLabel(focus == .cost ? .done : .next)
            .onSubmit {
                switch focus {
                case .symbol: focusedAddField = .shares
                case .shares: focusedAddField = .cost
                case .cost: addHolding()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            #if os(iOS)
            .frame(maxWidth: .infinity, minHeight: 44)
            #else
            .frame(minWidth: width, maxWidth: width * 1.8)
            #endif
            .background(Color.white.opacity(active ? 0.11 : 0.09), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .stroke(active
                        ? AnyShapeStyle(LinearGradient(colors: [DS.Palette.accent.opacity(0.55), DS.Palette.accent.opacity(0.15)],
                                                       startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(DS.Palette.surfaceStroke), lineWidth: 1))
            .shadow(color: DS.Palette.accent.opacity(active ? 0.15 : 0.0), radius: 8, y: 2)
            .animation(DS.Motion.lux, value: active)
            .accessibilityLabel(placeholder)
        }
    }

    private func positionRow(_ p: PortfolioPosition, asOf now: Date) -> some View {
        let price = currentPrice(p.symbol, asOf: now)
        let value = holdingValue(p.symbol, perShare: price ?? p.costBasis, shares: p.shares)
        // Both legs use major units; a London holding's pence cost must also become GBP.
        let profit = value - holdingValue(p.symbol, perShare: p.costBasis, shares: p.shares)
        let hovered = hoveredPositionID == p.id
        let remove = Button { pendingPositionRemoval = p } label: {
            Image(systemName: "trash").font(.system(size: mvFont12))
                .foregroundStyle(hovered ? DS.Palette.danger.opacity(0.7) : Color.secondary)
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(LuxPressStyle()).help("Remove holding")
        .accessibilityLabel("Remove \(p.symbol)")
        .accessibilityIdentifier("portfolio.remove.\(p.symbol)")

        return ViewThatFits(in: .horizontal) {
            if !workspaceTypeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    positionIdentity(p, price: price, asOf: now).frame(minWidth: 100, alignment: .leading)
                    Spacer(minLength: 8)
                    holdingMarks(p, price: price, value: value, profit: profit, alignment: .trailing)
                        .fixedSize(horizontal: true, vertical: true)
                    remove
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                positionIdentity(p, price: price, asOf: now)
                HStack(alignment: .top, spacing: 12) {
                    holdingMarks(p, price: price, value: value, profit: profit, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    remove
                }
            }
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, 10)
        .background(hovered ? DS.Palette.accent.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .confirmationDialog("Remove \(p.symbol) holding?",
            isPresented: Binding(get: { pendingPositionRemoval?.id == p.id },
                                 set: { if !$0 { pendingPositionRemoval = nil } }),
            titleVisibility: .visible) {
            Button("Remove \(p.symbol)", role: .destructive) {
                portfolio.remove(p.id)
                pendingPositionRemoval = nil
            }.accessibilityIdentifier("portfolio.confirmRemove")
            Button("Cancel", role: .cancel) { pendingPositionRemoval = nil }
                .accessibilityIdentifier("portfolio.cancelRemove")
        } message: {
            Text("Remove \(numString(p.shares)) shares with cost per share \(adaptivePrice(p.costBasis)) \(StockSageCurrency.quoteUnitLabel(forSymbol: p.symbol)) from saved holdings? This changes your tracked portfolio totals and cannot be undone. It does not place a sell order.")
        }
        .onHover { over in
            withAnimation(DS.Motion.smooth) {
                if over { hoveredPositionID = p.id }
                else if hoveredPositionID == p.id { hoveredPositionID = nil }
            }
        }
    }

    private func positionIdentity(_ p: PortfolioPosition, price: Double?, asOf now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.symbol).font(.system(size: mvFont14, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("\(numString(p.shares)) sh · Cost \(adaptivePrice(p.costBasis)) \(StockSageCurrency.quoteUnitLabel(forSymbol: p.symbol)) per share")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel("\(numString(p.shares)) shares, cost per share \(adaptivePrice(p.costBasis)) \(StockSageCurrency.quoteUnitLabel(forSymbol: p.symbol))")
            if price != nil, let quote = store.latestQuote(p.symbol) {
                Text(MarketsView.sourceTagLabel(isSampleData: false, loadedFromCache: store.loadedFromCache,
                    priceAsOf: quote.marketTime, now: now, priceSource: quote.priceSource) ?? "Source and time unknown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("portfolio.identity.\(p.symbol)")
    }

    private func holdingMarks(_ p: PortfolioPosition, price: Double?, value: Double, profit: Double,
                              alignment: HorizontalAlignment) -> some View {
        let currency = conversionCurrencyForSymbol(p.symbol)
        let valueText = price == nil ? "— no price" : adaptivePrice(value)
        let profitText = (profit >= 0 ? "+" : "") + adaptivePrice(profit)
        return VStack(alignment: alignment, spacing: 2) {
            Text("Value (\(currency))").font(.caption2).foregroundStyle(.secondary)
            Text(valueText)
                .font(.system(size: mvFont14, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(DS.Motion.smooth, value: value)
                .priceFlash(price)
                .accessibilityLabel("\(p.symbol) holding value")
                .accessibilityValue(price == nil ? valueText : "\(valueText) \(currency)")
                .accessibilityIdentifier("portfolio.value.\(p.symbol)")
            if price != nil {
                Text(profitText)
                    .font(.caption).foregroundStyle(MarketsView.signedMetricColor(positive: profit >= 0))
                    .contentTransition(.numericText())
                    .animation(DS.Motion.smooth, value: profit)
                    .priceFlash(price)
                    .accessibilityLabel("\(p.symbol) profit or loss")
                    .accessibilityValue("\(profitText) \(currency)")
                    .accessibilityIdentifier("portfolio.profit.\(p.symbol)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func numString(_ d: Double) -> String {
        // %.0f, not String(Int(d)) — Int(Double) TRAPS past Int.max (~9.22e18), and a persisted
        // pathological share count would then crash every Portfolio render (an in-app-unrecoverable
        // crash loop, since positions live in UserDefaults).
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

}
