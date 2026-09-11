import SwiftUI

/// Value-only card strip: no socket, requests, timers or separate observation subscription.
struct StockSageNBBOCompactView: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Observes only the existing coalesced stream, not a second socket or REST polling loop.
struct StockSageNBBOView: View {
    let symbol: String
    @ObservedObject private var live = StockSageLiveStream.shared
    @AppStorage("stocksage.ticks.nasdaqOnly") private var nasdaqOnly = false
    @State private var showTape = false
    @State private var exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]
    @State private var exchangeNotice: String?

    var body: some View {
        if StockSageLiveStream.stockSymbol(symbol) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(nasdaqOnly ? "Nasdaq-attributed SIP sides" : "NBBO · Massive SIP").font(.headline)
                        Spacer()
                        Button("Tape") { showTape = true }.buttonStyle(.bordered)
                    }
                    Toggle("Nasdaq only", isOn: $nasdaqOnly).font(.caption)
                    if let exchangeNotice {
                        Text(exchangeNotice).font(.caption).foregroundStyle(DS.Palette.warningSoft)
                    }
                    if let quote = StockSageLiveStream.displayQuote(for: symbol, in: live.quotes) {
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
                            Text(quote.costConditionVerified
                                 ? StockSageNetEdge.costsDisplayLabel(forSymbol: symbol, advDollar: nil, nbbo: quote, now: context.date)
                                 : "Quote condition/indicators not verified for costs — default estimate retained.")
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
                    Text("Consolidated US quote, not a Nasdaq-only book or guaranteed fill. Eligible fresh spreads can raise estimated costs; the spread floor and estimated slippage/fees remain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            .task {
                guard StockSageMassive.isConfigured else { return }
                // A swallowed `try?` here was the whole defect: a FAILED reference load left
                // `exchanges` empty, and an empty map made every side render "No Nasdaq-attributed
                // side" — a confident claim about the venue, produced by not knowing the venue.
                do {
                    exchanges = try await StockSageMassiveTicks.exchanges()
                    exchangeNotice = nil
                } catch {
                    exchanges = [:]
                    exchangeNotice = "Exchange reference unavailable — venue names and Nasdaq attribution cannot be verified."
                }
            }
            // Deliberate: the !isConfigured path sets NO notice. Without a key there is no
            // authenticated quote, `side(...)` never renders, and the card already says so —
            // an amber line there would be a new false alarm for every keyless user.
            .sheet(isPresented: $showTape) {
                StockSageTapeView(symbol: symbol).presentationDetents([.large])
            }
        }
    }

    /// Pure seam: the caption a filtered side may honestly show, or nil when the side renders
    /// normally. An EMPTY `exchanges` map means the venue reference never loaded —
    /// `StockSageMassiveTicks.parseExchanges` throws rather than returning an empty map
    /// (StockSageMassiveTicks.swift:168) — so it is NOT evidence that the side is non-Nasdaq.
    /// `isNasdaq` is untouched: its false-on-unknown contract stays correct and is pinned at
    /// StockSageMassiveTicksTests:112.
    static func filteredSideNotice(nasdaqOnly: Bool,
                                   exchanges: [Int64: StockSageMassiveTicks.Exchange],
                                   exchange: Int64?) -> String? {
        guard nasdaqOnly else { return nil }
        guard !exchanges.isEmpty else { return "Nasdaq attribution unavailable" }
        return StockSageMassiveTicks.isNasdaq(exchange, exchanges: exchanges) ? nil : "No Nasdaq-attributed side"
    }

    private func side(_ label: String, price: Double, size: Double, exchange: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let notice = Self.filteredSideNotice(nasdaqOnly: nasdaqOnly, exchanges: exchanges, exchange: exchange) {
                Text(notice).font(.caption)
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
