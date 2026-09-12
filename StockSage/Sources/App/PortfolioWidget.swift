import Foundation

// UNWIRED — retained by owner choice (D4, 2026-09-12). This file belongs to the APP
// target, not StockSageWidget.appex. The shipped widget is StockSageWidget/StockSageWidget.swift.
// Do not activate this prototype without app-group snapshots, observation-age/source labels
// and working navigation. Its singleton reads and stocksage://portfolio links are still parked.
// Only the pure entry builder below is shared across platforms, to test its actual arithmetic.
struct PortfolioEntry {
    let date: Date
    /// Estimated open P&L in USD, the app's portfolio valuation base. nil when any leg lacks
    /// a usable mark or FX rate; a partial sum must never look like the whole portfolio.
    let totalPnL: Double?
    let openPositions: Int
    let winRate: Double
    let bestPerformer: PerformerInfo?
    let worstPerformer: PerformerInfo?

    static func make(date: Date, openTrades: [TradeRecord], closedTrades: [TradeRecord],
                     prices: [String: Double], ratesToUSD: [String: Double]) -> PortfolioEntry {
        // Prices are keyed by uppercase symbol; FX is USD per MAJOR unit, like the app's
        // widget-snapshot writer. Never use the exposure leg of an FX pair for valuation.
        var totalPnL: Double? = 0
        var performers: [PerformerInfo] = []
        for trade in openTrades {
            let symbol = trade.symbol.uppercased()
            guard let price = prices[symbol], price.isFinite, price > 0,
                  trade.entry.isFinite, trade.entry > 0, trade.shares.isFinite, trade.shares > 0 else {
                totalPnL = nil
                continue
            }
            let currency = StockSageCurrency.conversionCurrencyForSymbol(symbol)
            let rate = currency == "USD" ? 1 : ratesToUSD[currency]
            if let rate, rate.isFinite, rate > 0 {
                let usd = StockSageCurrency.majorUnitValue(symbol: symbol,
                    rawValue: trade.profit(at: price)) * rate
                totalPnL = totalPnL.flatMap { total in
                    let sum = total + usd
                    return sum.isFinite ? sum : nil
                }
            } else {
                totalPnL = nil
            }
            // R is dimensionless and needs no FX, but an absent mark/undefined R is not 0R.
            if let r = trade.rMultiple(at: price), r.isFinite {
                performers.append(PerformerInfo(symbol: symbol, rMultiple: r))
            }
        }
        let winRate = closedTrades.isEmpty ? 0.0 :
            Double(closedTrades.filter { ($0.realizedR ?? 0) > 0 }.count) /
            Double(closedTrades.count)
        let sorted = performers.sorted { a, b in
            a.rMultiple != b.rMultiple ? a.rMultiple > b.rMultiple : a.symbol < b.symbol
        }
        return PortfolioEntry(date: date, totalPnL: totalPnL, openPositions: openTrades.count,
                              winRate: winRate, bestPerformer: sorted.first,
                              worstPerformer: sorted.count > 1 ? sorted.last : nil)
    }

    static func refreshInterval(at date: Date, symbols: [String]) -> TimeInterval {
        // Reuse the venue calendar, including US pre/after-hours, DST, holidays and early closes.
        // This is a WidgetKit refresh hint, not a claim that a price is fresh or the venue live.
        symbols.contains { StockSageStore.marketIsTrading(symbol: $0, at: date) } ? 15 * 60 : 60 * 60
    }

    var pnlText: String {
        guard let totalPnL, totalPnL.isFinite else { return "Needs prices / FX" }
        return String(format: "≈%+.2f USD", totalPnL)
    }
}

struct PerformerInfo {
    let symbol: String
    let rMultiple: Double
}

#if os(iOS)
import SwiftUI
import WidgetKit

extension PortfolioEntry: TimelineEntry {}

// MARK: - StockSage Portfolio Widget (iOS enhancement, 2026-07-27)
//
// Parked portfolio summary: estimated USD P&L, open positions, win rate and performers.
// Requests a refresh every 15 minutes while a held venue trades, hourly otherwise.

struct PortfolioWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: .now, totalPnL: 0, openPositions: 0, winRate: 0, 
                      bestPerformer: nil, worstPerformer: nil)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        let entry = makeEntry()
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let now = Date()
        let entry = makeEntry(at: now)
        let refreshInterval = PortfolioEntry.refreshInterval(at: now,
            symbols: StockSageJournalStore.shared.open.map(\.symbol))
        let nextUpdate = now.addingTimeInterval(refreshInterval)
        
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func makeEntry(at now: Date = Date()) -> PortfolioEntry {
        let journal = StockSageJournalStore.shared
        let openTrades = journal.open
        let store = StockSageStore.shared
        var prices: [String: Double] = [:]
        var ratesToUSD: [String: Double] = [:]
        for trade in openTrades {
            let symbol = trade.symbol.uppercased()
            if let quote = store.latestQuote(symbol), quote.priceSource != .sample {
                prices[symbol] = quote.price
            }
        }
        for currency in Set(openTrades.map { StockSageCurrency.conversionCurrencyForSymbol($0.symbol) }) {
            ratesToUSD[currency] = store.fxConversionToUSD(currency, now: now)?.rate
        }
        return PortfolioEntry.make(date: now, openTrades: openTrades, closedTrades: journal.closed,
                                   prices: prices, ratesToUSD: ratesToUSD)
    }
}

