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
        // A TIMELINE, not a single entry (2026-09-11). WidgetKit renders an entry once and keeps
        // showing that bitmap; the view is NOT re-evaluated while it sits on screen. With one
        // entry, the age text and the stale styling froze at render time, so a snapshot could read
        // "12m ago" for hours — the widget asserting freshness it could not know. The 30-minute
        // refresh below is a HINT iOS routinely ignores, so it cannot be relied on to correct it.
        //
        // Each entry's `date` is the moment iOS should display it, and the view ages every figure
        // against that date rather than against `Date()`. The clock therefore advances correctly
        // with no refresh at all. This half is useless without that one, and vice versa.
        let now = Date()
        let snapshot = StockSageWidgetSnapshot.load()
        var dates: [Date] = []
        for step in 0..<12 { dates.append(now.addingTimeInterval(Double(step) * 5 * 60)) }   // 1h, 5-min
        for hour in 1...24 { dates.append(now.addingTimeInterval(Double(hour) * 3600)) }     // then hourly
        // The exact moment this snapshot turns stale, computed from asOf so the styling flips on
        // the boundary rather than at the next arbitrary step.
        if let asOf = snapshot?.asOf {
            let boundary = asOf.addingTimeInterval(StockSageWidgetSnapshot.staleAfter)
            if boundary > now { dates.append(boundary) }
        }
        let entries = dates.sorted().map { StockSageEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
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
        .opacity(s.isStale(now: entry.date) ? 0.55 : 1)
    }

    @ViewBuilder private func header(_ s: StockSageWidgetSnapshot) -> some View {
        HStack(spacing: 4) {
            Text("Best opportunity").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(s.sourceText).font(.system(size: 8, weight: .bold))
                .foregroundStyle(s.isSampleData || s.isCachedData == true ? .orange : .secondary)
        }
    }

    @ViewBuilder private func heat(_ s: StockSageWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                // Heat only prints when an account size made it computable — see the snapshot's
                // own note on why a 0 here would be a false reassurance.
                if let heat = s.portfolioHeatPct {
                    Text("Paper heat \(String(format: "%.1f", heat))% of \(String(format: "%.0f", s.heatCapPct))%")
                        .font(.caption2).foregroundStyle(s.isAtHeatCap ? .red : .secondary)
                }
                Text(s.paperPositionsText).font(.caption2).foregroundStyle(.secondary)
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
            if let progress = s.forwardProgressText {
                Text(progress)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            // Aged against the ENTRY's date, not Date(): see getTimeline. A rendered bitmap is
            // not re-evaluated, so Date() froze this text at render time.
            Text(s.ageText(now: entry.date)).font(.system(size: 9))
                .foregroundStyle(s.isStale(now: entry.date) ? .orange : .secondary)
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
        .description("A rule-based idea from your last scan, and simulated paper-account risk.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StockSageWidgetBundle: WidgetBundle {
    var body: some Widget { StockSageWidget() }
}
