import Foundation

// MARK: - User-set price alerts
//
// Distinct from the signal-based `IdeaAlert` (which fires on advice crossings):
// these are levels the OWNER sets — "tell me when AAPL is ≥ 150" — checked each
// monitor cycle against freshly-fetched live prices. One-shot: an alert fires once
// when its level is reached, at or through it (triggeredAt set), then stays quiet
// until re-armed, so it can't spam.
struct PriceAlert: Sendable, Equatable, Identifiable, Codable {
    enum Direction: String, Sendable, Codable {
        case above   // notify when price rises to/through the target
        case below   // notify when price falls to/through the target

        var symbol: String { self == .above ? "≥" : "≤" }
    }

    let id: UUID
    let symbol: String        // uppercased ticker
    let target: Double
    let direction: Direction
    var triggeredAt: Date?    // nil = armed; set when it fires

    init(id: UUID = UUID(), symbol: String, target: Double, direction: Direction, triggeredAt: Date? = nil) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.target = target
        self.direction = direction
        self.triggeredAt = triggeredAt
    }

    nonisolated var isArmed: Bool { triggeredAt == nil }

    /// Has `price` reached the target in this alert's direction?
    nonisolated func isMet(by price: Double) -> Bool {
        switch direction {
        case .above: return price >= target
        case .below: return price <= target
        }
    }
}

// MARK: - Pure evaluator (unit-tested; no I/O)
enum StockSagePriceAlertEngine {
    /// The ARMED alerts whose target is now met by the supplied prices (symbol→price,
    /// keys uppercased). Pure — the caller fires notifications and marks them triggered.
    nonisolated static func newlyTriggered(_ alerts: [PriceAlert], prices: [String: Double]) -> [PriceAlert] {
        alerts.filter { a in
            guard a.isArmed, let p = prices[a.symbol] else { return false }
            return a.isMet(by: p)
        }
    }

    /// Validate a user-typed target. Returns the parsed price (or nil) + a reason.
    nonisolated static func validateTarget(_ raw: String) -> (price: Double?, error: String?) {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty else { return (nil, "Enter a target price.") }
        guard let v = Double(s), v > 0, v.isFinite else { return (nil, "Enter a positive number.") }
        return (v, nil)
    }
}
