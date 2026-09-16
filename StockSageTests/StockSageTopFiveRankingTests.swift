import Foundation
import Testing
@testable import StockSage

// Fixtures build a minimal but STRUCTURALLY REAL Q.Receipt directly via its memberwise init,
// rather than the full capture()/prepare() pipeline, so each score component can be controlled
// independently and hand-derived. The scoring formula itself is restated in comments here (not
// read back from the implementation): horizonFit = min(max(return,0),20)/20*10; technical =
// aligned:10/mixed:5/conflicted-or-insufficient:0; catalyst = uncited:0/news:6/insiderFiling:8;
// liquidity = min(ratio,4)/4*10; freshness = max(0, 10 - staleHours); insider = signed, decayed,
// clustered; counterevidence = -2 per contrary confluence check; hard penalties -50/-50/-10 for
// unready capture / contradictory basis / no catalyst at all.
@Suite("Deterministic Top-5 ranking")
struct StockSageTopFiveRankingTests {
    private typealias T = StockSageTopFiveRanking
    private typealias Q = StockSageResearchQualification
    private typealias E = StockSageMassiveEvents
    private let now = Date(timeIntervalSince1970: 1_789_477_200) // 2026-09-15 13:00 UTC

    private func earnings() -> Q.Earnings {
        .init(relation: "outside", outcome: "answered",
              date: now.addingTimeInterval(60 * 86_400), confirmed: true,
              checkedAt: now, recordedAt: now)
    }
    private func catalyst(_ kind: Q.Catalyst.Kind, key: String = "news.item.fixture") -> Q.Catalyst {
        .init(key: key, identity: "fixture", kind: kind, date: now.addingTimeInterval(-3600), checkedAt: now)
    }
    /// `qualified` controls whether `reasons`/`exclusions()` allow `isQualified` to read true;
    /// the simplest lever is `originalAction` (exclusions() requires Buy/Strong Buy first).
    private func receipt(symbol: String = "ACME", qualified: Bool = true, horizonReturn: Double = 10,
                        volumeRatio: Double = 3, criticalCaptureReady: Bool = true,
                        cited: Bool = true, catalystKind: Q.Catalyst.Kind = .news,
                        noCatalyst: Bool = false, confluenceVerdict: Q.TechnicalVerdict? = .aligned,
                        contraryChecks: Int = 0, evidenceAsOf: Date? = nil) -> Q.Receipt {
        let m = Q.Measurements(completedBars: 70, close: 100, sma20: 95, horizonReturnPercent: horizonReturn,
            volumeRatio: volumeRatio, atr14: 2, stopLow: 95, targetHigh: 110)
        let cat = noCatalyst ? [] : [catalyst(catalystKind, key: catalystKind == .news ? "news.item.fixture" : "feed.insider.event")]
        var confluence: Q.Confluence? = nil
        if let confluenceVerdict {
            let checks: [Q.ConfluenceCheck] = Array(repeating: .contrary, count: contraryChecks)
                + Array(repeating: .confirmed, count: 5 - contraryChecks)
            confluence = .init(version: 1, verdict: confluenceVerdict, trendAlignment: checks[0],
                momentumDirection: checks[1], volatilitySuitability: checks[2],
                liquidityConfirmation: checks[3], resistanceDistance: checks[4], reasons: [])
        }
        return .init(version: Q.version, symbol: symbol, horizon: StockSageHorizonResearch.Horizon.week.rawValue,
            capturedAt: now.addingTimeInterval(-2), evidenceAsOf: evidenceAsOf ?? now, barDate: nil,
            criticalCaptureReady: criticalCaptureReady, measurements: m, earnings: earnings(),
            candidateCatalysts: cat, citedQualifyingKeys: cited && !noCatalyst ? [cat[0].key] : [],
            originalAction: qualified ? "Buy" : "Hold", scenario: nil,
            reasons: qualified ? [] : ["Original model opinion is not Buy / Strong Buy."],
            completedSessionPolicy: nil, technicalSnapshot: nil, confluence: confluence)
    }
    private func candidate(_ symbol: String, qualified: Bool = true, sector: String? = nil,
                          catalystIdentity: String? = nil, insider: [E.InsiderTransaction] = [],
                          horizonReturn: Double = 10, receiptOverride: Q.Receipt? = nil) -> T.Candidate {
        .init(symbol: symbol, action: qualified ? "Buy" : "Hold", sector: sector, catalystIdentity: catalystIdentity,
            qualification: receiptOverride ?? receipt(symbol: symbol, qualified: qualified, horizonReturn: horizonReturn),
            insiderTransactions: insider)
    }
    private func insider(_ direction: E.InsiderTransaction.Direction, owner: String = "Owner",
                        ageDays: Double = 1, amendment: Bool = false) -> E.InsiderTransaction {
        .init(direction: direction, transactionDate: now.addingTimeInterval(-ageDays * 86_400),
              filingDate: now, ownerName: owner, role: "Director", shares: 100,
              pricePerShare: 50, planReported: false, amendment: amendment)
    }