struct PortfolioWidgetView: View {
    let entry: PortfolioEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        default:
            smallWidget
        }
    }
    
    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(DS.Palette.accent)
                Text("Portfolio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            
            Spacer()
            
            Text(entry.pnlText)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(pnlColor)
            
            HStack(spacing: 12) {
                Label("\(entry.openPositions)", systemImage: "briefcase")
                if entry.winRate > 0 {
                    Label(String(format: "%.0f%%", entry.winRate * 100), systemImage: "target")
                }
            }
            .font(.caption2)
            .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding()
        .background(DS.Gradient.bg)
        .widgetURL(URL(string: "stocksage://portfolio"))
    }
    
    private var mediumWidget: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(DS.Palette.accent)
                    Text("Portfolio")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                
                Spacer()
                
                Text(entry.pnlText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(pnlColor)
                
                HStack(spacing: 12) {
                    Label("\(entry.openPositions)", systemImage: "briefcase")
                    if entry.winRate > 0 {
                        Label(String(format: "%.0f%%", entry.winRate * 100), systemImage: "target")
                    }
                }
                .font(.caption2)
                .foregroundStyle(DS.Palette.textSecondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Top/Bottom")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                
                if let best = entry.bestPerformer {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(DS.Palette.successSoft)
                        Text(best.symbol)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2fR", best.rMultiple))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(DS.Palette.successSoft)
                    }
                }
                
                if let worst = entry.worstPerformer {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(DS.Palette.dangerSoft)
                        Text(worst.symbol)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2fR", worst.rMultiple))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(DS.Palette.dangerSoft)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(DS.Gradient.bg)
        .widgetURL(URL(string: "stocksage://portfolio"))
    }
    
    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3)
                    .foregroundStyle(DS.Palette.accent)
                Text("Portfolio Summary")
                    .font(.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            
            Divider()
            
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Estimated open P&L")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(entry.pnlText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(pnlColor)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    statRow(icon: "briefcase", label: "Open", value: "\(entry.openPositions)")
                    if entry.winRate > 0 {
                        statRow(icon: "target", label: "Win Rate", 
                               value: String(format: "%.0f%%", entry.winRate * 100))
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Performance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                
                if let best = entry.bestPerformer {
                    performerRow(symbol: best.symbol, r: best.rMultiple, isPositive: true)
                }
                
                if let worst = entry.worstPerformer {
                    performerRow(symbol: worst.symbol, r: worst.rMultiple, isPositive: false)
                }
            }
        }
        .padding()
        .background(DS.Gradient.bg)
        .widgetURL(URL(string: "stocksage://portfolio"))
    }
    
    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundStyle(DS.Palette.textSecondary)
    }
    
    private func performerRow(symbol: String, r: Double, isPositive: Bool) -> some View {
        HStack {
            Image(systemName: isPositive ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(isPositive ? DS.Palette.successSoft : DS.Palette.dangerSoft)
            Text(symbol)
                .font(.callout.weight(.semibold))
            Spacer()
            Text(String(format: "%.2fR", r))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(isPositive ? DS.Palette.successSoft : DS.Palette.dangerSoft)
        }
        .padding(8)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.small))
    }
    
    private var pnlColor: Color {
        guard let value = entry.totalPnL, value.isFinite else { return DS.Palette.textSecondary }
        return value >= 0 ? DS.Palette.successSoft : DS.Palette.dangerSoft
    }
}

// No @main: APP-target prototype; it is not registered in the shipping widget bundle.
struct PortfolioWidget: Widget {
    let kind = "PortfolioWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioWidgetProvider()) { entry in
            PortfolioWidgetView(entry: entry)
        }
        .configurationDisplayName("Portfolio")
        .description("Track your StockSage portfolio at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    PortfolioWidget()
} timeline: {
    PortfolioEntry(
        date: .now,
        totalPnL: 1250.50,
        openPositions: 3,
        winRate: 0.67,
        bestPerformer: PerformerInfo(symbol: "AAPL", rMultiple: 2.3),
        worstPerformer: PerformerInfo(symbol: "TSLA", rMultiple: -0.5)
    )
}
#endif
