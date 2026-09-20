import Foundation
import Testing
@testable import StockSage

/// Synthetic, memory-only captures shared by Mac and iPhone layout tests.
@MainActor enum StockSageLayoutFixtures {
    static func populatedResearch(horizon: StockSageHorizonResearch.Horizon) async throws -> StockSageHorizonResearch {
        typealias R = StockSageHorizonResearch
        let research = R()
        let symbols = ["SYNA", "SYNB", "SYNC", "SYND", "SYNE", "SYNF"]
        let listings = symbols.map {
            R.Listing(ticker: $0, name: "Synthetic company \($0)", market: "stocks", locale: "us",
                active: true, type: "CS", currency_name: "usd", primary_exchange: "XNAS")
        }
        let started = research.start([horizon], allowed: { true }, universe: { .init(listings) },
            rank: { _, _ in .failure(.modelFailure) }, qualificationPolicyVersion: 1,
            makeAnalysis: { listing in
                { requested in result(symbol: listing.ticker, horizon: requested) }
            })
        try #require(started)
        defer { research.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while research.running != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(research.running == nil, "Synthetic layout research did not finish within three seconds")
        try #require(Set(research.scans.keys) == Set([horizon]))
        let scan = try #require(research.scans[horizon])
        let ranking = try #require(scan.deterministicRanking)
        try #require(ranking.horizon == horizon.rawValue && ranking.ranked.count == 5)
        try #require(ranking.ranked.filter { $0.status == .qualified }.count == 2)
        try #require(ranking.ranked.filter { $0.status == .notQualified && !$0.failedGates.isEmpty }.count == 3)
        try #require(ranking.ranked.contains { $0.action == TradeAdvice.Action.hold.rawValue })
        try #require(scan.ranking == nil && scan.rankingFailure != nil && scan.topBuys.isEmpty)
        try #require(ranking.ranked.flatMap(\.insiderSignals).contains { $0.direction == .purchase })
        try #require(ranking.ranked.flatMap(\.insiderSignals).contains { $0.direction == .sale })
        try #require(scan.rankedTopFive(horizon: horizon, now: Date().addingTimeInterval(14 * 86_400)) == ranking)
        return research
    }

    private static func result(symbol: String, horizon: StockSageHorizonResearch.Horizon) -> StockSageHorizonResearch.Result {
        typealias R = StockSageHorizonResearch
        typealias A = StockSageAIAssessment
        typealias E = StockSageMassiveEvents
        let at = Date()
        let qualifies = symbol == "SYNA" || symbol == "SYNB"
        let action: TradeAdvice.Action = qualifies || symbol == "SYNC" ? .buy : .hold
        guard var day = StockSageMarketHours.latestCompletedDailySession(at: at) else {
            return .init(note: "Synthetic fixture requires a supported completed-session calendar", at: at)
        }
        var dates: [Date] = []
        for _ in 0..<160 {
            if StockSageMarketHours.nasdaqDay(at: day)?.trading == true { dates.append(day) }
            if dates.count == 70 { break }
            day = day.addingTimeInterval(-86_400)
        }
        guard dates.count == 70 else { return .init(note: "Synthetic fixture needs 70 supported sessions", at: at) }
        dates.reverse()
        // Same measured history shape used by the qualification/history regressions.
        let closes = (0..<70).map { $0 < 50 ? 98.0 : 99 + Double($0 - 50) / 19 }
        var highs = closes.map { $0 + 1 }; highs[59] = 104
        let history = StockSagePriceHistory(symbol: symbol, dates: dates, opens: closes, highs: highs,
            lows: closes.map { $0 - 1 }, closes: closes,
            volumes: (0..<70).map { qualifies && $0 >= 67 ? 200 : 100 }, priceSource: .massiveDaily)
        let idea = StockSageIdea(symbol: symbol, market: "NASDAQ", price: 100,
            advice: .init(action: .hold, conviction: 0, regime: .range, rationale: ["Synthetic fixture"],
                stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Synthetic; not live research"),
            spark: [], generatedAt: at, priceAsOf: dates.last, priceSource: .massiveDaily)
        let insider = E.InsiderTransaction(direction: symbol == "SYNB" ? .sale : .purchase,
            transactionDate: at.addingTimeInterval(-86_400), filingDate: at.addingTimeInterval(-60),
            ownerName: "Synthetic director \(symbol)", role: "Director", shares: 100, pricePerShare: 50,
            planReported: symbol == "SYNB", amendment: false)
        let fact = A.EvidenceFact(key: "feed.insider.event",
            text: "Synthetic Form 4 \(insider.direction.rawValue): 100 shares at 50 USD; intent unknown. Not a real filing.",
            required: false, availability: .available)
        let event = E.Event(id: "synthetic-filing-\(symbol)", symbol: symbol, feed: .insider,
            date: insider.filingDate, headline: "Synthetic reported \(insider.direction.rawValue)",
            details: [fact.text], link: nil, transactionIdentity: "synthetic-transaction-\(symbol)", insider: insider)
        let observation = E.Observation(symbol: symbol, feed: .insider, checkedAt: at, outcome: .answered,
            event: event, insiderEvents: [event], insiderOmittedRecordCount: 0)
        let context = A.Context(idea: idea, earnings: nil, company: [.insider: observation], at: at, quotedInUSD: true)
        let coverage: [R.EvidenceCoverage] = [.init(source: E.Feed.insider.source, state: .answered, checkedAt: at)]
        let capture = R.Capture(history: history, context: context, facts: [fact.text], coverage: coverage,
            at: at, blockedByThrottle: false, evidencePacket: .init(facts: [fact], prePromptOmittedRecordCount: 0),
            nextEarnings: .init(outcome: .answered(.init(date: at.addingTimeInterval(60 * 86_400), confirmed: true)),
                checkedAt: at, recordedAt: at))
        let verdict = A.Verdict(action: action, reason: "Synthetic \(horizon.rawValue) interpretation; not a forecast.",
            risk: "Synthetic filing does not establish intent; overnight gaps can exceed scenario references.", evidence: ["F1"])
        let qualification = StockSageResearchQualification.prepare(capture, horizon: horizon)
            .receipt(verdict: verdict, citedKeys: [fact.key])
        return .init(verdict: verdict, levels: qualification.levels, facts: [fact.text], note: "Synthetic layout capture",
            at: at, model: "offline-layout-fixture", validationOutcome: .validated,
            referenceClose: (100, dates.last!), coverage: coverage,
            evidenceReceipt: context.coverage(offered: [fact], verdict: verdict), qualification: qualification,
            insiderTransactions: [insider], insiderEvidence: observation)
    }
}
