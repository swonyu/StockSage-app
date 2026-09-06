import Testing
import Foundation
@testable import StockSage

// MARK: - Earnings proximity (pure)

struct StockSageEarningsTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func severityBands() {
        #expect(StockSageEarnings.severity(daysUntil: 0) == .imminent)
        #expect(StockSageEarnings.severity(daysUntil: 3) == .imminent)
        #expect(StockSageEarnings.severity(daysUntil: 4) == .soon)
        #expect(StockSageEarnings.severity(daysUntil: 10) == .soon)
        #expect(StockSageEarnings.severity(daysUntil: 11) == .clear)
    }

    @Test func proximityCountsDaysAndFloorsThePast() {
        let inTwo = now.addingTimeInterval(2 * 86_400)
        let p = StockSageEarnings.proximity(now: now, earnings: inTwo)
        #expect(p.daysUntil == 2)
        #expect(p.severity == .imminent)
        #expect(p.isWarning)

        #expect(StockSageEarnings.proximity(now: now, earnings: now.addingTimeInterval(7 * 86_400)).severity == .soon)
        #expect(StockSageEarnings.proximity(now: now, earnings: now.addingTimeInterval(30 * 86_400)).severity == .clear)

        // A just-passed date floors to 0 (not negative).
        let past = StockSageEarnings.proximity(now: now, earnings: now.addingTimeInterval(-5 * 86_400))
        #expect(past.daysUntil == 0)
    }

    @Test func parsesSoonestEarningsEpoch() {
        let soon = 1_700_500_000.0, later = 1_700_900_000.0
        let json = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[
          {"raw":\(later),"fmt":"later"},{"raw":\(soon),"fmt":"soon"}]}}}],"error":null}}
        """
        let date = StockSageEarnings.parseEarningsDate(Data(json.utf8))
        #expect(date == Date(timeIntervalSince1970: soon))
    }

    @Test func malformedOrEmptyBodyParsesToNil() {
        #expect(StockSageEarnings.parseEarningsDate(Data("{}".utf8)) == nil)
        #expect(StockSageEarnings.parseEarningsDate(Data("not json".utf8)) == nil)
        let noDates = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}
        """
        #expect(StockSageEarnings.parseEarningsDate(Data(noDates.utf8)) == nil)
    }

    // MARK: - F32: session-cache stale-expiry via deriveEarningsProximity
    //
    // Hand-derived via derive_statecache.swift:
    //   pastDate (2 days past) → timeIntervalSince(now) = -172800 < -86400 → EXPIRED → omitted
    //   futureDate (2 days future) → timeIntervalSince(now) = +172800 → FRESH → included
    //   recentPast (12h past) → timeIntervalSince(now) = -43200 ≥ -86400 → still active
    //
    // A date more than 1 day in the past is treated as expired: the badge and rank demotion clear.
    // A date within 1 day of now (either direction) is kept — proximity(now:earnings:) converts it.

    @Test func deriveEarningsProximityEvictsEntriesMoreThanOneDayInThePast() {
        // Fixture: "AAPL" report was 2 days ago — cache entry that survived the refresh guard.
        // Under F32, deriveEarningsProximity must evict it so no demotion/badge persists.
        let pastDate = now.addingTimeInterval(-2 * 86_400)
        let result = StockSageStore.deriveEarningsProximity(["AAPL": pastDate], now: now)
        #expect(result["AAPL"] == nil,
                "A date 2 days in the past must be evicted — got: \(String(describing: result["AAPL"]))")
    }

    @Test func deriveEarningsProximityKeepsFutureDatesUnchanged() {
        // A date 2 days in the future must remain and produce the right proximity.
        let futureDate = now.addingTimeInterval(2 * 86_400)
        let result = StockSageStore.deriveEarningsProximity(["AAPL": futureDate], now: now)
        #expect(result["AAPL"] != nil, "A date 2 days in the future must not be evicted")
        #expect(result["AAPL"]?.daysUntil == 2)
        #expect(result["AAPL"]?.severity == .imminent)
    }

    @Test func deriveEarningsProximityKeepsRecentPastWithin86400() {
        // A date 12 hours in the past is within -86400s: treated as proximity=0 (floored), still active.
        let recentPast = now.addingTimeInterval(-0.5 * 86_400)   // -43200s ≥ -86400s
        let result = StockSageStore.deriveEarningsProximity(["AAPL": recentPast], now: now)
        #expect(result["AAPL"] != nil, "A date 12h in the past must not be evicted yet")
        #expect(result["AAPL"]?.daysUntil == 0)   // max(0, -0.5.rounded()) = 0
        #expect(result["AAPL"]?.severity == .imminent)
    }

    @Test func deriveEarningsProximityEarningsRankPenaltyClearsForExpiredDate() {
        // End-to-end: earningsRankPenalty must return 0 once the date is evicted.
        // Stale date → evicted → earnings dict has no entry → penalty = 0 (unknown → not penalized).
        let pastDate = now.addingTimeInterval(-2 * 86_400)
        let earningsMap = StockSageStore.deriveEarningsProximity(["AAPL": pastDate], now: now)
        let advice = TradeAdvice(action: .buy, conviction: 0.8, regime: .bullTrend,
                                 rationale: [], stopPrice: 90, targetPrice: 110,
                                 suggestedWeight: 0.1, caveat: "")
        let fakeIdea = StockSageIdea(symbol: "AAPL", market: "M", price: 100, advice: advice, spark: [])
        let penalty = StockSageExpectedValue.earningsRankPenalty(for: fakeIdea, earnings: earningsMap)
        #expect(penalty == 0,
                "Expired earnings date must produce zero rank penalty — got \(penalty)")
    }

    @Test func deriveEarningsProximityEarningsRankPenaltyFiresForFreshImminentDate() {
        // Counterpart: a fresh imminent date must still fire the -2000 penalty.
        let futureDate = now.addingTimeInterval(2 * 86_400)   // 2 days → .imminent
        let earningsMap = StockSageStore.deriveEarningsProximity(["AAPL": futureDate], now: now)
        let advice = TradeAdvice(action: .buy, conviction: 0.8, regime: .bullTrend,
                                 rationale: [], stopPrice: 90, targetPrice: 110,
                                 suggestedWeight: 0.1, caveat: "")
        let fakeIdea = StockSageIdea(symbol: "AAPL", market: "M", price: 100, advice: advice, spark: [])
        let penalty = StockSageExpectedValue.earningsRankPenalty(for: fakeIdea, earnings: earningsMap)
        #expect(penalty == 2000,
                "Imminent fresh earnings must produce the -2000 rank penalty — got \(penalty)")
    }

    // MARK: - A2: earningsCheckedAt TTL guard + the pure refreshEarnings core
    //
    // `refreshEarnings` itself is an instance method on the `@MainActor` singleton and hits the
    // real network — like every other StockSageStore test in this file (and per
    // StockSageNewListingReconcileTests.swift's documented rationale), these exercise the pure
    // `nonisolated static` rule it's a thin shell over, never the singleton and never the network.

    @Test func shouldRefreshEarningsIsTrueWhenNeverChecked() {
        #expect(StockSageStore.shouldRefreshEarnings(checkedAt: nil, now: now))
    }

    // Genuine boundary straddle, hand-derived: checkedAt = now; +86_399s = 23h59m59s elapsed
    // (still inside the TTL, guard stays closed); +86_400s = exactly 24h00m00s elapsed (TTL's own
    // `>=` opens the guard at that instant, not one second later).
    @Test func shouldRefreshEarningsTTLBoundaryStraddle() {
        let checkedAt = now
        let justUnder = checkedAt.addingTimeInterval(86_399)
        let exactlyAt = checkedAt.addingTimeInterval(86_400)
        #expect(!StockSageStore.shouldRefreshEarnings(checkedAt: checkedAt, now: justUnder),
                "23h59m59s after checkedAt must still be within the TTL")
        #expect(StockSageStore.shouldRefreshEarnings(checkedAt: checkedAt, now: exactlyAt),
                "Exactly 24h00m00s after checkedAt must open the TTL guard")
    }

    @Test func earningsRefreshOutcomeStampsCheckedAtOnANilFetch() async {
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { nil }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == nil)
    }

    @Test func earningsRefreshOutcomeStampsCheckedAtOnADatedFetch() async {
        let found = now.addingTimeInterval(10 * 86_400)
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { found }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == found)
    }

    @Test func earningsRefreshOutcomeIgnoresAStalePastDateButStillStampsCheckedAt() async {
        // Honesty floor: the provider returned SOMETHING, but it's a report date more than a day
        // in the past — the unchanged `> -86_400` fetch guard treats that as unusable, yet we DID
        // ask, so checkedAt must still be stamped (never left nil, which would re-ask forever).
        let stale = now.addingTimeInterval(-2 * 86_400)
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { stale }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == nil)
    }

    @Test func earningsRefreshOutcomeDoesNotReenterFetchInsideTheTTL() async {
        let checkedAt = now
        let stillFresh = checkedAt.addingTimeInterval(86_399)   // one second inside the 24h TTL
        var fetchWasCalled = false
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: checkedAt, now: stillFresh) {
            fetchWasCalled = true
            return stillFresh.addingTimeInterval(86_400)
        }
        #expect(outcome == nil, "Inside the TTL, refreshEarnings must no-op, not re-stamp")
        #expect(!fetchWasCalled, "The TTL guard must short-circuit BEFORE the fetch closure ever runs")
    }

    // MARK: - A2: catalystRecords / applyCatalystRecords disk round trip
    //
    // StockSageCatalystRecordCacheTests already pins the cache type's OWN round trip; this pins
    // the store-level dict ↔ Record conversion on top of it, through an actual save()/load() at a
    // temp URL (never the real Application Support location).

    @Test func catalystRecordsRoundTripThroughTheDiskCache() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageEarningsCheckedAtTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalyst_records_v1.json")

        // AAPL: asked, provider returned a real date. NVDA: asked, provider had nothing — the
        // honest dated negative (present in checkedAt, absent from earningsDates).
        let earningsDates = ["AAPL": now.addingTimeInterval(30 * 86_400)]
        let earningsCheckedAt = ["AAPL": now, "NVDA": now]

        let records = StockSageStore.catalystRecords(earningsDates: earningsDates, earningsCheckedAt: earningsCheckedAt)
        StockSageCatalystRecordCache(entries: records, savedAt: now).save(to: url)

        let loaded = StockSageCatalystRecordCache.load(from: url)
        let restored = StockSageStore.applyCatalystRecords(loaded?.entries ?? [])
        #expect(restored.dates == earningsDates)
        #expect(restored.checkedAt == earningsCheckedAt)
    }

    @Test func aSymbolNotYetSweptHasNoCheckedAtEntry() {
        // MSFT was never asked (no Record for it at all) — applying a record set that doesn't
        // mention it must leave it with NO entry in either dict, never inferred as "checked, none".
        let restored = StockSageStore.applyCatalystRecords([
            .init(symbol: "AAPL", earningsDate: nil, checkedAt: now, source: "yahoo"),
        ])
        #expect(restored.checkedAt["MSFT"] == nil)
        #expect(restored.dates["MSFT"] == nil)
        #expect(restored.checkedAt["AAPL"] == now)
        #expect(restored.dates["AAPL"] == nil)   // AAPL's own record is the honest negative too
    }
}
