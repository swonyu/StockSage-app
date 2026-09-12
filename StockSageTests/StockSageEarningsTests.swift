import Testing
import Foundation
@testable import StockSage

// MARK: - Earnings proximity (pure)

struct StockSageEarningsTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test @MainActor func laterStartedCatalystRequestOwnsPublication() async throws {
        let suite = "earnings.ownership.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let pause = EarningsPause()
        let negative = StockSageCatalystChain.Outcome(earningsDate: nil, dateRangeEnd: nil,
            confirmed: nil, status: .unchecked, source: "synthetic", sourcesAsked: ["synthetic"],
            projectionBasis: nil, anySourceAnswered: true)
        let date = now.addingTimeInterval(86_400)
        let positive = StockSageCatalystChain.Outcome(earningsDate: date, dateRangeEnd: nil,
            confirmed: true, status: .dateKnown, source: "synthetic", sourcesAsked: ["synthetic"],
            projectionBasis: nil, anySourceAnswered: true)
        let older = Task { @MainActor in
            await store.refreshCatalyst(symbol: "AAPL", now: now, allowed: { true }, resolve: { _, _ in
                await pause.suspend(); return negative
            })
        }
        defer { older.cancel(); pause.release() }
        try await pause.waitUntilSuspended()
        await store.refreshCatalyst(symbol: "aapl", now: now.addingTimeInterval(1), allowed: { true },
                                   resolve: { _, _ in positive })
        pause.release()
        await older.value
        #expect(store.catalystChain["AAPL"]?.earningsDate == date)
        #expect(store.earningsDates["AAPL"] == date)
        #expect(store.earningsCheckedAt["AAPL"] == now.addingTimeInterval(1))
    }

    @MainActor private final class EarningsPause {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilSuspended() async throws {
            for _ in 0..<100 where continuation == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(continuation != nil, "The real request/publication boundary must be reached")
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @Test(arguments: [200, 429], [false, true])
    @MainActor func yahooSuspendedReplyCannotSurviveInvalidation(status: Int, cancel: Bool) async throws {
        let pause = EarningsPause()
        var permitted = true
        var calls = 0
        var sleeps: [UInt64] = []
        let request = URLRequest(url: URL(string: "https://example.invalid/earnings")!)
        let body = Data(#"{"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}"#.utf8)
        let task = Task { @MainActor in
            await StockSageEarnings.get(request, allowed: { permitted }, transport: { req in
                calls += 1
                if calls == 1 { await pause.suspend() }
                return (body, HTTPURLResponse(url: req.url!, statusCode: calls == 1 ? status : 200,
                                              httpVersion: nil, headerFields: nil)!)
            }, sleep: { sleeps.append($0) })
        }
        defer { task.cancel(); pause.release() }
        try await pause.waitUntilSuspended()
        #expect(calls == 1)
        if cancel { task.cancel() } else { permitted = false }
        pause.release()
        let result = await task.value
        #expect(result == nil)
        #expect(calls == 1 && sleeps.isEmpty, "No retry or backoff may start after invalidation")
    }

    @Test(arguments: [429, 503], [false, true])
    @MainActor func yahooInvalidationDuringBackoffCannotStartAnotherRequest(status: Int, cancel: Bool) async throws {
        let pause = EarningsPause()
        var permitted = true
        var calls = 0
        var sleeps: [UInt64] = []
        let request = URLRequest(url: URL(string: "https://example.invalid/earnings")!)
        let task = Task { @MainActor in
            await StockSageEarnings.get(request, allowed: { permitted }, transport: { req in
                calls += 1
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: calls == 1 ? status : 200,
                                               httpVersion: nil, headerFields: nil)!)
            }, sleep: { delay in
                sleeps.append(delay)
                await pause.suspend()
                try Task.checkCancellation()
            })
        }
        defer { task.cancel(); pause.release() }
        try await pause.waitUntilSuspended()
        #expect(calls == 1 && sleeps == [1_000_000_000])
        if cancel { task.cancel() } else { permitted = false }
        pause.release()
        let result = await task.value
        #expect(result == nil && calls == 1)
        #expect(sleeps == [1_000_000_000])
    }

    @Test(arguments: [false, true])
    @MainActor func yahooValidRetryBudgetRemainsThreeAttempts(exhaust: Bool) async {
        var calls = 0
        var sleeps: [UInt64] = []
        let request = URLRequest(url: URL(string: "https://example.invalid/earnings")!)
        let body = Data("fixture".utf8)
        let result = await StockSageEarnings.get(request, allowed: { true }, transport: { req in
            calls += 1
            return (body, HTTPURLResponse(url: req.url!, statusCode: exhaust || calls < 3 ? 503 : 200,
                                          httpVersion: nil, headerFields: nil)!)
        }, sleep: { sleeps.append($0) })
        #expect(calls == 3 && sleeps == [1_000_000_000, 2_000_000_000])
        #expect(result == (exhaust ? nil : body))
    }

    @Test @MainActor func yahooDeniedBeforeRequestDoesNotCallTransportOrSleep() async {
        let request = URLRequest(url: URL(string: "https://example.invalid/earnings")!)
        var calls = 0
        let result = await StockSageEarnings.get(request, allowed: { false }, transport: { req in
            calls += 1
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in Issue.record("Unexpected backoff") })
        #expect(result == nil && calls == 0)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func invalidatedChainCannotPublishOverRetainedEarnings(cancel: Bool, negative: Bool) async throws {
        let suite = "StockSageEarningsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let originalDate = now.addingTimeInterval(10 * 86_400)
        let original = StockSageCatalystChain.Outcome(earningsDate: originalDate, dateRangeEnd: nil,
            confirmed: false, status: .dateKnown, source: "fixture original",
            sourcesAsked: ["fixture original"], projectionBasis: nil, anySourceAnswered: true)
        store.publishCatalyst(original, symbol: "AAPL", checkedAt: now, allowed: { true })
        #expect(store.earningsDates["AAPL"] == originalDate && store.earningsCheckedAt["AAPL"] == now)
        let records = store.catalystChain
        let dates = store.earningsDates
        let checked = store.earningsCheckedAt
        let replacement = StockSageCatalystChain.Outcome(
            earningsDate: negative ? nil : now.addingTimeInterval(20 * 86_400), dateRangeEnd: nil,
            confirmed: negative ? nil : true, status: negative ? .unchecked : .dateKnown,
            source: "fixture late", sourcesAsked: ["fixture late"], projectionBasis: nil, anySourceAnswered: true)
        let pause = EarningsPause()
        var permitted = true
        let task = Task { @MainActor in
            await pause.suspend()
            store.publishCatalyst(replacement, symbol: "AAPL", checkedAt: now.addingTimeInterval(86_400),
                                  allowed: { permitted })
        }
        defer { task.cancel(); pause.release() }
        try await pause.waitUntilSuspended()
        if cancel { task.cancel() } else { permitted = false }
        pause.release()
        await task.value
        #expect(store.catalystChain == records)
        #expect(store.earningsDates == dates && store.earningsCheckedAt == checked)
        // The same synchronous production publication still accepts a legitimate completion.
        store.publishCatalyst(replacement, symbol: "AAPL", checkedAt: now.addingTimeInterval(86_400),
                              allowed: { true })
        #expect(store.catalystChain["AAPL"]?.source == "fixture late")
        #expect(store.earningsDates["AAPL"] == replacement.earningsDate)
        #expect(store.earningsCheckedAt["AAPL"] == now.addingTimeInterval(86_400))
    }

    @Test(arguments: [false, true])
    @MainActor func invalidatedEarningsChainDoesNotStartHistory(cancel: Bool) async throws {
        let pause = EarningsPause()
        var permitted = true
        var yahooCalls = 0
        var historyCalls = 0
        let task = Task { @MainActor in
            await StockSageCatalystChain.resolve(now: now, stillValid: { permitted },
                massiveCalendar: { .answered(nil) },
                yahooCalendar: {
                    await pause.suspend()
                    yahooCalls += 1
                    return .answered(.init(date: now.addingTimeInterval(86_400), dateRangeEnd: nil, isEstimate: false))
                }, history: { historyCalls += 1; return .answered([]) })
        }
        defer { task.cancel(); pause.release() }
        try await pause.waitUntilSuspended()
        if cancel { task.cancel() } else { permitted = false }
        pause.release()
        let result = await task.value
        #expect(yahooCalls == 1 && historyCalls == 0)
        #expect(result.earningsDate == nil && result.status == .unchecked)
        #expect(result.sourcesAsked == [StockSageMassiveEarnings.source])
        #expect(result.anySourceAnswered, "Keep provenance from the completed first source")
    }

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
        // `.answered(nil)`: the provider WAS asked and responded 200, just with no date.
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { .answered(nil) }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == nil)
    }

    @Test func earningsRefreshOutcomeStampsCheckedAtOnADatedFetch() async {
        let found = now.addingTimeInterval(10 * 86_400)
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { .answered(found) }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == found)
    }

    @Test func earningsRefreshOutcomeIgnoresAStalePastDateButStillStampsCheckedAt() async {
        // Honesty floor: the provider returned SOMETHING, but it's a report date more than a day
        // in the past — the unchanged `> -86_400` fetch guard treats that as unusable, yet we DID
        // ask, so checkedAt must still be stamped (never left nil, which would re-ask forever).
        let stale = now.addingTimeInterval(-2 * 86_400)
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { .answered(stale) }
        #expect(outcome?.checkedAt == now)
        #expect(outcome?.earningsDate == nil)
    }

    @Test func earningsRefreshOutcomeDoesNotReenterFetchInsideTheTTL() async {
        let checkedAt = now
        let stillFresh = checkedAt.addingTimeInterval(86_399)   // one second inside the 24h TTL
        var fetchWasCalled = false
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: checkedAt, now: stillFresh) {
            fetchWasCalled = true
            return .answered(stillFresh.addingTimeInterval(86_400))
        }
        #expect(outcome == nil, "Inside the TTL, refreshEarnings must no-op, not re-stamp")
        #expect(!fetchWasCalled, "The TTL guard must short-circuit BEFORE the fetch closure ever runs")
    }

    // MARK: Blocker fix 2026-09-06 — a FAILED request must never be stamped as an observation.
    //
    // Before this fix, `fetchNextEarnings` returned `nil` identically for "asked, 200, no date"
    // AND for "never asked" (external access off, non-equity, timeout, non-200, parse failure),
    // so the store stamped a dated "none known" record for a request that was never answered.
    // `.unavailable` is the ONLY outcome that must leave `checkedAt` untouched (returns nil).

    @Test func earningsRefreshOutcomeStampsNothingWhenNeverAnswered() async {
        var fetchWasCalled = false
        let outcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) {
            fetchWasCalled = true
            return .unavailable
        }
        #expect(fetchWasCalled, "the fetch DID run (TTL passed) — it just never got an answer")
        #expect(outcome == nil, "an unanswered request must stamp NOTHING, not a dated negative")
    }

    @Test func earningsRefreshOutcomeUnavailableLeavesCheckedAtNilSoTheNextSweepRetries() async {
        // Never-answered must not poison the TTL gate: the next sweep should see checkedAt still
        // nil (never stamped) and immediately re-ask, rather than waiting out a 24h TTL earned by
        // a request that was never actually answered.
        let firstOutcome = await StockSageStore.earningsRefreshOutcome(checkedAt: nil, now: now) { .unavailable }
        #expect(firstOutcome == nil)
        let stillNeverChecked: Date? = firstOutcome?.checkedAt   // nil: nothing to carry forward
        #expect(StockSageStore.shouldRefreshEarnings(checkedAt: stillNeverChecked, now: now.addingTimeInterval(1)))
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

    // MARK: - W1 (2026-09-06): the date RANGE + isEarningsDateEstimate flag
    //
    // `parseEarningsCalendar` is a NEW, richer read of the exact same `calendarEvents` body
    // `parseEarningsDate` already parses (untouched above — min-epoch behaviour preserved).

    @Test func parsesRangeAndConfirmedFlag() {
        // Hand-derived: two epochs, 400,000s apart; isEarningsDateEstimate explicitly false.
        let start = 1_701_000_000.0, end = 1_701_400_000.0
        let json = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[
          {"raw":\(start),"fmt":"start"},{"raw":\(end),"fmt":"end"}],"isEarningsDateEstimate":false}}}]}}
        """
        let info = StockSageEarnings.parseEarningsCalendar(Data(json.utf8))
        #expect(info?.date == Date(timeIntervalSince1970: start))
        #expect(info?.dateRangeEnd == Date(timeIntervalSince1970: end))
        #expect(info?.isEstimate == false)
    }

    @Test func parsesEstimateTrueFlag() {
        let raw = 1_701_000_000.0
        let json = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[
          {"raw":\(raw)}],"isEarningsDateEstimate":true}}}]}}
        """
        let info = StockSageEarnings.parseEarningsCalendar(Data(json.utf8))
        #expect(info?.date == Date(timeIntervalSince1970: raw))
        #expect(info?.dateRangeEnd == nil, "a single-element earningsDate must not fabricate a range end")
        #expect(info?.isEstimate == true)
    }

    @Test func missingEstimateFlagDefaultsToTrueTheSaferUnconfirmedReading() {
        // Yahoo doesn't always populate isEarningsDateEstimate — absence must read as
        // "unconfirmed", never silently as "confirmed" (a false negative is the safer failure).
        let raw = 1_701_000_000.0
        let json = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[{"raw":\(raw)}]}}}]}}
        """
        let info = StockSageEarnings.parseEarningsCalendar(Data(json.utf8))
        #expect(info?.isEstimate == true)
    }

    @Test func malformedCalendarBodyParsesToNil() {
        #expect(StockSageEarnings.parseEarningsCalendar(Data("{}".utf8)) == nil)
        #expect(StockSageEarnings.parseEarningsCalendar(Data("not json".utf8)) == nil)
        let noDates = """
        {"quoteSummary":{"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}
        """
        #expect(StockSageEarnings.parseEarningsCalendar(Data(noDates.utf8)) == nil)
    }

    // MARK: - W1: Yahoo `earningsHistory` (Tadawul's only candidate projection source)

    @Test func parsesEarningsHistorySortedOldestFirst() {
        let older = 1_700_000_000.0, newer = 1_701_000_000.0
        let json = """
        {"quoteSummary":{"result":[{"earningsHistory":{"history":[
          {"quarter":{"raw":\(newer)}},{"quarter":{"raw":\(older)}}]}}]}}
        """
        let dates = StockSageEarnings.parseEarningsHistory(Data(json.utf8))
        #expect(dates == [Date(timeIntervalSince1970: older), Date(timeIntervalSince1970: newer)])
    }

    @Test func partialEarningsHistoryCannotEarnACompleteObservation() {
        let good = 1_700_000_000.0
        let json = """
        {"quoteSummary":{"result":[{"earningsHistory":{"history":[
          {"quarter":{"raw":\(good)}},{"quarter":{}},{"notQuarter":1},{}]}}]}}
        """
        let dates = StockSageEarnings.parseEarningsHistory(Data(json.utf8))
        #expect(dates == nil)
    }

    @Test func earningsHistoryMissingModuleIsUnavailable() {
        #expect(StockSageEarnings.parseEarningsHistory(Data("{}".utf8)) == nil)
        #expect(StockSageEarnings.parseEarningsHistory(Data("not json".utf8)) == nil)
        #expect(StockSageEarnings.parseEarningsHistory(Data(#"{"quoteSummary":{"result":[{"earningsHistory":{"history":[]}}]}}"#.utf8)) == [])
    }

    @Test func calendarResponseDistinguishesEmptyMalformedAndProviderErrors() {
        for json in ["{}", "not json", #"{"quoteSummary":{"result":[]}}"#,
                     #"{"quoteSummary":{"result":[{}]}}"#,
                     #"{"quoteSummary":{"error":{"code":"Denied"},"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}"#] {
            if case .answered = StockSageEarnings.parseCalendarOutcome(Data(json.utf8)) {
                Issue.record("Malformed/error response must be unavailable: \(json)")
            }
        }
        let empty = Data(#"{"quoteSummary":{"error":null,"result":[{"calendarEvents":{"earnings":{"earningsDate":[]}}}]}}"#.utf8)
        if case .answered(let info) = StockSageEarnings.parseCalendarOutcome(empty) { #expect(info == nil) }
        else { Issue.record("An explicit valid empty array must remain answered") }
        for raw in ["true", "-1", "0", "1e100", "\"bad\""] {
            let json = "{\"quoteSummary\":{\"result\":[{\"calendarEvents\":{\"earnings\":{\"earningsDate\":[{\"raw\":1701000000},{\"raw\":\(raw)}]}}}]}}"
            if case .answered = StockSageEarnings.parseCalendarOutcome(Data(json.utf8)) {
                Issue.record("A partial/invalid date range cannot be answered")
            }
        }
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

    // MARK: Blocker fix 2026-09-06 — a `.projected` record must never reach `earningsDates` on
    // restore, the same rule `refreshCatalyst` already applies at write time. Without this, a
    // relaunch bypasses that write-time guard entirely and a GUESS becomes an announced date.

    @Test func aProjectedRecordRoundTripsWithoutLeakingIntoEarningsDatesButCheckedAtSurvives() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageProjectedRoundTripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalyst_records_v1.json")

        let projectedDate = now.addingTimeInterval(45 * 86_400)
        let record = StockSageCatalystRecordCache.Record(
            symbol: "TSLA", earningsDate: projectedDate, checkedAt: now, source: "projection",
            status: .projected, projectionBasis: "median gap of last 3 reports = 91 d from 2026-07-30")
        StockSageCatalystRecordCache(entries: [record], savedAt: now).save(to: url)

        let loaded = StockSageCatalystRecordCache.load(from: url)
        let restored = StockSageStore.applyCatalystRecords(loaded?.entries ?? [])
        #expect(restored.dates["TSLA"] == nil, "a PROJECTED date must never reach earningsDates on restore")
        #expect(restored.checkedAt["TSLA"] == now, "checkedAt must still survive so the TTL guard doesn't re-ask immediately")
    }

    @Test func aDateKnownRecordStillRestoresIntoEarningsDates() {
        // Sanity companion to the projected-exclusion test above: a genuinely KNOWN date must
        // still flow through — the fix excludes ONLY `.projected`, nothing else.
        let date = now.addingTimeInterval(10 * 86_400)
        let restored = StockSageStore.applyCatalystRecords([
            .init(symbol: "NVDA", earningsDate: date, checkedAt: now, source: "eodhd calendar", status: .dateKnown),
        ])
        #expect(restored.dates["NVDA"] == date)
        #expect(restored.checkedAt["NVDA"] == now)
    }
}
