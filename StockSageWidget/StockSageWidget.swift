import WidgetKit
import SwiftUI

// MARK: - StockSageX home-screen widget
//
// Shows the board's own last word: the best opportunity it found, how much of the account is
// already at risk against the 8% cap, and how far the forward test has got.
//
// It runs NO engine. A widget process gets seconds and tens of megabytes; it reads the snapshot
// the app wrote after its last scan (StockSageWidgetSnapshot, shared through the App Group) and
// renders that. Everything it shows is therefore AS OF a moment in the past, and it says so —
// the one thing a home-screen number must never do is imply it is current when it is not.

struct StockSageEntry: TimelineEntry {
    let date: Date
    let snapshot: StockSageWidgetSnapshot?
}

struct StockSageProvider: TimelineProvider {
    /// Shown in the widget gallery before any real data exists. Deliberately a placeholder
    /// SHAPE with no invented numbers — a gallery preview that shows a plausible symbol and
    /// conviction teaches the wrong thing about what this widget knows.
    func placeholder(in context: Context) -> StockSageEntry {
        StockSageEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StockSageEntry) -> Void) {
        completion(StockSageEntry(date: Date(), snapshot: StockSageWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StockSageEntry>) -> Void) {
        let entry = StockSageEntry(date: Date(), snapshot: StockSageWidgetSnapshot.load())
        // Ask for a refresh in 30 minutes. iOS treats this as a HINT and routinely ignores it —
        // which is exactly why every rendered figure carries its own age rather than trusting
        // this cadence to keep it honest.
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct StockSageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StockSageEntry

    var body: some View {
        if let s = entry.snapshot {
            content(s)
        } else {
            // No snapshot: the app has not completed a scan since the widget was added. Say that,
            // rather than drawing zeros that read as "no opportunities, no risk".
            VStack(alignment: .leading, spacing: 4) {
                Text("StockSageX").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Open the app to load the board")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func content(_ s: StockSageWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            header(s)
            if let sym = s.bestSymbol {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sym).font(.title3.weight(.bold)).minimumScaleFactor(0.7).lineLimit(1)
                    HStack(spacing: 4) {
                        if let a = s.bestAction {
                            Text(a).font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                        }
                        if let st = s.bestStrength {
                            // Ordinal, matching the board — never a percentage the engine cannot
                            // support.
                            Text("\(st)/5").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No idea clears the bar").font(.caption).foregroundStyle(.secondary)
            }

            if family != .systemSmall { heat(s) }

            Spacer(minLength: 0)
            footer(s)
        }
        .padding(family == .systemSmall ? 2 : 4)
        // Stale data is dimmed as well as labelled — a glance that skips the text still reads
        // "this is not live".
        .opacity(s.isStale() ? 0.55 : 1)
    }

    @ViewBuilder private func header(_ s: StockSageWidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Text("Best opportunity").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if s.isSampleData {
                // A demo board must never be mistaken for a real one, at any size.
                Text("SAMPLE").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func heat(_ s: StockSageWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                // Heat only prints when an account size made it computable — see the snapshot's
                // own note on why a 0 here would be a false reassurance.
                if let heat = s.portfolioHeatPct {
                    Text("Heat \(String(format: "%.1f", heat))% of \(String(format: "%.0f", s.heatCapPct))%")
                        .font(.caption2).foregroundStyle(s.isAtHeatCap ? .red : .secondary)
                }
                Text("\(s.openPositions) open").font(.caption2).foregroundStyle(.secondary)
            }
            if let f = s.heatFractionOfCap {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(s.isAtHeatCap ? Color.red : Color.accentColor)
                            .frame(width: geo.size.width * f)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    @ViewBuilder private func footer(_ s: StockSageWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if s.forwardCloses < s.forwardNeeded {
                Text("Forward test \(s.forwardCloses)/\(s.forwardNeeded)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(s.ageText()).font(.system(size: 9))
                .foregroundStyle(s.isStale() ? .orange : .secondary)
        }
    }
}

struct StockSageWidget: Widget {
    let kind = "StockSageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockSageProvider()) { entry in
            StockSageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("StockSageX")
        .description("The best opportunity from your last scan, and how much of the account is already at risk.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StockSageWidgetBundle: WidgetBundle {
    var body: some Widget { StockSageWidget() }
}