    @Test func fewerThanFiveQualifiedFillsRemainingSlotsFromTheEligiblePool() {
        let pool = ["AAA", "BBB"].map { candidate($0, qualified: true) }
            + ["CCC", "DDD", "EEE"].map { candidate($0, qualified: false) }
        let result = T.rank(pool, horizon: .week, now: now)
        #expect(result.ranked.count == 5)
        #expect(result.ranked.prefix(2).allSatisfy { $0.status == .qualified })
        #expect(result.ranked.suffix(3).allSatisfy { $0.status == .notQualified })
        #expect(result.ranked.suffix(3).allSatisfy { $0.action == "Hold" },
                "A fallback row shows the REAL action, never a fabricated Buy")
        #expect(result.ranked.suffix(3).allSatisfy { !$0.failedGates.isEmpty })
        #expect(result.ranked.prefix(2).allSatisfy { $0.failedGates.isEmpty })
    }

    @Test func exactlyFiveQualifiedUsesAllFiveAndNoFallbackRows() {
        let pool = ["AAA", "BBB", "CCC", "DDD", "EEE"].map { candidate($0, qualified: true) }
        let result = T.rank(pool, horizon: .week, now: now)
        #expect(result.ranked.count == 5)
        #expect(result.ranked.allSatisfy { $0.status == .qualified && $0.failedGates.isEmpty })
    }

    @Test func moreThanFiveQualifiedKeepsOnlyTheTopFiveByScore() {
        // Distinct horizonReturn values give distinct, hand-orderable scores (higher return = higher score).
        let pool = (0..<7).map { candidate("SYM\($0)", qualified: true, horizonReturn: Double($0)) }
        let result = T.rank(pool, horizon: .week, now: now)
        #expect(result.ranked.count == 5)
        #expect(result.ranked.map(\.symbol) == ["SYM6", "SYM5", "SYM4", "SYM3", "SYM2"],
                "The five highest horizonReturn values win, in descending score order")
    }

    @Test func equalScoresBreakTiesBySymbolAscendingAndAreStableAcrossRepeatedCalls() {
        let pool = ["ZETA", "ALPHA", "MID"].map { candidate($0, qualified: true, horizonReturn: 10) }
        let first = T.rank(pool, horizon: .week, now: now)
        #expect(first.ranked.map(\.symbol) == ["ALPHA", "MID", "ZETA"])
        for _ in 0..<5 {
            #expect(T.rank(pool, horizon: .week, now: now) == first, "Identical inputs must reproduce identical output")
        }
    }

    @Test func zeroQualifiedStillProducesFiveRealActionFallbackRows() {
        let pool = (0..<5).map { candidate("SYM\($0)", qualified: false) }
        let result = T.rank(pool, horizon: .fortnight, now: now)
        #expect(result.ranked.count == 5)
        #expect(result.ranked.allSatisfy { $0.status == .notQualified && $0.action == "Hold" })
        #expect(result.ranked.allSatisfy { !$0.failedGates.isEmpty })
    }

    @Test func staleCaptureAppliesAFlatHardPenaltyDistinctFromTheSmoothComponents() throws {
        let fresh = candidate("FRESH", qualified: true)
        let stale = candidate("STALE", qualified: true,
            receiptOverride: receipt(symbol: "STALE", qualified: true, criticalCaptureReady: false))
        let result = T.rank([fresh, stale], horizon: .week, now: now)
        let staleRow = try #require(result.ranked.first { $0.symbol == "STALE" })
        #expect(staleRow.components.hardPenalties == StockSageTopFiveRanking.staleCapturePenalty)
        #expect(!staleRow.hardPenaltyReasons.isEmpty)
        #expect(result.ranked.map(\.symbol) == ["FRESH", "STALE"], "The -50 penalty demotes it below an otherwise-identical fresh candidate")
    }

    @Test func contraryConfluenceChecksSubtractCounterevidencePoints() throws {
        let clean = candidate("CLEAN", qualified: true)
        let contrary = candidate("CONTRARY", qualified: true,
            receiptOverride: receipt(symbol: "CONTRARY", qualified: true, contraryChecks: 2))
        let result = T.rank([clean, contrary], horizon: .week, now: now)
        let row = try #require(result.ranked.first { $0.symbol == "CONTRARY" })
        #expect(row.components.counterevidence == -4, "Two contrary checks at -2 each")
        #expect(result.ranked.map(\.symbol) == ["CLEAN", "CONTRARY"])
    }

    @Test func insiderEvidenceIsRetainedCorrectlyClassifiedAndFreshnessDecayed() throws {
        let purchase = insider(.purchase, owner: "Owner P", ageDays: 1)
        let sale = insider(.sale, owner: "Owner S", ageDays: 1)
        let staleSale = insider(.sale, owner: "Owner Old", ageDays: 30) // past the 14-day decay window
        let c = candidate("ACME", qualified: true, insider: [purchase, sale, staleSale])
        let result = T.rank([c], horizon: .week, now: now)
        let row = result.ranked[0]
        #expect(row.insiderSignals.count == 3, "Every supplied transaction is retained, including the sale")
        let purchaseSignal = try #require(row.insiderSignals.first { $0.direction == .purchase })
        let saleSignal = try #require(row.insiderSignals.first { $0.direction == .sale && $0.ownerName == "Owner S" })
        let staleSignal = try #require(row.insiderSignals.first { $0.ownerName == "Owner Old" })
        #expect(purchaseSignal.contribution > 0, "A purchase contributes positively")
        #expect(saleSignal.contribution < 0, "A sale contributes negatively, never as momentum")
        #expect(abs(staleSignal.contribution) < 1e-9, "Past the 14-day decay window, contribution is fully decayed to zero")
        #expect(abs(purchaseSignal.contribution) > abs(staleSignal.contribution),
                "A fresh transaction outweighs a fully decayed one")
    }

    @Test func clusteredSameDirectionInsidersWithinTheWindowGetAMultiplier() throws {
        let solo = candidate("SOLO", qualified: true, insider: [insider(.purchase, owner: "A", ageDays: 1)])
        let clustered = candidate("CLUSTER", qualified: true,
            insider: [insider(.purchase, owner: "A", ageDays: 1), insider(.purchase, owner: "B", ageDays: 2)])
        let result = T.rank([solo, clustered], horizon: .week, now: now)
        let soloRow = try #require(result.ranked.first { $0.symbol == "SOLO" })
        let clusterRow = try #require(result.ranked.first { $0.symbol == "CLUSTER" })
        let clusterPerTransaction = clusterRow.insiderSignals.map(\.contribution).reduce(0, +) / 2
        #expect(clusterPerTransaction > soloRow.insiderSignals[0].contribution,
                "Each clustered transaction is worth more than an equally-fresh solo one")
    }

    @Test func insiderEvidenceCannotByItselfOverrideAFailedHardGate() {
        // Strong recent open-market insider buying on a candidate that FAILS qualification must
        // never outrank a candidate that PASSES qualification with weaker insider evidence.
        let strongInsiderButUnqualified = candidate("BUYS", qualified: false,
            insider: [insider(.purchase, owner: "A", ageDays: 0), insider(.purchase, owner: "B", ageDays: 0)])
        let weakInsiderButQualified = candidate("PASSES", qualified: true, insider: [])
        let result = T.rank([strongInsiderButUnqualified, weakInsiderButQualified], horizon: .week, now: now)
        #expect(result.ranked.map(\.symbol) == ["PASSES", "BUYS"],
                "Qualification status is the primary sort key; insider score is never enough to invert it")
    }

    @Test func concentrationGuardDemotesExcessSameSectorCandidatesWithoutAMaterialAdvantage() {
        // Four Tech candidates (decreasing score) plus three OTHER-sector alternates close
        // enough behind to be non-material. With three distinct alternate sectors, capping Tech
        // at 2 and taking one from each alternate is achievable without falling short of five.
        let pool = (0..<4).map { candidate("TECH\($0)", qualified: true, sector: "Tech", horizonReturn: 10 - Double($0)) }
            + [candidate("ENERGY0", qualified: true, sector: "Energy", horizonReturn: 6),
               candidate("HEALTH0", qualified: true, sector: "Health", horizonReturn: 5),
               candidate("FINANCE0", qualified: true, sector: "Finance", horizonReturn: 4)]
        let result = T.rank(pool, horizon: .week, now: now)
        let sectors = Dictionary(grouping: result.ranked) { row in
            pool.first { $0.symbol == row.symbol }?.sector ?? "?"
        }
        #expect((sectors["Tech"]?.count ?? 0) <= StockSageTopFiveRanking.maximumPerConcentrationKey,
                "No more than the documented cap from one sector without a material score advantage")
        #expect(result.concentrationGuardApplied)
        #expect(Set(result.ranked.map(\.symbol)) == ["TECH0", "TECH1", "ENERGY0", "HEALTH0", "FINANCE0"],
                "The two best Tech candidates plus all three diversifying alternates fill the five")
    }

    @Test func concentrationGuardKeepsAConcentratedCandidateWhenItsAdvantageIsMaterial() {
        // The third Tech candidate leads the Energy alternative by more than the material margin.
        let pool = [candidate("TECH0", qualified: true, sector: "Tech", horizonReturn: 20),
                    candidate("TECH1", qualified: true, sector: "Tech", horizonReturn: 19),
                    candidate("TECH2", qualified: true, sector: "Tech", horizonReturn: 18),
                    candidate("ENERGY0", qualified: true, sector: "Energy", horizonReturn: 1)]
        let result = T.rank(pool, horizon: .week, now: now)
        #expect(result.ranked.map(\.symbol).contains("TECH2"),
                "A material score lead keeps the concentrated candidate despite the cap")
    }

    @Test func resultEncodesByteIdenticallyAndVersionsTheSchema() throws {
        let pool = ["AAA", "BBB"].map { candidate($0, qualified: true) }
        let result = T.rank(pool, horizon: .week, now: now)
        #expect(result.version == 1 && result.horizon == StockSageHorizonResearch.Horizon.week.rawValue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(result)
        let decoded = try JSONDecoder().decode(StockSageTopFiveRanking.Result.self, from: bytes)
        let reencoded = try encoder.encode(decoded)
        #expect(decoded == result && reencoded == bytes)
    }

    // MARK: - Regressions from the independent 2026-09-16 review of commit 9a74d34

    /// P1: the concentration guard must never demote a qualified candidate to admit an
    /// unqualified one. Five qualified Tech candidates (all one concentration key) plus three
    /// unqualified, higher-diversity candidates must still yield all five Tech qualified rows —
    /// the qualified quota is filled BEFORE any fallback selection is even considered.
    @Test func concentrationGuardNeverDemotesAQualifiedCandidateForAnUnqualifiedAlternative() {
        let fiveQualifiedTech = (0..<5).map {
            candidate("TECH\($0)", qualified: true, sector: "Tech", horizonReturn: 10 - Double($0))
        }
        let threeUnqualifiedDiverse = [
            candidate("ENERGY0", qualified: false, sector: "Energy", horizonReturn: 9.9),
            candidate("HEALTH0", qualified: false, sector: "Health", horizonReturn: 9.8),
            candidate("FINANCE0", qualified: false, sector: "Finance", horizonReturn: 9.7),
        ]
        let result = T.rank(fiveQualifiedTech + threeUnqualifiedDiverse, horizon: .week, now: now)
        #expect(result.ranked.count == 5)
        #expect(result.ranked.allSatisfy { $0.status == .qualified },
                "All five available qualified candidates are used before any fallback is considered, even though they share one concentration key")
        #expect(Set(result.ranked.map(\.symbol)) == Set((0..<5).map { "TECH\($0)" }))
    }

    /// The same guarantee with only four qualified candidates available: the four qualified fill
    /// first, and only the single remaining slot comes from the unqualified pool.
    @Test func concentrationGuardFillsTheQualifiedQuotaFirstEvenWhenItIsFourOfFive() {
        let fourQualifiedTech = (0..<4).map {
            candidate("TECH\($0)", qualified: true, sector: "Tech", horizonReturn: 10 - Double($0))
        }
        let threeUnqualifiedDiverse = [
            candidate("ENERGY0", qualified: false, sector: "Energy", horizonReturn: 9.9),
            candidate("HEALTH0", qualified: false, sector: "Health", horizonReturn: 9.8),
            candidate("FINANCE0", qualified: false, sector: "Finance", horizonReturn: 9.7),
        ]
        let result = T.rank(fourQualifiedTech + threeUnqualifiedDiverse, horizon: .week, now: now)
        #expect(result.ranked.count == 5)
        let qualifiedRows = result.ranked.filter { $0.status == .qualified }
        #expect(qualifiedRows.count == 4, "All four available qualified candidates are used")
        #expect(Set(qualifiedRows.map(\.symbol)) == Set((0..<4).map { "TECH\($0)" }))
        #expect(result.ranked.filter { $0.status == .notQualified }.count == 1,
                "Exactly one fallback slot remains once the qualified quota is exhausted")
    }

    /// P2: clustering must count DISTINCT OWNERS within the window, not transaction rows, and the
    /// boost must apply only to transactions actually inside the window. Reproduces the review's
    /// own numbers: one owner, two purchases aged 1 and 2 days, must score 10.7143 (unboosted),
    /// not 16.0714 (the old row-counting bug's value).
    @Test func clusterBoostRequiresDistinctOwnersWithinTheWindowNotRowCount() throws {
        let sameOwnerTwice = candidate("SOLO", qualified: true,
            insider: [insider(.purchase, owner: "Same Owner", ageDays: 1),
                      insider(.purchase, owner: "Same Owner", ageDays: 2)])
        let result = T.rank([sameOwnerTwice], horizon: .week, now: now)
        let total = result.ranked[0].insiderSignals.map(\.contribution).reduce(0, +)
        #expect(abs(total - 10.7143) < 0.001, "One owner trading twice is not a cluster; no boost applies")
        #expect(abs(total - 16.0714) > 0.001, "Must not reproduce the old row-counting bug's value")
    }

    @Test func clusterBoostOnlyAppliesToTransactionsInsideTheWindowItself() throws {
        // Two distinct owners buy within the 7-day window (a real cluster); a THIRD, unrelated
        // purchase by a different owner ten days ago is outside the window and must not be
        // boosted just because a same-direction cluster exists elsewhere for this candidate.
        let c = candidate("CLUSTERED", qualified: true, insider: [
            insider(.purchase, owner: "A", ageDays: 1),
            insider(.purchase, owner: "B", ageDays: 2),
            insider(.purchase, owner: "C", ageDays: 10),
        ])
        let result = T.rank([c], horizon: .week, now: now)
        let signals = result.ranked[0].insiderSignals
        let outside = try #require(signals.first { $0.ownerName == "C" })
        let insideA = try #require(signals.first { $0.ownerName == "A" })
        // Unboosted magnitude at 10 days: 6 * (1 - 10/14) = 6 * 4/14 ≈ 1.7143.
        #expect(abs(outside.contribution - 1.7143) < 0.001, "The outside-window transaction is never boosted")
        // Boosted magnitude at 1 day: 6 * (13/14) * 1.5 ≈ 8.3571.
        #expect(abs(insideA.contribution - 8.3571) < 0.001, "The two in-window, distinct-owner transactions ARE boosted")
    }

    /// P2: a Form 4/A amendment corrects the original filing; it must not be scored as a second,
    /// additional trade. Both records remain visible as evidence, but only one contributes.
    @Test func amendmentsDoNotDoubleCountTheSameEconomicTrade() {
        let sameDayOwner = now.addingTimeInterval(-1 * 86_400)
        let original = E.InsiderTransaction(direction: .purchase, transactionDate: sameDayOwner,
            filingDate: now.addingTimeInterval(-3600), ownerName: "Owner", role: "Director",
            shares: 100, pricePerShare: 50, planReported: false, amendment: false)
        let amendment = E.InsiderTransaction(direction: .purchase, transactionDate: sameDayOwner,
            filingDate: now, ownerName: "Owner", role: "Director", shares: 100, pricePerShare: 50,
            planReported: false, amendment: true)
        let c = candidate("AMEND", qualified: true, insider: [original, amendment])
        let result = T.rank([c], horizon: .week, now: now)
        let signals = result.ranked[0].insiderSignals
        #expect(signals.count == 2, "Both the original and the amendment remain visible as evidence")
        let nonZero = signals.filter { $0.contribution != 0 }
        #expect(nonZero.count == 1, "Only one of the pair contributes to the score")
        // A single unboosted purchase at 1 day: 6 * 13/14 ≈ 5.5714, not double that.
        let total = signals.map(\.contribution).reduce(0, +)
        #expect(abs(total - 5.5714) < 0.001, "The amendment is a correction, not a second trade")
    }

    /// Finding 6: a corrupted or malicious cached record with a FUTURE transaction date must not
    /// be clamped to age zero and scored at full weight. It contributes nothing.
    @Test func futureDatedTransactionsContributeNothingRatherThanFullWeight() {
        let future = E.InsiderTransaction(direction: .purchase, transactionDate: now.addingTimeInterval(30 * 86_400),
            filingDate: now.addingTimeInterval(31 * 86_400), ownerName: "Owner", role: "Director",
            shares: 100, pricePerShare: 50, planReported: false, amendment: false)
        let c = candidate("FUTURE", qualified: true, insider: [future])
        let result = T.rank([c], horizon: .week, now: now)
        let signal = result.ranked[0].insiderSignals[0]
        #expect(signal.contribution == 0, "A future-dated transaction must not be clamped to age zero and scored at full weight")
    }

    @Test func transactionDatedAfterItsOwnFilingDateContributesNothing() {
        // transactionDate > filingDate is structurally invalid for a real Form 4 (filing follows
        // the trade); decoded/cached data is not re-validated by the network parser, so the
        // scoring boundary itself must reject it.
        let invalid = E.InsiderTransaction(direction: .purchase, transactionDate: now,
            filingDate: now.addingTimeInterval(-86_400), ownerName: "Owner", role: "Director",
            shares: 100, pricePerShare: 50, planReported: false, amendment: false)
        let c = candidate("INVALID", qualified: true, insider: [invalid])
        let result = T.rank([c], horizon: .week, now: now)
        #expect(result.ranked[0].insiderSignals[0].contribution == 0)
    }
}
