import Foundation

// MARK: - StockSage data models
//
// Integrated from the StockSage v32 package, but reworked as plain value types
// instead of the package's SwiftData `@Model` classes. Reasons:
//   * The package's `MarketStore` did `try! ModelContainer(for: MarketSymbol.self,
//     Quote.self)` in its initializer — a force-try that crashes the whole app if
//     the container can't be built. Value types in an in-memory store can't crash
//     on init.
//   * The `MarketSymbol` / `Quote` SwiftData models were *referenced* by the
//     package but never *included* in it, so it couldn't compile.
//   * `StockSage`-prefixed names avoid colliding with Chat A's existing
//     `MarketStore` (`Views/MarketsStub.swift`).
//
// These are the minimal shapes the signal engine, briefing service, and monitor
// actually read. When Chat A's live Yahoo feed lands, it just produces these.

/// One price observation for a symbol.
struct StockSageQuote: Sendable, Equatable, Identifiable {
    let id: UUID
    let price: Double
    /// The immediately-prior price, used by the signal engine to compute change.
    let previousPrice: Double
    /// When we OBSERVED/fetched this quote (defaults to now). Not a freshness signal on its own.
    let time: Date
    /// The quote's own MARKET timestamp from the feed (nil when the feed omitted it). Distinct from
    /// `time` so staleness only judges a REAL market time — a nil one means "can't judge", never stale.
    let marketTime: Date?

    init(id: UUID = UUID(), price: Double, previousPrice: Double, time: Date = Date(), marketTime: Date? = nil) {
        self.id = id
        self.price = price
        self.previousPrice = previousPrice
        self.time = time
        self.marketTime = marketTime
    }

    /// Percent change vs the previous price. Guards divide-by-zero (a brand-new
    /// symbol with no prior price reports 0% rather than NaN/inf).
    var changePercent: Double {
        guard previousPrice != 0 else { return 0 }
        return ((price - previousPrice) / previousPrice) * 100
    }
}

/// A tracked instrument plus its observed quotes (most recent last).
struct StockSageSymbol: Sendable, Equatable, Identifiable {
    let id: UUID
    let symbol: String
    /// Free-text market label, e.g. "TASI", "NASDAQ". Surfaced in alert titles.
    let market: String
    var quotes: [StockSageQuote]

    init(id: UUID = UUID(), symbol: String, market: String, quotes: [StockSageQuote] = []) {
        self.id = id
        self.symbol = symbol
        self.market = market
        self.quotes = quotes
    }

    /// Most recent quote, if any.
    var latest: StockSageQuote? { quotes.last }

    /// Is the latest quote materially old for this asset class? Crypto trades 24/7 so a quote should
    /// be fresh; equities/FX/indices close, so tolerate an overnight gap but flag a multi-day
    /// (weekend/holiday) stale close. false when there's no quote, or the quote's time is the fetch
    /// time (feed gave no real market timestamp) — can't judge, so don't cry wolf. Mirrors the
    /// GE-flip / regime per-item staleness precedent.
    func isStale(asOf now: Date = Date()) -> Bool {
        StockSageQuoteFreshness.isStale(symbol: symbol, marketTime: latest?.marketTime, asOf: now)
    }
}

/// ONE definition of "is this quote materially old?", shared by the per-row display badge AND the
/// price-alert firing gate so they can never disagree. Crypto trades 24/7 → fresh fast (6h);
/// equities/FX/indices close, so tolerate an overnight gap (48h). nil marketTime ⇒ can't judge ⇒
/// NOT stale (don't false-alarm a badge, and don't suppress an alert when the feed simply omitted
/// a timestamp — Yahoo normally supplies one).
enum StockSageQuoteFreshness {
    nonisolated static func isStale(symbol: String, marketTime: Date?, asOf now: Date = Date()) -> Bool {
        guard let t = marketTime else { return false }
        let tolerance: TimeInterval = StockSageAllocation.assetClass(symbol) == "Crypto" ? 6 * 3600 : 48 * 3600
        return now.timeIntervalSince(t) > tolerance
    }
}
