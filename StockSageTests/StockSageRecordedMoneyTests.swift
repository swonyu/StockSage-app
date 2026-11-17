import Foundation
import Testing
@testable import StockSage

/// All amounts below are independently declared fixture data. A ticker never
/// supplies denomination to production code, and no provider or model is called.
@MainActor
struct StockSageRecordedMoneyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func unit(_ currency: String, hundredths: Bool = false,
                      provider: Bool = false) -> StockSagePriceDenomination {
        StockSagePriceDenomination(currencyCode: currency,
            rawUnitsPerMajor: hundredths ? .hundredths : .major,
            provenance: provider ? .yahooChartMetadata : .manualEntry)!
    }

    private func quote(_ price: Double, _ unit: StockSagePriceDenomination?) -> StockSageQuote {
        StockSageQuote(price: price, previousPrice: price, marketTime: now,
            priceSource: .manualEntry, denomination: unit)
    }

    private func trade(_ symbol: String, entry: Double, exit: Double, shares: Double,
                       unit: StockSagePriceDenomination?) -> TradeRecord {
        TradeRecord(symbol: symbol, side: .long, entry: entry, stop: entry / 2,
            target: nil, shares: shares, openedAt: now.addingTimeInterval(-100),
            exitPrice: exit, closedAt: now, denomination: unit)
    }

    @Test func chartMetadataBindsEURCryptoAndUSDOrPenceLondonPrices() throws {
        for (symbol, currency, expected, scale) in [
            ("BTC-EUR", "EUR", "EUR", 1.0),
            ("CSPX.L", "USD", "USD", 1.0),
            ("BP.L", "GBp", "GBP", 100.0),
            ("CSPX.L", "GBP", "GBP", 1.0)
        ] {
            let payload = try JSONSerialization.data(withJSONObject: ["chart": ["result": [[
                "meta": ["symbol": symbol, "currency": currency,
                         "regularMarketPrice": 600, "previousClose": 590,
                         "regularMarketTime": now.timeIntervalSince1970]
            ]]]])
            let parsed = try #require(StockSageQuoteService.parseChart(payload, requestedSymbol: symbol, now: now))
            #expect(parsed.price == 600)
            #expect(parsed.denomination?.currencyCode == expected)
            #expect(parsed.denomination?.rawUnitsPerMajor.rawValue == scale)
            #expect(StockSageQuoteService.parseChart(payload, requestedSymbol: "OTHER", now: now) == nil)
        }
    }

    @Test func missingChartCurrencyNeverBecomesUSDFromItsTicker() throws {
        let bytes = Data(#"{"chart":{"result":[{"meta":{"symbol":"BTC-EUR","regularMarketPrice":600,"previousClose":590}}]}}"#.utf8)
        let parsed = try #require(StockSageQuoteService.parseChart(bytes, requestedSymbol: "BTC-EUR", now: now))
        #expect(parsed.price == 600 && parsed.denomination == nil)
        #expect(StockSagePositionSizer.rawQuoteUnitToUSD(symbol: "BTC-EUR", fxRatesToUSD: ["EUR": 2]) == nil)
    }

    @Test func manualCurrencyInputDoesNotUppercasePenceIntoPounds() {
        #expect(StockSagePriceDenomination.manualDeclaration(currencyInput: " usd ", hundredths: false)?.currencyCode == "USD")
        #expect(StockSagePriceDenomination.manualDeclaration(currencyInput: "GBP", hundredths: true)?.majorValue(rawValue: 400) == 4)
        for token in ["GBp", "GBX", "ZAc", "XXX", "XTS", "not a currency"] {
            #expect(StockSagePriceDenomination.manualDeclaration(currencyInput: token, hundredths: false) == nil)
        }
    }

    @Test func recordedLondonUSDValuationKeepsItsDeclaredDollars() throws {
        let holding = PortfolioPosition(symbol: "CSPX.L", shares: 2, costBasis: 500, costDenomination: unit("USD"))
        let result = try #require(StockSageRecordedValuation.holding(holding, quote: quote(600, unit("USD")), now: now))
        #expect(result.currency == "USD" && result.value == 1_200 && result.cost == 1_000 && result.profit == 200)
    }

    @Test func penceMarkAndPoundCostNormalizeSeparately() throws {
        let holding = PortfolioPosition(symbol: "BP.L", shares: 10, costBasis: 4, costDenomination: unit("GBP"))
        let result = try #require(StockSageRecordedValuation.holding(holding,
            quote: quote(450, unit("GBP", hundredths: true)), now: now))
        #expect(result.value == 45 && result.cost == 40 && result.profit == 5)
    }

    @Test func unknownOrDifferentCostCurrencyWithholdsOnlyProfit() throws {
        for costUnit: StockSagePriceDenomination? in [nil, unit("EUR")] {
            let holding = PortfolioPosition(symbol: "CSPX.L", shares: 2, costBasis: 500, costDenomination: costUnit)
            let result = try #require(StockSageRecordedValuation.holding(holding, quote: quote(600, unit("USD")), now: now))
            #expect(result.value == 1_200 && result.cost == nil && result.profit == nil)
        }
        let legacy = PortfolioPosition(symbol: "CSPX.L", shares: 2, costBasis: 500)
        #expect(StockSageRecordedValuation.holding(legacy, quote: quote(600, nil), now: now) == nil)
    }

    @Test func recordedTotalsKeepDifferentCurrenciesSeparateAndCountPricedLots() throws {
        let usd = PortfolioPosition(symbol: "AAPL", shares: 2, costBasis: 10, costDenomination: unit("USD"))
        let eur = PortfolioPosition(symbol: "BTC-EUR", shares: 1, costBasis: 20, costDenomination: unit("EUR"))
        let usdValue = try #require(StockSageRecordedValuation.holding(usd, quote: quote(15, unit("USD")), now: now))
        let eurValue = try #require(StockSageRecordedValuation.holding(eur, quote: quote(25, unit("EUR")), now: now))
        let rows = [usdValue, eurValue]
        let totals = try #require(StockSageRecordedValuation.totals(rows))
        #expect(totals.map(\.currency) == ["EUR", "USD"])
        #expect(totals.map(\.value) == [25, 30])
        #expect(totals.map(\.profit) == [5, 10])
        #expect(totals.map(\.pricedLots) == [1, 1])
        #expect(StockSageRecordedValuation.totals([]) == [])
    }

    @Test func unrepresentableRecordedAmountsStayUnavailable() {
        let huge = PortfolioPosition(symbol: "X", shares: 1e200, costBasis: 1, costDenomination: unit("USD"))
        #expect(StockSageRecordedValuation.holding(huge, quote: quote(1e200, unit("USD")), now: now) == nil)
        let tiny = PortfolioPosition(symbol: "X", shares: 1, costBasis: 0, costDenomination: unit("GBP"))
        #expect(StockSageRecordedValuation.holding(tiny,
            quote: quote(.leastNonzeroMagnitude, unit("GBP", hundredths: true)), now: now) == nil)
        let enormous = StockSageRecordedValuation.Holding(currency: "USD", value: 1e308, cost: nil, profit: nil)
        #expect(StockSageRecordedValuation.totals([enormous, enormous]) == nil)
    }

    @Test func personalPricesCannotBecomeSessionSignalsOrExecutableFeedQuotes() {
        let mark = quote(100, unit("USD"))
        #expect(!mark.hasSessionBaseline(symbol: "AAPL", at: now))
        #expect(!StockSageStore.acceptsLiveTick(now, after: nil, priceSource: .manualEntry, now: now))
        #expect(!StockSageStore.acceptsLiveTick(now, after: nil, priceSource: .importedRecord, now: now))
        let cache = StockSageQuoteCache.from(symbols: [.init(symbol: "AAPL", market: "Personal record", quotes: [mark])], savedAt: now)
        #expect(cache.entries.isEmpty)
        #expect(StockSageCurrency.fxRateToUSD(currency: "EUR", observations: [(mark, false)], forSizing: false, now: now) == nil)
    }

    @Test func sizingUsesDeclaredUnitsInsteadOfLondonSuffix() throws {
        let dollars = try #require(StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01,
            entry: 100, stop: 90, symbol: "CSPX.L", fxRatesToUSD: [:], denomination: unit("USD")))
        #expect(dollars.shares == 10 && dollars.dollarsAtRisk == 100 && dollars.pctOfAccount == 10)
        let pounds = try #require(StockSagePositionSizer.recordedSize(accountMajor: 10_000, riskFraction: 0.01,
            entry: 10_000, stop: 9_000, denomination: unit("GBP", hundredths: true)))
        #expect(pounds.shares == 10 && pounds.dollarsAtRisk == 10_000 && pounds.pctOfAccount == 10)
        #expect(pounds.denomination?.majorValue(rawValue: pounds.dollarsAtRisk) == 100)
        #expect(StockSagePositionSizer.recordedSize(accountMajor: 10_000, riskFraction: 0.01,
            entry: 100, stop: 90, denomination: nil) == nil)
        #expect(StockSagePositionSizer.recordedSize(accountMajor: .leastNonzeroMagnitude,
            riskFraction: .leastNonzeroMagnitude, entry: 100, stop: 90, denomination: unit("USD")) == nil)
    }

    @Test func explicitEURConversionAndUnknownDenominationAreDistinct() {
        #expect(StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01,
            entry: 100, stop: 90, symbol: "BTC-EUR", fxRatesToUSD: ["EUR": 2], denomination: unit("EUR"))?.shares == 5)
        #expect(StockSagePositionSizer.size(account: 10_000, riskFraction: 0.01,
            entry: 100, stop: 90, symbol: "AAPL", fxRatesToUSD: [:], denomination: nil) == nil)
    }

    @Test func journalNormalizesDeclaredPenceAndPoundsBeforeSumming() throws {
        let rows = [trade("BP.L", entry: 100, exit: 50, shares: 1, unit: unit("GBP", hundredths: true)),
                    trade("OTHER", entry: 0.75, exit: 1.25, shares: 2, unit: unit("GBP"))]
        let stats = StockSageJournal.stats(rows)
        let year = try #require(StockSageJournal.yearlyPnL(rows).first)
        #expect(stats.closed == 2 && stats.totalProfit == 0.5 && stats.profitCurrency == "GBP")
        #expect(year.realizedDollars == 0.5 && year.profitCurrency == "GBP")
    }

    @Test func unknownOrMixedJournalMoneyNeverBecomesACombinedUSDTotal() {
        let a = trade("AAPL", entry: 100, exit: 110, shares: 1, unit: unit("USD"))
        for b in [trade("BTC-EUR", entry: 100, exit: 110, shares: 1, unit: unit("EUR")),
                  trade("AAPL", entry: 100, exit: 110, shares: 1, unit: nil)] {
            let stats = StockSageJournal.stats([a, b])
            #expect(stats.closed == 2 && stats.wins == 2 && stats.totalR == 0.4)
            #expect(stats.totalProfit.isNaN && stats.profitCurrency == nil)
            #expect(StockSageJournal.yearlyPnL([a, b]).first?.realizedDollars.isNaN == true)
        }
    }

    @Test func knownUnitConversionFailureDoesNotRelabelCurrencyAsUnknown() {
        let x = Double.leastNonzeroMagnitude
        let recorded = trade("BP.L", entry: 2 * x, exit: 3 * x, shares: 1, unit: unit("GBP", hundredths: true))
        #expect(recorded.realizedProfit == x && recorded.realizedMajorProfit == nil)
        #expect(recorded.realizedProfitDescription.contains("GBp"))
        #expect(recorded.realizedProfitDescription.contains("conversion"))
        #expect(!recorded.realizedProfitDescription.contains("currency unconfirmed"))
        #expect(StockSageCurrency.adaptivePrice(x) != "0.000000")
    }

    @Test func chatCapturesExactRawValuesUnitsAndPersonalProvenance() throws {
        let rows = [StockSageSymbol(symbol: "BTC-EUR", market: "fixture", quotes: [quote(600, unit("EUR"))]),
                    StockSageSymbol(symbol: "CSPX.L", market: "fixture", quotes: [quote(600, unit("USD"))]),
                    StockSageSymbol(symbol: "BP.L", market: "fixture", quotes: [quote(600, unit("GBP", hundredths: true))]),
                    StockSageSymbol(symbol: "UNKNOWN", market: "fixture", quotes: [quote(600, nil)])]
        let facts = StockSageChat.snapshot(symbols: rows, ideas: [], earnings: [:], sample: false, now: now).facts
        #expect(facts.count == 4 && facts.allSatisfy { $0.value == "600.00" })
        #expect(facts.map(\.unit) == ["EUR", "USD", "GBp (100 = 1 GBP)", "raw units; denomination unknown"])
        #expect(facts.allSatisfy { $0.status.contains("personal record") && $0.status.contains("not provider-verified") })
    }

    @Test func quoteCacheRoundTripRetainsMetadataAndLegacyQuotesRemainUnknown() throws {
        let original = StockSageQuoteCache(entries: [.init(symbol: "CSPX.L", price: 600,
            previousClose: 590, time: now, marketTime: now, priceSource: .yahoo, denomination: unit("USD", provider: true))], savedAt: now)
        let bytes = try JSONEncoder().encode(original)
        let recovered = try JSONDecoder().decode(StockSageQuoteCache.self, from: bytes)
        #expect(recovered == original)
        #expect(recovered.symbols(marketFor: { _ in "fixture" }).first?.latest?.denomination?.currencyCode == "USD")
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "denomination"); json["entries"] = entries
        let legacy = try JSONDecoder().decode(StockSageQuoteCache.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.entries.first?.price == 600 && legacy.entries.first?.denomination == nil)
    }

    @Test func baselineRepairCannotMixDeclaredCurrenciesOrRawUnits() throws {
        let original = StockSageQuote(price: 600, previousPrice: 600, time: now,
            marketTime: now, priceSource: .massiveSIP, denomination: unit("USD", provider: true))
        let comparable = StockSageQuoteService.LiveQuote(symbol: "CSPX.L", price: 600,
            previousClose: 590, marketTime: now, priceSource: .yahoo,
            previousCloseSource: .yahoo, previousCloseQuoteTime: now, denomination: unit("USD", provider: true))
        let repaired = try #require(StockSageStore.mergedQuote(comparable, after: original,
            symbol: "CSPX.L", acceptPrice: false, now: now))
        #expect(repaired.previousPrice == 590 && repaired.hasSessionBaseline(symbol: "CSPX.L", at: now))
        for incomingUnit in [unit("GBP", hundredths: true, provider: true), unit("EUR", provider: true)] {
            let incoming = StockSageQuoteService.LiveQuote(symbol: "CSPX.L", price: 50_000,
                previousClose: 49_000, marketTime: now, priceSource: .yahoo,
                previousCloseSource: .yahoo, previousCloseQuoteTime: now, denomination: incomingUnit)
            let result = try #require(StockSageStore.mergedQuote(incoming, after: original,
                symbol: "CSPX.L", acceptPrice: false, now: now))
            #expect(result == original)
            #expect(!result.hasSessionBaseline(symbol: "CSPX.L", at: now))
        }
    }

    @Test func adviceLevelsOnlyReceiveAQuoteWithMatchingDeclaredUnits() {
        let advice = TradeAdvice(action: .buy, conviction: 0.6, regime: .bullTrend,
            rationale: [], stopPrice: 90, targetPrice: 130, suggestedWeight: 0.05, caveat: "Fixture")
        let base = StockSageIdea(symbol: "CSPX.L", market: "Fixture", price: 100,
            advice: advice, spark: [], denomination: unit("USD"))
        #expect(base.withLivePrice(105, asOf: now, denomination: nil) == base)
        #expect(base.withLivePrice(105, asOf: now, denomination: unit("EUR")) == base)
        #expect(base.withLivePrice(10_500, asOf: now, denomination: unit("USD", hundredths: true)) == base)
        let updated = base.withLivePrice(105, asOf: now, denomination: unit("USD", provider: true))
        #expect(updated.price == 105 && updated.advice.stopPrice == 90 && updated.advice.targetPrice == 130)
        #expect(updated.denomination == base.denomination)
        let legacy = StockSageIdea(symbol: "CSPX.L", market: "Fixture", price: 100, advice: advice, spark: [])
        #expect(legacy.withLivePrice(105, asOf: now, denomination: unit("USD")) == legacy)
    }

    @Test func narratorAnchorsStateTheOriginalRawUnitAndDeclarationSource() {
        let advice = TradeAdvice(action: .buy, conviction: 0.6, regime: .bullTrend,
            rationale: [], stopPrice: 590, targetPrice: 620, suggestedWeight: 0.05, caveat: "Fixture")
        for declaration: StockSagePriceDenomination? in [unit("USD"), unit("GBP", hundredths: true), nil] {
            let idea = StockSageIdea(symbol: "CSPX.L", market: "Fixture", price: 600,
                advice: advice, spark: [], denomination: declaration)
            let brief = StockSageCatalystWatch.brief(for: idea, inputs: .init(now: now))
            let facts = StockSageCatalystNarrator.facts(for: brief)
            let label = declaration?.quoteUnitLabel ?? "raw units; denomination unknown"
            #expect(facts.contains("Price: 600.00 " + label))
            #expect(facts.contains("Stop: 590.00 " + label))
            #expect(facts.contains("Target: 620.00 " + label))
            #expect(facts.contains { $0.contains(declaration?.provenanceLabel ?? "do not infer currency") })
        }
    }

    @Test func legacyCSVRefusesToDiscardRecordedCurrencyButJSONPreservesIt() throws {
        let recorded = trade("CSPX.L", entry: 500, exit: 600, shares: 2, unit: unit("USD"))
        #expect(throws: StockSageJournalCSV.ExportError.self) { try StockSageJournalCSV.csv([recorded]) }
        let data = try StockSageBackup.export(trades: [recorded], positions: [], userSymbols: [])
        let restored = try StockSageBackup.restore(from: data).get()
        #expect(restored.trades == [recorded] && restored.trades.first?.realizedMajorProfit == 200)
        let legacy = trade("CSPX.L", entry: 500, exit: 600, shares: 2, unit: nil)
        #expect(try StockSageJournalCSV.csv([legacy]).hasPrefix(StockSageJournalCSV.header))
    }

    @Test func historyCachePreservesValidatedDailyBasisAndRejectsMalformedMetadata() throws {
        let basis = try #require(StockSageHistoryBasis(currencyCode: "EUR", rawUnitsPerMajor: .major,
            sampling: .continuousDays365, exchangeTimeZoneIdentifier: "UTC", provenance: .yahooChartMetadata))
        let h = StockSagePriceHistory(symbol: "BTC-EUR", dates: [now.addingTimeInterval(-86_400), now],
            opens: [100, 110], highs: [100, 110], lows: [100, 110], closes: [100, 110],
            volumes: [0, 0], priceSource: .yahoo, analyticsBasis: basis)
        let cache = StockSageHistoryCache.from(histories: ["BTC-EUR": h], universe: ["BTC-EUR"], savedAt: now)
        let bytes = try JSONEncoder().encode(cache)
        let recovered = try #require(StockSageHistoryCache.decode(bytes))
        #expect(recovered.priceHistories()["BTC-EUR"] == h)
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        var bad = try #require(entries[0]["analyticsBasis"] as? [String: Any])
        bad["currencyCode"] = "XXX"; entries[0]["analyticsBasis"] = bad; json["entries"] = entries
        #expect(StockSageHistoryCache.decode(try JSONSerialization.data(withJSONObject: json)) == nil)
        entries[0].removeValue(forKey: "analyticsBasis"); json["entries"] = entries
        let legacy = try #require(StockSageHistoryCache.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(legacy.priceHistories()["BTC-EUR"]?.analyticsBasis == nil)
        #expect(legacy.priceHistories()["BTC-EUR"]?.closes == [100, 110])
    }
}
