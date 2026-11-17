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

    @Test func completedSessionPolicyPreservesLegacyAfterCloseReceipts() throws {
        let captured = try capture(), key = newsKey(news())
        let original = Q.prepare(captured, horizon: .week).receipt(verdict: buy, citedKeys: [key])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        #expect(json["completedSessionPolicy"] as? Int == 1)
        let afterClose = try Date("2026-09-16T00:59:00Z", strategy: .iso8601)
        let time = afterClose.timeIntervalSinceReferenceDate
        json["capturedAt"] = time - 2
        json["evidenceAsOf"] = time
        var earnings = try #require(json["earnings"] as? [String: Any])
        earnings["checkedAt"] = time; earnings["recordedAt"] = time
        json["earnings"] = earnings
        var catalysts = try #require(json["candidateCatalysts"] as? [[String: Any]])
        for index in catalysts.indices { catalysts[index]["checkedAt"] = time }
        json["candidateCatalysts"] = catalysts
        json.removeValue(forKey: "completedSessionPolicy")
        // A genuinely old capture predates confluence too; the barDate mutations below only
        // touch the top-level receipt, and a real receipt never has technicalSnapshot.barDate
        // diverge from receipt.barDate (both come from the same source in prepare()).
        json.removeValue(forKey: "technicalSnapshot")
        json.removeValue(forKey: "confluence")
        func decode() throws -> Q.Receipt {
            try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func valid(_ receipt: Q.Receipt) -> Bool {
            Q.valid(receipt, symbol: "ACME", horizon: R.Horizon.week.rawValue,
                    at: afterClose.addingTimeInterval(-2), citedKeys: [key])
        }
        let legacy = try decode()
        #expect(legacy.isQualified && valid(legacy), "Keep the old September 14 capture readable after the date-rule correction")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(encoded["completedSessionPolicy"] == nil, "Absent legacy fields must stay absent for archive digests")
        json["completedSessionPolicy"] = 1
        #expect(!valid(try decode()), "New captures must not silently keep September 14 after September 15 ends")
        json["barDate"] = try Date("2026-09-15T04:00:00Z", strategy: .iso8601).timeIntervalSinceReferenceDate
        #expect(valid(try decode()))
        json["completedSessionPolicy"] = 2
        let unsupported = try decode()
        #expect(!unsupported.isQualified && !valid(unsupported))
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

    // MARK: - Technical confluence (Task 8)
    //
    // Confluence is SHADOW evidence: it never changes isQualified, reasons, or exclusions().
    // These tests exercise the pure Q.confluence(...) function directly against hand-built
    // snapshots so every threshold is unambiguous and independent of the strict-screen fixture.
    // The ladder under test (restated here, not read from the implementation):
    //   1. fewer than two checks resolve (confirmed+contrary) -> insufficient
    //   2. two or more checks are contrary                    -> conflicted
    //   3. zero contrary and two or more confirmed            -> aligned
    //   4. anything else (exactly one contrary)                -> mixed
    // Per-check rules: trend needs close>SMA20 and (no SMA50 or SMA20>=SMA50); momentum needs
    // RSI>50 and/or MACD histogram>0 (both, when both are present); volatility needs ATR% in
    // [0.5, 10] for a week horizon or [0.5, 15] for a fortnight; liquidity needs volumeRatio>=1.5;
    // resistance needs rangePosition<0.85. Any nil input is unavailable for that check.

    private let barDate = Date(timeIntervalSince1970: 1_789_430_400) // 2026-09-14 UTC, some fixed session

    private func snapshot(horizon: R.Horizon = .week, symbol: String = "ACME", close: Double = 100,
                         sma20: Double? = 95, sma50: Double? = 90, rsi14: Double? = 60,
                         macdHistogram: Double? = 0.5, atrPercent: Double? = 3,
                         volumeRatio: Double? = 2.0, rangePosition: Double? = 0.5,
                         barDate: Date? = nil) -> StockSageTechnical.Snapshot {
        .init(version: StockSageTechnical.version, symbol: symbol, horizon: horizon.rawValue,
            barDate: barDate ?? self.barDate, timezone: StockSageTechnical.timezone,
            calculatedAt: barDate ?? self.barDate, lookbackBars: horizon == .week ? 20 : 60, shortWindows: [],
            close: close, sma20: sma20, sma50: sma50, sma200: nil, rsi14: rsi14,
            macd: nil, macdSignal: nil, macdHistogram: macdHistogram,
            atr14: atrPercent.map { $0 / 100 * close }, atrPercent: atrPercent, volumeRatio: volumeRatio,
            rangeHigh: nil, rangeLow: nil, rangePosition: rangePosition,
            gapMeanPercent: nil, gapMaxPercent: nil, gapSampleCount: 0,
            relativeStrengthPercent: nil, benchmarkSymbol: nil,
            sufficiency: .init(completedBars: 220, unavailable: []))
    }
    private func measurements(close: Double = 100) -> Q.Measurements {
        .init(completedBars: 220, close: close, sma20: 95, horizonReturnPercent: 5,
              volumeRatio: 2.0, atr14: 3, stopLow: 95, targetHigh: 110)
    }

    @Test(arguments: [R.Horizon.week, .fortnight])
    func fiveConfirmedChecksAndNoContraryYieldsAligned(horizon: R.Horizon) {
        let confluence = Q.confluence(snapshot: snapshot(horizon: horizon), symbol: "ACME",
            barDate: barDate, measurements: measurements(), horizon: horizon)
        #expect(confluence.verdict == .aligned)
        #expect([confluence.trendAlignment, confluence.momentumDirection, confluence.volatilitySuitability,
                 confluence.liquidityConfirmation, confluence.resistanceDistance].allSatisfy { $0 == .confirmed })
        #expect(confluence.reasons.isEmpty, "An aligned verdict names no failed check")
    }

    @Test func confluenceQualifiedRequiresBothAnAlignedVerdictAndACitedCatalyst() throws {
        let captured = try capture(), key = newsKey(news())
        let receipt = Q.prepare(captured, horizon: .week).receipt(verdict: buy, citedKeys: [key])
        let aligned = Q.confluence(snapshot: snapshot(), symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        try #require(aligned.verdict == .aligned)
        let mixed = Q.confluence(snapshot: snapshot(volumeRatio: 1.0), symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        try #require(mixed.verdict == .mixed)

        func withConfluence(_ c: Q.Confluence, citedKeys: [String]) throws -> Q.Receipt {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            json["confluence"] = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
            json["citedQualifyingKeys"] = citedKeys
            return try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(try withConfluence(aligned, citedKeys: []).confluenceQualified == false,
                "Aligned alone, without a cited catalyst, is not enough")
        #expect(try withConfluence(aligned, citedKeys: [key]).confluenceQualified == true)
        #expect(try withConfluence(mixed, citedKeys: [key]).confluenceQualified == false,
                "A cited catalyst alone, without an aligned verdict, is not enough")
    }

    @Test func oneContraryCheckAmongConfirmedIsMixedNotConflicted() throws {
        // Liquidity below the 1.5x bar; the other four checks stay confirmed.
        let s = snapshot(volumeRatio: 1.0)
        let confluence = Q.confluence(snapshot: s, symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        #expect(confluence.verdict == .mixed)
        #expect(confluence.liquidityConfirmation == .contrary)
        #expect(confluence.trendAlignment == .confirmed && confluence.momentumDirection == .confirmed)
        #expect(confluence.reasons.count == 1, "Only the one failed check is explained")
    }

    @Test func twoOrMoreContraryChecksIsConflictedEvenWithConfirmationsPresent() throws {
        // Liquidity AND resistance both contrary; trend/momentum/volatility stay confirmed.
        let s = snapshot(volumeRatio: 1.0, rangePosition: 0.95)
        let confluence = Q.confluence(snapshot: s, symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        #expect(confluence.verdict == .conflicted, "2+ contrary checks outrank the aligned count")
        #expect(confluence.liquidityConfirmation == .contrary && confluence.resistanceDistance == .contrary)
        #expect(confluence.reasons.count == 2)
    }

    @Test func trendCheckRequiresBothCloseAboveSMA20AndSMA20AtOrAboveSMA50() {
        #expect(Q.confluence(snapshot: snapshot(sma20: nil), symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week).trendAlignment == .unavailable)
        #expect(Q.confluence(snapshot: snapshot(close: 90, sma20: 95), symbol: "ACME", barDate: barDate,
            measurements: measurements(close: 90), horizon: .week).trendAlignment == .contrary,
            "Close at or below SMA20 is not a bullish structure")
        #expect(Q.confluence(snapshot: snapshot(sma20: 95, sma50: 98), symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week).trendAlignment == .contrary,
            "SMA20 still below SMA50 is a bounce inside a still-declining intermediate trend")
        #expect(Q.confluence(snapshot: snapshot(sma20: 95, sma50: nil), symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week).trendAlignment == .confirmed,
            "SMA50 absent does not block confirmation; only a KNOWN conflict does")
    }

    @Test func momentumCheckNeedsBothSignalsWhenBothArePresent() {
        typealias V = StockSageResearchQualification.ConfluenceCheck
        func momentum(rsi: Double?, macd: Double?) -> V {
            Q.confluence(snapshot: snapshot(rsi14: rsi, macdHistogram: macd), symbol: "ACME",
                barDate: barDate, measurements: measurements(), horizon: .week).momentumDirection
        }
        #expect(momentum(rsi: nil, macd: nil) == .unavailable)
        #expect(momentum(rsi: 60, macd: nil) == .confirmed, "RSI alone above 50 confirms")
        #expect(momentum(rsi: 40, macd: nil) == .contrary)
        #expect(momentum(rsi: nil, macd: 0.5) == .confirmed, "MACD histogram alone above zero confirms")
        #expect(momentum(rsi: 60, macd: 0.5) == .confirmed, "Both present and both bullish")
        #expect(momentum(rsi: 60, macd: -0.1) == .contrary, "One bearish signal denies confirmation even if the other is bullish")
    }

    @Test func volatilityBandIsWiderForTheFortnightHorizon() {
        typealias V = StockSageResearchQualification.ConfluenceCheck
        func volatility(_ atrPercent: Double?, _ horizon: R.Horizon) -> V {
            Q.confluence(snapshot: snapshot(horizon: horizon, atrPercent: atrPercent), symbol: "ACME",
                barDate: barDate, measurements: measurements(), horizon: horizon).volatilitySuitability
        }
        #expect(volatility(nil, .week) == .unavailable)
        #expect(volatility(0.1, .week) == .contrary, "Below the 0.5% floor for either horizon")
        #expect(volatility(3, .week) == .confirmed && volatility(3, .fortnight) == .confirmed)
        #expect(volatility(12, .week) == .contrary, "12% exceeds the week's 10% ceiling")
        #expect(volatility(12, .fortnight) == .confirmed, "12% is inside the fortnight's wider 15% ceiling")
    }

    @Test func liquidityCheckUsesTheSameOneAndAHalfTimesBarAsTheStrictScreen() {
        typealias V = StockSageResearchQualification.ConfluenceCheck
        func liquidity(_ ratio: Double?) -> V {
            Q.confluence(snapshot: snapshot(volumeRatio: ratio), symbol: "ACME", barDate: barDate,
                measurements: measurements(), horizon: .week).liquidityConfirmation
        }
        #expect(liquidity(nil) == .unavailable)
        #expect(liquidity(1.4) == .contrary)
        #expect(liquidity(1.5) == .confirmed, "Exactly at the bar confirms")
        #expect(liquidity(3.0) == .confirmed)
    }

    @Test func resistanceDistanceFlagsAnAlreadyExtendedCloseAsContrary() {
        typealias V = StockSageResearchQualification.ConfluenceCheck
        func resistance(_ position: Double?) -> V {
            Q.confluence(snapshot: snapshot(rangePosition: position), symbol: "ACME", barDate: barDate,
                measurements: measurements(), horizon: .week).resistanceDistance
        }
        #expect(resistance(nil) == .unavailable)
        #expect(resistance(0.5) == .confirmed, "Comfortable room below the measured high")
        #expect(resistance(0.849) == .confirmed)
        #expect(resistance(0.85) == .contrary, "At the measured-high threshold: little room to the target")
        #expect(resistance(0.99) == .contrary, "Already sitting at the recent high")
    }

    @Test func mismatchedSnapshotBasisFailsClosedAsInsufficientRatherThanMixingAdjustmentRegimes() {
        // A different reference close than the qualification's own measurements: cannot verify
        // both are on the same adjusted basis, so confluence refuses to guess.
        let mismatchedClose = Q.confluence(snapshot: snapshot(close: 101), symbol: "ACME",
            barDate: barDate, measurements: measurements(close: 100), horizon: .week)
        #expect(mismatchedClose.verdict == .insufficient)
        #expect(mismatchedClose.reasons.count == 1 && mismatchedClose.reasons[0].contains("close"))

        // A stale bar: the snapshot's session does not match the qualification's completed bar.
        let staleBar = Q.confluence(snapshot: snapshot(barDate: barDate.addingTimeInterval(-86_400)),
            symbol: "ACME", barDate: barDate, measurements: measurements(), horizon: .week)
        #expect(staleBar.verdict == .insufficient)
        #expect(staleBar.reasons.count == 1 && staleBar.reasons[0].lowercased().contains("session"))

        // A foreign symbol: never mix one symbol's technical picture into another's qualification.
        let wrongSymbol = Q.confluence(snapshot: snapshot(symbol: "OTHER"), symbol: "ACME",
            barDate: barDate, measurements: measurements(), horizon: .week)
        #expect(wrongSymbol.verdict == .insufficient)
    }

    @Test func missingSnapshotOrAllUnavailableFieldsIsInsufficientNotConflicted() {
        let noSnapshot = Q.confluence(snapshot: nil, symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        #expect(noSnapshot.verdict == .insufficient)
        #expect([noSnapshot.trendAlignment, noSnapshot.momentumDirection, noSnapshot.volatilitySuitability,
                 noSnapshot.liquidityConfirmation, noSnapshot.resistanceDistance].allSatisfy { $0 == .unavailable })

        let emptySnapshot = snapshot(sma20: nil, sma50: nil, rsi14: nil, macdHistogram: nil,
            atrPercent: nil, volumeRatio: nil, rangePosition: nil)
        let allUnavailable = Q.confluence(snapshot: emptySnapshot, symbol: "ACME", barDate: barDate,
            measurements: measurements(), horizon: .week)
        #expect(allUnavailable.verdict == .insufficient, "Zero resolved checks cannot support any verdict")
    }

    @Test func confluenceEncodesAdditivelyAndLegacyReceiptsSkipItInValidation() throws {
        let captured = try capture(), key = newsKey(news())
        let receipt = Q.prepare(captured, horizon: .week).receipt(verdict: buy, citedKeys: [key])
        let fresh = try #require(receipt.technicalSnapshot)
        #expect(fresh.symbol == "ACME" && fresh.close == receipt.measurements.close)
        let confluence = try #require(receipt.confluence)
        #expect(confluence == Q.confluence(snapshot: receipt.technicalSnapshot, symbol: "ACME",
            barDate: receipt.barDate, measurements: receipt.measurements, horizon: .week))
        #expect(Q.valid(receipt, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))
        let roundTrip = try JSONDecoder().decode(Q.Receipt.self, from: JSONEncoder().encode(receipt))
        #expect(roundTrip == receipt && roundTrip.technicalSnapshot == fresh && roundTrip.confluence == confluence)

        // Legacy bytes (no technicalSnapshot/confluence keys at all) must still decode and validate.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        json.removeValue(forKey: "technicalSnapshot")
        json.removeValue(forKey: "confluence")
        let legacy = try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.technicalSnapshot == nil && legacy.confluence == nil)
        #expect(Q.valid(legacy, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))
        #expect(legacy.isQualified, "Confluence is additive and never blocks the original strict gate")
        let reencoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(reencoded["technicalSnapshot"] == nil && reencoded["confluence"] == nil,
                "Absent legacy fields stay absent for archive digests")

        // A tampered receipt with only one of the pair present must fail closed.
        json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        json.removeValue(forKey: "confluence")
        let orphanedSnapshot = try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!Q.valid(orphanedSnapshot, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))

        // A recomputation mismatch (someone hand-edited a verdict field) must fail closed.
        // The default fixture's real verdict is .aligned, so tamper to a genuinely different value.
        json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        var tamperedConfluence = try #require(json["confluence"] as? [String: Any])
        try #require(tamperedConfluence["verdict"] as? String == "aligned")
        tamperedConfluence["verdict"] = "conflicted"
        json["confluence"] = tamperedConfluence
        let tampered = try JSONDecoder().decode(Q.Receipt.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!Q.valid(tampered, symbol: "ACME", horizon: R.Horizon.week.rawValue, at: captured.at, citedKeys: [key]))
    }
}
