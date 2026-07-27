#if os(iOS)
import SwiftUI
import WidgetKit

// MARK: - StockSage Portfolio Widget (iOS enhancement, 2026-07-27)
//
// Home screen widget showing portfolio summary: total P&L, open positions count,
// win rate, and best/worst performers. Updates every 15 minutes during market hours,
// hourly otherwise. Tapping opens the main app.

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
        let entry = makeEntry()
        
        // Refresh every 15 min during market hours (9:30 AM - 4 PM ET), hourly otherwise
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let isMarketHours = (9...16).contains(hour)
        let refreshInterval: TimeInterval = isMarketHours ? 15 * 60 : 60 * 60
        let nextUpdate = now.addingTimeInterval(refreshInterval)
        
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func makeEntry() -> PortfolioEntry {
        let journal = StockSageJournalStore.shared
        let openTrades = journal.open
        
        let totalPnL = openTrades.reduce(0.0) { sum, trade in
            // Use current price from store for open P&L
            let currentPrice = StockSageStore.shared.symbols
                .first(where: { $0.symbol == trade.symbol })?.latest?.price ?? trade.entry
            return sum + trade.profit(at: currentPrice)
        }
        
        let closedTrades = journal.closed
        // Review 2026-07-27: side-aware — exit > entry is a LOSS for a short. realizedR
        // carries the side; a missing exit contributes 0 (not a win) rather than a fake loss.
        let winRate = closedTrades.isEmpty ? 0.0 :
            Double(closedTrades.filter { ($0.realizedR ?? 0) > 0 }.count) /
            Double(closedTrades.count)
        
        // Find best/worst open positions by R-multiple
        let sortedByPerformance = openTrades.sorted { a, b in
            let priceA = StockSageStore.shared.symbols
                .first(where: { $0.symbol == a.symbol })?.latest?.price ?? a.entry
            let priceB = StockSageStore.shared.symbols
                .first(where: { $0.symbol == b.symbol })?.latest?.price ?? b.entry
            return (a.rMultiple(at: priceA) ?? 0) > (b.rMultiple(at: priceB) ?? 0)
        }
        
        let best = sortedByPerformance.first.map { trade -> PerformerInfo in
            let price = StockSageStore.shared.symbols
                .first(where: { $0.symbol == trade.symbol })?.latest?.price ?? trade.entry
            return PerformerInfo(symbol: trade.symbol, rMultiple: trade.rMultiple(at: price) ?? 0)
        }
        
        let worst = sortedByPerformance.last.map { trade -> PerformerInfo in
            let price = StockSageStore.shared.symbols
                .first(where: { $0.symbol == trade.symbol })?.latest?.price ?? trade.entry
            return PerformerInfo(symbol: trade.symbol, rMultiple: trade.rMultiple(at: price) ?? 0)
        }
        
        return PortfolioEntry(
            date: .now,
            totalPnL: totalPnL,
            openPositions: openTrades.count,
            winRate: winRate,
            bestPerformer: best,
            worstPerformer: worst
        )
    }
}

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let totalPnL: Double
    let openPositions: Int
    let winRate: Double
    let bestPerformer: PerformerInfo?
    let worstPerformer: PerformerInfo?
}

struct PerformerInfo {
    let symbol: String
    let rMultiple: Double
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
            
            Text(formatCurrency(entry.totalPnL))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(entry.totalPnL >= 0 ? DS.Palette.successSoft : DS.Palette.dangerSoft)
            
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
                
                Text(formatCurrency(entry.totalPnL))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.totalPnL >= 0 ? DS.Palette.successSoft : DS.Palette.dangerSoft)
                
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
                    Text("Total P&L")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(formatCurrency(entry.totalPnL))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.totalPnL >= 0 ? DS.Palette.successSoft : DS.Palette.dangerSoft)
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
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

// @main   — PARKED (review triage 2026-07-27): this file was authored as a standalone
// WidgetKit EXTENSION (own entry point) but lives in the APP target, where a second
// @main collides with StockSageApp's. The bundle activates when a real widget
// extension target exists; until then the views compile as parked code.
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
