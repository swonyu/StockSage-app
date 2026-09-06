import Foundation

/// Massive's consolidated SIP quote, NOT a Nasdaq-only book or an executable fill.
/// https://massive.com/docs/websocket/stocks/quotes: bp/ap, bs/as (shares), bx/ax,
/// t (SIP milliseconds), q (per-symbol sequence). Zero sides represent withdrawals.
nonisolated struct StockSageNBBO: Sendable, Equatable {
    let symbol: String
    let bid: Double
    let ask: Double
    let bidSize: Double
    let askSize: Double
    let bidExchange: Int64?
    let askExchange: Int64?
    let timestamp: Date
    let sequence: Int64?

    static let usableAge: TimeInterval = 5

    var hasTwoSides: Bool {
        [bid, ask, bidSize, askSize].allSatisfy { $0.isFinite && $0 > 0 }
    }

    /// Freshness of THIS quote, not the last trade. Future quotes may be retained for
    /// clock-skew tolerance but cannot supply a cost input until their time arrives.
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && age >= 0 && age <= Self.usableAge
    }

    /// Full quoted spread at midpoint. Two half-spread crossings make one full
    /// round-trip spread; this is not slippage, market depth, or a fill guarantee.
    func spreadBps(at now: Date) -> Double? {
        guard hasTwoSides, ask > bid, isFresh(at: now) else { return nil }
        let midpoint = bid / 2 + ask / 2
        let bps = ((ask - bid) / midpoint) * 10_000
        return bps.isFinite ? bps : nil
    }

    /// Only compare q within this Massive quote channel and symbol. A different day
    /// may restart q; equal timestamps require positive evidence of a later sequence.
    func supersedes(_ previous: Self?, now: Date) -> Bool {
        guard StockSageStore.acceptsLiveTick(timestamp, after: nil, now: now),
              [bid, ask, bidSize, askSize].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        guard let previous else { return true }
        guard symbol == previous.symbol else { return false }
        if StockSageStore.acceptsLiveTick(timestamp, after: previous.timestamp, now: now) { return true }
        guard timestamp == previous.timestamp, let sequence, let old = previous.sequence else { return false }
        return sequence >= 0 && old >= 0 && sequence > old
    }
}
