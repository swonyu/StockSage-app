import Testing
import Foundation
@testable import StockSage

// MARK: - Disk quote cache (pure round-trip + rebuild)

@MainActor
struct StockSageQuoteCacheTests {

    @Test func roundTripsAndRebuildsSymbolsLosslessly() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 110, previousClose: 100, time: t),
            .init(symbol: "BTC-USD", price: 50, previousClose: 50, time: t),
        ], savedAt: t)

        // Codable round-trip is exact (default Date strategy).
        let data = try! JSONEncoder().encode(cache)
        let back = try! JSONDecoder().decode(StockSageQuoteCache.self, from: data)
        #expect(back == cache)

        // Rebuild rows — latest price, change%, and label preserved.
        let syms = cache.symbols(marketFor: { _ in "M" })
        let aapl = syms.first { $0.symbol == "AAPL" }!
        #expect(aapl.latest?.price == 110)
        #expect(abs((aapl.latest?.changePercent ?? 0) - 10) < 1e-9)   // (110−100)/100 = 10%
        #expect(aapl.market == "M")

        // from(symbols:) is the inverse of symbols(marketFor:).
        let rebuilt = StockSageQuoteCache.from(symbols: syms, savedAt: t)
        #expect(rebuilt.entries.count == 2)
        #expect(rebuilt.entries.first { $0.symbol == "AAPL" }?.price == 110)
        #expect(rebuilt.entries.first { $0.symbol == "AAPL" }?.previousClose == 100)
        #expect(rebuilt.entries.first { $0.symbol == "AAPL" }?.marketTime == nil)   // no marketTime supplied in the source cache
    }

    // Q4 (2026-07-28 review): Entry had no marketTime, so a cache-restored row hit the
    // fail-closed `nil marketTime ⇒ STALE` rule (StockSageModels.swift) even when the cache
    // was written seconds ago. marketTime must round-trip through Codable AND survive the
    // symbols(marketFor:) → from(symbols:) rebuild, landing on the LATEST quote only.
    @Test func roundTripPreservesMarketTimeAndUnstalesFreshCache() {
        let mt = Date(timeIntervalSince1970: 1_700_000_000)
        let c = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 110, previousClose: 100, time: mt, marketTime: mt)
        ], savedAt: mt)

        // Codable round-trip preserves marketTime.
        let data = try! JSONEncoder().encode(c)
        let back = try! JSONDecoder().decode(StockSageQuoteCache.self, from: data)
        #expect(back == c)
        #expect(back.entries.first?.marketTime == mt)

        // Rebuild threads marketTime onto the LATEST quote only, and a 1h-old cache reads fresh.
        let row = c.symbols(marketFor: { _ in "M" })[0]
        #expect(row.latest?.marketTime == mt)
        #expect(row.isStale(asOf: mt.addingTimeInterval(3600)) == false)

        // from(symbols:) round-trips marketTime back into the Entry.
        let rebuilt = StockSageQuoteCache.from(symbols: [row], savedAt: mt)
        #expect(rebuilt.entries.first?.marketTime == mt)

        // Legacy file with no marketTime key still decodes, and stays fail-closed stale.
        let legacy = #"{"entries":[{"symbol":"A","price":1,"previousClose":1,"time":0,"isNewListing":false}],"savedAt":0}"#
        let legacyCache = try? JSONDecoder().decode(StockSageQuoteCache.self, from: Data(legacy.utf8))
        #expect(legacyCache != nil)
        #expect(legacyCache?.entries.first?.marketTime == nil)
        let legacyRow = legacyCache!.symbols(marketFor: { _ in "M" })[0]
        #expect(legacyRow.isStale(asOf: Date(timeIntervalSince1970: 0)) == true)
    }

    // Finding 4: `isNewListing` used to be dropped entirely on the way to disk (Entry had no
    // field for it), so a brand-new-listing row silently read back as a genuine flat 0%-move
    // "hold" after relaunch. It must now round-trip through Codable AND survive the
    // symbols(marketFor:) → from(symbols:) rebuild path (via the store's `newListings` set).
    @Test func roundTripPreservesIsNewListingFlag() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = StockSageQuoteCache(entries: [
            .init(symbol: "NEWCO", price: 42, previousClose: 42, time: t, isNewListing: true),
            .init(symbol: "AAPL", price: 110, previousClose: 100, time: t, isNewListing: false),
        ], savedAt: t)

        // Codable round-trip preserves the flag.
        let data = try! JSONEncoder().encode(cache)
        let back = try! JSONDecoder().decode(StockSageQuoteCache.self, from: data)
        #expect(back == cache)
        #expect(back.entries.first { $0.symbol == "NEWCO" }?.isNewListing == true)
        #expect(back.entries.first { $0.symbol == "AAPL" }?.isNewListing == false)

        // A cache entry with no explicit isNewListing (e.g. a pre-fix call site) defaults false —
        // never silently promotes a normal quote to "new listing".
        #expect(StockSageQuoteCache.Entry(symbol: "OLD", price: 10, previousClose: 10, time: t).isNewListing == false)

        // from(symbols:newListings:) threads the CURRENT newListings set back into the rebuilt
        // rows — this is the store's actual save path (StockSageStore.refresh()).
        let syms = cache.symbols(marketFor: { _ in "M" })
        let rebuilt = StockSageQuoteCache.from(symbols: syms, savedAt: t, newListings: ["NEWCO"])
        #expect(rebuilt.entries.first { $0.symbol == "NEWCO" }?.isNewListing == true)
        #expect(rebuilt.entries.first { $0.symbol == "AAPL" }?.isNewListing == false)
    }
}
