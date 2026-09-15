import Foundation
import CryptoKit
import Testing
@testable import StockSage

@Suite("Strict research qualification") @MainActor
struct StockSageResearchQualificationTests {
    typealias Q = StockSageResearchQualification
    typealias R = StockSageHorizonResearch
    typealias E = StockSageMassiveEarnings
    typealias N = StockSageNewsService
    typealias M = StockSageMassiveEvents
    private let now = Date(timeIntervalSince1970: 1_789_477_200) // 2026-09-15 13:00 UTC
    private var buy: StockSageAIAssessment.Verdict {
        .init(action: .buy, reason: "Public insider sale supports market momentum under the reported plan.",
              risk: "Execution risk remains.", evidence: ["F1"])
    }

    private func history(count: Int = 70, closes changeCloses: ((inout [Double]) -> Void)? = nil,
                         highs changeHighs: ((inout [Double]) -> Void)? = nil,
                         volumes changeVolumes: ((inout [Double]) -> Void)? = nil,
                         stale: Bool = false) -> StockSagePriceHistory {
        var dates: [Date] = [], day = now.addingTimeInterval(-86_400)
        while dates.count < count + (stale ? 1 : 0) {
            if StockSageMarketHours.nasdaqDay(at: day)?.trading == true { dates.append(day) }
            day = day.addingTimeInterval(-86_400)
        }
        if stale { dates.removeFirst() }
        dates.reverse()
        var closes = (0..<count).map { $0 < count - 20 ? 98.0 : 99 + Double($0 - count + 20) / 19 }
        changeCloses?(&closes)
        var highs = closes.map { $0 + 1 }
        if count > 11 { highs[count - 11] = max(highs[count - 11], 104) }
        changeHighs?(&highs)
        var volumes = (0..<count).map { $0 >= count - 3 ? 200.0 : 100.0 }
        changeVolumes?(&volumes)
        return .init(symbol: "ACME", dates: dates, opens: closes, highs: highs,
                     lows: closes.map { $0 - 1 }, closes: closes, volumes: volumes, priceSource: .massiveDaily)
    }

