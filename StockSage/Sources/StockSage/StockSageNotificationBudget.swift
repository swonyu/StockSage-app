import Foundation

/// Notification rate control — owner report 2026-07-28: "the notifications are fucked, it sends
/// so much".
///
/// ROOT CAUSE, measured rather than assumed: the monitor polls every 45 SECONDS and every cycle
/// re-evaluates every alert path. A price resting near a threshold crosses it back and forth all
/// day, and each crossing was a push. The existing `lastAlerted` / `lastIdeaPrice` maps prevent
/// an *identical repeat*, but nothing stopped a symbol oscillating 19.99 / 20.01 from alerting
/// every single cycle, and nothing capped the total across symbols during a broad market move.
///
/// (An external review blamed scene-phase task-stacking. That is not possible here — `start()`
/// guards on `isRunning`, so repeated foreground transitions are no-ops. The cadence and the
/// missing hysteresis were the real causes.)
///
/// Three independent brakes, each answering a different failure:
///   1. HYSTERESIS  — after alerting, the price must move a real distance away before that
///                    symbol can alert again. Kills threshold-wobble spam.
///   2. COOLDOWN    — a hard per-symbol quiet period. Kills "same story, ten times an hour".
///   3. GLOBAL CAP  — a rolling hourly ceiling across all symbols. Kills the crash-day flood,
///                    where every name legitimately crosses at once and 60 pushes arrive.
///
/// Deliberately NOT silent: `suppressedSinceLastAllowed` counts what was held back so the app can
/// tell the owner "12 other alerts were suppressed" rather than quietly hiding events. Hiding
/// them without saying so would be an honesty-floor violation.
struct StockSageNotificationBudget: Sendable {

    struct AlertRecord: Sendable, Equatable, Codable {
        let at: Date
        let price: Double
    }

    /// Price must move at least this fraction away from the last alerted price before the same
    /// symbol may alert again. 0.5% is wider than typical bid/ask noise on both venues but well
    /// inside a move worth waking someone for.
    nonisolated static let hysteresisFraction = 0.005
    /// Hard quiet period per symbol.
    nonisolated static let symbolCooldown: TimeInterval = 1800      // 30 minutes
    /// Rolling-hour ceiling across ALL symbols.
    nonisolated static let hourlyCap = 8

    private(set) var perSymbol: [String: AlertRecord] = [:]
    private(set) var recentAlerts: [Date] = []
    /// How many pushes the budget has withheld since the last one it allowed.
    private(set) var suppressedSinceLastAllowed = 0

    // MARK: - Persistence
    //
    // WHY THIS EXISTS (second review, 2026-07-28): every brake here is worthless in memory
    // alone. iOS kills backgrounded apps routinely, and a relaunch with an empty map means the
    // monitor re-alerts on EVERY name currently past its threshold, ~20s after launch,
    // uncapped. That cold-start burst is the loudest half of the spam the owner reported —
    // hysteresis and cooldown cannot fire if the state they read was wiped by the OS.

    private static let defaultsKey = "stocksage.notify.budgetState.v1"

    /// Restore the same price anchors a continuing process uses: cooldown expiry does NOT
    /// expire hysteresis. Only hourly timestamps have a time-only retention rule.
    init(loadingFrom defaults: UserDefaults = .standard, now: Date = Date()) {
        guard let raw = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: raw) else { return }
        // ponytail: one anchor per ever-alerted symbol, matching live memory; prune only if
        // an explicit hysteresis-expiry policy is also applied to the running budget.
        perSymbol = decoded.perSymbol
        recentAlerts = decoded.recentAlerts.filter { now.timeIntervalSince($0) <= 3600 }
    }

    /// Write-through. Called after every state change; the blob is a few hundred bytes.
    func save(to defaults: UserDefaults = .standard) {
        let blob = Persisted(perSymbol: perSymbol, recentAlerts: recentAlerts)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private struct Persisted: Codable {
        let perSymbol: [String: AlertRecord]
        let recentAlerts: [Date]
    }

    // MARK: - Pure decision (no state mutation — trivially testable)

    /// Why a push was refused, or nil when it is allowed. Returning a REASON rather than a Bool
    /// so the caller can surface an honest explanation instead of a silent drop.
    enum Refusal: String, Sendable, Equatable {
        case hourlyCapReached
        case symbolCoolingDown
        case priceHasNotMovedEnough
    }

    nonisolated static func refusal(last: AlertRecord?,
                                    alertsInLastHour: Int,
                                    price: Double,
                                    now: Date) -> Refusal? {
        if alertsInLastHour >= hourlyCap { return .hourlyCapReached }
        guard let last else { return nil }                       // first alert for this symbol
        if now.timeIntervalSince(last.at) < symbolCooldown { return .symbolCoolingDown }
        // Hysteresis is measured against the price we ALERTED at, not the previous tick — the
        // whole point is that drifting back and forth across one level must not re-arm.
        guard last.price > 0 else { return nil }
        let move = abs(price - last.price) / abs(last.price)
        return move < hysteresisFraction ? .priceHasNotMovedEnough : nil
    }

    /// Alerts inside the rolling hour ending at `now`.
    nonisolated static func countWithinHour(_ timestamps: [Date], now: Date) -> Int {
        timestamps.filter { now.timeIntervalSince($0) <= 3600 }.count
    }

    // MARK: - Stateful use

    /// Ask permission for one push. Mutates only the suppression counter on refusal.
    mutating func allow(symbol: String, price: Double, now: Date = Date()) -> Bool {
        recentAlerts.removeAll { now.timeIntervalSince($0) > 3600 }
        let key = symbol.uppercased()
        let refusal = Self.refusal(last: perSymbol[key],
                                   alertsInLastHour: Self.countWithinHour(recentAlerts, now: now),
                                   price: price, now: now)
        if refusal != nil { suppressedSinceLastAllowed += 1; return false }
        return true
    }

    /// Record a push that was actually ACCEPTED by the system. Never call this for a push that
    /// failed to deliver — that would start a cooldown for an alert the owner never saw.
    mutating func record(symbol: String, price: Double, now: Date = Date()) {
        perSymbol[symbol.uppercased()] = AlertRecord(at: now, price: price)
        recentAlerts.append(now)
        suppressedSinceLastAllowed = 0
    }

    /// Wipe state for a symbol (e.g. the owner re-armed a price alert by hand — an explicit
    /// action should not be silenced by a cooldown they didn't ask for).
    mutating func clear(symbol: String) { perSymbol.removeValue(forKey: symbol.uppercased()) }
}
