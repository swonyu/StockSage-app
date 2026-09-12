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

/// Observation origin, not a configured preference or proof of freshness. Nil in older
/// caches means unknown; only a provider parser/stream (or explicit sample seed) sets it.
nonisolated enum StockSagePriceSource: String, Codable, Sendable {
    case massiveSIP, massiveDaily, yahoo, yahooBars, eodhd, sample

    var label: String {
        switch self {
        case .massiveSIP: "Massive SIP"
        case .massiveDaily: "Massive daily bars"
        case .yahoo: "Yahoo"
        case .yahooBars: "Yahoo bars"
        case .eodhd: "EODHD"
        case .sample: "sample"
        }
    }
}

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
    /// Only Massive T-channel sequence for this symbol; never a quote-channel/provider ID.
    let massiveTradeSequence: Int64?
    let priceSource: StockSagePriceSource?
    let previousCloseSource: StockSagePriceSource?
    /// Timestamp of the provider quote carrying the previous-close field, NOT the closing session.
    let previousCloseQuoteTime: Date?

    // `nonisolated` (W3): plain value-struct construction, no MainActor state touched — mirrors
    // `StockSageIdea`'s own `nonisolated init`/`withLivePrice` precedent just above in
    // StockSageStore.swift, needed so a `nonisolated static` pure merge helper
    // (StockSageStore.mergedPolledQuotes) can build fresh quotes without hopping actors.
    nonisolated init(id: UUID = UUID(), price: Double, previousPrice: Double, time: Date = Date(),
                     marketTime: Date? = nil, massiveTradeSequence: Int64? = nil,
                     priceSource: StockSagePriceSource? = nil,
                     previousCloseSource: StockSagePriceSource? = nil, previousCloseQuoteTime: Date? = nil) {
        self.id = id
        self.price = price
        self.previousPrice = previousPrice
        self.time = time
        self.marketTime = marketTime
        self.massiveTradeSequence = massiveTradeSequence
        self.priceSource = priceSource
        self.previousCloseSource = previousCloseSource
        self.previousCloseQuoteTime = previousCloseQuoteTime
    }

    nonisolated func hasSessionBaseline(symbol: String, at marketTime: Date?) -> Bool {
        guard priceSource != .sample, previousPrice.isFinite, previousPrice > 0,
              previousCloseSource == .massiveSIP || previousCloseSource == .yahoo,
              let baseline = previousCloseQuoteTime, let marketTime,
              baseline.timeIntervalSince1970.isFinite, marketTime.timeIntervalSince1970.isFinite,
              baseline <= marketTime else { return false }
        if StockSageMassive.covers(symbol) {
            guard StockSageMarketHours.nasdaqDay(at: baseline)?.trading == true,
                  StockSageMarketHours.nasdaqDay(at: marketTime)?.trading == true else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            return calendar.isDate(baseline, inSameDayAs: marketTime)
        }
        // Foreign listings have no US-stream carry-forward: accept only the direct provider pair.
        return baseline == marketTime
    }

    /// Percent change vs the previous price. Guards divide-by-zero (a brand-new
    /// symbol with no prior price reports 0% rather than NaN/inf).
    var changePercent: Double {
        guard previousPrice != 0 else { return 0 }
        // abs() divisor (owner-signed 2026-07-27, Gemini-report item 4): identical for every
        // positive-price asset this app trades; guards sign-inversion if a negative-price
        // instrument (commodity futures class) ever enters the universe.
        return ((price - previousPrice) / abs(previousPrice)) * 100
    }
}

/// A tracked instrument plus its observed quotes (most recent last).
struct StockSageSymbol: Sendable, Equatable, Identifiable {
    let id: UUID
    let symbol: String
    /// Free-text market label, e.g. "TASI", "NASDAQ". Surfaced in alert titles.
    let market: String
    var quotes: [StockSageQuote]

    // `nonisolated` (W3) — same reason as StockSageQuote's init just above.
    nonisolated init(id: UUID = UUID(), symbol: String, market: String, quotes: [StockSageQuote] = []) {
        self.id = id
        self.symbol = symbol
        self.market = market
        self.quotes = quotes
    }

    /// Most recent quote, if any.
    var latest: StockSageQuote? { quotes.last }
    var sessionChangePercent: Double? {
        guard let latest, latest.price.isFinite, latest.price > 0 else { return nil }
        // Keep explicitly labelled illustrative previews; sample numbers cannot establish
        // a baseline for a real stream tick (hasSessionBaseline rejects them).
        if latest.priceSource == .sample { return latest.changePercent }
        guard latest.hasSessionBaseline(symbol: symbol, at: latest.marketTime) else { return nil }
        return latest.changePercent
    }

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
/// equities/FX/indices close, so tolerate an overnight gap (48h). nil marketTime ⇒ STALE —
/// FAIL-CLOSED (owner-signed contract change 2026-07-27, Gemini-report item 2): a quote whose
/// freshness cannot be verified must never pass an alert gate; the stale-self-heal retry loop
/// re-fetches such rows each refresh, so a transient feed omission self-corrects.
enum StockSageQuoteFreshness {
    nonisolated static func isStale(symbol: String, marketTime: Date?, asOf now: Date = Date()) -> Bool {
        guard let t = marketTime else { return true }
        // A stamp in the FUTURE gives a negative age, which is never greater than the tolerance,
        // so the old comparison called it fresh — the one direction a fail-closed gate must not
        // fail open. -60s mirrors acceptsQuote's already-ratified clock-skew allowance rather
        // than introducing a second number.
        let age = now.timeIntervalSince(t)
        guard age.isFinite, age >= -60 else { return true }
        let tolerance: TimeInterval = StockSageAllocation.assetClass(symbol) == "Crypto" ? 6 * 3600 : 48 * 3600
        return age > tolerance
    }
}