    private func news(age: TimeInterval = 3600) -> N.NewsItem {
        .init(date: now.addingTimeInterval(-age), title: "Dated customer announcement",
              snippet: "Company disclosed a new customer contract.", link: nil, sentiment: nil,
              source: "Fixture source", articleIdentity: "fixture-news")
    }
    private func newsKey(_ item: N.NewsItem) -> String {
        "news.item." + SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func earnings(_ date: String = "2026-11-24", confirmed: Bool = true,
                          age: TimeInterval = 0) throws -> E.Observation {
        .init(outcome: .answered(.init(date: try Date(date + "T00:00:00Z", strategy: .iso8601), confirmed: confirmed)),
              checkedAt: now.addingTimeInterval(-age), recordedAt: now)
    }
    private func insider(_ identity: String, age: TimeInterval = 3600, sale: Bool = true) -> M.Event {
        .init(id: "same-accession", symbol: "ACME", feed: .insider, date: now.addingTimeInterval(-age),
              headline: sale ? "Form 4 sale filed" : "Form 4 purchase filed", details: ["Original owner-approved plan wording"],
              link: nil, transactionIdentity: identity)
    }
    private func capture(history: StockSagePriceHistory? = nil, news items: [N.NewsItem]? = nil,
                         newsState: N.Status = .answered, newsCheckAge: TimeInterval = 0,
                         insider events: [M.Event] = [], insiderCheckAge: TimeInterval = 0,
                         earnings observation: E.Observation? = nil, defaultEarnings: Bool = true,
                         removeKey: String? = nil) throws -> R.Capture {
        let h = history ?? self.history()
        let idea = StockSageIdea(symbol: "ACME", market: "NASDAQ", price: h.closes.last!,
            advice: .init(action: .hold, conviction: 0, regime: .range, rationale: ["Fixture"],
                          stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Synthetic fixture"), spark: [],
            generatedAt: now, priceAsOf: h.dates.last, priceSource: .massiveDaily)
        let observationNews = N.Observation(attempts: [.init(provider: .benzinga,
            checkedAt: now.addingTimeInterval(-newsCheckAge), status: newsState, items: items ?? [news()])])
        let company: [M.Feed: M.Observation] = events.isEmpty ? [:] : [.insider: .init(symbol: "ACME", feed: .insider,
            checkedAt: now.addingTimeInterval(-insiderCheckAge), outcome: .answered, event: events.first,
            insiderEvents: events, insiderOmittedRecordCount: 0)]
        let context = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: company,
            at: now, newsObservation: observationNews, quotedInUSD: true)
        let packet = context.evidencePacket()
        let offered = packet.facts.filter { $0.key != removeKey }
        return .init(history: h, context: context, facts: offered.map(\.text), coverage: [],
            at: now.addingTimeInterval(-2), blockedByThrottle: false,
            evidencePacket: .init(facts: offered, prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount),
            nextEarnings: try observation ?? (defaultEarnings ? earnings() : nil))
    }

    @Test(arguments: [R.Horizon.week, .fortnight])
    func qualifiedScenarioUsesActualHistoryAndPreservesOriginalVerdict(horizon: R.Horizon) throws {
        let captured = try capture()
        let original = buy
        let inputs = Q.prepare(captured, horizon: horizon)
        let receipt = inputs.receipt(verdict: original, citedKeys: [newsKey(news())])
        #expect(receipt.isQualified && receipt.reasons.isEmpty)
        #expect(receipt.levels?.entry == 100 && receipt.levels?.target == 104)
        let span = horizon == .week ? 5 : 10
        #expect(receipt.levels?.stop == captured.history.lows.suffix(span).min())
        #expect(receipt.capturedAt == captured.at && receipt.evidenceAsOf == captured.context.asOf)
        #expect(original == buy, "Qualification must not rewrite Gemma's action, prose, or insider interpretation")
        #expect(inputs.fact.contains("unvalidated") && inputs.fact.contains("projected") == false)
        #expect(Q.valid(receipt, symbol: "ACME", horizon: horizon.rawValue, at: captured.at, citedKeys: [newsKey(news())]))
        let roundTrip = try JSONDecoder().decode(Q.Receipt.self, from: JSONEncoder().encode(receipt))
        #expect(roundTrip == receipt)
    }

    @Test func downsideVolumeSpikeCannotQualify() throws {
        let h = history(closes: { $0[$0.count - 1] = 90 }, volumes: { $0[$0.count - 1] = 1000 })
        let result = Q.prepare(try capture(history: h), horizon: .week).receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(!result.isQualified && result.levels == nil)
        #expect(result.measurements.volumeRatio! >= 1.5)
        #expect(result.reasons.contains { $0.contains("SMA20") } && result.reasons.contains { $0.contains("historical return") })
    }

    @Test(arguments: [false, true]) func zeroOrMissingVolumeCannotQualify(missing: Bool) throws {
        let h = history(volumes: { if missing { $0.removeLast() } else { $0 = $0.map { _ in 0 } } })
        let result = Q.prepare(try capture(history: h), horizon: .week).receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(!result.isQualified && result.measurements.volumeRatio == nil && result.levels == nil)
    }

    @Test func staleDailyHistoryKeepsMeasurementsUnknown() throws {
        let result = Q.prepare(try capture(history: history(stale: true)), horizon: .week)
            .receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(!result.isQualified && result.measurements.close == nil && result.scenario == nil)
        #expect(result.reasons.contains { $0.contains("completed daily") })
    }

    @Test func targetCannotBeInventedAboveObservedResistanceOrFromTheLatestBar() throws {
        let h = history(closes: { $0[$0.count - 1] = 110 })
        let result = Q.prepare(try capture(history: h), horizon: .week).receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(result.measurements.targetHigh == 104, "The latest bar's 111 high cannot create resistance")
        #expect(!result.isQualified && result.scenario == nil)
        #expect(result.reasons.contains { $0.contains("resistance") })
    }

    @Test func sixtyPriorBarsAreRequiredForFortnightResistance() throws {
        let captured = try capture(history: history(count: 60))
        let week = Q.prepare(captured, horizon: .week).receipt(verdict: buy, citedKeys: [newsKey(news())])
        let long = Q.prepare(captured, horizon: .fortnight).receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(week.isQualified && !long.isQualified && long.measurements.targetHigh == nil)
        #expect(long.reasons.contains { $0.contains("60") && $0.contains("resistance") })
    }

    @Test func weakRiskRewardExcludesWithoutChangingTheBuy() throws {
        let captured = try capture(history: history(highs: { values in
            values = values.map { min($0, 101.2) }
        }))
        let original = buy
        let result = Q.prepare(captured, horizon: .week).receipt(verdict: original, citedKeys: [newsKey(news())])
        #expect(!result.isQualified && result.scenario != nil && result.levels == nil)
        #expect(result.reasons.contains { $0.contains("2:1") })
        #expect(original == buy)
    }

    @Test func onlyFreshOutsideEarningsMayQualifyIncludingExplicitlyProjectedDates() throws {
        for observation in [nil, try earnings("2026-09-17"), try earnings("2026-09-24"), try earnings(age: 301)] {
            let result = Q.prepare(try capture(earnings: observation, defaultEarnings: false), horizon: .week)
                .receipt(verdict: buy, citedKeys: [newsKey(news())])
            #expect(!result.isQualified && result.reasons.contains { $0.contains("earnings") })
        }
        let projected = Q.prepare(try capture(earnings: earnings(confirmed: false)), horizon: .week)
        let result = projected.receipt(verdict: buy, citedKeys: [newsKey(news())])
        #expect(result.isQualified && result.earnings.confirmed == false)
        #expect(projected.fact.contains("projected, not announced") && projected.fact.contains("not absence of earnings risk"))
    }

    @Test func onlyRecentFreshOfferedAndExactlyCitedNewsQualifies() throws {
        let item = news(), key = newsKey(item)
        let valid = Q.prepare(try capture(news: [item], newsState: .partial), horizon: .week)
        #expect(valid.receipt(verdict: buy, citedKeys: [key]).isQualified)
        for citation in [[], ["news.status"], [key + "x"], ["benzinga.record.analyst"], ["sec.record.filing"]] {
            #expect(!valid.receipt(verdict: buy, citedKeys: citation).isQualified)
        }
        for captured in [try capture(news: [news(age: 3 * 86_400 + 1)]),
                         try capture(newsCheckAge: 301), try capture(newsState: .unavailable(.transport)),
                         try capture(removeKey: key), try capture(news: [news(age: -1)])] {
            #expect(!Q.prepare(captured, horizon: .week).receipt(verdict: buy, citedKeys: [key]).isQualified)
        }
        let fourDays = news(age: 4 * 86_400)
        #expect(Q.prepare(try capture(news: [fourDays]), horizon: .fortnight)
            .receipt(verdict: buy, citedKeys: [newsKey(fourDays)]).isQualified)
    }

