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

    /// Validate backup values without narrowing the stored symbol contract. The dedicated
    /// ticker form is stricter than the store/Codable paths; preserve legacy spelling verbatim.
    nonisolated var validationError: String? {
        guard !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ticker must not be blank."
        }
        guard target > 0, target.isFinite else { return "target must be positive and finite." }
        guard triggeredAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            return "trigger time must be finite when present."
        }
        return nil
    }

    /// A new one-shot intent: old fetches/accepted-send callbacks must not match this arm.
    func rearmed() -> PriceAlert {
        PriceAlert(symbol: symbol, target: target, direction: direction)
    }

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
    ///
    /// The lookup UPPERCASES the alert's own symbol (2026-09-12). `PriceAlert.init` normalizes,
    /// but decoding from storage does NOT call that init — a legacy record saved as "nvda" keeps
    /// its spelling, and `prices` is keyed uppercase by every producer. The raw lookup missed, so
    /// the alert silently never fired; worse, `StockSageMonitor`'s `?? a.target` fallback then
    /// pushed the alert's OWN TARGET as the observed price. Normalizing here fixes every source of
    /// non-canonical spelling at once, including records already on disk.
    nonisolated static func newlyTriggered(_ alerts: [PriceAlert], prices: [String: Double]) -> [PriceAlert] {
        alerts.filter { a in
            guard a.isArmed, let p = prices[a.symbol.uppercased()] else { return false }
            return a.isMet(by: p)
        }
    }

    /// Validate a user-typed target. Returns the parsed price (or nil) + a reason.
    nonisolated static func validateTarget(_ raw: String) -> (price: Double?, error: String?) {
        // Stripping every comma read the Saudi decimal "28,50" as 2850 — a 100x target on a
        // market the owner actually trades. StockSageInput.positiveAmount is the one parser that
        // already knows a comma may be a decimal separator, and it enforces finite and > 0.
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, "Enter a target price.") }
        guard let v = StockSageInput.positiveAmount(raw) else { return (nil, "Enter a positive number.") }
        return (v, nil)
    }
}
