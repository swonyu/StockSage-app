import Foundation

// MARK: - Sector-rotation confirmation read (HARDENING_BACKLOG #31, reframed)
//
// The owner's OWN closed-trade journal already knows which sectors have been
// working (StockSageJournal.bySector). This re-ranks the SAME closed trades by
// realized R PER TRADE (not raw total R, which just rewards trade COUNT — a
// 20-trade small-edge sector would otherwise outrank a 5-trade strong-edge one)
// and flags the top-N sectors as "rotating in": capital has recently paid off
// in that industry, in THIS book.
//
// Deliberately NOT a conviction/sizing nudge (unlike the ±0.10 nudge the
// original backlog item proposed): a same-territory ablation already showed a
// benchmark-relative trend term (relativeStrengthEnabled) does not survive
// backtesting (2026-06-27) — this signal is EVEN MORE lagging, since by the
// time a sector shows up in the CLOSED-trade log, the move that made it
// profitable is already at least partly over (half-priced-in). This module
// touches no benchmark/relative-strength machinery at all (it is a pure
// self-referential read of the owner's own journal) and ships exactly like
// EDGE_RESEARCH #4/#5 (StockSageReturnShape / StockSageVolStability): a
// flag-only surfaced note in the idea's "Why", never an input to advise()'s
// conviction, EV, or position size. Read-only, honest that it describes the
// past, not a forecast.

struct SectorRotationSignal: Sendable, Equatable, Identifiable {
    let sector: String
    /// Realized R / closed-with-R trade (mean of `realizedR`, NOT raw total R).
    let avgR: Double
    /// Sample size this average is over — same `closedWithR` discipline as SectorPnL.
    let trades: Int
    /// 1-based rank among sectors that clear `minTrades` (best avgR = 1).
    let rank: Int
    /// True for the top-N ranked sectors (rotating in — recently paying off in THIS book).
    let isRotatingIn: Bool
    /// One-line plain read.
    let note: String
    /// Standing honesty caveat (always non-empty).
    let caveat: String
    var id: String { sector }
}

enum StockSageSectorRotation {
    nonisolated static let caveat =
        "This ranks sectors by what has ALREADY worked in your own closed trades — it is a " +
        "LAGGING confirmation, not a forecast. By the time a sector shows up here the move that " +
        "made it profitable is at least partly over (half-priced-in). It does not change " +
        "conviction, EV, or position size anywhere in the app — read-only."

    /// Rank sectors by realized R PER CLOSED TRADE (mean of `realizedR` over trades with a
    /// DEFINED R), restricted to sectors with at least `minTrades` such trades — the same
    /// small-sample honesty gate `StockSageJournal.reliability` already applies per-bucket
    /// (minN=5 convention). Sectors below the bar are OMITTED (not zero-filled), so a thin book
    /// returns an empty or short array rather than noisy ranks. The top `topN` (default 3) by
    /// avgR are flagged `isRotatingIn`. Pure function of the closed, R-defined subset of
    /// `allTrades`; does NOT read or mutate `StockSageJournal.bySector`'s own (total-R) ordering.
    nonisolated static func analyze(allTrades: [TradeRecord], minTrades: Int = 5, topN: Int = 3) -> [SectorRotationSignal] {
        let closed = allTrades.filter { !$0.isOpen }
        var groups: [String: [Double]] = [:]   // sector -> realizedR values (defined-R only)
        for t in closed {
            guard let r = t.realizedR else { continue }
            groups[StockSageSector.sector(t.symbol), default: []].append(r)
        }
        let eligible = groups.compactMap { sector, rs -> (String, Double, Int)? in
            guard rs.count >= minTrades else { return nil }
            return (sector, rs.reduce(0, +) / Double(rs.count), rs.count)
        }
        // desc by avgR, tie-broken alphabetically by sector name (2026-07-01 adversarial-review
        // fix): `groups` is a Swift Dictionary, whose iteration order carries NO stability
        // guarantee across runs/processes — two sectors with an EXACT avgR tie could otherwise
        // rank differently from one run to the next, silently changing which one is flagged
        // "rotating in" for no real reason.
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }

        return eligible.enumerated().map { idx, entry in
            let (sector, avgR, n) = entry
            let rank = idx + 1
            // 2026-07-01 adversarial-review fix: rank alone isn't enough — the "rotating in" note
            // reads as a positive confirmation ("capital has recently paid off"), so a sector that
            // is merely the LEAST-BAD among eligible sectors (rank #1 with a genuinely negative
            // avgR — plausible for a newer journal, or when every eligible sector is a net loser)
            // must never be labeled that way. Require avgR > 0, not just top rank.
            let rotating = rank <= topN && avgR > 0
            let note = rotating
                ? String(format: "%@ ranks #%d of your sectors by realized R/trade (%.2fR avg over %d trades) — rotating in.", sector, rank, avgR, n)
                : String(format: "%@ ranks #%d of your sectors by realized R/trade (%.2fR avg over %d trades).", sector, rank, avgR, n)
            return SectorRotationSignal(sector: sector, avgR: avgR, trades: n, rank: rank,
                                        isRotatingIn: rotating, note: note, caveat: caveat)
        }
    }

    /// Convenience for a ONE-OFF single-symbol query (UI code, tests): this symbol's rotation
    /// read, or nil if its sector doesn't clear `minTrades` — identical nil-on-too-few contract
    /// as `returnShape`/`volStability`. Callers ranking MANY symbols (e.g. buildIdeas) should call
    /// `analyze` ONCE and look up each symbol's sector in the result instead of calling this per
    /// symbol, to avoid re-deriving the whole ranking on every idea.
    nonisolated static func signal(for symbol: String, allTrades: [TradeRecord], minTrades: Int = 5, topN: Int = 3) -> SectorRotationSignal? {
        let mySector = StockSageSector.sector(symbol)
        return analyze(allTrades: allTrades, minTrades: minTrades, topN: topN).first { $0.sector == mySector }
    }
}
