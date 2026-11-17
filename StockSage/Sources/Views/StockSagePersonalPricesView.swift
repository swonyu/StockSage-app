import SwiftUI

/// Phone watchlist has useful local actions from first launch. Ticker membership
/// and personal observations are separate; neither claims provider verification.
struct StockSagePersonalPricesView: View {
    @ObservedObject var store: StockSageStore
    @ObservedObject var prices: StockSageManualPriceBook
    let browse: () -> Void
    @State private var symbol = ""
    @State private var error: String?
    @State private var pendingRemoval: String?
    @State private var priceSymbol = ""
    @State private var showPriceEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your watchlist").font(.title2.bold())
                Text("Track tickers and record your own prices. Everything here works offline, with no data subscription or account.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Ticker").font(.headline)
                TextField("For example AAPL or 2222.SR", text: $symbol)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    #endif
                    .accessibilityIdentifier("personalPrice.addTicker")
                Button("Add to watchlist", systemImage: "plus") {
                    let entered = symbol
                    Task {
                        error = await store.addSymbol(entered)
                        if error == nil { symbol = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isAddingSymbol)
                .accessibilityIdentifier("personalPrice.addTicker.confirm")
                Button("Browse ticker catalog", systemImage: "magnifyingglass", action: browse)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("personalPrice.browse")
                Text("A saved ticker is a personal label. The catalog does not verify a price or make a trading recommendation.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = error ?? store.watchlistPersistenceError ?? prices.lastError {
                Text(message).foregroundStyle(DS.Palette.warningSoft).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("personalPrice.error")
            }
            if store.userSymbols.isEmpty {
                ContentUnavailableView("Start your watchlist", systemImage: "star",
                    description: Text("Add a ticker, then record a price with its currency and observation date."))
            } else {
                ForEach(store.userSymbols, id: \.self) { ticker in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ticker).font(.headline)
                        if let record = prices.latest(for: ticker) {
                            Text(StockSageCurrency.adaptivePrice(record.rawPrice) + " " + record.denomination.quoteUnitLabel)
                                .font(.title3.monospacedDigit())
                                .accessibilityIdentifier("personalPrice.value.\(ticker)")
                            Text("\(record.denomination.provenanceLabel) · observed \(record.observedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let note = record.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Text(prices.hasLoadedRecords ? "No personal price recorded" : "Personal prices unavailable")
                                .foregroundStyle(.secondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { priceButton(ticker); removeButton(ticker) }
                            VStack(alignment: .leading) { priceButton(ticker); removeButton(ticker) }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .contain)
                }
            }
            Text("Recorded prices are personal observations, not live quotes. They do not trigger price alerts or paper trades.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showPriceEntry) { StockSagePersonalPriceEntry(prices: prices, symbol: priceSymbol) }
        .confirmationDialog("Remove ticker from watchlist?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            if let ticker = pendingRemoval {
                Button("Remove \(ticker)", role: .destructive) { store.removeSymbol(ticker); pendingRemoval = nil }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("Your saved holdings, journal and personal price history are kept.") }
    }

    private func priceButton(_ ticker: String) -> some View {
        Button("Record price", systemImage: "square.and.pencil") { priceSymbol = ticker; showPriceEntry = true }
            .buttonStyle(.bordered).disabled(!prices.hasLoadedRecords)
            .accessibilityIdentifier("personalPrice.record.\(ticker)")
    }
    private func removeButton(_ ticker: String) -> some View {
        Button("Remove", systemImage: "star.slash") { pendingRemoval = ticker }
            .buttonStyle(.bordered).accessibilityIdentifier("personalPrice.remove.\(ticker)")
    }
}

struct StockSagePersonalPriceEntry: View {
    @ObservedObject var prices: StockSageManualPriceBook
    let symbol: String
    @Environment(\.dismiss) private var dismiss
    @State private var price = ""
    @State private var currency = ""
    @State private var hundredths = false
    @State private var observedAt = Date()
    @State private var note = ""

    private var denomination: StockSagePriceDenomination? {
        StockSagePriceDenomination.manualDeclaration(currencyInput: currency, hundredths: hundredths)
    }
    private var record: StockSageManualPriceRecord? {
        guard let denomination, let value = StockSageInput.positiveAmount(price) else { return nil }
        let entered = StockSageManualPriceRecord(symbol: symbol, rawPrice: value,
            denomination: denomination, observedAt: observedAt, note: note.isEmpty ? nil : note)
        return entered.validationError == nil ? entered : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("\(symbol) · personal observation") {
                    LabeledContent("Price") {
                        TextField("Positive amount", text: $price).decimalKeyboardOnIOS(true)
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("personalPrice.entry.price")
                    }
                    StockSageDenominationFields(currency: $currency, hundredths: $hundredths)
                    DatePicker("Observed at", selection: $observedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("personalPrice.entry.date")
                    TextField("Source note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("personalPrice.entry.note")
                }
                Section {
                    Text("Enter the currency and units shown with your observation. A London ticker can be quoted in pounds, pence, dollars or another currency; its suffix is not enough.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This adds a dated personal record. It is not a market feed, price verification or an order.")
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.caption).foregroundStyle(.secondary)
                if let error = prices.lastError { Text(error).foregroundStyle(DS.Palette.warningSoft) }
            }
            .personalRecordKeyboard()
            .navigationTitle("Record price")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let record, prices.add(record) { dismiss() } }
                        .disabled(record == nil || !prices.hasLoadedRecords)
                        .accessibilityIdentifier("personalPrice.entry.save")
                }
            }
        }
    }
}

/// Shared explicit declaration for price, cost and journal entry. No symbol lookup.
struct StockSageDenominationFields: View {
    @Binding var currency: String
    @Binding var hundredths: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Currency code").font(.callout)
            TextField("For example USD, GBP, SAR or EUR", text: $currency)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("denomination.currency")
            Picker("Entered units", selection: $hundredths) {
                Text("Major units (1 = 1 currency unit)").tag(false)
                Text("Hundredths (100 = 1 currency unit)").tag(true)
            }.pickerStyle(.menu).accessibilityIdentifier("denomination.units")
            if let declared = StockSagePriceDenomination.manualDeclaration(currencyInput: currency, hundredths: hundredths) {
                Text("Entered values use \(declared.quoteUnitLabel).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter a three-letter currency such as GBP and select the units separately. For pence, use GBP with Hundredths.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
