import Foundation
import Testing
@testable import StockSage

/// Tests the ADAPTER seam only: turning a real `Scan`'s `results` (with their attached
/// `Result.insiderTransactions` and `qualification` receipts) into `StockSageTopFiveRanking`
/// input, and extracting typed insider transactions from a `Context` at analysis time. The
/// scoring math itself is covered separately in StockSageTopFiveRankingTests.
@Suite("Top-5 ranking wiring")
@MainActor
struct StockSageTopFiveAdapterTests {
    private typealias R = StockSageHorizonResearch
    private typealias T = StockSageTopFiveRanking
    private typealias Q = StockSageResearchQualification
    private typealias E = StockSageMassiveEvents
    private let now = Date(timeIntervalSince1970: 1_789_477_200) // 2026-09-15 13:00 UTC

    private func idea(_ symbol: String) -> StockSageIdea {
        .init(symbol: symbol, market: "NASDAQ", price: 100,
            advice: .init(action: .hold, conviction: 0, regime: .range, rationale: ["Fixture"],
                stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Synthetic fixture"),
            spark: [], generatedAt: now, priceAsOf: now, priceSource: .massiveDaily)
    }
    private func insiderEvent(_ symbol: String, direction: E.InsiderTransaction.Direction,
                             ageHours: Double = 1, transactionAgeDays: Double = 1) -> E.Event {
        .init(id: "acc-\(symbol)-\(direction.rawValue)", symbol: symbol, feed: .insider,
            date: now.addingTimeInterval(-ageHours * 3600),
            headline: "Form 4 \(direction == .purchase ? "purchase" : "sale") filed",
            details: ["Owner: shares"], link: nil,
            insider: .init(direction: direction, transactionDate: now.addingTimeInterval(-transactionAgeDays * 86_400),
                filingDate: now.addingTimeInterval(-ageHours * 3600), ownerName: "Owner", role: "Director",
                shares: 100, pricePerShare: 50, planReported: false, amendment: false))
    }

    @Test func insiderTransactionsAreExtractedForASymbolMatchedFreshlyCheckedObservation() throws {
        // Extraction keeps EVERY symbol-matched transaction from a freshly-checked observation,
        // regardless of that individual transaction's own age — a sale is never dropped here.
        // Age-based decay is the SCORING layer's job (StockSageTopFiveRanking), not extraction's.
        let recentPurchase = insiderEvent("ACME", direction: .purchase, ageHours: 1)
        let olderSale = insiderEvent("ACME", direction: .sale, ageHours: 30)
        let foreign = insiderEvent("OTHER", direction: .purchase, ageHours: 1)
        let observation = E.Observation(symbol: "ACME", feed: .insider, checkedAt: now.addingTimeInterval(-3600),
            outcome: .answered, event: recentPurchase, insiderEvents: [recentPurchase, olderSale, foreign], insiderOmittedRecordCount: 0)
        let context = StockSageAIAssessment.Context(idea: idea("ACME"), earnings: nil,
            company: [.insider: observation], at: now)
        let extracted = R.insiderTransactions(from: context, at: now)
        #expect(extracted.count == 2, "Both ACME transactions survive extraction; only the foreign symbol is excluded")
        #expect(Set(extracted.map(\.direction)) == [.purchase, .sale], "The older sale is retained, never dropped")

        // A stale check (the whole observation itself unanswered-fresh) yields nothing at all.
        let staleObservation = E.Observation(symbol: "ACME", feed: .insider, checkedAt: now.addingTimeInterval(-90_000),
            outcome: .answered, event: recentPurchase, insiderEvents: [recentPurchase], insiderOmittedRecordCount: 0)
        let staleContext = StockSageAIAssessment.Context(idea: idea("ACME"), earnings: nil,
            company: [.insider: staleObservation], at: now)
        #expect(R.insiderTransactions(from: staleContext, at: now).isEmpty)

        // No insider feed at all yields nothing, never a crash or a guessed transaction.
        let empty = StockSageAIAssessment.Context(idea: idea("ACME"), earnings: nil, company: [:], at: now)
        #expect(R.insiderTransactions(from: empty, at: now).isEmpty)
    }

    @Test func scanRankedTopFiveBuildsCandidatesFromResultsAndPreservesInsiderTransactions() throws {
        func qualifiedReceipt(_ symbol: String, action: String = "Buy") -> Q.Receipt {
            let m = Q.Measurements(completedBars: 70, close: 100, sma20: 95, horizonReturnPercent: 5,
                volumeRatio: 3, atr14: 2, stopLow: 95, targetHigh: 110)
            return .init(version: Q.version, symbol: symbol, horizon: R.Horizon.week.rawValue,
                capturedAt: now.addingTimeInterval(-2), evidenceAsOf: now, barDate: nil,
                criticalCaptureReady: true, measurements: m,
                earnings: .init(relation: "outside", outcome: "answered", date: now.addingTimeInterval(90 * 86_400),
                    confirmed: true, checkedAt: now, recordedAt: now),
                candidateCatalysts: [.init(key: "news.item.fixture", identity: "fixture", kind: .news,
                    date: now.addingTimeInterval(-3600), checkedAt: now)],
                citedQualifyingKeys: ["news.item.fixture"], originalAction: action, scenario: nil,
                reasons: action == "Buy" ? [] : ["Original model opinion is not Buy / Strong Buy."],
                completedSessionPolicy: nil, technicalSnapshot: nil, confluence: nil)
        }
        var scan = R.Scan()
        scan.listings = ["AAA", "BBB", "CCC"].map { .init(ticker: $0, name: $0, market: "stocks", locale: "us",
            active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS") }
        let insider = [insiderEvent("AAA", direction: .purchase, ageHours: 1).insider!]
        scan.results = [
            "AAA": .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), note: "Original",
                qualification: qualifiedReceipt("AAA"), insiderTransactions: insider),
            "BBB": .init(verdict: .init(action: .hold, reason: "Case", risk: "Risk", evidence: ["F1"]), note: "Original",
                qualification: qualifiedReceipt("BBB", action: "Hold")),
            "CCC": .init(verdict: .init(action: .buy, reason: "Case", risk: "Risk", evidence: ["F1"]), note: "Original",
                qualification: qualifiedReceipt("CCC")),
        ]
        let result = try #require(scan.rankedTopFive(horizon: .week, now: now))
        #expect(result.ranked.count == 3, "All three checked, fully-qualified candidates are used when fewer than five exist")
        let aaa = try #require(result.ranked.first { $0.symbol == "AAA" })
        #expect(aaa.insiderSignals.count == 1 && aaa.insiderSignals[0].direction == .purchase,
                "The insider transaction attached to the Result survives into the ranking output")
        let bbb = try #require(result.ranked.first { $0.symbol == "BBB" })
        #expect(bbb.status == .notQualified && bbb.action == "Hold", "The real Hold action is shown, never fabricated")

        // A scan with incomplete checks (fewer results than listings) or no qualification data
        // at all cannot produce a ranking: there is nothing verified to rank yet.
        var incomplete = scan
        incomplete.listings.append(.init(ticker: "DDD", name: "DDD", market: "stocks", locale: "us",
            active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS"))
        #expect(incomplete.rankedTopFive(horizon: .week, now: now) == nil)
    }
}
