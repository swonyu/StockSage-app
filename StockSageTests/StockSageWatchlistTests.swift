import Foundation
import Testing
@testable import StockSage

@Suite("Personal watchlist", .serialized)
@MainActor
struct StockSageWatchlistTests {
    @Test func catalogTickerCanBeSavedAndReloadedWithoutReplacingItsMarketRow() async throws {
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ORCL"], forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let definition = try #require(StockSageUniverse.catalog.first { $0.symbol == "RKLB" })

        await store.addSymbol("  rklb \n")

        #expect(store.addSymbolError == nil)
        #expect(store.userSymbols == ["ORCL", "RKLB"])
        #expect(store.symbols.first { $0.symbol == "RKLB" }?.market == definition.market)
        #expect(store.symbols.first { $0.symbol == "RKLB" }?.quotes.isEmpty == true,
                "Saving a catalog ticker must not invent a quote")
        let restored = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(restored.userSymbols == ["ORCL", "RKLB"])
        #expect(restored.watchlistSymbols.map(\.symbol) == ["ORCL", "RKLB"],
                "Saved tickers must remain visible even without cached quotes")
        let before = store.symbols
        await store.addSymbol("RKLB")
        #expect(store.userSymbols == ["ORCL", "RKLB"])
        #expect(store.symbols == before)
        #expect(store.addSymbolError == "RKLB is already in your watchlist.")
    }

    @Test func readdingAnExistingBoardRowKeepsQuotesAndIdentity() async throws {
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        await store.addSymbol("RKLB")
        store.applyPolledQuotes(["RKLB": .init(symbol: "RKLB", price: 61, previousClose: 60,
            marketTime: Date(), priceSource: .massiveSIP)])
        let original = try #require(store.symbols.first)
        #expect(original.latest?.price == 61)
        store.removeSymbol("RKLB")
        #expect(!store.isWatchlisted("rklb") && store.watchlistSymbols.isEmpty)
        #expect(store.symbols == [original], "Removing a favorite must retain its catalog market data")
        var quoteCalls = 0
        let error = await store.addSymbol("rklb", fetchQuotes: { _ in quoteCalls += 1; return [:] })
        #expect(error == nil && quoteCalls == 0)
        #expect(store.isWatchlisted("rklb") && store.symbols == [original])
    }

    @Test func corruptSavedWatchlistIsNeverOverwritten() async throws {
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(42, forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(await store.addSymbol("RKLB") != nil)
        #expect(defaults.integer(forKey: "stocksage_user_symbols") == 42)
        #expect(store.userSymbols.isEmpty && store.symbols.isEmpty)
    }

    @Test(arguments: ["add rklb to watchlist", "Please add $RKLB to my watchlist.",
                      "can you add RKLB to the watch list please?", "ADD RKLB TO WATCHLIST"])
    func explicitCommandsRecognizeTheRequestedTicker(command: String) {
        #expect(StockSageChat.watchlistSymbol(in: command) == "RKLB")
    }

    @Test(arguments: ["Should I add RKLB to watchlist?", "Don't add RKLB to watchlist",
        "\"add RKLB to watchlist\"", "add RKLB and ORCL to watchlist", "add RKLB to watchlist and buy it",
        "The article says add RKLB to watchlist", "add it to watchlist", "Add It to my watchlist",
        "ADD IT TO WATCHLIST", "add THIS to watchlist", "remove RKLB from watchlist"])
    func otherTextNeverBecomesAnAction(command: String) {
        #expect(StockSageChat.watchlistSymbol(in: command) == nil)
    }

    @Test func chatActionPersistsAnAppReceiptAndDuplicateIsHonest() async throws {
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ORCL"], forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let chat = StockSageChatSession(historyURL: url)
        for attempt in 0..<2 {
            #expect(chat.beginWatchlistAddition(question: "add rklb to watchlist", store: store) != nil)
            try await waitUntil { chat.pending == nil }
            let turn = try #require(chat.turns.last)
            #expect(turn.model == "StockSage" && turn.isWatchlistAction == true)
            #expect(turn.snapshot.facts.isEmpty && turn.evidence.isEmpty && turn.snapshot.sources == nil)
            #expect(turn.answer == (attempt == 0 ? "Added RKLB to your watchlist." : "RKLB is already in your watchlist."))
            #expect(turn.notice == (attempt == 0 ? "Local watchlist action completed." : "Watchlist unchanged."))
            #expect(store.userSymbols == ["ORCL", "RKLB"])
            #expect(chat.followUpSymbols(watchlist: store.userSymbols) == ["RKLB"],
                    "The next research question should keep the most recently named ticker")
            let restored = StockSageChatSession(historyURL: url)
            #expect(restored.turns.last?.answer == turn.answer && restored.turns.last?.isWatchlistAction == true)
        }
    }

    @Test func cancellingChatBeforeItsTaskRunsDoesNotAdd() async throws {
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let chat = StockSageChatSession(historyURL: nil)
        let id = try #require(chat.beginWatchlistAddition(question: "add RKLB to watchlist", store: store))
        chat.cancel(id: id)
        await Task.yield()
        #expect(store.userSymbols.isEmpty && store.symbols.isEmpty)
        #expect(chat.turns.last?.answer == "Watchlist addition cancelled.")
        #expect(chat.turns.last?.notice == "Watchlist unchanged.")
    }

    @Test(arguments: [false, true])
    func pendingQuoteHandlesBusyCancellationAndConcurrentImport(cancel: Bool) async throws {
        let restore = allowFixtureQuotes()
        defer { restore() }
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        var resume: CheckedContinuation<[String: StockSageQuoteService.LiveQuote], Never>?
        let work = Task { await store.addSymbol("ZZFIX", fetchQuotes: { _ in
            await withCheckedContinuation { resume = $0 }
        }) }
        try await waitUntil { resume != nil || work.isCancelled || !store.isAddingSymbol && store.addSymbolError != nil }
        let continuation = try #require(resume, "Fixture must reach the injected quote fetch")
        let busy = await store.addSymbol("RKLB")
        #expect(busy?.contains("Another ticker") == true)
        if cancel { work.cancel() }
        else { try store.prepareBackupImport(["ZZFIX", "ORCL"]).apply() }
        continuation.resume(returning: ["ZZFIX": .init(symbol: "ZZFIX", price: 10, previousClose: 9,
            marketTime: Date(), priceSource: .massiveSIP)])
        let error = await work.value
        #expect(error == (cancel ? "Watchlist addition cancelled." : "ZZFIX is already in your watchlist."))
        #expect(store.userSymbols == (cancel ? [] : ["ZZFIX", "ORCL"]))
        #expect(!store.isAddingSymbol && store.symbols.isEmpty)
    }

    @Test func failedQuoteNeverSavesAnUnknownTicker() async throws {
        let restore = allowFixtureQuotes()
        defer { restore() }
        let name = "stocksage-watchlist-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let error = await store.addSymbol("ZZFIX", fetchQuotes: { _ in [:] })
        #expect(error?.contains("Couldn't find a tradeable price") == true)
        #expect(store.userSymbols.isEmpty && store.symbols.isEmpty && !store.isAddingSymbol)
    }

    /// The transport is injected; only this process's volatile policy permits reaching it.
    /// Preserve the owner's persisted Offline Mode, including when a test host is interrupted.
    private func allowFixtureQuotes() -> () -> Void {
        ToolPolicyTestLock.lock.lock()
        let prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let priorOverride = ToolPolicy.override
        ToolPolicyTestLock.set(false, forKey: AppSettings.Keys.offlineOnly)
        ToolPolicyTestLock.set(true, forKey: AppSettings.Keys.webAccess)
        ToolPolicy.override = .allowExternalTools
        return {
            ToolPolicy.override = priorOverride
            UserDefaults.standard.setVolatileDomain(prior, forName: UserDefaults.argumentDomain)
            ToolPolicyTestLock.lock.unlock()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
