import Foundation

// MARK: - Chunked progressive scan — pure infrastructure (PLAN_2026-07-08_equity2000.md Stage 1)
//
// Stage 1 (shipped n=210, behaviour-preserving) switched performRefreshIdeas from one
// single-shot fetch+build+publish to a chunked fetch→build→merge→publish loop, so Stage 2's
// universe promotion (worldwide now 2,420 names, groups+catalogExtra) streams results onto a
// live board instead of a single multi-minute block. NOW that Stage 2 has landed, the analyzed
// universe (`StockSageUniverse.worldwide`) is 901 names post the 2026-07-16 Tadawul+NASDAQ restriction — ~4 chunks at the 250-wide size
// below, not the single Stage-1-era chunk.

nonisolated enum StockSageScanChunking {
    /// Symbols per chunk. `~250` per the plan — was large enough that Stage 1's n=210 universe
    /// was ONE chunk (byte-identical scan shape to the pre-chunking store); post-Stage-2's
    /// 901-name universe (Tadawul+NASDAQ, 2026-07-16) streams in ~4 chunks.
    static let chunkSize = 250

    /// Split `defs` into ordered, contiguous, non-overlapping chunks of at most `size`
    /// elements, preserving the array's natural (head-first) order — callers pass
    /// `trackedDefs()` whose head is the curated Saudi-first core, so chunk 0 is always
    /// that core and later chunks are whatever follows it (catalogExtra names in Stage 2).
    /// `size <= 0` is treated as 1 (never an infinite/empty chunk). Pure, nonisolated, and
    /// Sendable-generic so it works for `[StockSageSymbol]` or any other array the caller
    /// wants to chunk identically (e.g. tests use plain `[Int]`/`[String]`).
    nonisolated static func chunks<T>(_ defs: [T], size: Int = chunkSize) -> [[T]] {
        guard !defs.isEmpty else { return [] }
        let step = Swift.max(1, size)
        return stride(from: 0, to: defs.count, by: step).map {
            Array(defs[$0 ..< Swift.min($0 + step, defs.count)])
        }
    }

    /// A chunk BEYOND the first (`chunkIndex > 0`) is throttle-fallback-eligible: the
    /// coverage-guard/empty-feed bail that legacy single-shot scans apply to a totally
    /// failed run is reserved for chunk 0 (the plan's "first chunk = legacy total-failure
    /// path"); a low-coverage LATER chunk is a partial-success signal, not a hard failure,
    /// and instead trips the throttle-fallback scaffold (`scanThrottled`). Pure predicate —
    /// `priced`/`attempted` describe ONE chunk's fetch result.
    nonisolated static func chunkCoverage(priced: Int, attempted: Int) -> Double {
        guard attempted > 0 else { return 1 }   // nothing attempted this chunk ⇒ vacuously "fully covered", never a false throttle trip
        return Double(priced) / Double(attempted)
    }

    /// Throttle-fallback trigger (plan step 5): true when a chunk BEYOND the first
    /// (`chunkIndex > 0`) returns coverage below `threshold` (default 30%, the 429-storm
    /// signature). Chunk 0 is EXEMPT — it is covered by the existing empty-feed/coverage
    /// guards on the legacy total-failure path, not this scaffold.
    nonisolated static func shouldThrottle(chunkIndex: Int, priced: Int, attempted: Int,
                                           threshold: Double = 0.30) -> Bool {
        guard chunkIndex > 0 else { return false }
        return chunkCoverage(priced: priced, attempted: attempted) < threshold
    }

    // MARK: Cache-aware skip (plan step 3)

    /// UTC calendar-day bucket for a `Date` — same convention `StockSageHistoryCache.panel`
    /// already aligns dates on (audit L3-05), reused here so "same day" means the same thing
    /// everywhere in the engine.
    nonisolated static func utcDayKey(_ d: Date) -> Int { Int((d.timeIntervalSince1970 / 86_400).rounded(.down)) }

    /// True when `symbol` can serve straight from `cache` for this scan — no network call —
    /// because the cache was SAVED today (UTC) and the symbol's own entry is not stale per
    /// `HistoryCache.isStale`. Both conditions matter: `savedAt` alone can't tell a genuinely
    /// fresh whole-cache save from one that carried forward an old entry the last scan never
    /// re-fetched (a partial chunk failure), and staleness alone can't tell "fetched an hour
    /// ago" from "fetched yesterday and happens to still be within the 7-day staleness
    /// window" — the plan's "same UTC day" bar is stricter than `isStale`'s ~5-trading-day one
    /// on purpose (same-day skip is about NOT re-hitting the feed twice in one day, not about
    /// whether the data is usably fresh for analysis). Pure — `cache`/`now` both injected.
    nonisolated static func isCacheFreshForToday(symbol: String, cache: StockSageHistoryCache, now: Date) -> Bool {
        guard utcDayKey(cache.savedAt) == utcDayKey(now) else { return false }
        return !cache.isStale(symbol: symbol, asOf: now)
    }

    /// Partition `symbols` into (servable-from-cache-today, needs-a-fetch). Order within each
    /// output preserves `symbols`' order. `cache == nil` ⇒ everything needs a fetch (first
    /// scan of the day / no cache on disk yet — never invents freshness).
    nonisolated static func partitionByCacheFreshness(symbols: [String], cache: StockSageHistoryCache?,
                                                       now: Date = Date()) -> (fromCache: [String], toFetch: [String]) {
        guard let cache else { return ([], symbols) }
        var fromCache: [String] = [], toFetch: [String] = []
        for s in symbols {
            if isCacheFreshForToday(symbol: s, cache: cache, now: now) { fromCache.append(s) } else { toFetch.append(s) }
        }
        return (fromCache, toFetch)
    }

    // MARK: Chunk merge (shared by BOTH the chunked scan's per-chunk loop AND
    // StockSageStore.retryFailedIdeas — review round 1, finding 5: retryFailedIdeas now calls
    // this directly instead of re-implementing the same replace-by-symbol-then-resort inline,
    // so the two paths literally cannot drift apart — one function, two call sites.)

    /// Merge one chunk's freshly-built ideas into the running board: REPLACE any existing entry
    /// for the same symbol (case-insensitive), then re-sort by `rankScore`. Pure — `rankScore`
    /// is injected so this stays independent of `StockSageStore`. Callers that need additional
    /// filtering (e.g. `retryFailedIdeas`'s `stillTracked` reconcile) apply it AFTER this
    /// returns — this function only ever does the replace-and-resort, nothing tracked-set-aware.
    nonisolated static func mergeChunk(current: [StockSageIdea], newlyBuilt: [StockSageIdea],
                                       rankScore: (TradeAdvice) -> Double) -> [StockSageIdea] {
        guard !newlyBuilt.isEmpty else { return current }
        let newSyms = Set(newlyBuilt.map { $0.symbol.uppercased() })
        return (current.filter { !newSyms.contains($0.symbol.uppercased()) } + newlyBuilt)
            .sorted { rankScore($0.advice) > rankScore($1.advice) }
    }
}
