import Testing
import Foundation
@testable import StockSage

// MARK: - Velocity history (pure)

struct StockSageVelocityHistoryTests {

    // FIXTURE MIGRATION (2026-09-12), not an assertion edit. `lastDelta`/`trend` now compare only
    // rows on the CURRENT metric basis, so a fixture standing in for days THIS build recorded must
    // be stamped — an unstamped row means "written by the pre-fix code", which is exactly what the
    // legacy-decode test below asserts. The expected VALUES are unchanged.
    private func snaps(_ rs: [Double]) -> [VelocitySnapshot] {
        rs.enumerated().map {
            VelocitySnapshot(day: String(format: "2026-06-%02d", $0.offset + 1), weeklyR: $0.element,
                             metricBasis: VelocityMetricBasis.current.rawValue)
        }
    }

    @Test func recordReplacesSameDayAndCaps() {
        var s = StockSageVelocityHistory.record([], day: "2026-06-01", weeklyR: 2.0)
        s = StockSageVelocityHistory.record(s, day: "2026-06-01", weeklyR: 3.0)   // same day → replace
        #expect(s.count == 1)
        #expect(s[0].weeklyR == 3.0)
        s = StockSageVelocityHistory.record(s, day: "2026-06-02", weeklyR: 4.0, maxDays: 2)
        s = StockSageVelocityHistory.record(s, day: "2026-06-03", weeklyR: 5.0, maxDays: 2)
        #expect(s.count == 2)
        #expect(s.map(\.day) == ["2026-06-02", "2026-06-03"])    // oldest dropped by the cap
    }

    @Test func changeSinceLastNamesTheMover() {
        let basis = VelocityMetricBasis.current.rawValue
        let prev = VelocitySnapshot(day: "2026-06-01", weeklyR: 1.0, bestSymbol: "AAPL",
                                    fastestSymbol: "AAPL", metricBasis: basis)
        let cur = VelocitySnapshot(day: "2026-06-02", weeklyR: 2.5, bestSymbol: "BTC-USD",
                                   fastestSymbol: "AAPL", metricBasis: basis)
        let c = StockSageVelocityHistory.changeSinceLast([prev, cur])!
        #expect(abs(c.weeklyRDelta - 1.5) < 1e-9)
        #expect(c.bestChangedTo == "BTC-USD")      // best moved AAPL → BTC-USD
        #expect(c.fastestChangedTo == nil)         // fastest unchanged (AAPL)
        #expect(StockSageVelocityHistory.changeSinceLast([prev]) == nil)   // <2 → nil
    }

    @Test func snapshotDecodesLegacyJSONWithoutSymbols() {
        // Migration safety: snapshots persisted before the symbol fields must still decode.
        let legacy = #"{"day":"2026-06-01","weeklyR":2.0}"#.data(using: .utf8)!
        let s = try! JSONDecoder().decode(VelocitySnapshot.self, from: legacy)
        #expect(s.weeklyR == 2.0)
        #expect(s.bestSymbol == nil)
        #expect(s.fastestSymbol == nil)
        // …and the 2026-09-12 basis marker is absent too, which MEANS the pre-fix basis: this row
        // was written by the code that multiplied a top-N sum by the whole lane's cadence.
        #expect(s.metricBasis == nil)
        #expect(s.basisRaw == VelocityMetricBasis.wholeLaneCadenceV1.rawValue)
        #expect(!s.isCurrentBasis)
    }

    // MARK: Metric basis (5.1) — a cadence correction must not read as a market move

    @Test func preFixDaysAreKeptButNeverComparedAgainstTheNewBasis() {
        let old = (1...3).map {
            VelocitySnapshot(day: String(format: "2026-06-%02d", $0), weeklyR: 5.0)   // unstamped ⇒ v1
        }
        let new = (4...6).map {
            VelocitySnapshot(day: String(format: "2026-06-%02d", $0), weeklyR: 4.0,
                             metricBasis: VelocityMetricBasis.current.rawValue)
        }
        let mixed = old + new
        // Kept: nothing is deleted from the stored series.
        #expect(mixed.count == 6)
        #expect(StockSageVelocityHistory.comparable(mixed).count == 3)
        // The 5.0 -> 4.0 step is the CORRECTION, not a market move. Comparing across the seam
        // would report -1.0R "since last session"; comparing within the new basis reports 0.
        #expect(StockSageVelocityHistory.lastDelta(mixed) == 0)
        #expect(StockSageVelocityHistory.lastDelta(old + [new[0]]) == nil,
                "one same-basis day is not two — no delta rather than a cross-basis one")
        // The trend needs 4 same-basis days; three is not enough, and the old ones cannot fill in.
        #expect(StockSageVelocityHistory.trend(mixed) == nil)