    @Test func fittedOutCatalystIsNotReportedAsAnIgnoredOfferedCitation() throws {
        let captured = try capture(), key = newsKey(news())
        let inputs = Q.prepare(captured, horizon: .week)
        let offered = try #require(captured.evidencePacket?.facts.map(\.key))
        let retained = inputs.receipt(verdict: buy, citedKeys: [key], offeredKeys: offered)
        #expect(retained.isQualified && retained.candidateCatalysts.map(\.key) == [key])
        let omitted = inputs.receipt(verdict: buy, citedKeys: [key], offeredKeys: offered.filter { $0 != key })
        #expect(!omitted.isQualified && omitted.candidateCatalysts.isEmpty && omitted.citedQualifyingKeys.isEmpty)
        #expect(omitted.reasons.contains { $0.contains("No recent dated news") })
        #expect(!omitted.reasons.contains { $0.contains("model did not cite") })
        #expect(Q.valid(omitted, symbol: "ACME", horizon: R.Horizon.week.rawValue,
                        at: captured.at, citedKeys: []))
    }

    @Test func publicSalesAndPurchasesKeepDistinctExactCitationsAndFilingDates() throws {
        let sale = insider("sale-identity"), purchase = insider("purchase-identity", sale: false)
        let captured = try capture(news: [], insider: [sale, purchase])
        let inputs = Q.prepare(captured, horizon: .week)
        for key in ["feed.insider.event", "feed.insider.transaction.purchase-identity"] {
            let receipt = inputs.receipt(verdict: buy, citedKeys: [key])
            #expect(receipt.isQualified && receipt.citedQualifyingKeys == [key])
            #expect(receipt.candidateCatalysts.allSatisfy { $0.kind == .publicInsiderFiling })
        }
        #expect(!inputs.receipt(verdict: buy, citedKeys: ["feed.insider.transaction.sale-identity"]).isQualified)
        let old = insider("old", age: 8 * 86_400)
        let oldCapture = try capture(news: [], insider: [old])
        #expect(!Q.prepare(oldCapture, horizon: .week).receipt(verdict: buy, citedKeys: ["feed.insider.event"]).isQualified)
        #expect(Q.prepare(oldCapture, horizon: .fortnight).receipt(verdict: buy, citedKeys: ["feed.insider.event"]).isQualified)
        #expect(!Q.prepare(try capture(news: [], insider: [sale], insiderCheckAge: 86_400), horizon: .week)
            .receipt(verdict: buy, citedKeys: ["feed.insider.event"]).isQualified)
        #expect(captured.context.company[.insider]?.insiderEvents == [sale, purchase])
    }

    @Test func holdAndInvalidArchiveIdentityNeverBecomeQualified() throws {
        let captured = try capture(), key = newsKey(news())
        let inputs = Q.prepare(captured, horizon: .week)
        let hold = StockSageAIAssessment.Verdict(action: .hold, reason: buy.reason, risk: buy.risk, evidence: buy.evidence)
        #expect(!inputs.receipt(verdict: hold, citedKeys: [key]).isQualified)
        let receipt = inputs.receipt(verdict: buy, citedKeys: [key])
        #expect(!Q.valid(receipt, symbol: "OTHER", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))
        #expect(!Q.valid(receipt, symbol: "ACME", horizon: R.Horizon.fortnight.rawValue, at: captured.at, citedKeys: [key]))
        #expect(!Q.valid(receipt, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at.addingTimeInterval(1), citedKeys: [key]))
        #expect(!Q.valid(receipt, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: []))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        json["reasons"] = ["Invented reason"]
        let changed = try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!Q.valid(changed, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))
    }
}
