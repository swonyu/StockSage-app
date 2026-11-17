import Foundation
import CryptoKit
import Testing
@testable import StockSage

@MainActor
struct StockSageManualRecordPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = "stocksage_manual_prices_v1"
    private var usd: StockSagePriceDenomination {
        StockSagePriceDenomination(currencyCode: "USD", rawUnitsPerMajor: .major, provenance: .manualEntry)!
    }
    private func record(_ symbol: String = "CSPX.L", price: Double = 600,
                        id: UUID = UUID(), offset: TimeInterval = 0) -> StockSageManualPriceRecord {
        StockSageManualPriceRecord(id: id, symbol: symbol, rawPrice: price, denomination: usd,
            observedAt: now.addingTimeInterval(-60), recordedAt: now.addingTimeInterval(offset), note: "Fixture observation")
    }
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "stocksage.manual-core." + UUID().uuidString
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    @Test func manualPriceEditsAppendAndFreshInstancesPreserveBothObservations() throws {
        try withDefaults { defaults, _ in
            let first = StockSageManualPriceBook(defaults: defaults)
            let other = StockSageManualPriceBook(defaults: defaults)
            let original = record(), correction = record(price: 610, offset: 1)
            #expect(first.add(original))
            #expect(other.add(correction))
            let reopened = StockSageManualPriceBook(defaults: defaults)
            #expect(reopened.records == [original, correction] && reopened.hasLoadedRecords)
            #expect(reopened.latest(for: "cspx.l", now: now.addingTimeInterval(2))?.id == correction.id)
            #expect(reopened.records.first?.rawPrice == 600)
        }
    }

    @Test func sameIDIsIdempotentButConflictingEditsPreserveCommittedBytes() throws {
        try withDefaults { defaults, _ in
            let book = StockSageManualPriceBook(defaults: defaults), original = record()
            #expect(book.add(original) && book.add(original) && book.records.count == 1)
            let bytes = try #require(defaults.data(forKey: key))
            #expect(!book.add(record(price: 999, id: original.id)))
            #expect(book.records == [original] && book.lastError != nil)
            #expect(defaults.data(forKey: key) == bytes)
        }
    }

    @Test func corruptOrWrongTypePriceBookBlocksWritesWithoutReplacingOriginalData() throws {
        try withDefaults { defaults, _ in
            for value: Any in [Data("{broken".utf8), "not data"] {
                defaults.set(value, forKey: key)
                let before = defaults.object(forKey: key) as? NSObject
                let book = StockSageManualPriceBook(defaults: defaults)
                #expect(!book.hasLoadedRecords && book.lastError != nil)
                #expect(!book.add(record()) && !book.removeAll())
                #expect(book.records.isEmpty)
                #expect((defaults.object(forKey: key) as? NSObject) == before)
                #expect(throws: (any Error).self) { try book.backupRecords() }
            }
        }
    }

    @Test func invalidOrFutureRecordsCannotBecomeUsablePrices() {
        for price in [Double.nan, .infinity, 0, -1] { #expect(record(price: price).validationError != nil) }
        let future = StockSageManualPriceRecord(symbol: "AAPL", rawPrice: 100, denomination: usd,
            observedAt: now.addingTimeInterval(120), recordedAt: now.addingTimeInterval(120))
        #expect(StockSageManualPriceBook.latest(in: [future], symbol: "AAPL", now: now) == nil)
        let badClock = StockSageManualPriceRecord(symbol: "AAPL", rawPrice: 100, denomination: usd,
            observedAt: now.addingTimeInterval(61), recordedAt: now)
        #expect(badClock.validationError != nil)
        let provider = StockSagePriceDenomination(currencyCode: "USD", rawUnitsPerMajor: .major, provenance: .yahooChartMetadata)!
        #expect(StockSageManualPriceRecord(symbol: "AAPL", rawPrice: 100, denomination: provider,
            observedAt: now, recordedAt: now).validationError != nil)
    }

    @Test func fullBackupRestoresAllFiveCollectionsWithExactIDsAndRepeatCounts() throws {
        try withDefaults { defaults, _ in
            let price = record()
            let trade = TradeRecord(symbol: "CSPX.L", side: .long, entry: 500, stop: 450,
                target: 650, shares: 2, openedAt: now.addingTimeInterval(-100), denomination: usd)
            let position = PortfolioPosition(symbol: "CSPX.L", shares: 2, costBasis: 500, costDenomination: usd)
            let alert = PriceAlert(symbol: "CSPX.L", target: 650, direction: .above)
            let data = try StockSageBackup.export(trades: [trade], positions: [position],
                userSymbols: ["CSPX.L"], priceAlerts: [alert], manualPrices: [price])
            let journal = StockSageJournalStore(defaults: defaults)
            let portfolio = StockSagePortfolio(userDefaults: defaults)
            let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
            let first = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
            #expect(first.trades == 1 && first.positions == 1 && first.symbols == 1 && first.priceAlerts == 1 && first.manualPrices == 1)
            let again = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
            #expect(again.trades == 0 && again.positions == 0 && again.symbols == 0 && again.priceAlerts == 0 && again.manualPrices == 0 && again.skipped == 5)
            #expect(StockSageJournalStore(defaults: defaults).trades == [trade])
            #expect(StockSagePortfolio(userDefaults: defaults).positions == [position])
            let reopened = StockSageStore(defaults: defaults, heldSymbols: { [] })
            #expect(reopened.userSymbols == ["CSPX.L"] && reopened.priceAlerts == [alert])
            #expect(reopened.manualPriceBook.records == [price])
            let exported = try StockSageBackup.restore(from: StockSageBackup.export(journal: journal, portfolio: portfolio, store: reopened)).get()
            #expect(exported.manualPrices == [price] && exported.trades == [trade] && exported.positions == [position])
        }
    }

    @Test func schemaThreeRequiresEveryCollectionButAcceptsExplicitEmptyArrays() throws {
        let bytes = try StockSageBackup.export(trades: [], positions: [], userSymbols: [])
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(try StockSageBackup.restore(from: bytes).get().manualPrices == [])
        for key in ["trades", "positions", "userSymbols", "priceAlerts", "manualPrices"] {
            for missing in [true, false] {
                var json = original
                if missing { json.removeValue(forKey: key) } else { json[key] = NSNull() }
                if case .success = StockSageBackup.restore(from: try JSONSerialization.data(withJSONObject: json)) {
                    Issue.record("Damaged schema3 backup silently omitted collection \(key)")
                }
            }
        }
    }

    @Test func legacySchemasRemainReadableWithoutInventingPriceDenominations() throws {
        for version in [1, 2] {
            let date = version == 1 ? "\"2026-01-01T00:00:00Z\"" : "0"
            let bytes = Data("{\"schemaVersion\":\(version),\"exportedAt\":\(date),\"trades\":[],\"positions\":[],\"userSymbols\":[]}".utf8)
            let result = try StockSageBackup.restore(from: bytes).get()
            #expect(result.manualPrices == nil && result.priceAlerts == nil)
        }
        let bytes = Data(#"{"symbol":"CSPX.L","shares":2,"costBasis":500,"id":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        let legacy = try JSONDecoder().decode(PortfolioPosition.self, from: bytes)
        #expect(legacy.symbol == "CSPX.L" && legacy.costBasis == 500 && legacy.costDenomination == nil)
    }

    @Test func legacyRestoreKeepsExistingPersonalPrices() throws {
        try withDefaults { defaults, _ in
            let journal = StockSageJournalStore(defaults: defaults)
            let portfolio = StockSagePortfolio(userDefaults: defaults)
            let store = StockSageStore(defaults: defaults, heldSymbols: { [] }), price = record()
            #expect(store.manualPriceBook.add(price))
            let data = Data(#"{"schemaVersion":2,"exportedAt":0,"trades":[],"positions":[],"userSymbols":[]}"#.utf8)
            _ = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
            #expect(store.manualPriceBook.records == [price])
            #expect(StockSageManualPriceBook(defaults: defaults).records == [price])
        }
    }

    @Test func invalidPersonalPriceAbortsTheWholeRestoreBeforeAnyCollectionChanges() throws {
        try withDefaults { defaults, suite in
            let journal = StockSageJournalStore(defaults: defaults)
            let portfolio = StockSagePortfolio(userDefaults: defaults)
            let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
            let kept = record()
            #expect(store.manualPriceBook.add(kept))
            #expect(portfolio.add(symbol: "KEPT", shares: 1, costBasis: 10, costDenomination: usd))
            let before = defaults.persistentDomain(forName: suite) ?? [:]
            let lot = PortfolioPosition(symbol: "NEW", shares: 1, costBasis: 20, costDenomination: usd)
            let data = try StockSageBackup.export(trades: [], positions: [lot], userSymbols: ["NEW"], manualPrices: [record(price: 0)])
            if case .success = StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
                Issue.record("Invalid manual price must reject the whole restore")
            }
            #expect(portfolio.positions.map(\.symbol) == ["KEPT"] && store.userSymbols.isEmpty)
            #expect(store.manualPriceBook.records == [kept])
            #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
        }
    }

    @Test func deletedPersonalPriceIsRestoredByOriginalBackupIDOnly() throws {
        try withDefaults { defaults, _ in
            let journal = StockSageJournalStore(defaults: defaults)
            let portfolio = StockSagePortfolio(userDefaults: defaults)
            let store = StockSageStore(defaults: defaults, heldSymbols: { [] }), price = record()
            #expect(store.manualPriceBook.add(price))
            let bytes = try StockSageBackup.export(journal: journal, portfolio: portfolio, store: store)
            #expect(store.manualPriceBook.removeAll() && store.manualPriceBook.records.isEmpty)
            #expect(!store.manualPriceBook.add(price))
            let result = try StockSageBackup.restore(from: bytes, journal: journal, portfolio: portfolio, store: store).get()
            #expect(result.manualPrices == 1 && store.manualPriceBook.records == [price])
        }
    }

    @Test func originalFourCollectionAtomicImageRemainsReadable() throws {
        try withDefaults { defaults, _ in
            try StockSageRecordStorage.update([.init(key: "stocksage_user_symbols", value: .strings(["KEPT"]))], defaults: defaults, activate: true)
            let url = try StockSageRecordStorage.fileURL(defaults: defaults)
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let payload = try #require((envelope["payload"] as? String).flatMap { Data(base64Encoded: $0) })
            var image = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            image.removeValue(forKey: key)
            let oldPayload = try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys])
            envelope["payload"] = oldPayload.base64EncodedString()
            envelope["sha256"] = SHA256.hash(data: oldPayload).map { String(format: "%02x", $0) }.joined()
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url, options: .atomic)
            let before = try Data(contentsOf: url)
            let book = StockSageManualPriceBook(defaults: defaults)
            #expect(book.hasLoadedRecords && book.records.isEmpty && book.lastError == nil)
            #expect(try StockSageRecordStorage.object(forKey: "stocksage_user_symbols", defaults: defaults) as? [String] == ["KEPT"])
            #expect(try Data(contentsOf: url) == before)
        }
    }
}
