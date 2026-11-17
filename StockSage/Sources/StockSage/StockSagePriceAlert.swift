import Foundation

// MARK: - User-set price alerts
//
// Distinct from the signal-based `IdeaAlert` (which fires on advice crossings):
// these are levels the OWNER sets — "tell me when AAPL is ≥ 150" — checked each
// monitor cycle against freshly-fetched live prices, and sooner by live regular-session
// trades from the Massive stream (StockSageMonitor.noteStreamedTicks). One-shot: an alert fires once
// when its level is reached, at or through it (triggeredAt set), then stays quiet
// until re-armed, so it can't spam.
struct PriceAlert: Sendable, Equatable, Identifiable, Codable {
    enum Direction: String, Sendable, Codable {
        case above   // notify when price rises to/through the target
        case below   // notify when price falls to/through the target

        var symbol: String { self == .above ? "≥" : "≤" }
    }

    /// What `target` measures. `dayVolume` is the regular-session day's share volume, confirmed
    /// from a Massive REST snapshot (`day.v`) before any push; it is created only with `.above`.
    nonisolated enum Metric: String, Sendable, Codable {
        case price
        case dayVolume
    }

    let id: UUID
    let symbol: String        // uppercased ticker
    let target: Double
    let direction: Direction
    var triggeredAt: Date?    // nil = armed; set when it fires
    /// nil means `.price`: records saved before this field existed (and every price alert) omit
    /// it, so stored `stocksage_price_alerts` data and backups keep their exact bytes and decode.
    let metric: Metric?

    init(id: UUID = UUID(), symbol: String, target: Double, direction: Direction, triggeredAt: Date? = nil,
         metric: Metric = .price) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.target = target
        self.direction = direction
        self.triggeredAt = triggeredAt
        self.metric = metric == .price ? nil : metric
    }

    nonisolated var isArmed: Bool { triggeredAt == nil }
    nonisolated var resolvedMetric: Metric { metric ?? .price }

    /// Row/notification level text, e.g. "≥ 150.00" or "day volume ≥ 2.5M".
    var levelText: String {
        switch resolvedMetric {
        case .price: return "\(direction.symbol) \(StockSageCurrency.adaptivePrice(target))"
        case .dayVolume: return "day volume \(direction.symbol) \(Self.volumeText(target))"
        }
    }

    static func volumeText(_ shares: Double) -> String {
        shares.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Validate backup values without narrowing the stored symbol contract. The dedicated
    /// ticker form is stricter than the store/Codable paths; preserve legacy spelling verbatim.
    nonisolated var validationError: String? {
        guard !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "ticker must not be blank."
        }
        guard target > 0, target.isFinite else { return "target must be positive and finite." }
        // Day volume only rises during a session, so a "≤" level would fire at the open.
        if case .dayVolume = resolvedMetric, case .below = direction {
            return "a day-volume alert must use ≥."
        }
        guard triggeredAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            return "trigger time must be finite when present."
        }
        return nil
    }

    /// A new one-shot intent: old fetches/accepted-send callbacks must not match this arm.
    func rearmed() -> PriceAlert {
        PriceAlert(symbol: symbol, target: target, direction: direction, metric: resolvedMetric)
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
    ///
    /// Day-volume alerts read ONLY `volumes` (REST-confirmed `day.v`), never `prices`.
    nonisolated static func newlyTriggered(_ alerts: [PriceAlert], prices: [String: Double],
                                           volumes: [String: Double] = [:]) -> [PriceAlert] {
        alerts.filter { a in
            guard a.isArmed, let v = observed(a, prices: prices, volumes: volumes) else { return false }
            return a.isMet(by: v)
        }
    }

    /// The observation an alert compares against, or nil when none was supplied for its metric.
    nonisolated static func observed(_ a: PriceAlert, prices: [String: Double], volumes: [String: Double]) -> Double? {
        let key = a.symbol.uppercased()
        switch a.resolvedMetric {
        case .price: return prices[key]
        case .dayVolume: return volumes[key]
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
