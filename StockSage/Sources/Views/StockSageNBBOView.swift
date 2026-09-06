import SwiftUI

/// Observes only the existing coalesced stream, not a second socket or REST polling loop.
struct StockSageNBBOView: View {
    let symbol: String
    @ObservedObject private var live = StockSageLiveStream.shared
    @AppStorage("stocksage.ticks.nasdaqOnly") private var nasdaqOnly = false
    @State private var showTape = false
    @State private var exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]

    var body: some View {
        if StockSageMassive.covers(symbol) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(nasdaqOnly ? "Nasdaq-attributed SIP sides" : "NBBO · Massive SIP").font(.headline)
                        Spacer()
                        Button("Tape") { showTape = true }.buttonStyle(.bordered)
                    }
                    Toggle("Nasdaq only", isOn: $nasdaqOnly).font(.caption)
                    if let quote = live.quotes[symbol.uppercased()] {
                        ViewThatFits(in: .horizontal) {
                            HStack { side("Bid", price: quote.bid, size: quote.bidSize, exchange: quote.bidExchange); Spacer(); side("Ask", price: quote.ask, size: quote.askSize, exchange: quote.askExchange) }
                            VStack(alignment: .leading, spacing: 4) {
                                side("Bid", price: quote.bid, size: quote.bidSize, exchange: quote.bidExchange)
                                side("Ask", price: quote.ask, size: quote.askSize, exchange: quote.askExchange)
                            }
                        }
                        if nasdaqOnly {
                            Text(quote.isFresh(at: context.date) ? "Recent authenticated quote" : "Stale or future-dated quote")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Filtered quote sides are not consolidated NBBO; no spread cost is inferred from this view.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let spread = quote.spreadBps(at: context.date) {
                            Text(String(format: "Live quote · spread %.2f bps", spread))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(quote.isFresh(at: context.date)
                                 ? "One-sided, locked or crossed quote — spread unavailable."
                                 : "Stale or future-dated quote — spread unavailable.")
                                .font(.caption).foregroundStyle(DS.Palette.warningSoft)
                        }
                        Text("SIP time: \(quote.timestamp.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No authenticated bid/ask received. Enable live prices with your Massive key; last trade is shown separately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Consolidated US quote, not a Nasdaq-only book or guaranteed fill. Ranking and tickets still use estimated costs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            .task {
                guard StockSageMassive.isConfigured else { return }
                exchanges = (try? await StockSageMassiveTicks.exchanges()) ?? [:]
            }
            .sheet(isPresented: $showTape) {
                StockSageTapeView(symbol: symbol).presentationDetents([.large])
            }
        }
    }

    private func side(_ label: String, price: Double, size: Double, exchange: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if nasdaqOnly, !StockSageMassiveTicks.isNasdaq(exchange, exchanges: exchanges) {
                Text("No Nasdaq-attributed side").font(.caption)
            } else if price > 0, size > 0 {
                Text(price, format: .currency(code: "USD").precision(.fractionLength(2...4))).monospacedDigit()
                Text("\(size.formatted()) shares").font(.caption).foregroundStyle(.secondary)
                Text(exchange.flatMap { exchanges[$0]?.label } ?? exchange.map { "Unknown exchange #\($0)" } ?? "Unknown venue")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Unavailable").font(.body)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
