import SwiftUI

/// Personal records only. No feed mark, inferred currency, trading order or automatic close.
struct StockSagePersonalJournalView: View {
    @ObservedObject var journal: StockSageJournalStore
    @State private var showEntry = false
    @State private var closing: TradeRecord?
    @State private var removing: TradeRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your trade journal").font(.title2.bold())
            Text("Record decisions and actual fills in their original currency and units. These records do not place orders.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = journal.lastError { Text(error).foregroundStyle(DS.Palette.warningSoft) }
            if !journal.hasLoadedRecords {
                Text("Saved journal unavailable. Its data was preserved; this is not an empty journal.")
            } else {
                let stats = journal.stats
                Text("\(journal.open.count) open · \(stats.closed) finalized")
                    .font(.headline).accessibilityIdentifier("personalJournal.counts")
                if stats.closed > 0 {
                    Text("Recorded total: \(StockSageJournal.formattedFinite(stats.totalR, format: "%+.2fR"))")
                    if let reason = stats.rUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let currency = stats.profitCurrency, stats.totalProfit.isFinite {
                        Text("Realized P&L: \(StockSageCurrency.signedAmount(stats.totalProfit, currency: currency)) \(currency == "USD" ? "USD" : "")")
                    } else if let reason = stats.profitUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("R compares each outcome with that record's original stop risk. It describes these trades and does not establish a future edge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Log trade", systemImage: "plus") { showEntry = true }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("personalJournal.add")
                if journal.trades.isEmpty {
                    ContentUnavailableView("No recorded trades", systemImage: "book.closed",
                        description: Text("Add a trade when you have an actual entry and an explicitly chosen stop."))
                }
                ForEach(journal.trades) { trade in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(trade.symbol) · \(trade.side.rawValue)").font(.headline)
                        Text("\(trade.shares.formatted()) shares · \(trade.openedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Entry \(StockSageCurrency.adaptivePrice(trade.entry)) · stop \(StockSageCurrency.adaptivePrice(trade.stop)) \(trade.rawUnitLabel)")
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = trade.closureError {
                            Text("Retained record needs review: \(error)").foregroundStyle(DS.Palette.warningSoft)
                        } else if trade.isFinalized {
                            Text("Realized: \(trade.realizedProfitDescription)")
                            if let r = trade.realizedR {
                                Text(StockSageJournal.formattedFinite(r, format: "%+.2fR")).font(.caption)
                            }
                        } else {
                            Text("Open record · no automatic mark or close").font(.caption).foregroundStyle(.secondary)
                            Button("Record exit") { closing = trade }
                                .buttonStyle(.bordered).accessibilityIdentifier("personalJournal.close.\(trade.symbol)")
                        }
                        if let note = trade.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Button("Remove record", systemImage: "trash") { removing = trade }
                            .buttonStyle(.bordered).accessibilityIdentifier("personalJournal.remove.\(trade.symbol)")
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .sheet(isPresented: $showEntry) { StockSagePersonalTradeEntry(journal: journal) }
        .sheet(item: $closing) { trade in StockSagePersonalTradeExit(journal: journal, trade: trade) }
        .confirmationDialog("Remove journal record?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let trade = removing {
                Button("Remove \(trade.symbol)", role: .destructive) { journal.remove(trade.id); removing = nil }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This removes the saved record. It does not close a broker position. A JSON backup can restore its original ID.") }
    }
}

private struct StockSagePersonalTradeEntry: View {
    @ObservedObject var journal: StockSageJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var symbol = ""
    @State private var entry = ""
    @State private var stop = ""
    @State private var target = ""
    @State private var shares = ""
    @State private var currency = ""
    @State private var hundredths = false
    @State private var side: TradeRecord.Side = .long
    @State private var openedAt = Date()
    @State private var note = ""

    private var record: TradeRecord? {
        let ticker = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !ticker.isEmpty, ticker.count <= 20,
              let entry = StockSageInput.positiveAmount(entry),
              let stop = StockSageInput.positiveAmount(stop),
              (side == .long ? stop < entry : stop > entry),
              let shares = StockSageInput.positiveAmount(shares),
              StockSageInput.journalTargetIsValid(target, entry: entry, isLong: side == .long),
              let unit = StockSagePriceDenomination.manualDeclaration(currencyInput: currency, hundredths: hundredths),
              openedAt <= Date(), (entry * shares).isFinite else { return nil }
        return TradeRecord(symbol: ticker, side: side, entry: entry, stop: stop,
            target: StockSageInput.positiveAmount(target), shares: shares, openedAt: openedAt,
            note: note.isEmpty ? nil : note, denomination: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Actual entry") {
                    field("Symbol", text: $symbol, numeric: false)
                    Picker("Side", selection: $side) {
                        ForEach(TradeRecord.Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    field("Entry", text: $entry)
                    field("Stop", text: $stop)
                    field("Target (optional)", text: $target)
                    field("Shares", text: $shares)
                    StockSageDenominationFields(currency: $currency, hundredths: $hundredths)
                    DatePicker("Opened at", selection: $openedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    TextField("Notes (optional)", text: $note, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    Text("Entry, stop, target and later exit must use these same recorded units. For a long, the stop is below entry; for a short, it is above. A stop is not a guarantee of its execution price.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = journal.lastError { Text(error).foregroundStyle(DS.Palette.warningSoft) }
            }
            .personalRecordKeyboard()
            .navigationTitle("Log trade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let record, journal.add(record) { dismiss() } }
                        .disabled(record == nil || !journal.hasLoadedRecords)
                        .accessibilityIdentifier("personalJournal.entry.save")
                }
            }
        }
    }
    private func field(_ label: String, text: Binding<String>, numeric: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            TextField(label, text: text).decimalKeyboardOnIOS(numeric)
                .accessibilityIdentifier("personalJournal.entry.\(label)")
        }
    }
}

private struct StockSagePersonalTradeExit: View {
    @ObservedObject var journal: StockSageJournalStore
    let trade: TradeRecord
    @Environment(\.dismiss) private var dismiss
    @State private var exit = ""
    @State private var closedAt = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section("\(trade.symbol) · actual exit") {
                    Text("Use the original record's units: \(trade.rawUnitLabel).")
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Exit price", text: $exit).decimalKeyboardOnIOS(true)
                        .accessibilityIdentifier("personalJournal.exit.price")
                    DatePicker("Closed at", selection: $closedAt, displayedComponents: [.date, .hourAndMinute])
                    Text("The close time must be after the entry and no later than now. Recording an exit does not place an order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = journal.lastError { Text(error).foregroundStyle(DS.Palette.warningSoft) }
            }
            .personalRecordKeyboard()
            .navigationTitle("Record exit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let price = StockSageInput.positiveAmount(exit),
                           journal.close(trade.id, exitPrice: price, at: closedAt) { dismiss() }
                    }
                    .disabled(StockSageInput.positiveAmount(exit) == nil || closedAt < trade.openedAt || closedAt > Date())
                    .accessibilityIdentifier("personalJournal.exit.save")
                }
            }
        }
    }
}
