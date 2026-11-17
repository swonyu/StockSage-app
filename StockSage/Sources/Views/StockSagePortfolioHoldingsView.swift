import Combine
import Foundation
import SwiftUI

/// Explicit observation/cost units; each currency has its own subtotal. No ticker-based FX.
struct StockSagePortfolioHoldingsView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var portfolio: StockSagePortfolio
    @ObservedObject var draft: EntryDraft
    @ObservedObject var prices: StockSageManualPriceBook

    @MainActor final class EntryDraft: ObservableObject {
        @Published var symbol = ""
        @Published var shares = ""
        @Published var cost = ""
        @Published var currency = ""
        @Published var hundredths = false
    }
    @State private var pendingPositionRemoval: PortfolioPosition?
    @State private var priceSymbol = ""
    @State private var showPriceEntry = false

    private var costUnit: StockSagePriceDenomination? {
        StockSagePriceDenomination.manualDeclaration(currencyInput: draft.currency, hundredths: draft.hundredths)
    }
    private func quote(_ ticker: String, at now: Date) -> StockSageQuote? {
        if let record = prices.latest(for: ticker, now: now) { return record.quote }
        #if os(iOS)
        return nil
        #else
        return store.latestQuote(ticker)
        #endif
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 20) {
                if let error = portfolio.lastError ?? prices.lastError {
                    Text(error).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                }
                if portfolio.hasLoadedRecords { summary(at: context.date) }
                entryForm
                if !portfolio.hasLoadedRecords {
                    Text("Holdings unavailable because saved records could not be read. The original data was preserved; this is not an empty account.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if portfolio.positions.isEmpty {
                    ContentUnavailableView("Record your first holding", systemImage: "briefcase",
                        description: Text("Enter shares, cost per share and the currency and units on your record."))
                } else {
                    ForEach(portfolio.positions) { position in row(position, at: context.date) }
                }
            }
        }
        .sheet(isPresented: $showPriceEntry) { StockSagePersonalPriceEntry(prices: prices, symbol: priceSymbol) }
        .confirmationDialog("Remove holding?", isPresented: Binding(
            get: { pendingPositionRemoval != nil }, set: { if !$0 { pendingPositionRemoval = nil } }), titleVisibility: .visible) {
            if let position = pendingPositionRemoval {
                Button(removeLabel(position), role: .destructive) {
                    portfolio.remove(position.id); pendingPositionRemoval = nil
                }.accessibilityIdentifier("portfolio.confirmRemove")
            }
            Button("Cancel", role: .cancel) { pendingPositionRemoval = nil }
                .accessibilityIdentifier("portfolio.cancelRemove")
        } message: {
            if let position = pendingPositionRemoval {
                Text("Remove \(Self.quantityText(position.shares)) shares of \(position.symbol), cost \(StockSageCurrency.adaptivePrice(position.costBasis)) \(position.costDenomination?.quoteUnitLabel ?? "raw units (currency unconfirmed)") per share? This removes the saved lot. It does not place a sell order. A backup can restore the original record.")
            }
        }
    }

    private func summary(at now: Date) -> some View {
        let marked = portfolio.positions.compactMap {
            StockSageRecordedValuation.holding($0, quote: quote($0.symbol, at: now), now: now)
        }
        let totals = StockSageRecordedValuation.totals(marked)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Recorded portfolio value").font(.title2.bold())
            if portfolio.positions.isEmpty {
                Text("No holdings yet").foregroundStyle(.secondary)
            } else if let totals, !totals.isEmpty {
                ForEach(totals) { total in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(StockSageCurrency.adaptivePrice(total.value)) \(total.currency)")
                            .font(.title3.bold().monospacedDigit())
                        if let profit = total.profit {
                            Text("Recorded P&L: \(StockSageCurrency.signedAmount(profit, currency: total.currency))")
                                .foregroundStyle(MarketsView.signedMetricColor(positive: profit >= 0))
                        } else {
                            Text("P&L unavailable: one or more costs have unknown or different units, or their amounts cannot be represented.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(total.pricedLots) priced lot\(total.pricedLots == 1 ? "" : "s") in \(total.currency)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(totals == nil ? "Value unavailable: the amounts cannot be represented." : "Record a price to calculate a holding's value.")
                    .foregroundStyle(.secondary)
            }
            if !portfolio.positions.isEmpty {
                Text("\(marked.count) of \(portfolio.positions.count) lots have a usable mark and explicit price units. Each currency is shown separately; no exchange rate is assumed. Each mark's observation date is shown when available.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("These are your recorded holdings and available observations, not a live account balance. Missing dates and cost units stay unknown.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("portfolio.recordedSummary")
    }

    private var entryForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a holding").font(.headline)
            entryField("Symbol", text: $draft.symbol, numeric: false)
            entryField("Shares", text: $draft.shares, numeric: true)
            entryField("Cost per share", text: $draft.cost, numeric: true)
            StockSageDenominationFields(currency: $draft.currency, hundredths: $draft.hundredths)
            Text("Declare the units of the cost you entered. A mark can use different raw units in the same currency; the app converts those units explicitly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Add holding", systemImage: "plus") {
                guard let shares = StockSageInput.positiveAmount(draft.shares),
                      let cost = StockSageInput.nonNegativeAmount(draft.cost), let costUnit,
                      portfolio.add(symbol: draft.symbol, shares: shares, costBasis: cost, costDenomination: costUnit) else { return }
                draft.symbol = ""; draft.shares = ""; draft.cost = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || StockSageInput.positiveAmount(draft.shares) == nil
                || StockSageInput.nonNegativeAmount(draft.cost) == nil || costUnit == nil || !portfolio.hasLoadedRecords)
            .accessibilityIdentifier("portfolio.addHolding")
        }.padding(.vertical, 8)
    }

    private func entryField(_ label: String, text: Binding<String>, numeric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            TextField(label, text: text).textFieldStyle(.roundedBorder).decimalKeyboardOnIOS(numeric)
                #if os(iOS)
                .textInputAutocapitalization(numeric ? .never : .characters).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("portfolio.field.\(label)")
        }
    }

    private func row(_ position: PortfolioPosition, at now: Date) -> some View {
        let observation = quote(position.symbol, at: now)
        let mark = StockSageRecordedValuation.holding(position, quote: observation, now: now)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(position.symbol).font(.headline)
                Text("\(Self.quantityText(position.shares)) shares · cost \(StockSageCurrency.adaptivePrice(position.costBasis)) \(position.costDenomination?.quoteUnitLabel ?? "raw units (currency unconfirmed)") per share")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let context = lotContext(position) {
                    Text(context).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let observation {
                    Text("\(observation.priceSource?.label ?? "Unknown source") · \(observation.marketTime?.formatted(date: .abbreviated, time: .shortened) ?? "observation date unknown")")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("portfolio.identity.\(recordKey(position))")
            if let mark {
                Text("Value: \(StockSageCurrency.adaptivePrice(mark.value)) \(mark.currency)")
                    .font(.body.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(position.symbol) holding value")
                    .accessibilityValue("\(StockSageCurrency.adaptivePrice(mark.value)) \(mark.currency)")
                    .accessibilityIdentifier("portfolio.value.\(recordKey(position))")
                if let profit = mark.profit {
                    Text("P&L: \(Self.signedMajorAmount(profit, currency: mark.currency))")
                        .foregroundStyle(MarketsView.signedMetricColor(positive: profit >= 0))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(position.symbol) profit or loss")
                        .accessibilityValue(Self.signedMajorAmount(profit, currency: mark.currency))
                        .accessibilityIdentifier("portfolio.profit.\(recordKey(position))")
                } else {
                    Text("P&L unavailable: cost units are unknown or different, or the amounts cannot be represented.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(position.symbol) profit or loss")
                        .accessibilityValue("Unavailable: cost units are unknown or different, or the amounts cannot be represented.")
                        .accessibilityIdentifier("portfolio.profit.\(recordKey(position))")
                }
            } else {
                Text("Value unavailable: the price or units are missing, the observation is unusable, or the amount cannot be represented.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(position.symbol) holding value")
                    .accessibilityValue("Unavailable: price or units are missing, the observation is unusable, or the amount cannot be represented.")
                    .accessibilityIdentifier("portfolio.value.\(recordKey(position))")
            }
            ViewThatFits(in: .horizontal) {
                HStack { recordPrice(position); remove(position) }
                VStack(alignment: .leading) { recordPrice(position); remove(position) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
    private func recordPrice(_ position: PortfolioPosition) -> some View {
        Button { priceSymbol = position.symbol; showPriceEntry = true } label: {
            Label("Record price", systemImage: "square.and.pencil").frame(minHeight: 44)
        }
        .buttonStyle(.bordered).disabled(!prices.hasLoadedRecords)
        .accessibilityLabel("Record price for \(position.symbol)")
        .accessibilityIdentifier("portfolio.recordPrice.\(recordKey(position))")
    }
    private func remove(_ position: PortfolioPosition) -> some View {
        Button { pendingPositionRemoval = position } label: {
            Label("Remove holding", systemImage: "trash").frame(minHeight: 44)
        }
        .buttonStyle(.bordered).accessibilityLabel(removeLabel(position))
        .accessibilityIdentifier("portfolio.remove.\(recordKey(position))")
    }
    private func recordKey(_ position: PortfolioPosition) -> String {
        Self.accessibilityRecordKey(position, positions: portfolio.positions)
    }
    nonisolated static func accessibilityRecordKey(_ position: PortfolioPosition,
                                                  positions: [PortfolioPosition]) -> String {
        positions.filter { $0.symbol == position.symbol }.count > 1
            ? position.symbol + "." + position.id.uuidString : position.symbol
    }
    private func lotContext(_ position: PortfolioPosition) -> String? {
        let lots = portfolio.positions.filter { $0.symbol == position.symbol }
        guard lots.count > 1, let index = lots.firstIndex(where: { $0.id == position.id }) else { return nil }
        return "Lot \(index + 1) of \(lots.count)"
    }
    private func removeLabel(_ position: PortfolioPosition) -> String {
        guard let context = lotContext(position) else { return "Remove \(position.symbol)" }
        return "Remove \(position.symbol), \(context), \(Self.quantityText(position.shares)) shares, cost per share \(StockSageCurrency.adaptivePrice(position.costBasis)) \(position.costDenomination?.quoteUnitLabel ?? "raw units (currency unconfirmed)")"
    }
    /// Keep the recorded Double's shortest round-tripping decimal. Two visible
    /// decimal places are a minimum for simple fractions, never a rounding cap.
    /// Scientific notation preserves tiny nonzero and very large quantities.
    nonisolated static func quantityText(_ amount: Double) -> String {
        guard amount.isFinite else { return "Unavailable" }
        if amount == 0 { return "0" }
        let text = String(amount)
        if text.contains("e") || text.contains("E") { return text }
        if text.hasSuffix(".0") { return String(text.dropLast(2)) }
        if let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) == 2 {
            return text + "0"
        }
        return text
    }
    nonisolated static func signedMajorAmount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "Unavailable" }
        let normalized = amount == 0 ? 0.0 : amount
        return (normalized >= 0 ? "+" : "") + StockSageCurrency.adaptivePrice(normalized) + " " + currency
    }
}
