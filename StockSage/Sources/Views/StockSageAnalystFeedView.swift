import Foundation
#if os(macOS)
import SwiftUI
#endif

/// Pure projection of the store's cached Massive/Benzinga company-event checks (ratings and
/// guidance) onto the watchlist. It makes no request and keeps no storage; the Markets sweep
/// (`StockSageStore.refreshCompanyEvents`) owns the checks, their windows and their freshness.
nonisolated enum StockSageAnalystFeed {
    typealias Events = StockSageMassiveEvents
    static let feeds: [Events.Feed] = [.ratings, .guidance]

    nonisolated struct Item: Equatable, Identifiable {
        let symbol: String
        let event: Events.Event
        var id: String { symbol + "|" + event.feed.rawValue + "|" + event.id }
    }

    nonisolated struct Projection: Equatable {
        /// Current selected events, newest first.
        var items: [Item] = []
        /// Symbols whose ratings and guidance checks are both current with no qualifying event.
        var quiet: [String] = []
        /// One line per uncovered, ETF, unchecked, unavailable or stale symbol/feed.
        var statuses: [String] = []
    }

    /// - Parameters:
    ///   - watchlist: the user's watchlist symbols, in display order; duplicates are ignored.
    ///   - etfSymbols: uppercased symbols known to be ETFs; their corporate feeds are not applicable.
    ///   - checks: `StockSageStore.companyEventChecks`.
    /// - Returns: items only from answered checks that are fresh at `now`; everything else is a status line.
    static func project(watchlist: [String], etfSymbols: Set<String>,
                        checks: [String: [Events.Feed: Events.Observation]], now: Date) -> Projection {
        var result = Projection()
        var seen = Set<String>()
        for raw in watchlist {
            let symbol = raw.uppercased()
            guard seen.insert(symbol).inserted else { continue }
            guard StockSageMassive.covers(symbol) else {
                result.statuses.append("\(symbol): analyst ratings and company guidance cover US-listed tickers only; not checked.")
                continue
            }
            guard !etfSymbols.contains(symbol) else {
                result.statuses.append("\(symbol): not applicable to this ETF; corporate analyst ratings and guidance are withheld.")
                continue
            }
            var quiet = true
            for feed in feeds {
                let observation = checks[symbol]?[feed]
                guard let observation, observation.outcome == .answered, observation.fresh(at: now) else {
                    quiet = false
                    result.statuses.append("\(symbol) · " + Events.statusLine(feed, observation: observation, now: now))
                    continue
                }
                if let event = observation.event {
                    quiet = false
                    result.items.append(.init(symbol: symbol, event: event))
                }
            }
            if quiet { result.quiet.append(symbol) }
        }
        result.items.sort {
            $0.event.date != $1.event.date ? $0.event.date > $1.event.date
                : ($0.symbol, $0.event.feed.rawValue) < ($1.symbol, $1.event.feed.rawValue)
        }
        return result
    }
}

#if os(macOS)
/// Watchlist analyst-rating and company-guidance feed. Benzinga text stays in this local view:
/// no export, sharing or notification path.
struct StockSageAnalystFeedView: View {
    @ObservedObject var store: StockSageStore

    var body: some View {
        let watchlist = store.watchlistSymbols
        // Same ETF rule as Browse's ETF filter: the curated market label, not the ticker.
        let projection = StockSageAnalystFeed.project(
            watchlist: watchlist.map(\.symbol),
            etfSymbols: Set(watchlist.filter { $0.market.localizedCaseInsensitiveContains("ETF") }.map { $0.symbol.uppercased() }),
            checks: store.companyEventChecks, now: Date())
        if !watchlist.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Analyst and guidance feed").font(.headline)
                Text("Latest cached Massive/Benzinga rating changes (7-day window) and company guidance updates (14-day window) for your watchlist, newest first. Analyst opinions and company guidance are not StockSage targets or trade instructions.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if projection.items.isEmpty {
                    Text("No current rating change or guidance update to show.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(projection.items) { item in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("\(item.symbol) · \(item.event.headline)").font(.callout.weight(.semibold))
                        ForEach(Array(item.event.details.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if let link = item.event.link {
                            Link("Read source", destination: link).font(.caption)
                        }
                    }
                    .padding(.vertical, DS.Space.xxs)
                }
                if !projection.quiet.isEmpty {
                    Text("Checked, no qualifying update in the queried window: " + projection.quiet.joined(separator: ", ") + ".")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !projection.statuses.isEmpty {
                    DisclosureGroup("Coverage status · \(projection.statuses.count)") {
                        ForEach(projection.statuses, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("watchlist.analystFeed")
        }
    }
}
#endif
