import Testing
import Foundation
@testable import StockSage

// MARK: - Disk quote cache (pure round-trip + rebuild)

@MainActor
struct StockSageQuoteCacheTests {

    @Test func testHostCannotResolveTheOwnersDefaultQuoteCache() {
        #expect(StockSageStore.isRunningTests)
        #expect(StockSageQuoteCache.diskURL() == nil)
        #expect(StockSageQuoteCache.load() == nil)
    }

    @Test func sampleRowsNeverBecomeLastGoodCacheAndOldContaminationIsIgnored() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let real = StockSageQuoteCache.Entry(symbol: "MSFT", price: 400, previousClose: 390,
            time: t, marketTime: t, priceSource: .massiveSIP)
        let demo = StockSageQuoteCache.Entry(symbol: "AAPL", price: 227.1, previousClose: 226,
            time: t, marketTime: t, priceSource: .sample)
        let mixed = StockSageQuoteCache(entries: [demo, real], savedAt: t)
        let extracted = StockSageQuoteCache.from(symbols: mixed.symbols(marketFor: { _ in "NASDAQ" }), savedAt: t)
        #expect(extracted.entries == [real])
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old-contaminated-cache.json")
        let original = try JSONEncoder().encode(mixed)
        try original.write(to: url)
        let restored = try #require(StockSageQuoteCache.load(from: url))
        #expect(restored.entries == [real])
        #expect(restored.savedAt == t)
        #expect(try Data(contentsOf: url) == original) // recovery reads, never rewrites history
    }

    @Test func tradeSequenceSurvivesDiskRebuildAndLegacyFilesStayUnknown() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let seq: Int64 = 9_007_199_254_740_993
        let row = StockSageSymbol(symbol: "AAPL", market: "NASDAQ", quotes: [
            StockSageQuote(price: 151, previousPrice: 150, marketTime: t, massiveTradeSequence: seq)])
        let cache = StockSageQuoteCache.from(symbols: [row], savedAt: t)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sequence.json")
        cache.save(to: url)
        let restored = try #require(StockSageQuoteCache.load(from: url)).symbols(marketFor: { _ in "NASDAQ" })
        #expect(restored[0].latest?.massiveTradeSequence == seq)
        #expect(restored[0].latest?.marketTime == t)
        #expect(StockSageQuoteCache.from(symbols: restored, savedAt: t) == cache)
        let legacy = #"{"entries":[{"symbol":"AAPL","price":151,"previousClose":150,"time":0,"marketTime":0,"isNewListing":false}],"savedAt":0}"#
        let decoded = try JSONDecoder().decode(StockSageQuoteCache.self, from: Data(legacy.utf8))
        #expect(decoded.symbols(marketFor: { _ in "NASDAQ" })[0].latest?.massiveTradeSequence == nil)
    }

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

    // MARK: - Q11: retention merge — a throttled/partial sweep must not erase last-good prices

    // A pure merge: no disk involved, just the per-symbol union/replace rule itself.
    @Test func mergingReplacesReturnedSymbolsAndKeepsMissedOnesAtTheirOldEntry() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(3600)   // one hour later — the second sweep
        let previous = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 100, previousClose: 99, time: t0, marketTime: t0),
            .init(symbol: "2222.SR", price: 30, previousClose: 29, time: t0, marketTime: t0),
        ], savedAt: t0)
        // Second sweep is a throttled/partial one: only AAPL came back this time — 2222.SR was
        // MISSED (e.g. a `.core` cycle that didn't reach it, or the feed simply dropped it).
        let secondSweep = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 105, previousClose: 99, time: t1, marketTime: t1),
        ], savedAt: t1)

        let merged = StockSageQuoteCache.merging(previous: previous, new: secondSweep)

        // The symbol the feed actually returned this sweep is REPLACED with the new entry.
        let aapl = merged.entries.first { $0.symbol == "AAPL" }
        #expect(aapl?.price == 105)
        #expect(aapl?.marketTime == t1)

        // The MISSED symbol keeps its PREVIOUS entry verbatim — same price, same old marketTime —
        // so freshness (StockSageQuoteFreshness) still honestly reads it as stale/cached, never
        // silently re-stamped fresh by inheriting the new sweep's savedAt.
        let sr = merged.entries.first { $0.symbol == "2222.SR" }
        #expect(sr?.price == 30)
        #expect(sr?.marketTime == t0)
        #expect(merged.entries.count == 2)
        #expect(merged.savedAt == t1)   // savedAt reflects when THIS sweep ran, not any one entry
    }

    @Test func mergingWithNoPreviousCacheReturnsTheNewCacheUnchanged() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let new = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 105, previousClose: 99, time: t0),
        ], savedAt: t0)
        #expect(StockSageQuoteCache.merging(previous: nil, new: new) == new)
    }

    // MARK: - Q11 retention must not resurrect a REMOVED symbol (major fix 2026-09-06)
    //
    // Before this fix, `merging(previous:new:)` carried forward EVERY previous entry absent from
    // the new sweep, including a symbol `removeSymbol` had just dropped from `userSymbols` (which
    // never touches the disk cache) — so a removed watchlist ticker reappeared on the board at
    // next launch. `StockSageStore.retainedCacheEntries` is the pre-filter that fixes this: only
    // entries whose symbol is still in the tracked set survive to be merged forward at all.

    @Test func retainedCacheEntriesDropsAnUntrackedSymbol() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = [
            StockSageQuoteCache.Entry(symbol: "AAPL", price: 100, previousClose: 99, time: t0),
            StockSageQuoteCache.Entry(symbol: "REMOVED", price: 50, previousClose: 49, time: t0),
        ]
        let retained = StockSageStore.retainedCacheEntries(previous: previous, tracked: ["AAPL"])
        #expect(retained.map(\.symbol) == ["AAPL"])       // n=1: REMOVED dropped, never on disk again
    }

    @Test func retainedCacheEntriesMatchIsCaseInsensitive() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = [StockSageQuoteCache.Entry(symbol: "aapl", price: 100, previousClose: 99, time: t0)]
        let retained = StockSageStore.retainedCacheEntries(previous: previous, tracked: ["AAPL"])
        #expect(retained.count == 1)
    }

    @Test func retainedCacheEntriesKeepsEverythingWhenAllStillTracked() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = [
            StockSageQuoteCache.Entry(symbol: "AAPL", price: 100, previousClose: 99, time: t0),
            StockSageQuoteCache.Entry(symbol: "MSFT", price: 200, previousClose: 199, time: t0),
        ]
        let retained = StockSageStore.retainedCacheEntries(previous: previous, tracked: ["AAPL", "MSFT"])
        #expect(Set(retained.map(\.symbol)) == ["AAPL", "MSFT"])
    }

    @Test func retainedCacheEntriesEmptyTrackedSetDropsEverything() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = [StockSageQuoteCache.Entry(symbol: "AAPL", price: 100, previousClose: 99, time: t0)]
        #expect(StockSageStore.retainedCacheEntries(previous: previous, tracked: []).isEmpty)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageQuoteCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The full round trip: save a first sweep, merge a throttled second sweep OVER it via the
    // load(from:)/save(to:) temp-directory seam, reload, and confirm the merge survived the
    // actual disk write — never touching real Application Support.
    @Test func roundTripsTheRetentionMergeThroughDiskAtATempLocation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stocksage_quote_cache.json")

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(3600)
        let firstSweep = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 100, previousClose: 99, time: t0, marketTime: t0),
            .init(symbol: "2222.SR", price: 30, previousClose: 29, time: t0, marketTime: t0),
        ], savedAt: t0)
        firstSweep.save(to: url)

        let secondSweep = StockSageQuoteCache(entries: [
            .init(symbol: "AAPL", price: 105, previousClose: 99, time: t1, marketTime: t1),
        ], savedAt: t1)
        let merged = StockSageQuoteCache.merging(previous: StockSageQuoteCache.load(from: url), new: secondSweep)
        merged.save(to: url)

        let reloaded = StockSageQuoteCache.load(from: url)
        #expect(reloaded?.entries.count == 2)
        #expect(reloaded?.entries.first { $0.symbol == "AAPL" }?.price == 105)
        #expect(reloaded?.entries.first { $0.symbol == "2222.SR" }?.price == 30)
        #expect(reloaded?.entries.first { $0.symbol == "2222.SR" }?.marketTime == t0)
    }
}