        // And the owner is told why the line is rebuilding.
        let notice = StockSageVelocityHistory.preBasisNotice(mixed)
        #expect(notice?.contains("3 earlier days through 2026-06-03") == true)
        #expect(notice?.contains("previous weekly-R basis") == true)
        #expect(StockSageVelocityHistory.preBasisNotice(new) == nil, "no old days ⇒ no notice")
    }

    // An unrecognized (newer-build) basis must read as not-current rather than being compared,
    // without making the whole 60-day history unreadable.
    @Test func anUnknownFutureBasisDecodesAndIsExcluded() throws {
        let future = #"{"day":"2026-06-09","weeklyR":9.0,"metricBasis":99}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(VelocitySnapshot.self, from: future)
        #expect(s.metricBasis == 99)
        #expect(!s.isCurrentBasis)
        #expect(StockSageVelocityHistory.comparable([s]).isEmpty)
    }

    @Test func recordStampsTheCurrentBasis() {
        let s = StockSageVelocityHistory.record([], day: "2026-06-01", weeklyR: 2.0)
        #expect(s[0].metricBasis == VelocityMetricBasis.current.rawValue)
        #expect(s[0].isCurrentBasis)
    }

    // The "Mover:" line names SYMBOLS, which are not on the weeklyR basis at all — suppressing it
    // because of a cadence fix would hide information this change has nothing to do with.
    @Test func theMoverLineSurvivesTheBasisSeam() throws {
        let prev = VelocitySnapshot(day: "2026-06-01", weeklyR: 5.0, bestSymbol: "AAPL", fastestSymbol: "AAPL")
        let cur = VelocitySnapshot(day: "2026-06-02", weeklyR: 4.0, bestSymbol: "BTC-USD",
                                   fastestSymbol: "AAPL", metricBasis: VelocityMetricBasis.current.rawValue)
        let c = try #require(StockSageVelocityHistory.changeSinceLast([prev, cur]))
        #expect(c.bestChangedTo == "BTC-USD", "the mover is still reported across the seam")
        #expect(c.weeklyRDelta == 0, "…but the cross-basis R delta is NOT")
    }

    @Test func lastDeltaIsLatestMinusPrevious() {
        #expect(abs(StockSageVelocityHistory.lastDelta(snaps([1, 3]))! - 2) < 1e-9)    // 3 − 1
        #expect(abs(StockSageVelocityHistory.lastDelta(snaps([3, 1]))! - (-2)) < 1e-9) // 1 − 3
        #expect(StockSageVelocityHistory.lastDelta(snaps([5])) == nil)                 // <2 → nil
    }

    @Test func trendComparesRecentHalfToEarly() {
        #expect(StockSageVelocityHistory.trend(snaps([1, 1, 3, 3]))?.direction == .rising)   // 1→3
        #expect(StockSageVelocityHistory.trend(snaps([3, 3, 1, 1]))?.direction == .fading)   // 3→1
        #expect(StockSageVelocityHistory.trend(snaps([2, 2, 2, 2]))?.direction == .flat)     // 2→2
        #expect(StockSageVelocityHistory.trend(snaps([1, 2, 3])) == nil)                     // <4 days
        // Odd count 5: half=2 → early[first 2]=1, recent[last 3]=3 → rising (no off-by-one crash).
        #expect(StockSageVelocityHistory.trend(snaps([1, 1, 3, 3, 3]))?.direction == .rising)
        let t = StockSageVelocityHistory.trend(snaps([1, 1, 3, 3]))!
        #expect(abs(t.earlyAvg - 1) < 1e-9)
        #expect(abs(t.recentAvg - 3) < 1e-9)
        #expect(abs(t.delta - 2) < 1e-9)
    }

    // MARK: store save() day-key union (2026-07-09 C8 — a second app instance's stale
    // whole-array write silently deleted other days' snapshots from the durable trend
    // history. Union by day: this process's days win, disk-only days are preserved.)

    @Test func staleProcessSaveCannotDeleteAnotherDaysSnapshot() {
        let suite = "velocity.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Store B loads while the key is EMPTY (its memory holds no days).
        let b = StockSageVelocityHistoryStore(defaults: defaults, key: "velocityHistory.v1")
        // Another process then lands an OLD day's snapshot on disk.
        let old = [VelocitySnapshot(day: "2026-07-01", weeklyR: 1.5, bestSymbol: "OLD", fastestSymbol: nil)]
        defaults.set(try! JSONEncoder().encode(old), forKey: "velocityHistory.v1")
        // Stale B records today and saves — pre-fix this clobbered 2026-07-01 forever.
        b.record(weeklyR: 2.0)
        let final = StockSageVelocityHistoryStore(defaults: defaults, key: "velocityHistory.v1")
        #expect(final.series.contains { $0.day == "2026-07-01" && $0.weeklyR == 1.5 })
        #expect(final.series.contains { $0.day == StockSageVelocityHistoryStore.dayKey(Date()) && $0.weeklyR == 2.0 })
        #expect(final.series == final.series.sorted { $0.day < $1.day })   // stays day-sorted
    }

    @MainActor @Test(arguments: ["broken-at-load", "broken-after-load", "wrong-type-at-load",
                                "wrong-type-after-load", "nan", "positive-infinity", "negative-infinity"])
    func rejectedRecordPreservesStoredBytesAndLastValidSeries(failure: String) throws {
        let suite = "velocity.preservation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "history"
        let saved = [VelocitySnapshot(day: "2000-01-01", weeklyR: 1.5),
                     VelocitySnapshot(day: "2000-01-02", weeklyR: 2.5,
                                      metricBasis: VelocityMetricBasis.current.rawValue)]
        let savedData = try JSONEncoder().encode(saved)
        let startsUnreadable = failure.hasSuffix("at-load")
        if startsUnreadable {
            if failure.hasPrefix("wrong-type") { defaults.set("unexpected stored string", forKey: key) }
            else { defaults.set(Data("{broken".utf8), forKey: key) }
        } else {
            defaults.set(savedData, forKey: key)
        }
        let store = StockSageVelocityHistoryStore(defaults: defaults, key: key)
        #expect(store.series == (startsUnreadable ? [] : saved))
        #expect((store.lastError != nil) == startsUnreadable)

        if failure == "broken-after-load" { defaults.set(Data("{broken".utf8), forKey: key) }
        if failure == "wrong-type-after-load" { defaults.set("unexpected stored string", forKey: key) }
        let previousSeries = store.series
        let previousData = defaults.data(forKey: key)
        let previousString = defaults.string(forKey: key)
        let weeklyR: Double
        switch failure {
        case "nan": weeklyR = .nan
        case "positive-infinity": weeklyR = .infinity
        case "negative-infinity": weeklyR = -.infinity
        default: weeklyR = 3
        }
        store.record(weeklyR: weeklyR)
        #expect(store.lastError != nil)
        #expect(store.series == previousSeries)
        #expect(defaults.data(forKey: key) == previousData)
        #expect(defaults.string(forKey: key) == previousString)

        // An external repair becomes readable on the next record without discarding old-basis days.
        defaults.set(savedData, forKey: key)
        store.record(weeklyR: 3)
        #expect(store.lastError == nil)
        #expect(store.series.contains(saved[0]))
        #expect(store.series.contains(saved[1]))
        #expect(store.series.last?.day == StockSageVelocityHistoryStore.dayKey(Date()))
        #expect(store.series.last?.weeklyR == 3)
        #expect(store.series.last?.isCurrentBasis == true)
        let persistedData = try #require(defaults.data(forKey: key))
        let persisted = try JSONDecoder().decode([VelocitySnapshot].self, from: persistedData)
        #expect(persisted == store.series)
    }

    @MainActor @Test func missingKeyCanStartANewHistory() throws {
        let suite = "velocity.fresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageVelocityHistoryStore(defaults: defaults, key: "history")
        #expect(store.series.isEmpty)
        #expect(store.lastError == nil)
        store.record(weeklyR: 2)
        #expect(store.lastError == nil)
        let restored = StockSageVelocityHistoryStore(defaults: defaults, key: "history")
        #expect(restored.series == store.series)
        #expect(restored.series.count == 1)
        #expect(restored.series.first?.weeklyR == 2)
        #expect(restored.series.first?.isCurrentBasis == true)
    }
}
