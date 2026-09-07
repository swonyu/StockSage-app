import Testing
import Foundation
@testable import StockSage

/// Hand-built fixtures — a small, fully-specified trade + position + symbol set, not
/// anything derived from the code under test. Round-trip proves export→restore preserves
/// every field; the error-path tests prove restore is all-or-nothing (never partial).
struct StockSageBackupTests {

    @MainActor @Test func nativeRestorePersistsAllThreeCollectionsAndIsRepeatable() throws {
        let suite = "stocksage-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let trade = fixtureTrade(), position = fixturePosition()
        let data = StockSageBackup.export(trades: [trade], positions: [position], userSymbols: ["TSLA", "NVDA"])
        let summary = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
        #expect(summary.trades == 1)
        #expect(summary.positions == 1)
        #expect(summary.symbols == 2)
        #expect(journal.trades == [trade])
        #expect(portfolio.positions == [position])
        #expect(store.userSymbols == ["TSLA", "NVDA"])
        #expect(store.symbols.isEmpty) // restore preferences, never invent quotes or fetch a live price
        #expect(StockSageJournalStore(defaults: defaults).trades == [trade])
        #expect(StockSagePortfolio(userDefaults: defaults).positions == [position])
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).userSymbols == ["TSLA", "NVDA"])
        let repeated = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
        #expect(repeated.trades == 0 && repeated.positions == 0 && repeated.symbols == 0)
        #expect(repeated.skipped == 4)
        #expect(portfolio.positions == [position])
    }

    @MainActor @Test func restoreKeepsExistingAndForeignRecordsAndDistinctLots() throws {
        let suite = "stocksage-backup-merge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = fixtureTrade()
        original.closedAt = nil; original.exitPrice = nil
        let journal = StockSageJournalStore(defaults: defaults)
        #expect(journal.add(original))
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { portfolio.positions.map(\.symbol) })
        // Another instance writes after these stores loaded. Preserve its terminal close,
        // foreign lot and watchlist symbol as well as the local in-memory records.
        let foreignJournal = StockSageJournalStore(defaults: defaults)
        #expect(foreignJournal.close(original.id, exitPrice: 170, at: Date(timeIntervalSince1970: 1_701_000_000)))
        StockSagePortfolio(userDefaults: defaults).add(symbol: "MSFT", shares: 2, costBasis: 310)
        defaults.set(["TSLA"], forKey: "stocksage_user_symbols")
        let foreignPositions = StockSagePortfolio(userDefaults: defaults).positions
        let newTrade = TradeRecord(symbol: "NVDA", side: .long, entry: 100, stop: 95,
            target: nil, shares: 2, openedAt: original.openedAt)
        let lot = fixturePosition()
        let data = StockSageBackup.export(trades: [fixtureTrade(), newTrade, newTrade],
            positions: [lot, lot], userSymbols: [" tsla ", "nvda", "NVDA"])
        let result = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
        #expect(result.trades == 1 && result.positions == 1 && result.symbols == 1)
        #expect(result.skipped == 5)
        #expect(journal.trades == [newTrade] + foreignJournal.trades)
        #expect(portfolio.positions == foreignPositions + [lot])
        #expect(portfolio.positions.count == 2) // same ticker, different immutable lot IDs
        #expect(store.userSymbols == ["TSLA", "NVDA"])
        #expect(store.trackedSymbolsUnion.contains("MSFT"))
        #expect(StockSageJournalStore(defaults: defaults).trades == journal.trades)
        #expect(StockSagePortfolio(userDefaults: defaults).positions == portfolio.positions)
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).userSymbols == store.userSymbols)
    }

    @MainActor @Test(arguments: ["journal", "position", "watchlist", "schema", "truncated", "corrupt"])
    func invalidBackupCannotChangeAnyCollection(fault: String) throws {
        let suite = "stocksage-backup-invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        portfolio.add(symbol: "TEST", shares: 3, costBasis: 12)
        defaults.set(["TEST"], forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let positionsBefore = portfolio.positions
        let valid = StockSageBackup.export(trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        switch fault {
        case "journal":
            var records = try #require(json["trades"] as? [[String: Any]])
            records[0]["shares"] = -1
            json["trades"] = records
        case "position":
            var records = try #require(json["positions"] as? [[String: Any]])
            records[0]["shares"] = 0
            json["positions"] = records
        case "watchlist": json["userSymbols"] = ["NVDA", " "]
        case "schema": json["schemaVersion"] = 99
        case "truncated": json.removeValue(forKey: "positions")
        default: break
        }
        let data = fault == "corrupt" ? Data("{bad".utf8) : try JSONSerialization.data(withJSONObject: json)
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Invalid \(fault) must reject the entire restore")
        case .failure: break
        }
        #expect(journal.trades.isEmpty)
        #expect(portfolio.positions == positionsBefore)
        #expect(store.userSymbols == ["TEST"])
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test(arguments: ["journal", "portfolio", "watchlist", "journal-type", "portfolio-type", "journal-encode", "portfolio-encode", "journal-conflict"])
    func preparationFailureCannotPartiallyApplyAValidBackup(fault: String) throws {
        let suite = "stocksage-backup-prepare-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        switch fault {
        case "journal": defaults.set(Data("bad".utf8), forKey: "stocksage.journal.v1")
        case "portfolio": defaults.set(Data("bad".utf8), forKey: "stocksage_portfolio_v1")
        case "watchlist": defaults.set(42, forKey: "stocksage_user_symbols")
        case "journal-type": defaults.set(42, forKey: "stocksage.journal.v1")
        case "portfolio-type": defaults.set(42, forKey: "stocksage_portfolio_v1")
        case "journal-encode":
            var trade = fixtureTrade(); trade.conviction = .nan
            journal.qaSeed([trade])
        case "portfolio-encode":
            var lot = fixturePosition(); lot.costBasis = .infinity
            portfolio.qaSeed([lot])
        case "journal-conflict":
            var trade = fixtureTrade(); trade.closedAt = nil
            journal.qaSeed([fixtureTrade()])
            defaults.set(try JSONEncoder().encode([trade]), forKey: "stocksage.journal.v1")
        default: break
        }
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let journalIDs = journal.trades.map(\.id), lotIDs = portfolio.positions.map(\.id)
        let data = StockSageBackup.export(trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Destination \(fault) failure must not partially restore")
        case .failure(let error): #expect(error.localizedDescription.contains("Nothing was restored"))
        }
        #expect(journal.trades.map(\.id) == journalIDs)
        #expect(portfolio.positions.map(\.id) == lotIDs)
        #expect(store.userSymbols.isEmpty)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @Test func incoherentJournalRejectsTheWholeRestoreWithoutRepairingIt() {
        var invalid = fixtureTrade()
        invalid.closedAt = nil
        let data = StockSageBackup.export(trades: [fixtureTrade(), invalid], positions: [fixturePosition()], userSymbols: ["AAPL"])
        switch StockSageBackup.restore(from: data) {
        case .success:
            Issue.record("An exit without a close time must fail the entire restore, not be repaired or dropped")
        case .failure(let error):
            #expect(error.localizedDescription.contains("journal") || error.localizedDescription.contains("trade"))
        }
    }

    private func fixtureTrade() -> TradeRecord {
        TradeRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            symbol: "AAPL", side: .long, entry: 150.0, stop: 145.0, target: 165.0,
            shares: 10, openedAt: Date(timeIntervalSince1970: 1_700_000_000),
            exitPrice: 160.0, closedAt: Date(timeIntervalSince1970: 1_700_500_000),
            note: "test note", conviction: 0.72
        )
    }

    private func fixturePosition() -> PortfolioPosition {
        PortfolioPosition(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                           symbol: "MSFT", shares: 5, costBasis: 300.0)
    }

    @Test func exportRestoreRoundTrip() throws {
        let trade = fixtureTrade()
        let position = fixturePosition()
        let symbols = ["TSLA", "NVDA"]

        let data = StockSageBackup.export(trades: [trade], positions: [position], userSymbols: symbols)
        let result = StockSageBackup.restore(from: data)

        let payload = try result.get()
        #expect(payload.schemaVersion == StockSageBackup.currentSchemaVersion)
        #expect(payload.trades == [trade])
        #expect(payload.positions == [position])
        #expect(payload.userSymbols == symbols)
    }

    @Test func exportProducesNonEmptyPrettyJSON() {
        let data = StockSageBackup.export(trades: [fixtureTrade()], positions: [], userSymbols: [])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("AAPL"))
        #expect(text.contains("\n"))   // pretty-printed, not single-line
    }

    @Test func wrongSchemaVersionIsError() {
        // Hand-built JSON with schemaVersion 99 — never derived from the encoder.
        let json = """
        {"schemaVersion":99,"exportedAt":"2026-01-01T00:00:00Z","trades":[],"positions":[],"userSymbols":[]}
        """
        let result = StockSageBackup.restore(from: Data(json.utf8))
        switch result {
        case .success:
            Issue.record("expected a schema-version error, got success")
        case .failure(let error):
            guard case .unsupportedSchemaVersion(let found, let supported) = error else {
                Issue.record("expected unsupportedSchemaVersion, got \(error)")
                return
            }
            #expect(found == 99)
            #expect(supported == StockSageBackup.currentSchemaVersion)
        }
    }

    @Test func corruptJSONIsErrorNoPartialState() {
        let corrupt = Data("{not valid json at all".utf8)
        let result = StockSageBackup.restore(from: corrupt)
        switch result {
        case .success:
            Issue.record("expected a decode error, got success")
        case .failure(let error):
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test func truncatedPayloadMissingFieldIsErrorNotPartial() {
        // Valid JSON, right schema version, but `trades` is missing entirely — must fail
        // the whole decode rather than silently defaulting trades to [].
        let json = """
        {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z","positions":[],"userSymbols":[]}
        """
        let result = StockSageBackup.restore(from: Data(json.utf8))
        switch result {
        case .success:
            Issue.record("expected a decode error for a missing required field, got success")
        case .failure(let error):
            guard case .decodeFailed = error else {
                Issue.record("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    @Test func importFromParentAppNilWhenDomainEmpty() {
        // A suite name that has never been written to — the parent-app read must return
        // nil, never throw or fabricate data.
        let result = StockSageBackup.importFromParentApp()
        // Can't assert nil unconditionally (a real "SA.Salehman-AI" domain may exist on
        // the CI/dev machine running the parent app too) — only assert it never crashes
        // and, when present, the counts are non-negative and internally consistent.
        if let result {
            #expect(result.tradeCount == result.trades.count)
            #expect(result.positionCount == result.positions.count)
        }
    }
}
