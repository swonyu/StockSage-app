import SwiftUI

/// Opening this sheet is the only tape fetch trigger. No background polling.
struct StockSageTapeView: View {
    let symbol: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("stocksage.ticks.nasdaqOnly") private var nasdaqOnly = false
    @AppStorage("stocksage.massive.credentialRevision") private var credentialRevision = ""
    @AppStorage("set_policyRevision") private var policyRevision = ""
    @State private var tape: StockSageMassiveTicks.Tape?
    @State private var exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]
    @State private var exchangeNotice: String?
    private let access: StockSageMassive.Access
    private let loadExchanges: @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange]
    private let loadTape: @MainActor (String, Date, Date) async -> StockSageMassiveTicks.Tape

    init(symbol: String, access: StockSageMassive.Access = .init(),
         loadExchanges: @escaping @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange] = {
             try await StockSageMassiveTicks.exchanges()
         },
         loadTape: @escaping @MainActor (String, Date, Date) async -> StockSageMassiveTicks.Tape = {
             await StockSageMassiveTicks.fetch(symbol: $0, from: $1, to: $2)
         }) {
        self.symbol = symbol
        self.access = access
        self.loadExchanges = loadExchanges
        self.loadTape = loadTape
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Nasdaq only", isOn: $nasdaqOnly)
                    Text("Nasdaq-attributed SIP data, not a proprietary Nasdaq feed. Listing tape C does not prove execution on Nasdaq.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Last 7 days; newest first, at most 300 trades and 300 quotes. Up to 3 pages of 100 per channel. A snapshot, not a streaming or complete historical tape.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let exchangeNotice { Text(exchangeNotice).font(.caption).foregroundStyle(DS.Palette.warningSoft) }
                }
                if let tape {
                    if !tape.notices.isEmpty {
                        Section("Availability") {
                            ForEach(Array(tape.notices.enumerated()), id: \.offset) { _, notice in
                                Text(notice).font(.caption).foregroundStyle(DS.Palette.warningSoft)
                            }
                        }
                    }
                    Section("Trades") {
                        let trades = tape.trades.filter { !nasdaqOnly || StockSageMassiveTicks.isNasdaq($0.exchange, exchanges: exchanges) }
                        if trades.isEmpty {
                            Text(nasdaqOnly && exchanges.isEmpty
                                 ? "Nasdaq attribution unavailable. Turn off Nasdaq only to inspect the returned SIP trades without a venue filter."
                                 : "No matching trades in the returned window.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(trades.enumerated()), id: \.offset) { _, trade in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(trade.price.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) · \(trade.size.formatted()) shares")
                                    .monospacedDigit()
                                Text("\(trade.timestamp.formatted(date: .abbreviated, time: .standard)) · \(venue(trade.exchange))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Conditions: \(trade.conditions.map { $0.map(String.init).joined(separator: ", ") } ?? "unavailable") · raw reported trade; not a qualified current price")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let participant = trade.participantTime {
                                    Text("Exchange time: \(participant.formatted(date: .abbreviated, time: .standard))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if let sequence = trade.sequence { Text("Sequence \(String(sequence))").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Section(nasdaqOnly ? "Nasdaq-attributed quote sides" : "SIP bid / ask quotes") {
                        let quotes = tape.quotes.filter {
                            !nasdaqOnly || StockSageMassiveTicks.isNasdaq($0.bidExchange, exchanges: exchanges)
                                || StockSageMassiveTicks.isNasdaq($0.askExchange, exchanges: exchanges)
                        }
                        if quotes.isEmpty {
                            Text(nasdaqOnly && exchanges.isEmpty
                                 ? "Nasdaq attribution unavailable. Turn off Nasdaq only to inspect the returned SIP quotes without a venue filter."
                                 : "No matching quotes in the returned window.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(quote.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                Text(side("Bid", price: quote.bid, size: quote.bidSize, exchange: quote.bidExchange))
                                Text(side("Ask", price: quote.ask, size: quote.askSize, exchange: quote.askExchange))
                                if let sequence = quote.sequence { Text("Sequence \(String(sequence))").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } else { ProgressView("Loading requested tape…") }
            }
            .navigationTitle("Tape · \(symbol)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: symbol + "|" + credentialRevision + "|" + policyRevision) {
                tape = nil
                exchanges = [:]
                exchangeNotice = nil
                let captured = access.capture()
                @MainActor func acceptsResult() -> Bool {
                    guard !Task.isCancelled else { return false }
                    guard captured.isCurrent() else {
                        tape = .init(notices: [StockSageMassiveTicks.Failure.unavailable.localizedDescription])
                        exchanges = [:]
                        return false
                    }
                    return true
                }
                guard acceptsResult() else { return }
                let to = Date()
                do {
                    let reference = try await loadExchanges()
                    guard acceptsResult() else { return }
                    exchanges = reference
                } catch {
                    guard acceptsResult() else { return }
                    exchangeNotice = "Exchange reference unavailable; unknown venue IDs are not treated as Nasdaq."
                }
                guard acceptsResult() else { return }
                let result = await loadTape(symbol, to.addingTimeInterval(-7 * 86_400), to)
                guard acceptsResult() else { return }
                tape = result
            }
        }
        .frame(minHeight: 350)
    }

    private func venue(_ id: Int64?) -> String {
        guard let id else { return "Unknown venue" }
        return exchanges[id]?.label ?? "Unknown exchange #\(id)"
    }

    private func side(_ label: String, price: Double, size: Double, exchange: Int64?) -> String {
        if let notice = StockSageNBBOView.filteredSideNotice(nasdaqOnly: nasdaqOnly,
                                                          exchanges: exchanges, exchange: exchange) {
            return "\(label): \(notice)"
        }
        guard price > 0, size > 0 else { return "\(label): unavailable · \(venue(exchange))" }
        return "\(label): \(price.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) × \(size.formatted()) shares · \(venue(exchange))"
    }
}
