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

        init(symbol: String, price: Double, previousClose: Double, time: Date, isNewListing: Bool = false) {
            self.symbol = symbol
            self.price = price
            self.previousClose = previousClose
            self.time = time
            self.isNewListing = isNewListing
        }
    }
    var entries: [Entry]
    var savedAt: Date

    /// Extract a cache from live symbol rows (the last quote per symbol). Touches the
    /// MainActor-isolated quote models, so it runs on the main actor. `newListings` is the
    /// store's per-refresh set of brand-new-listing symbols (uppercased) — threaded through so
    /// the flag survives a relaunch instead of it being dropped entirely (Finding 4 fix).
    @MainActor static func from(symbols: [StockSageSymbol], savedAt: Date, newListings: Set<String> = []) -> StockSageQuoteCache {
        let entries = symbols.compactMap { s -> Entry? in
            guard let q = s.latest else { return nil }
            return Entry(symbol: s.symbol, price: q.price, previousClose: q.previousPrice, time: q.time,
                        isNewListing: newListings.contains(s.symbol.uppercased()))
        }
        return StockSageQuoteCache(entries: entries, savedAt: savedAt)
    }

    /// Rebuild watchlist rows from the cache — two quotes (prior close, then last price) so
    /// the change% reads identically to the live path — labeled via `marketFor`. Builds the
    /// MainActor-isolated quote models, so it runs on the main actor.
    @MainActor func symbols(marketFor: (String) -> String) -> [StockSageSymbol] {
        entries.map { e in
            StockSageSymbol(symbol: e.symbol, market: marketFor(e.symbol), quotes: [
                StockSageQuote(price: e.previousClose, previousPrice: e.previousClose, time: e.time.addingTimeInterval(-86_400)),
                StockSageQuote(price: e.price, previousPrice: e.previousClose, time: e.time),
            ])
        }
    }

    // MARK: Thin file I/O (Application Support)

    nonisolated static func diskURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("salehman_quote_cache.json")
    }

    nonisolated static func load() -> StockSageQuoteCache? {
        guard let url = diskURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StockSageQuoteCache.self, from: data)
    }

    nonisolated func save() {
        guard let url = Self.diskURL(), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
