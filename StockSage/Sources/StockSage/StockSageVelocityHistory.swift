import Foundation
import Combine

// MARK: - Velocity history (is my opportunity set getting faster/fatter?)
//
// A tiny rolling daily series of the money-velocity summary's weekly-R estimate, plus
// a recent-half-vs-early-half trend (the same shape as the journal's expectancy trend).
// It answers "are the setups the app is surfacing improving over time?" — descriptive
// of the OPPORTUNITY SET, never a forecast. Pure engine + a persisted @MainActor store.

struct VelocitySnapshot: Codable, Sendable, Equatable {
    let day: String       // "YYYY-MM-DD" (UTC) — one snapshot per day
    let weeklyR: Double    // the day's estimated weekly R (top fast-lane setups)
    // Migration-safe optionals: snapshots persisted before this field decode as nil
    // (Swift synthesizes decodeIfPresent for optionals).
    var bestSymbol: String? = nil
    var fastestSymbol: String? = nil
}

/// What moved between the two most-recent snapshots — names the new best/fastest if it
/// changed. Descriptive of the owner's own recorded history, not a forecast.
struct VelocityChange: Sendable, Equatable {
    let weeklyRDelta: Double
    let bestChangedTo: String?
    let fastestChangedTo: String?
}

struct VelocityHistoryTrend: Sendable, Equatable {
    enum Direction: String, Sendable { case rising, flat, fading }
    let earlyAvg: Double   // mean weekly-R of the first half
    let recentAvg: Double  // mean weekly-R of the most-recent half
    let direction: Direction
    nonisolated var delta: Double { recentAvg - earlyAvg }
}

enum StockSageVelocityHistory {
    /// Append today's snapshot (replacing any existing one for the same day), keep the
    /// series sorted by day, and cap it to the newest `maxDays`. Pure.
    nonisolated static func record(_ series: [VelocitySnapshot], day: String, weeklyR: Double,
                                   bestSymbol: String? = nil, fastestSymbol: String? = nil,
                                   maxDays: Int = 60) -> [VelocitySnapshot] {
        var out = series.filter { $0.day != day }
        out.append(VelocitySnapshot(day: day, weeklyR: weeklyR, bestSymbol: bestSymbol, fastestSymbol: fastestSymbol))
        out.sort { $0.day < $1.day }
        if out.count > Swift.max(1, maxDays) { out = Array(out.suffix(Swift.max(1, maxDays))) }
        return out
    }

    /// What changed between the two most-recent snapshots: the weekly-R delta and the new
    /// best/fastest symbol IF it changed (nil if unchanged or unknown). nil under 2 snapshots.
    nonisolated static func changeSinceLast(_ series: [VelocitySnapshot]) -> VelocityChange? {
        let s = series.sorted { $0.day < $1.day }
        guard s.count >= 2 else { return nil }
        let prev = s[s.count - 2], cur = s[s.count - 1]
        return VelocityChange(
            weeklyRDelta: cur.weeklyR - prev.weeklyR,
            bestChangedTo: (cur.bestSymbol != nil && cur.bestSymbol != prev.bestSymbol) ? cur.bestSymbol : nil,
            fastestChangedTo: (cur.fastestSymbol != nil && cur.fastestSymbol != prev.fastestSymbol) ? cur.fastestSymbol : nil)
    }

    /// Change in weekly-R from the previous snapshot to the latest — "what changed since
    /// last session." nil with fewer than 2 snapshots. Descriptive of the owner's own
    /// recorded history, not a forecast.
    nonisolated static func lastDelta(_ series: [VelocitySnapshot]) -> Double? {
        let s = series.sorted { $0.day < $1.day }
        guard s.count >= 2 else { return nil }
        return s[s.count - 1].weeklyR - s[s.count - 2].weeklyR
    }

    /// Recent-half mean vs first-half mean of weekly-R, with a flat band. nil under 4 days.
    nonisolated static func trend(_ series: [VelocitySnapshot], band: Double = 0.25) -> VelocityHistoryTrend? {
        let vals = series.sorted { $0.day < $1.day }.map(\.weeklyR)
        guard vals.count >= 4 else { return nil }
        let half = vals.count / 2
        let early = vals.prefix(half), recent = vals.suffix(vals.count - half)
        let ea = early.reduce(0, +) / Double(early.count)
        let ra = recent.reduce(0, +) / Double(recent.count)
        let dir: VelocityHistoryTrend.Direction = (ra - ea) > band ? .rising : ((ra - ea) < -band ? .fading : .flat)
        return VelocityHistoryTrend(earlyAvg: ea, recentAvg: ra, direction: dir)
    }
}

/// Persisted daily velocity history (UserDefaults JSON). One snapshot per UTC day.
@MainActor
final class StockSageVelocityHistoryStore: ObservableObject {
    static let shared = StockSageVelocityHistoryStore()
    @Published private(set) var series: [VelocitySnapshot] = []
    private let key: String
    private let defaults: UserDefaults

    /// `defaults`/`key` injectable for the reconciliation tests ONLY (the paper/journal
    /// stores' seam shape) — production uses `.shared` on `.standard`/the v1 key.
    init(defaults: UserDefaults = .standard, key: String = "velocityHistory.v1") {
        self.defaults = defaults
        self.key = key
        load()
    }

    /// Record (or replace) today's snapshot (weekly-R + the day's best/fastest) and persist.
    func record(weeklyR: Double, bestSymbol: String? = nil, fastestSymbol: String? = nil) {
        series = StockSageVelocityHistory.record(series, day: Self.dayKey(Date()), weeklyR: weeklyR,
                                                 bestSymbol: bestSymbol, fastestSymbol: fastestSymbol)
        save()
    }

    var trend: VelocityHistoryTrend? { StockSageVelocityHistory.trend(series) }
    var lastDelta: Double? { StockSageVelocityHistory.lastDelta(series) }
    var change: VelocityChange? { StockSageVelocityHistory.changeSinceLast(series) }

    nonisolated static func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([VelocitySnapshot].self, from: data) else { return }
        series = decoded
    }

    /// LOST-UPDATE FIX (2026-07-09, C8 — same cross-process clobber class as the paper/
    /// journal/portfolio stores). This is the DURABLE per-day trend history the "since last
    /// session" delta reads — a stale whole-array write from a second app instance silently
    /// deleted other days' snapshots forever. Reconcile by DAY-KEY union: days this process
    /// holds win (its record() is the newest scan here; both same-day snapshots are equally
    /// valid), disk days it lacks are preserved; then re-sort and re-cap to the newest 60
    /// exactly like record() does. No deletion API exists on this store — every save
    /// reconciles.
    private func save() {
        if let data = defaults.data(forKey: key),
           let disk = try? JSONDecoder().decode([VelocitySnapshot].self, from: data) {
            let mine = Set(series.map(\.day))
            var merged = series
            for d in disk where !mine.contains(d.day) { merged.append(d) }
            merged.sort { $0.day < $1.day }
            if merged.count > 60 { merged = Array(merged.suffix(60)) }
            series = merged
        }
        if let data = try? JSONEncoder().encode(series) { defaults.set(data, forKey: key) }
    }
}
