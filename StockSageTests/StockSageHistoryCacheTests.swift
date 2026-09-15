import Testing
import Foundation
@testable import StockSage

// MARK: - Disk history cache (pure model + panel builder)

struct StockSageHistoryCacheTests {

    typealias HC = StockSageHistoryCache

    /// Deterministic price history: `closes[i] = base + i`, dates one day apart from epoch.
    /// OHLC mirror closes; volumes = closes. Newest LAST (as the real feed produces).
    private func history(_ symbol: String, bars: Int, base: Double = 0) -> StockSagePriceHistory {
        let closes = (0..<bars).map { base + Double($0) }
        let dates = (0..<bars).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
        return StockSagePriceHistory(symbol: symbol, dates: dates, opens: closes,
                                     highs: closes, lows: closes, closes: closes, volumes: closes)
    }

    @Test func diskURLSkipsResolverInTestHostAndUsesItInProductionMode() {
        #expect(StockSageStore.isRunningTests)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageHistoryCachePathProbe-\(UUID().uuidString)", isDirectory: true)
        var resolverCalls = 0
        let resolveApplicationSupport = {
            resolverCalls += 1
            return dir
        }

        #expect(HC.diskURL(isRunningTests: StockSageStore.isRunningTests,
                           resolveApplicationSupport: resolveApplicationSupport) == nil)
        #expect(resolverCalls == 0)

        resolverCalls = 0
        #expect(HC.diskURL(isRunningTests: false,
                           resolveApplicationSupport: resolveApplicationSupport)
                == dir.appendingPathComponent("stocksage_history_cache.json"))
        #expect(resolverCalls == 1)
    }

    @Test func injectedPathKeepsSerializedMergeAndRoundTripOffApplicationSupport() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageHistoryCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stocksage_history_cache.json")
        let day = Date(timeIntervalSince1970: 100 * 86_400)
        let disk = HC.from(
            histories: ["AAA": history("AAA", bars: 2, base: 10),
                        "BBB": history("BBB", bars: 2, base: 20)],
            universe: ["AAA", "BBB"], savedAt: day)
        disk.save(to: url)

        let candidate = HC.from(histories: ["AAA": history("AAA", bars: 2, base: 100)],
                                universe: ["AAA"], savedAt: day)
        await candidate.saveSerialized(to: url)

        let restored = try #require(HC.load(from: url))
        #expect(Set(restored.priceHistories().keys) == ["AAA", "BBB"])
        #expect(restored.priceHistories()["AAA"]?.closes == [100, 101])
        #expect(restored.priceHistories()["BBB"]?.closes == [20, 21])
        #expect(restored.schemaVersion == HC.currentSchemaVersion)
    }

    // 1. Codec round-trip: encode → decode preserves entries and parallel-array equality.
    @Test func codecRoundTripPreservesEntries() throws {
        let e = HC.Entry(symbol: "AAA",
                         dates: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 86_400)],
                         opens: [1, 2], highs: [1, 2], lows: [1, 2], closes: [10, 11], volumes: [100, 200])
        let cache = HC(schemaVersion: HC.currentSchemaVersion, entries: [e], savedAt: Date(timeIntervalSince1970: 500))
        let data = try JSONEncoder().encode(cache)
        let back = try #require(HC.decode(data))          // hard: must decode
        #expect(back == cache)                            // full value equality (all parallel arrays)
        #expect(back.entries.first?.closes == [10, 11])   // spot-check a reconstructed field
        #expect(back.entries.first?.dates.count == back.entries.first?.closes.count)  // arrays stay equal-length
    }

    // 2. Trim: a 400-bar history keeps exactly the last 252 (149…400 for closes = 1…400).
    @Test func fromTrimsToLastMaxBars() {
        // closes = base 1 → [1,2,…,400]; suffix(252) = indices 148…399 = values 149…400.
        // 400 − 252 + 1 = 149 (first kept); 400 (last kept). Derived by hand.
        let h = history("AAA", bars: 400, base: 1)
        let cache = HC.from(histories: ["AAA": h], universe: ["AAA"], savedAt: Date(timeIntervalSince1970: 0), maxBars: 252)
        let entry = cache.entries.first
        #expect(cache.entries.count == 1)
        #expect(entry?.closes.count == 252)
        #expect(entry?.closes.first == 149)
        #expect(entry?.closes.last == 400)
        #expect(entry?.dates.count == 252)   // dates trimmed in lock-step with closes
    }

    @Test func defaultRoundTripPreservesTheFullMomentumLookbackAndItsAnchor() throws {
        let source = history("AAA", bars: 253, base: 1_000)
        let falling = StockSagePriceHistory(symbol: source.symbol, dates: source.dates,
            opens: source.opens.reversed(), highs: source.highs.reversed(), lows: source.lows.reversed(),
            closes: source.closes.reversed(), volumes: source.volumes, priceSource: .massiveSIP)
        let cache = HC.from(histories: ["AAA": falling], universe: ["AAA"], savedAt: source.dates.last!)
        let restored = try #require(HC.decode(JSONEncoder().encode(cache))?.priceHistories()["AAA"])
        #expect(restored.closes.count == 253)
        #expect(StockSageIndicators.trendOK(falling.closes) == false)
        #expect(StockSageIndicators.trendOK(restored.closes) == false)
        #expect(!StockSageAdvisor.oversoldBounceIsBuyable(restored.closes))
    }

    // 3. Universe eviction: a symbol absent from `universe` is dropped; a present one survives.
    @Test func fromDropsSymbolsNotInUniverse() {
        let hs = ["AAA": history("AAA", bars: 5), "BBB": history("BBB", bars: 5)]
        let cache = HC.from(histories: hs, universe: ["AAA"], savedAt: Date(timeIntervalSince1970: 0))
        #expect(cache.entries.count == 1)
        #expect(cache.entries.first?.symbol == "AAA")
    }

    // Audit 2026-07-12 (concurrency R2): two detached scan savers can land out of order; the serial
    // CacheWriter funnels every write through nonShrinkMerge so a smaller SAME-DAY write never drops
    // symbols a larger same-day write already persisted. These pin the pure decision (no disk).
    @Test func nonShrinkMergeKeepsSameDaySupersetOnDiskFromASmallerCandidate() {
        let day = Date(timeIntervalSince1970: 100 * 86_400)   // any fixed UTC day
        // Disk holds a large same-day cache (the full scan); candidate is a smaller cancel save.
        let disk = HC.from(histories: ["AAA": history("AAA", bars: 5), "BBB": history("BBB", bars: 5), "CCC": history("CCC", bars: 5)],
                           universe: ["AAA", "BBB", "CCC"], savedAt: day)
        let candidate = HC.from(histories: ["AAA": history("AAA", bars: 5)], universe: ["AAA"], savedAt: day)
        let result = HC.nonShrinkMerge(disk: disk, candidate: candidate)
        // The smaller candidate must NOT shrink the same-day disk cache — all 3 symbols survive.
        #expect(Set(result.priceHistories().keys) == ["AAA", "BBB", "CCC"])
    }

    @Test func nonShrinkMergeLetsANewDayReplaceAndASupersetPassThrough() {
        let d1 = Date(timeIntervalSince1970: 100 * 86_400), d2 = Date(timeIntervalSince1970: 101 * 86_400)
        let disk = HC.from(histories: ["OLD": history("OLD", bars: 5)], universe: ["OLD"], savedAt: d1)
        // Different UTC day → the candidate legitimately REPLACES (no stale merge across days).
        let nextDay = HC.from(histories: ["NEW": history("NEW", bars: 5)], universe: ["NEW"], savedAt: d2)
        #expect(Set(HC.nonShrinkMerge(disk: disk, candidate: nextDay).priceHistories().keys) == ["NEW"])
        // Same day but candidate is a SUPERSET → passes through unchanged (no merge needed).
        let superset = HC.from(histories: ["OLD": history("OLD", bars: 5), "EXTRA": history("EXTRA", bars: 5)],
                               universe: ["OLD", "EXTRA"], savedAt: d1)
        #expect(Set(HC.nonShrinkMerge(disk: disk, candidate: superset).priceHistories().keys) == ["OLD", "EXTRA"])
        // No disk → candidate as-is.
        #expect(Set(HC.nonShrinkMerge(disk: nil, candidate: superset).priceHistories().keys) == ["OLD", "EXTRA"])
    }

    // 4. Schema-version + corruption guard: wrong version → nil; malformed JSON → nil; current → non-nil.
    @Test func decodeRejectsWrongVersionAndMalformed() throws {
        let wrong = HC(schemaVersion: 999, entries: [], savedAt: Date(timeIntervalSince1970: 0))
        #expect(HC.decode(try JSONEncoder().encode(wrong)) == nil)      // version mismatch → clean nil
        let ok = HC(schemaVersion: HC.currentSchemaVersion, entries: [], savedAt: Date(timeIntervalSince1970: 0))
        #expect(HC.decode(try JSONEncoder().encode(ok)) != nil)         // current version → decodes
        #expect(HC.decode(Data("{\"schemaVersion\":1}".utf8)) == nil)   // missing entries/savedAt → decode fails, no guess
    }

    @Test func decodeRejectsExtremeSaveDatesBeforeScanDayConversion() throws {
        for seconds in [Double.nan, .infinity, -.infinity, 1e308, -1e308] {
            #expect(StockSageScanChunking.utcDayKey(Date(timeIntervalSince1970: seconds)) == nil)
        }
        #expect(StockSageScanChunking.utcDayKey(Date(timeIntervalSince1970: -1)) == -1)
        #expect(StockSageScanChunking.utcDayKey(Date(timeIntervalSince1970: 0)) == 0)
        for seconds in [1e308, -1e308] {
            let cache = HC(schemaVersion: HC.currentSchemaVersion, entries: [],
                           savedAt: Date(timeIntervalSince1970: seconds))
            let bytes = try JSONEncoder().encode(cache) // Valid JSON; no malformed-text shortcut.
            let decoded = HC.decode(bytes)
            #expect(decoded == nil, "An unrepresentable day must not reach the scan's Int conversion")
            #expect(!StockSageScanChunking.isCacheFreshForToday(symbol: "AAA", cache: cache, now: cache.savedAt),
                    "Two unknown day keys must not compare as a fresh day")
            // Stop here on the old implementation so the red gate reports an assertion, not a process trap.
            guard decoded == nil else { continue }
            let partition = StockSageScanChunking.partitionByCacheFreshness(symbols: ["AAA"], cache: decoded)
            #expect(partition.fromCache.isEmpty && partition.toFetch == ["AAA"])
        }
    }

    @Test func malformedCachedEntriesCannotReenterAnalysis() throws {
        let day = Date(timeIntervalSince1970: 100 * 86_400)
        let entries = [
            HC.Entry(symbol: "AAA", dates: [day], opens: [10, 11], highs: [10, 11],
                     lows: [10, 11], closes: [10, 11], volumes: [100, 100]),
            HC.Entry(symbol: "AAA", dates: [day, Date(timeIntervalSince1970: 1e308)],
                     opens: [10, 11], highs: [10, 11], lows: [10, 11], closes: [10, 11], volumes: [100, 100])
        ]
        for entry in entries {
            let cache = HC(schemaVersion: HC.currentSchemaVersion, entries: [entry], savedAt: day)
            let decoded = HC.decode(try JSONEncoder().encode(cache))
            #expect(decoded?.priceHistories()["AAA"] == nil,
                    "Rejecting the whole cache or excluding the malformed entry are both safe")
        }
        let extreme = StockSagePriceHistory(symbol: "AAA", dates: [day, Date(timeIntervalSince1970: 1e308)],
            opens: [10, 11], highs: [10, 11], lows: [10, 11], closes: [10, 11], volumes: [100, 100])
        #expect(HC.panel(from: ["AAA": extreme, "BBB": history("BBB", bars: 2, base: 20)], industryOf: { _ in 0 }) == nil)
    }

    // 5. Staleness straddle (F05): full-day age 7 → fresh, 8 → stale; unknown symbol → stale.
    @Test func isStaleStraddlesTheDayBoundary() {
        let newest = Date(timeIntervalSince1970: 100 * 86_400)
        let e = HC.Entry(symbol: "AAA", dates: [newest], opens: [1], highs: [1], lows: [1], closes: [1], volumes: [1])
        let cache = HC(schemaVersion: HC.currentSchemaVersion, entries: [e], savedAt: newest)
        let asOf7 = Date(timeIntervalSince1970: 107 * 86_400)   // exactly 7 full days later
        let asOf8 = Date(timeIntervalSince1970: 108 * 86_400)   // 8 full days later
        #expect(cache.isStale(symbol: "AAA", asOf: asOf7, maxAgeDays: 7) == false)  // 7 > 7 is false → fresh
        #expect(cache.isStale(symbol: "AAA", asOf: asOf8, maxAgeDays: 7) == true)   // 8 > 7 → stale
        #expect(cache.isStale(symbol: "ZZZ", asOf: asOf7, maxAgeDays: 7) == true)   // unknown → stale (absence ≠ fresh)
    }

    // 6. The O6 unblock: cached candles feed StockSageNetCostSim (was 0 usable panels offline).
    //    3 symbols × 40 shared daily bars → 39 aligned returns each; lookback 5 + hold 2 ⇒ ≥ 4 rebalances.
    @Test func cachedHistoriesEnableTheNetCostSim() {
        let hs = ["AAA": history("AAA", bars: 40, base: 100),
                  "BBB": history("BBB", bars: 40, base: 50),
                  "CCC": history("CCC", bars: 40, base: 200)]
        let cache = HC.from(histories: hs, universe: ["AAA", "BBB", "CCC"], savedAt: Date(timeIntervalSince1970: 39 * 86_400))
        let panel = HC.panel(from: cache.priceHistories(), industryOf: { $0 == "CCC" ? 1 : 0 })
        #expect(panel != nil)
        guard let panel else { Issue.record("panel builder returned nil from a valid 3-symbol cache"); return }
        #expect(panel.symbolCount == 3)
        let result = StockSageNetCostSim.simulate(panel, lookback: 5, hold: 2, roundTripBps: 13)
        #expect(result != nil)                              // ← the unblock: cached data now simulates
        #expect((result?.rebalances.count ?? 0) >= 4)       // ≥ 4 rebalances (the sim's own non-nil floor)
    }

    // 7. Panel alignment: symbols with DIFFERENT date axes align on the shared-date INTERSECTION
    //    (a missing date is dropped, never fabricated); returns are computed on the shared axis only.
    @Test func panelAlignsOnSharedDateAxisIntersection() throws {
        let d = (0..<4).map { Date(timeIntervalSince1970: Double($0) * 86_400) }   // d0…d3
        // AAA has all 4 bars; BBB is MISSING d1 ⇒ shared dates = {d0, d2, d3} (3 → 2 returns).
        let a = StockSagePriceHistory(symbol: "AAA", dates: d, opens: [10, 11, 12, 13], highs: [10, 11, 12, 13],
                                      lows: [10, 11, 12, 13], closes: [10, 11, 12, 13], volumes: [1, 1, 1, 1])
        let b = StockSagePriceHistory(symbol: "BBB", dates: [d[0], d[2], d[3]], opens: [20, 22, 23], highs: [20, 22, 23],
                                      lows: [20, 22, 23], closes: [20, 22, 23], volumes: [1, 1, 1])
        let p = try #require(HC.panel(from: ["AAA": a, "BBB": b], industryOf: { _ in 0 }))
        #expect(p.symbolCount == 2)
        #expect(p.periodCount == 2)     // 3 shared dates → 2 returns; d1 dropped, not fabricated
        // AAA on shared [d0,d2,d3] = closes [10,12,13] (d1's 11 DROPPED): return[0] = 12/10−1 = 0.2 exactly.
        // If alignment did NOT drop d1, return[0] would be 11/10−1 = 0.1 — so 0.2 pins the intersection.
        #expect(abs(p.returns[0][0] - 0.2) < 1e-9)
        #expect(abs(p.returns[0][1] - (13.0 / 12.0 - 1.0)) < 1e-9)   // 13/12−1
        // BBB [20,22,23]: returns 22/20−1 = 0.1, 23/22−1.
        #expect(abs(p.returns[1][0] - 0.1) < 1e-9)
        #expect(abs(p.returns[1][1] - (23.0 / 22.0 - 1.0)) < 1e-9)
    }

    // 8. Cross-exchange alignment (audit L3-05, fixed 2026-07-07): Yahoo stamps each 1d bar at its
    //    exchange's session-open instant, so a US name (~13.5h UTC) and a crypto name (00:00 UTC) on
    //    the SAME calendar day carry DIFFERENT exact Date values. Exact-Date intersection shared ZERO
    //    dates → nil panel; UTC-day bucketing aligns them. This pins the bucketing.
    @Test func panelBucketsByUTCDayAcrossExchangeSessionOffsets() throws {
        let day = 86_400.0
        // US bars stamped at 13.5h into each UTC day (session open); crypto at 00:00. Same 3 calendar days.
        let usDates  = (0..<3).map { Date(timeIntervalSince1970: Double($0) * day + 13.5 * 3600) }
        let btcDates = (0..<3).map { Date(timeIntervalSince1970: Double($0) * day) }
        // NO exact Date is shared between the two axes (offset 48600s) — exact-intersection would give 0.
        #expect(Set(usDates).intersection(Set(btcDates)).isEmpty)
        let us  = StockSagePriceHistory(symbol: "US", dates: usDates, opens: [100, 110, 121], highs: [100, 110, 121],
                                        lows: [100, 110, 121], closes: [100, 110, 121], volumes: [1, 1, 1])
        let btc = StockSagePriceHistory(symbol: "BTC-USD", dates: btcDates, opens: [50, 52, 54.6], highs: [50, 52, 54.6],
                                        lows: [50, 52, 54.6], closes: [50, 52, 54.6], volumes: [1, 1, 1])
        let p = try #require(HC.panel(from: ["US": us, "BTC-USD": btc], industryOf: { _ in 0 }))
        #expect(p.symbolCount == 2)
        #expect(p.periodCount == 2)          // 3 UTC-day-aligned bars → 2 returns (was 0 under exact-Date)
        // syms sorted → ["BTC-USD","US"]. BTC [50,52,54.6]: 52/50−1 = 0.04, 54.6/52−1 = 0.05.
        #expect(abs(p.returns[0][0] - 0.04) < 1e-9)
        #expect(abs(p.returns[0][1] - 0.05) < 1e-9)
        // US [100,110,121]: 110/100−1 = 0.1, 121/110−1 = 0.1.
        #expect(abs(p.returns[1][0] - 0.1) < 1e-9)
        #expect(abs(p.returns[1][1] - 0.1) < 1e-9)
    }
}
