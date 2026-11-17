import Foundation
import Synchronization
import Testing
@testable import StockSage

#if os(iOS)
@Suite(.serialized)
@MainActor
struct StockSagePhoneOfflineCoreTests {
    @Test func formerAllowExternalOverrideCannotEnableThePhoneFeed() {
        ToolPolicyTestLock.lock.lock()
        defer { ToolPolicyTestLock.lock.unlock() }
        let previous = ToolPolicy.override
        defer { ToolPolicy.override = previous }
        ToolPolicy.override = .allowExternalTools
        #expect(!ToolPolicy.isExternalAllowed)
        #expect(ToolPolicy.webToolsDisabledReason()?.contains("local records") == true)
    }

    @Test func phoneTransportRejectsBeforeEvenAnInjectedURLProtocolStarts() async throws {
        PhoneNoTrafficProtocol.starts.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneNoTrafficProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://offline-fixture.invalid/quote")!)
        do {
            _ = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 10)
            Issue.record("Phone provider transport must remain unavailable")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
        #expect(PhoneNoTrafficProtocol.starts.withLock { $0 } == 0)
    }

    @Test func unknownPhoneTickerCanBeSavedWithoutAnyQuoteRequest() async throws {
        let suite = "stocksage.phone-local-watchlist." + UUID().uuidString
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        var calls = 0
        let error = await store.addSymbol("CSPX.L", fetchQuotes: { _ in calls += 1; return [:] })
        #expect(error == nil && calls == 0 && store.userSymbols == ["CSPX.L"])
        #expect(store.manualPriceBook.records.isEmpty)
        #expect(store.latestPrice("CSPX.L") == nil)
        #expect(store.recordedFactSymbols.first?.quotes.isEmpty == true)
    }

    @Test func recordedPriceDoesNotMutateFeedSymbolsOrFeedClocks() async throws {
        let suite = "stocksage.phone-record-separation." + UUID().uuidString
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(await store.addSymbol("CSPX.L") == nil)
        let rows = store.symbols, clock = store.quoteAsOf
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unit = try #require(StockSagePriceDenomination.manualDeclaration(currencyInput: "USD", hundredths: false))
        let recorded = StockSageManualPriceRecord(symbol: "CSPX.L", rawPrice: 600,
            denomination: unit, observedAt: now.addingTimeInterval(-60), recordedAt: now)
        #expect(store.manualPriceBook.add(recorded))
        #expect(store.symbols == rows && store.quoteAsOf == clock && store.latestPrice("CSPX.L") == nil)
        #expect(store.manualPriceBook.latest(for: "CSPX.L", now: now)?.quote.priceSource == .manualEntry)
    }
}

private nonisolated final class PhoneNoTrafficProtocol: URLProtocol, @unchecked Sendable {
    static let starts = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
    override func stopLoading() {}
}
#endif
