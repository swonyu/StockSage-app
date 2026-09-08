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
    /// REST carries a list; WebSocket c is a scalar. Never drop additional conditions.
    var conditions: [Int64]? = nil
    var condition: Int64? {
        get { conditions?.count == 1 ? conditions?.first : nil }
        set { conditions = newValue.map { [$0] } }
    }
    /// REST exchange event time, distinct from SIP receipt time; nil is not a substitute clock.
    var participantTime: Date? = nil
    /// nil means malformed metadata, [] means no indicators supplied.
    var indicators: [Int64]? = []
    private(set) var costConditionVerified = false

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
        isFresh(at: now) ? quotedSpreadBps : nil
    }

    /// Historical observation only. Cost callers MUST use spreadBps(at:) for freshness.
    var quotedSpreadBps: Double? {
        guard hasTwoSides, ask > bid else { return nil }
        let midpoint = bid / 2 + ask / 2
        let bps = ((ask - bid) / midpoint) * 10_000
        return bps.isFinite ? bps : nil
    }

    /// One reading for pixels AND the card's overriding VoiceOver label. No relative
    /// freshness claim: this dated observation remains true without per-card timers.
    static func compactText(_ quote: Self?, exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]) -> String {
        guard let quote else { return "NBBO · Massive SIP: bid/ask unavailable; costs estimated." }
        func venue(_ id: Int64?) -> String {
            guard let id, id >= 0 else { return "unknown venue" }
            return exchanges[id]?.label ?? "unknown #\(id)"
        }
        func side(_ name: String, price: Double, size: Double) -> String {
            guard price.isFinite, price > 0, size.isFinite, size > 0 else { return "\(name) unavailable" }
            let priceText = price.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
            return "\(name) \(priceText) × \(size.formatted()) sh"
        }
        let prices = side("Bid", price: quote.bid, size: quote.bidSize) + " · "
            + side("Ask", price: quote.ask, size: quote.askSize)
        let spread = quote.quotedSpreadBps.map { String(format: "Observed spread %.2f bps", $0) }
            ?? "Spread unavailable (one-sided, locked or crossed)"
        let stamp = quote.timestamp.formatted(date: .abbreviated, time: .standard)
        let venues = "Bid \(venue(quote.bidExchange)) · ask \(venue(quote.askExchange))"
        return "\(prices)\nNBBO · Massive SIP · \(stamp)\n\(venues)\n\(spread) · last observed, not a fill quote."
    }

    /// Provider IDs are resolved from /v3/reference/conditions, never guessed. UTP R
    /// means regular two-sided NBBO (UQDF specification §7.5.2.2). Other conditions
    /// and any indicators remain observational until their semantics are verified.
    func qualifyingCosts(regularConditions: Set<Int64>) -> Self {
        var copy = self
        copy.costConditionVerified = condition.map(regularConditions.contains) == true && indicators == []
        return copy
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
