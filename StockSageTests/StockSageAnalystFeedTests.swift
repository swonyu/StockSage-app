import Foundation
import Testing
@testable import StockSage

@Suite("Watchlist analyst and guidance feed projection")
struct StockSageAnalystFeedTests {
    private typealias E = StockSageMassiveEvents
    private typealias F = StockSageAnalystFeed
    private let now = Date(timeIntervalSince1970: 1_788_696_000) // 2026-09-06 12:00 UTC

    private func event(_ symbol: String, _ feed: E.Feed, daysAgo: Double) -> E.Event {
        .init(id: "\(symbol)-\(feed.rawValue)", symbol: symbol, feed: feed, date: now.addingTimeInterval(-daysAgo * 86_400),
              headline: "Observed \(feed.rawValue)", details: [feed.source], link: nil)
    }
    private func answered(_ symbol: String, _ feed: E.Feed, _ event: E.Event?, checkedAgo: Double = 3_600) -> E.Observation {
        .init(symbol: symbol, feed: feed, checkedAt: now.addingTimeInterval(-checkedAgo), outcome: .answered, event: event)
    }

    @Test func onlyWatchlistSymbolsProjectAndDuplicatesOrUncoveredListingsDoNot() {
        let checks: [String: [E.Feed: E.Observation]] = [
            "AAPL": [.ratings: answered("AAPL", .ratings, event("AAPL", .ratings, daysAgo: 1)),
                     .guidance: answered("AAPL", .guidance, nil)],
            "MSFT": [.ratings: answered("MSFT", .ratings, event("MSFT", .ratings, daysAgo: 0)),
                     .guidance: answered("MSFT", .guidance, nil)]]
        let feed = F.project(watchlist: ["aapl", "AAPL", "2222.SR"], etfSymbols: [], checks: checks, now: now)
        #expect(feed.items.map(\.symbol) == ["AAPL"])
        #expect(feed.items.first?.event.feed == .ratings)
        #expect(feed.statuses == ["2222.SR: analyst ratings and company guidance cover US-listed tickers only; not checked."])
        #expect(feed.quiet.isEmpty)
    }

    @Test func itemsAreNewestFirstAcrossSymbolsAndFeeds() {
        let checks: [String: [E.Feed: E.Observation]] = [
            "AAPL": [.ratings: answered("AAPL", .ratings, event("AAPL", .ratings, daysAgo: 1)),
                     .guidance: answered("AAPL", .guidance, event("AAPL", .guidance, daysAgo: 3))],
            "MSFT": [.ratings: answered("MSFT", .ratings, nil),
                     .guidance: answered("MSFT", .guidance, event("MSFT", .guidance, daysAgo: 0))]]
        let feed = F.project(watchlist: ["AAPL", "MSFT"], etfSymbols: [], checks: checks, now: now)
        #expect(feed.items.map(\.id) == ["MSFT|guidance|MSFT-guidance", "AAPL|ratings|AAPL-ratings", "AAPL|guidance|AAPL-guidance"])
        #expect(feed.statuses.isEmpty)
    }

    @Test func staleUnavailableAndUncheckedChecksBecomeStatusLinesNotItems() {
        let unavailable = E.Observation(symbol: "AAPL", feed: .guidance, checkedAt: now.addingTimeInterval(-60),
                                        outcome: .unavailable, event: nil, failure: .http(503))
        let checks: [String: [E.Feed: E.Observation]] = [
            "AAPL": [.ratings: answered("AAPL", .ratings, event("AAPL", .ratings, daysAgo: 2), checkedAgo: 2 * 86_400),
                     .guidance: unavailable]]
        let feed = F.project(watchlist: ["AAPL", "MSFT"], etfSymbols: [], checks: checks, now: now)
        #expect(feed.items.isEmpty && feed.quiet.isEmpty)
        #expect(feed.statuses.count == 4)
        #expect(feed.statuses[0].hasPrefix("AAPL · ") && feed.statuses[0].contains("stale check"))
        #expect(feed.statuses[1].hasPrefix("AAPL · ") && feed.statuses[1].contains("not an empty result")
                && feed.statuses[1].contains(E.Failure.http(503).message))
        #expect(feed.statuses[2] == "MSFT · \(E.Feed.ratings.source): not checked.")
        #expect(feed.statuses[3] == "MSFT · \(E.Feed.guidance.source): not checked.")
    }

    @Test func etfIsNotApplicableEvenWithACachedCorporateEvent() {
        let checks: [String: [E.Feed: E.Observation]] = [
            "SPY": [.ratings: answered("SPY", .ratings, event("SPY", .ratings, daysAgo: 0))]]
        let feed = F.project(watchlist: ["spy"], etfSymbols: ["SPY"], checks: checks, now: now)
        #expect(feed.items.isEmpty && feed.quiet.isEmpty)
        #expect(feed.statuses == ["SPY: not applicable to this ETF; corporate analyst ratings and guidance are withheld."])
    }

    @Test func currentChecksWithNoQualifyingEventAreQuietNotMissing() {
        let checks: [String: [E.Feed: E.Observation]] = [
            "AAPL": [.ratings: answered("AAPL", .ratings, nil), .guidance: answered("AAPL", .guidance, nil)]]
        let feed = F.project(watchlist: ["AAPL"], etfSymbols: [], checks: checks, now: now)
        #expect(feed.items.isEmpty && feed.statuses.isEmpty)
        #expect(feed.quiet == ["AAPL"])
    }
}
