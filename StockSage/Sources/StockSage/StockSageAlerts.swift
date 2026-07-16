import Foundation

// MARK: - Signal alerts (pure crossing detector)
//
// Turns a pair of Ideas snapshots (previous poll → current poll) into discrete
// alert EVENTS. Everything here keys off a *crossing* — an action that changed,
// a price that broke through a level it was on the other side of last time — so
// the same standing condition never re-fires every poll (no external dedup set
// needed). Honest: an alert is "this just happened", not "you should act".

struct IdeaAlert: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case flipBullish = "Turned bullish"
        case flipBearish = "Turned bearish"
        case stopBreach  = "Stop breached"
        case targetHit   = "Target reached"
    }
    // Stable unique id: the SAME (symbol, kind) legitimately re-fires over time
    // (a stop breached today and again next week are two real events), so the id
    // must be per-event, not "symbol-kind", to stay Identifiable-safe in lists.
    let id: UUID
    let symbol: String
    let kind: Kind
    let detail: String
    let price: Double

    nonisolated init(id: UUID = UUID(), symbol: String, kind: Kind, detail: String, price: Double) {
        self.id = id; self.symbol = symbol; self.kind = kind; self.detail = detail; self.price = price
    }

    /// Bearish events (stop breach, turned bearish) read as warnings.
    nonisolated var isWarning: Bool { kind == .stopBreach || kind == .flipBearish }
}

enum StockSageAlerts {
    private nonisolated static let bullish: Set<TradeAdvice.Action> = [.strongBuy, .buy]
    private nonisolated static let bearish: Set<TradeAdvice.Action> = [.sell, .reduce]

    /// Compare a previous ideas snapshot to the current one and emit alert events
    /// for CROSSINGS only. Pure — a new symbol (no previous) never alerts on its
    /// first appearance; we can only flag what *changed*.
    nonisolated static func detect(previous: [StockSageIdea], current: [StockSageIdea]) -> [IdeaAlert] {
        let prevBy = Dictionary(previous.map { ($0.symbol.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var alerts: [IdeaAlert] = []
        for idea in current {
            guard let prev = prevBy[idea.symbol.uppercased()] else { continue }
            let now = idea.advice.action
            let was = prev.advice.action

            // Action flips: entered the bullish/bearish set from outside it.
            if now != was {
                if bullish.contains(now), !bullish.contains(was) {
                    alerts.append(IdeaAlert(symbol: idea.symbol, kind: .flipBullish,
                                            detail: "\(was.rawValue) → \(now.rawValue)", price: idea.price))
                } else if bearish.contains(now), !bearish.contains(was) {
                    alerts.append(IdeaAlert(symbol: idea.symbol, kind: .flipBearish,
                                            detail: "\(was.rawValue) → \(now.rawValue)", price: idea.price))
                }
            }

            // Price crossed the advised stop or target. Direction depends on SIDE: a LONG stops
            // BELOW / targets ABOVE; a SHORT (sell/reduce) mirrors it — stop ABOVE, target BELOW.
            // (Was long-only: a short's stop-out was missed and a winning short fired a false stop.)
            let isShort = bearish.contains(idea.advice.action)
            let prevP = prev.price, nowP = idea.price
            if let stop = idea.advice.stopPrice {
                let breached: Bool
                if isShort { breached = prevP < stop && nowP >= stop }   // short: crossed UP through stop
                else { breached = prevP > stop && nowP <= stop }         // long: crossed DOWN through stop
                if breached {
                    alerts.append(IdeaAlert(symbol: idea.symbol, kind: .stopBreach,
                                            detail: String(format: "Price %.2f broke the %.2f stop", nowP, stop),
                                            price: idea.price))
                }
            }
            if let target = idea.advice.targetPrice {
                let hit: Bool
                if isShort { hit = prevP > target && nowP <= target }    // short: crossed DOWN through target
                else { hit = prevP < target && nowP >= target }          // long: crossed UP through target
                if hit {
                    alerts.append(IdeaAlert(symbol: idea.symbol, kind: .targetHit,
                                            detail: String(format: "Price %.2f reached the %.2f target", nowP, target),
                                            price: idea.price))
                }
            }
        }
        return alerts
    }
}
