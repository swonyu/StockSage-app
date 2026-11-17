import Foundation

// MARK: - Disk quote cache
//
// Persists the last successful quote per symbol so the board shows real last-good
// numbers INSTANTLY on launch (and stays useful offline) instead of fabricated sample
// data, and a refresh re-hammers the feed less. The Codable model + the rebuild/extract
// are pure (unit-tested); the actual file read/write is a thin Application-Support layer.
// Honest: rebuilt rows are last-good as of `savedAt`, not live — the UI labels them so.

nonisolated struct StockSageQuoteCache: Codable, Sendable, Equatable {
    nonisolated struct Entry: Codable, Sendable, Equatable {
        let symbol: String
        let price: Double
        let previousClose: Double
        let time: Date
        /// True when this quote was a brand-new listing (no real previousClose) when the cache
        /// was saved — threaded through from `LiveQuote.isNewListing` (Finding 4 fix) so a
        /// relaunch's cached row doesn't silently misread the flat placeholder as a genuine
        /// 0%-move "hold". A cache file written before this field existed simply won't decode
        /// (same fallback as no cache today — `load()` returns nil) rather than guess the flag.
        let isNewListing: Bool
        /// The quote's own MARKET timestamp when it was cached. Optional, so a cache file written
        /// before this field existed still decodes (synthesized `decodeIfPresent`) — unlike
        /// `isNewListing` above, which is non-optional and hard-fails an old file. WITHOUT this,
        /// every restored row hit the fail-closed `nil marketTime ⇒ STALE` rule (owner-signed
        /// 2026-07-27) and the whole board badged stale on launch even when the cache was seconds old.
        let marketTime: Date?
        /// Optional for backward-compatible decode; preserves equal-time ordering on relaunch.
        let massiveTradeSequence: Int64?
        let priceSource: StockSagePriceSource?
        let denomination: StockSagePriceDenomination?
        let previousCloseSource: StockSagePriceSource?
        let previousCloseQuoteTime: Date?

        init(symbol: String, price: Double, previousClose: Double, time: Date,
             isNewListing: Bool = false, marketTime: Date? = nil, massiveTradeSequence: Int64? = nil,
             priceSource: StockSagePriceSource? = nil,
             previousCloseSource: StockSagePriceSource? = nil, previousCloseQuoteTime: Date? = nil,
             denomination: StockSagePriceDenomination? = nil) {
            self.symbol = symbol
            self.price = price
            self.previousClose = previousClose
            self.time = time
            self.isNewListing = isNewListing
            self.marketTime = marketTime
            self.massiveTradeSequence = massiveTradeSequence
            self.priceSource = priceSource
            self.denomination = denomination
            self.previousCloseSource = previousCloseSource
            self.previousCloseQuoteTime = previousCloseQuoteTime
        }
    }
    var entries: [Entry]
    var savedAt: Date

    /// Restore membership from today's tracking, not the last successful refresh. Keep
    /// retained observations and the cache clock unchanged; this never rewrites the file.
    nonisolated func retaining(tracked: Set<String>) -> StockSageQuoteCache {
        StockSageQuoteCache(entries: StockSageStore.retainedCacheEntries(
            previous: entries, tracked: Set(tracked.map { $0.uppercased() })), savedAt: savedAt)
    }

    /// Extract a cache from live symbol rows (the last quote per symbol). Touches the
    /// MainActor-isolated quote models, so it runs on the main actor. `newListings` is the
    /// store's per-refresh set of brand-new-listing symbols (uppercased) — threaded through so
    /// the flag survives a relaunch instead of it being dropped entirely (Finding 4 fix).
    @MainActor static func from(symbols: [StockSageSymbol], savedAt: Date, newListings: Set<String> = []) -> StockSageQuoteCache {
        let entries = symbols.compactMap { s -> Entry? in
            guard let q = s.latest, q.priceSource != .sample,
                  q.priceSource != .manualEntry, q.priceSource != .importedRecord else { return nil }
            return Entry(symbol: s.symbol, price: q.price, previousClose: q.previousPrice, time: q.time,
                        isNewListing: newListings.contains(s.symbol.uppercased()), marketTime: q.marketTime,
                        massiveTradeSequence: q.massiveTradeSequence, priceSource: q.priceSource,
                        previousCloseSource: q.previousCloseSource, previousCloseQuoteTime: q.previousCloseQuoteTime,
                        denomination: q.denomination)
        }
        return StockSageQuoteCache(entries: entries, savedAt: savedAt)
    }

    /// Rebuild watchlist rows from the cache — two quotes (prior close, then last price) so
    /// the change% reads identically to the live path — labeled via `marketFor`. Builds the
    /// MainActor-isolated quote models, so it runs on the main actor.
    @MainActor func symbols(marketFor: (String) -> String) -> [StockSageSymbol] {
        entries.filter { $0.priceSource != .manualEntry && $0.priceSource != .importedRecord }.map { e in
            StockSageSymbol(symbol: e.symbol, market: marketFor(e.symbol), quotes: [
                StockSageQuote(price: e.previousClose, previousPrice: e.previousClose, time: e.time.addingTimeInterval(-86_400)),
                StockSageQuote(price: e.price, previousPrice: e.previousClose, time: e.time, marketTime: e.marketTime,
                               massiveTradeSequence: e.massiveTradeSequence, priceSource: e.priceSource,
                               previousCloseSource: e.previousCloseSource, previousCloseQuoteTime: e.previousCloseQuoteTime,
                               denomination: e.denomination),
            ])
        }
    }

    // MARK: Retention merge (Q11) — a throttled/partial sweep must not erase last-good prices

    /// Merge a freshly-written cache OVER the previous on-disk one so a partial/throttled sweep
    /// (e.g. the monitor's `.core` cycle, or a stream-gap top-up) can never ERASE a symbol's
    /// last-good disk entry merely because the feed missed it THIS cycle. Per symbol: `new`
    /// wins wherever it has an entry; any symbol present ONLY in `previous` carries its entry
    /// forward UNCHANGED — same price, same old `marketTime` — so freshness
    /// (`StockSageQuoteFreshness`) still honestly reads it as stale/cached, never silently
    /// re-stamped fresh. On-screen behavior is untouched by this — the board still only shows
    /// what `committed` (the caller's in-memory result) contains; this only protects what
    /// SURVIVES ON DISK for the next launch. Pure — no disk I/O — so it's unit-testable without
    /// touching Application Support.
    nonisolated static func merging(previous: StockSageQuoteCache?, new: StockSageQuoteCache) -> StockSageQuoteCache {
        guard let previous else { return new }
        let newKeys = Set(new.entries.map { $0.symbol.uppercased() })
        let carried = previous.entries.filter { !newKeys.contains($0.symbol.uppercased()) }
        return StockSageQuoteCache(entries: new.entries + carried, savedAt: new.savedAt)
    }

    // MARK: Thin file I/O (Application Support)

    nonisolated static func diskURL() -> URL? {
        guard !StockSageStore.isRunningTests else { return nil }
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        // STANDALONE DEVIATION (review HIGH, 2026-07-16): own filename — see
        // StockSageHistoryCache for the two-writer rationale.
        return dir.appendingPathComponent("stocksage_quote_cache.json")
    }

    /// `url` overrides the real Application Support location — used by tests to round-trip
    /// through a temp directory instead of touching the real disk cache (mirrors
    /// StockSageCatalystRecordCache's seam).
    nonisolated static func load(from url: URL? = nil) -> StockSageQuoteCache? {
        guard let url = url ?? diskURL(), let data = try? Data(contentsOf: url) else { return nil }
        guard var cache = try? JSONDecoder().decode(StockSageQuoteCache.self, from: data) else { return nil }
        // Recover files written when a demo's newer clock could beat a real market close.
        // Ignore only explicitly synthetic entries; retain genuine/legacy data unchanged.
        cache.entries.removeAll { $0.priceSource == .sample }
        return cache
    }

    nonisolated func save(to url: URL? = nil) {
        guard let url = url ?? Self.diskURL(), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
