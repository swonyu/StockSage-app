import Foundation
import Combine

// MARK: - Velocity history (is my opportunity set getting faster/fatter?)
//
// A tiny rolling daily series of the money-velocity summary's weekly-R estimate, plus
// a recent-half-vs-early-half trend (the same shape as the journal's expectancy trend).
// It answers "are the setups the app is surfacing improving over time?" — descriptive
// of the OPPORTUNITY SET, never a forecast. Pure engine + a persisted @MainActor store.

/// SCHEMA VERSION of the numeric metric stored in `VelocitySnapshot.weeklyR`. Two days are
/// comparable ONLY when they were computed on the same basis — the trend/delta readers filter on
/// it. ADDING A CASE is the migration procedure for ANY future change to what `weeklyR` MEANS
/// (netting it, re-basketing it, re-weighting it): bump `current`, never re-interpret a shipped
/// case. Persisted as its RAW Int (see `VelocitySnapshot.metricBasis`), never as the enum, so a
/// row written by a NEWER build can never throw inside this build's decode and take the whole
/// 60-day array down with it — `load()` uses `try?`, so one throw is total loss.
enum VelocityMetricBasis: Int, Sendable, Equatable, CaseIterable {
    /// Shipped through 2026-09-11. Top-N velocities x the WHOLE lane's trading-day cadence
    /// (finding 5.1: the multiplier described a different basket than the sum).
    case wholeLaneCadenceV1 = 1
    /// 2026-09-12 onward. Top-N velocities x the TOP-N basket's OWN cadence.
    case topNCadenceV2 = 2
    /// What today's writer stamps; readers compare only rows equal to this.
    nonisolated static let current: VelocityMetricBasis = .topNCadenceV2
}

struct VelocitySnapshot: Codable, Sendable, Equatable {
    let day: String       // "YYYY-MM-DD" (UTC) — one snapshot per day
    let weeklyR: Double    // the day's estimated weekly R (top fast-lane setups)
    // Migration-safe optionals: snapshots persisted before this field decode as nil
    // (Swift synthesizes decodeIfPresent for optionals).
    var bestSymbol: String? = nil
    var fastestSymbol: String? = nil
    /// Migration-safe optional: rows persisted before this field decode as nil, and nil MEANS
    /// `.wholeLaneCadenceV1` — that is literally the code that wrote them. Stored as the raw Int
    /// so an UNRECOGNIZED (future/downgrade) value decodes fine and simply reads as not-current.
    var metricBasis: Int? = nil

    /// nil ⇒ pre-marker row ⇒ v1.
    nonisolated var basisRaw: Int { metricBasis ?? VelocityMetricBasis.wholeLaneCadenceV1.rawValue }
    /// Is this row on the basis today's code computes? Unknown future values ⇒ false (excluded,
    /// never silently compared).
    nonisolated var isCurrentBasis: Bool { basisRaw == VelocityMetricBasis.current.rawValue }
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
                                   maxDays: Int = 60,
                                   basis: VelocityMetricBasis = .current) -> [VelocitySnapshot] {
        var out = series.filter { $0.day != day }
        out.append(VelocitySnapshot(day: day, weeklyR: weeklyR, bestSymbol: bestSymbol,
                                    fastestSymbol: fastestSymbol, metricBasis: basis.rawValue))
        out.sort { $0.day < $1.day }
        if out.count > Swift.max(1, maxDays) { out = Array(out.suffix(Swift.max(1, maxDays))) }
        return out
    }

    /// What changed between the two most-recent snapshots: the weekly-R delta and the new
    /// best/fastest symbol IF it changed (nil if unchanged or unknown). nil under 2 snapshots.
    ///
    /// BASIS (2026-09-12): the weeklyR DELTA is computed over `comparable(series)` only — a metric
    /// correction must never masquerade as a market move. The best/fastest SYMBOLS are not on the
    /// weeklyR basis at all, so they keep reading the full series: suppressing the "Mover:" line
    /// for a day because of a cadence fix would hide information this change has nothing to do
    /// with. nil delta ⇒ not enough same-basis days yet.
    nonisolated static func changeSinceLast(_ series: [VelocitySnapshot]) -> VelocityChange? {
        let s = series.sorted { $0.day < $1.day }
        guard s.count >= 2 else { return nil }
        let prev = s[s.count - 2], cur = s[s.count - 1]
        return VelocityChange(
            weeklyRDelta: lastDelta(series) ?? 0,
            bestChangedTo: (cur.bestSymbol != nil && cur.bestSymbol != prev.bestSymbol) ? cur.bestSymbol : nil,
            fastestChangedTo: (cur.fastestSymbol != nil && cur.fastestSymbol != prev.fastestSymbol) ? cur.fastestSymbol : nil)
    }

    /// Change in weekly-R from the previous snapshot to the latest — "what changed since
    /// last session." nil with fewer than 2 snapshots. Descriptive of the owner's own
    /// recorded history, not a forecast.
    nonisolated static func lastDelta(_ series: [VelocitySnapshot]) -> Double? {
        let s = comparable(series).sorted { $0.day < $1.day }
        guard s.count >= 2 else { return nil }
        return s[s.count - 1].weeklyR - s[s.count - 2].weeklyR
    }

    /// The rows today's math may compare with each other. Pre-fix (and unrecognized-future) days
    /// are KEPT in the series — owner decision 2026-09-12, "fix + mark the old days" — and excluded
    /// HERE, so a metric correction can never masquerade as a market move.
    nonisolated static func comparable(_ series: [VelocitySnapshot]) -> [VelocitySnapshot] {
        series.filter(\.isCurrentBasis)
    }

    /// How many stored days predate the current basis, and the newest of them — so the UI can say
    /// WHY the trend is rebuilding instead of silently rendering nothing.
    nonisolated static func preBasisExcluded(_ series: [VelocitySnapshot]) -> (count: Int, throughDay: String)? {
        let old = series.filter { !$0.isCurrentBasis }
        guard let through = old.map(\.day).max() else { return nil }
        return (old.count, through)
    }

    /// One sentence naming the excluded days, or nil when there are none. Engine-owned so the copy
    /// is testable without a view.
    nonisolated static func preBasisNotice(_ series: [VelocitySnapshot]) -> String? {
        guard let (count, through) = preBasisExcluded(series) else { return nil }
        return "\(count) earlier day\(count == 1 ? "" : "s") through \(through) used the previous weekly-R basis "
            + "(top-N cadence fix) — kept, but not compared against the new basis."
    }

    /// Recent-half mean vs first-half mean of weekly-R, with a flat band. nil under 4 days.
    nonisolated static func trend(_ series: [VelocitySnapshot], band: Double = 0.25) -> VelocityHistoryTrend? {
        let vals = comparable(series).sorted { $0.day < $1.day }.map(\.weeklyR)
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
