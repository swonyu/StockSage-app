import Testing
import Foundation
@testable import StockSage

// MARK: - StockSageStore.mergedPolledQuotes — W3 (owner: "live prices … seamless … update
// automatically every 30 seconds")
//
// Pins the pure merge behind `applyPolledQuotes`, the in-place update the `.streamGap` 30s timer
// now applies instead of `mergeLiveQuotes`/`replaceAll`. No `@MainActor` singleton, no live
// stream, no network — `symbols`/`ideas`/`symbolIndex` are hand-built fixtures, so this is
// parallel-test safe (mirrors the "never touches StockSageStore.shared" discipline documented in
// StockSageQAFixtureIdeasTests).
//
// Fixture: a 3-row board (AAPL, MSFT, GOOG) with matching ideas, indices 0/1/2 — the SAME order
// `rebuildSymbolIndex()` would produce. AAPL gets a priced quote WITH a market timestamp; MSFT
// gets an undated quote (marketTime: nil) which cannot erase its dated observation — the
// fail-closed straddle; GOOG gets no quote at all (must come through byte-identical); TSLA is
// on the board but its quote is price == 0 (the exact `price > 0` boundary) and must be skipped
// exactly like GOOG.
struct MarketsPolledQuoteMergeTests {
    @Test @MainActor func throttledRefreshRetainsEveryPriorRowWithoutClaimingAFullRefresh() async throws {
        let suite = "stocksage.quote-throttle.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let original = refreshFixtureRows()
        store.replaceAll(original)
        let incoming = Dictionary(uniqueKeysWithValues: original.prefix(8).map {
            ($0.symbol, StockSageQuoteService.LiveQuote(symbol: $0.symbol, price: 120,
                previousClose: 99, marketTime: Date().addingTimeInterval(-2), priceSource: .massiveSIP))
        })
        var fxCalls = 0, healCalls = 0

        await store.refresh(universe: original, allowed: { true }, fetchQuotes: { requested in
            #expect(requested == original.map(\.symbol))
            return .init(quotes: incoming, stop: .yahooThrottled)
        }, refreshFX: { fxCalls += 1 }, heal: { _ in healCalls += 1 })

        #expect(store.symbols.map(\.symbol) == original.map(\.symbol),
                "Even 80% coverage cannot remove the unrequested tail of a throttled sweep")
        #expect(store.latestPrice(original[0].symbol) == 120)
        #expect(store.symbol(named: original[9].symbol) == original[9])
        #expect(store.feedError?.localizedCaseInsensitiveContains("Yahoo") == true)
        #expect(store.feedError?.localizedCaseInsensitiveContains("partial") == true)
        #expect(store.lastFullRefreshAt == nil && !store.isRefreshing)
        #expect(fxCalls == 0 && healCalls == 0,
                "A stopped provider sweep must not restart Yahoo through FX or stale-quote healing")
    }

    @Test(arguments: ["fx", "invalidated", "cancelled", "heal", "heal-cancelled"]) @MainActor
    func interruptedRefreshPreservesTheBoardAndPreviousFeedError(point: String) async throws {
        let suite = "stocksage.quote-invalidation.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let original = refreshFixtureRows()
        store.replaceAll(original)
        await store.refresh(universe: original, allowed: { false }, fetchQuotes: { _ in
            Issue.record("Denied refresh must not fetch"); return .init(quotes: [:])
        }, refreshFX: {}, heal: { _ in })
        let previousError = try #require(store.feedError)
        var allowed = true
        var fxCalls = 0, healCalls = 0
        let incoming = Dictionary(uniqueKeysWithValues: original.map {
            ($0.symbol, StockSageQuoteService.LiveQuote(symbol: $0.symbol, price: 120,
                previousClose: 99, marketTime: Date().addingTimeInterval(-2), priceSource: .massiveSIP))
        })
        let task = Task { @MainActor in
            await store.refresh(universe: original, allowed: { allowed }, fetchQuotes: { _ in
                if point == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                return .init(quotes: incoming, stop: point == "invalidated" ? .invalidated : .finished)
            }, refreshFX: {
                fxCalls += 1
                if point == "fx" { allowed = false }
            }, heal: { _ in
                healCalls += 1
                if point == "heal" { allowed = false }
                if point == "heal-cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await task.value

        let afterPublication = point.hasPrefix("heal")
        if afterPublication {
            #expect(store.latestPrice(original[0].symbol) == 120,
                    "Rows accepted before invalidation may remain without a completed-refresh claim")
        } else { #expect(store.symbols == original) }
        #expect(store.feedError == previousError,
                "Cancellation or invalidation is not a market-feed outage or a successful refresh")
        #expect(store.lastUpdated == nil && store.lastFullRefreshAt == nil && !store.isRefreshing)
        #expect(healCalls == (afterPublication ? 1 : 0))
        #expect(fxCalls == (point == "fx" || afterPublication ? 1 : 0))
    }

    @Test(arguments: [false, true]) @MainActor
    func throttledRefreshPricesMissingCuratedRowsThroughNormalAcceptance(hasPriorRow: Bool) async throws {
        let suite = "stocksage.quote-throttle-missing.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let universe = refreshFixtureRows()
        let now = Date()
        let prior = StockSageSymbol(symbol: universe[0].symbol, market: "NASDAQ", quotes: [
            StockSageQuote(price: 130, previousPrice: 99, marketTime: now, priceSource: .massiveSIP)])
        if hasPriorRow { store.replaceAll([prior]) }
        func quote(_ index: Int, price: Double = 120, source: StockSagePriceSource = .massiveSIP,
                   at: Date? = nil) -> StockSageQuoteService.LiveQuote {
            .init(symbol: universe[index].symbol, price: price, previousClose: 99,
                  marketTime: at ?? now.addingTimeInterval(-2), priceSource: source)
        }
        let values = [quote(0), quote(1), quote(2, price: 0), quote(3, source: .sample),
                      quote(4, at: now.addingTimeInterval(3_600))]
        var incoming = Dictionary(uniqueKeysWithValues: values.map { ($0.symbol, $0) })
        incoming["UNREQUESTED"] = .init(symbol: "UNREQUESTED", price: 12, previousClose: 11,
                                         marketTime: now, priceSource: .massiveSIP)
        await store.refresh(universe: universe, allowed: { true }, fetchQuotes: { _ in
            .init(quotes: incoming, stop: .yahooThrottled)
        }, refreshFX: { Issue.record("Throttled refresh must not fetch FX") },
           heal: { _ in Issue.record("Throttled refresh must not heal") })

        #expect(Set(store.symbols.map(\.symbol)) == Set(universe.prefix(2).map(\.symbol)))
        #expect(store.latestPrice(universe[0].symbol) == (hasPriorRow ? 130 : 120))
        #expect(store.latestQuote(universe[1].symbol)?.priceSource == .massiveSIP)
        if hasPriorRow { #expect(store.symbol(named: prior.symbol) == prior) }
        #expect(store.lastFullRefreshAt == nil && store.feedError != nil)
    }

    @MainActor private func refreshFixtureRows() -> [StockSageSymbol] {
        let at = Date().addingTimeInterval(-60)
        return (0..<10).map { index in
            StockSageSymbol(symbol: "TEST\(index)", market: "NASDAQ", quotes: [
                StockSageQuote(price: 100, previousPrice: 99, marketTime: at, priceSource: .massiveSIP)])
        }
    }

    @Test func demoClockCannotBlockRealPricesOrContaminateScanAndHeader() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let market = now.addingTimeInterval(-2 * 86_400)
        let demo = StockSageSymbol(symbol: "AAPL", market: "NASDAQ", quotes: [
            StockSageQuote(price: 227.1, previousPrice: 226, marketTime: now, priceSource: .sample)])
        let real = StockSageSymbol(symbol: "MSFT", market: "NASDAQ", quotes: [
            StockSageQuote(price: 400, previousPrice: 390, marketTime: market, priceSource: .massiveSIP)])
        let demoIdea = StockSageIdea(symbol: "AAPL", market: "NASDAQ", price: 227.1,
            advice: advice(), spark: [], priceAsOf: now, priceSource: .sample)
        let live = StockSageQuoteService.LiveQuote(symbol: "AAPL", price: 245,
            previousClose: 240, marketTime: market, priceSource: .massiveSIP)
        let result = StockSageStore.mergedPolledQuotes(symbols: [demo], ideas: [demoIdea],
            symbolIndex: ["AAPL": 0], quotes: ["AAPL": live], now: now)
        #expect(result.acceptedKeys == ["AAPL"])
        #expect(result.symbols[0].latest?.price == 245)
        #expect(result.symbols[0].latest?.priceSource == .massiveSIP)
        #expect(result.ideas[0].priceAsOf == market)
        #expect(result.ideas[0].advice == demoIdea.advice)

        let fresh = demoIdea.withLivePrice(245, asOf: market, priceSource: .massiveDaily)
        let scan = StockSageStore.ideasWithLatestPrices([fresh], symbols: [demo], previous: [demoIdea], now: now)
        #expect(scan == [fresh])
        #expect(StockSageStore.closeableQuoteAsOf([demo, real]) == market)
        #expect(StockSageStore.quoteSourceLabel([demo, real], asOf: market) == StockSagePriceSource.massiveSIP.label)

        // Reverse direction: a newer synthetic quote must never overwrite genuine evidence.
        let injected = StockSageQuoteService.LiveQuote(symbol: "AAPL", price: 999,
            previousClose: 999, marketTime: now, priceSource: .sample)
        let rejected = StockSageStore.mergedPolledQuotes(symbols: result.symbols, ideas: result.ideas,
            symbolIndex: ["AAPL": 0], quotes: ["AAPL": injected], now: now)
        #expect(rejected.acceptedKeys.isEmpty)
        #expect(rejected.symbols == result.symbols)
        #expect(rejected.ideas == result.ideas)
    }

    private static let oldPrice: [String: Double] = ["AAPL": 150, "MSFT": 300, "GOOG": 140, "TSLA": 250]
    // Hand-picked, unambiguous instant distinct from any "now"-derived value a bug could smuggle in.
    private static let oldAsOf = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

    private func advice() -> TradeAdvice {
        TradeAdvice(action: .buy, conviction: 0.6, regime: .bullTrend, rationale: [],
                    stopPrice: 90, targetPrice: 130, suggestedWeight: 0.05, caveat: "x")
    }

    private func fixtureSymbols() -> [StockSageSymbol] {
        ["AAPL", "MSFT", "GOOG", "TSLA"].map { sym in
            StockSageSymbol(symbol: sym, market: "NASDAQ", quotes: [
                StockSageQuote(price: Self.oldPrice[sym]!, previousPrice: Self.oldPrice[sym]!,
                               time: Date(timeIntervalSinceNow: -86_400)),
                StockSageQuote(price: Self.oldPrice[sym]!, previousPrice: Self.oldPrice[sym]!,
                               marketTime: Self.oldAsOf),
            ])
        }
    }

    private func fixtureIdeas() -> [StockSageIdea] {
        ["AAPL", "MSFT", "GOOG", "TSLA"].map { sym in
            StockSageIdea(symbol: sym, market: "NASDAQ", price: Self.oldPrice[sym]!, advice: advice(),
                          spark: [Self.oldPrice[sym]!], priceAsOf: Self.oldAsOf)
        }
    }

    private func fixtureIndex(_ symbols: [StockSageSymbol]) -> [String: Int] {
        Dictionary(symbols.enumerated().map { ($0.element.symbol.uppercased(), $0.offset) },
                  uniquingKeysWith: { a, _ in a })
    }

    private func quote(symbol: String = "AAPL", price: Double, previousClose: Double, marketTime: Date?) -> StockSageQuoteService.LiveQuote {
        .init(symbol: symbol, price: price, previousClose: previousClose, marketTime: marketTime)
    }

    @Test func invalidFutureIdeaCannotHideAValidNewerBoardPrice() {
        let at = Self.oldAsOf
        let symbols = fixtureSymbols()
        let ideas = [fixtureIdeas()[0].withLivePrice(200, asOf: at.addingTimeInterval(100_000))]
        let result = StockSageStore.mergedPolledQuotes(
            symbols: symbols, ideas: ideas, symbolIndex: fixtureIndex(symbols),
            quotes: ["AAPL": .init(symbol: "AAPL", price: 90, previousClose: 100,
                                    marketTime: at.addingTimeInterval(-1))], now: at)
        #expect(result.symbols == symbols)
        #expect(result.ideas == ideas)
        #expect(result.acceptedKeys.isEmpty)
    }

    @Test func pollMergeUpdatesOnlyThePolledRowsAndLeavesArrayShapeUntouched() {
        let symbols = fixtureSymbols()
        let ideas = fixtureIdeas()
        let index = fixtureIndex(symbols)
        let freshStamp = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T06:40:00Z — distinct from oldAsOf

        let quotes: [String: StockSageQuoteService.LiveQuote] = [
            "AAPL": quote(price: 155.25, previousClose: 150, marketTime: freshStamp),
            "MSFT": quote(symbol: "MSFT", price: 305, previousClose: 300, marketTime: nil),   // feed omitted the timestamp
            "TSLA": quote(symbol: "TSLA", price: 0, previousClose: 250, marketTime: freshStamp),   // price == 0: excluded
            // GOOG: no quote at all.
        ]

        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: index,
                                                       quotes: quotes, now: freshStamp)

        // Shape: same count, same order (symbol at each index unchanged), same identity (idea.id == symbol).
        #expect(result.symbols.count == symbols.count)
        #expect(result.ideas.count == ideas.count)
        #expect(result.symbols.map(\.symbol) == symbols.map(\.symbol))
        #expect(result.symbols.map(\.id) == symbols.map(\.id))
        #expect(result.ideas.map(\.id) == ideas.map(\.id))

        // AAPL: priced quote WITH a market time -> price and asOf both move.
        #expect(result.symbols[0].latest?.price == 155.25)
        #expect(result.ideas[0].price == 155.25)
        #expect(result.ideas[0].priceAsOf == freshStamp)

        // M2 ordering contract: missing time does NOT prove a newer price. Preserve the dated
        // observation; its original timestamp still ages normally through the freshness gate.
        #expect(result.symbols[1] == symbols[1])
        #expect(result.ideas[1] == ideas[1])

        // GOOG: no quote in the batch -> byte-identical row and idea.
        #expect(result.symbols[2] == symbols[2])
        #expect(result.ideas[2] == ideas[2])

        // TSLA: quote present but price == 0 (the exact `price > 0` boundary) -> excluded,
        // byte-identical to GOOG's untouched case.
        #expect(result.symbols[3] == symbols[3])
        #expect(result.ideas[3] == ideas[3])

        // The reported newest market time reflects only the quote that actually carried one
        // (AAPL's) — MSFT's nil and TSLA's skip must not contribute.
        #expect(result.newestMarketTime == freshStamp)
        #expect(result.acceptedKeys == ["AAPL"])
    }

    @Test func emptyQuoteBatchLeavesEverythingByteIdenticalAndReportsNoNewestTime() {
        let symbols = fixtureSymbols()
        let ideas = fixtureIdeas()
        let index = fixtureIndex(symbols)

        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: index, quotes: [:])

        #expect(result.symbols == symbols)
        #expect(result.ideas == ideas)
        #expect(result.newestMarketTime == nil)
    }

    @Test func staleRESTResponseCannotRewindStreamedRowOrIdea() {
        let symbols = fixtureSymbols(), ideas = fixtureIdeas()
        for stamp: Date? in [nil, Self.oldAsOf, Self.oldAsOf.addingTimeInterval(-1)] {
            let result = StockSageStore.mergedPolledQuotes(
                symbols: symbols, ideas: ideas, symbolIndex: fixtureIndex(symbols),
                quotes: ["AAPL": quote(price: 90, previousClose: 100, marketTime: stamp)], now: Self.oldAsOf)
            #expect(result.symbols == symbols)
            #expect(result.ideas == ideas)
            #expect(result.acceptedKeys.isEmpty)
            #expect(result.newestMarketTime == nil)
        }
    }

    @Test func undatedQuoteSeedsUnknownRowWithoutInventingFreshness() {
        let symbol = StockSageSymbol(symbol: "AAPL", market: "NASDAQ")
        let idea = StockSageIdea(symbol: "AAPL", market: "NASDAQ", price: 150, advice: advice(), spark: [150])
        let result = StockSageStore.mergedPolledQuotes(
            symbols: [symbol], ideas: [idea], symbolIndex: ["AAPL": 0],
            quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: nil)], now: Self.oldAsOf)
        #expect(result.symbols[0].latest?.price == 155)
        #expect(result.symbols[0].latest?.marketTime == nil)
        #expect(result.ideas[0].price == 155)
        #expect(result.ideas[0].priceAsOf == nil)
        #expect(StockSageQuoteFreshness.isStale(symbol: "AAPL", marketTime: result.ideas[0].priceAsOf, asOf: Self.oldAsOf))
    }

    @Test func offBoardIdeaReceivesQuoteWithoutInventingBoardRow() {
        let ideas = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(1)
        let result = StockSageStore.mergedPolledQuotes(
            symbols: [], ideas: ideas, symbolIndex: [:],
            quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: at)], now: at)
        #expect(result.symbols.isEmpty)
        #expect(result.ideas[0].price == 155)
        #expect(result.ideas[0].priceAsOf == at)
        #expect(result.ideas[1] == ideas[1])
        #expect(result.acceptedKeys == ["AAPL"])
    }

    @Test func scanKeepsNewAdviceButDoesNotRewindLatestPrice() {
        let fresh = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(10)
        let live = StockSageSymbol(symbol: "AAPL", market: "NASDAQ", quotes: [
            StockSageQuote(price: 155, previousPrice: 150, marketTime: at),
        ])
        let offBoard = fresh[1].withLivePrice(310, asOf: at)
        let result = StockSageStore.ideasWithLatestPrices(fresh, symbols: [live], previous: [offBoard], now: at)
        #expect(result[0].price == 155)
        #expect(result[1].price == 310)
        #expect(result[0].priceAsOf == at)
        #expect(result[0].advice == fresh[0].advice)
        #expect(result[0].generatedAt == fresh[0].generatedAt)
        #expect(result[2] == fresh[2])
    }

    @Test func invalidValuesAndBogusIndexAreRejectedAndFutureCacheCanRecover() {
        let symbols = fixtureSymbols(), ideas = fixtureIdeas()
        let at = Self.oldAsOf.addingTimeInterval(1)
        for q in [quote(price: .infinity, previousClose: 150, marketTime: at),
                  quote(price: 155, previousClose: .nan, marketTime: at),
                  quote(price: 155, previousClose: 150, marketTime: at.addingTimeInterval(61))] {
            let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas, symbolIndex: fixtureIndex(symbols),
                                                           quotes: ["AAPL": q], now: at)
            #expect(result.symbols == symbols)
            #expect(result.ideas == ideas)
            #expect(result.acceptedKeys.isEmpty)
        }
        let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: [], symbolIndex: ["AAPL": 999],
                                                       quotes: ["AAPL": quote(price: 155, previousClose: 150, marketTime: at)], now: at)
        #expect(result.symbols == symbols)
        #expect(result.acceptedKeys.isEmpty)
        #expect(StockSageStore.acceptsQuote(at, after: at.addingTimeInterval(100_000), now: at))
    }

    @Test func sequenceSurvivesParserStateMergeAndScanWithoutMovingAdvice() throws {
        let now = Self.oldAsOf.addingTimeInterval(1)
        let events = StockSageLiveStream.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"T","sym":"AAPL","p":151,"t":1700000001000,"q":9007199254740992},{"ev":"T","sym":"AAPL","p":152,"t":1700000001000,"q":9007199254740993},{"ev":"T","sym":"AAPL","p":149,"t":1700000001000,"q":9007199254740992}]"#)
        var state = StockSageLiveStream.StreamState()
        var symbols = fixtureSymbols(), ideas = fixtureIdeas()
        let originals = ideas
        for event in events {
            guard let tick = state.consume(event, requested: ["AAPL"], now: now) else { continue }
            let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas,
                symbolIndex: fixtureIndex(symbols), quotes: [tick.symbol: .init(symbol: tick.symbol,
                    price: tick.price, previousClose: 150, marketTime: tick.timestamp,
                    massiveTradeSequence: tick.sequence)], now: now)
            symbols = result.symbols; ideas = result.ideas
        }
        #expect(symbols[0].latest?.price == 152)
        #expect(ideas[0].price == 152)
        #expect(ideas[0].massiveTradeSequence == 9_007_199_254_740_993)
        #expect(symbols[0].latest?.massiveTradeSequence == ideas[0].massiveTradeSequence)
        #expect(ideas[0].advice == originals[0].advice)
        let scan = StockSageStore.ideasWithLatestPrices(originals, symbols: symbols, previous: ideas, now: now)
        #expect(scan == ideas)

        // A newer off-board idea at the SAME time wins over the board in scan publication.
        let newer = ideas[0].withLivePrice(153, asOf: now, massiveTradeSequence: 9_007_199_254_740_994)
        let rescan = StockSageStore.ideasWithLatestPrices(ideas, symbols: symbols, previous: [newer], now: now)
        #expect(rescan[0] == newer)
        #expect(newer.withLivePrice(154, asOf: now.addingTimeInterval(1)).massiveTradeSequence == nil)
    }

    @Test func pollsCannotBorrowTradeSequenceOrUseTheWrongSymbol() {
        let now = Self.oldAsOf.addingTimeInterval(1)
        let symbols = [StockSageSymbol(symbol: "AAPL", market: "NASDAQ", quotes: [
            StockSageQuote(price: 151, previousPrice: 150, marketTime: now, massiveTradeSequence: 10)])]
        let ideas = [fixtureIdeas()[0].withLivePrice(151, asOf: now, massiveTradeSequence: 10)]
        for q in [quote(price: 90, previousClose: 150, marketTime: now),
                  quote(symbol: "MSFT", price: 90, previousClose: 150, marketTime: now.addingTimeInterval(1)),
                  StockSageQuoteService.LiveQuote(symbol: "AAPL", price: 90, previousClose: 150,
                      marketTime: now, massiveTradeSequence: 9)] {
            let result = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas,
                symbolIndex: ["AAPL": 0], quotes: ["AAPL": q], now: now)
            #expect(result.symbols == symbols)
            #expect(result.ideas == ideas)
            #expect(result.acceptedKeys.isEmpty)
        }
        let newerPoll = StockSageStore.mergedPolledQuotes(symbols: symbols, ideas: ideas,
            symbolIndex: ["AAPL": 0], quotes: ["AAPL": quote(price: 155, previousClose: 150,
                marketTime: now.addingTimeInterval(1))], now: now)
        #expect(newerPoll.ideas[0].price == 155)
        #expect(newerPoll.ideas[0].massiveTradeSequence == nil)
        #expect(newerPoll.symbols[0].latest?.massiveTradeSequence == nil)
    }
}
