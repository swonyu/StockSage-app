import Foundation
import Testing
@testable import StockSage

@MainActor struct StockSageFirstQuoteTests {
    @Test func onlyUnpricedPersonalSymbolsFetchAndDuplicateLotsDoNotRefetch() async throws {
        let name = "stocksage-first-quote-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var held = ["vra", "VRA", "KNOWN"]
        let store = StockSageStore(defaults: defaults, heldSymbols: { held })
        let now = Date().addingTimeInterval(-5)
        store.applyPolledQuotes(["KNOWN": .init(symbol: "KNOWN", price: 12, previousClose: 11,
            marketTime: now, priceSource: .massiveSIP)])
        var requests = [[String]]()
        await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { symbols in
            requests.append(symbols)
            return .init(quotes: ["VRA": .init(symbol: "VRA", price: 4.1, previousClose: 4,
                marketTime: now, priceSource: .massiveSIP)])
        })
        #expect(requests == [["VRA"]])
        #expect(store.latestQuote("VRA")?.marketTime == now && store.latestPrice("VRA") == 4.1)
        held.append("VRA")
        await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { _ in
            Issue.record("A duplicate lot must not refetch an already usable price")
            return .init(quotes: [:])
        })
        #expect(store.lastFullRefreshAt == nil)
    }

    @Test(arguments: ["removed", "invalidated", "future", "sample", "newer-stream", "throttled"])
    func firstQuoteUsesTheExistingPublicationGuards(mode: String) async throws {
        let name = "stocksage-first-quote-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var held = ["VRA"], allowed = true, calls = 0
        let store = StockSageStore(defaults: defaults, heldSymbols: { held })
        let at = Date().addingTimeInterval(-10)
        await store.refreshMissingTrackedQuotes(allowed: { allowed }, fetch: { _ in
            calls += 1
            if mode == "removed" { held = [] }
            if mode == "invalidated" { allowed = false }
            if mode == "newer-stream" {
                store.applyPolledQuotes(["VRA": .init(symbol: "VRA", price: 5, previousClose: 4,
                    marketTime: at.addingTimeInterval(1), priceSource: .massiveSIP)])
            }
            return .init(quotes: ["VRA": .init(symbol: "VRA", price: 4.1, previousClose: 4,
                marketTime: mode == "future" ? at.addingTimeInterval(3600) : at,
                priceSource: mode == "sample" ? .sample : .massiveSIP)],
                stop: mode == "throttled" ? .yahooThrottled : .finished)
        })
        #expect(calls == 1)
        switch mode {
        case "newer-stream": #expect(store.latestPrice("VRA") == 5)
        case "throttled": #expect(store.latestPrice("VRA") == 4.1)
        default: #expect(store.latestPrice("VRA") == nil)
        }
        #expect(store.lastFullRefreshAt == nil)
    }

    @Test func overlappingLifecycleCallsShareOneInFlightRequest() async throws {
        let name = "stocksage-first-quote-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { ["VRA"] })
        var calls = 0
        await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { _ in
            calls += 1
            await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { _ in
                calls += 1
                return .init(quotes: [:])
            })
            return .init(quotes: [:])
        })
        #expect(calls == 1)
        await store.refreshMissingTrackedQuotes(allowed: { false }, fetch: { _ in
            Issue.record("Denied policy must not dispatch")
            return .init(quotes: [:])
        })
    }

    @Test func cancelledLifecycleDoesNotBlockItsReplacement() async throws {
        let name = "stocksage-first-quote-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { ["VRA"] })
        var pending: CheckedContinuation<StockSageQuoteService.QuoteBatch, Never>?
        let old = Task { await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { _ in
            await withCheckedContinuation { pending = $0 }
        }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        guard pending != nil else { old.cancel(); Issue.record("First request never started"); return }
        old.cancel()
        var calls = 0
        await store.refreshMissingTrackedQuotes(allowed: { true }, fetch: { _ in
            calls += 1
            return .init(quotes: ["VRA": .init(symbol: "VRA", price: 5, previousClose: 4,
                marketTime: Date().addingTimeInterval(-5), priceSource: .massiveSIP)])
        })
        pending?.resume(returning: .init(quotes: [:]))
        await old.value
        #expect(calls == 1 && store.latestPrice("VRA") == 5)
    }
}
