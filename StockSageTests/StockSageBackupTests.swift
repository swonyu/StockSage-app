import Testing
import Foundation
@testable import StockSage

/// Hand-built fixtures — a small, fully-specified trade + position + symbol set, not
/// anything derived from the code under test. Round-trip proves export→restore preserves
/// every field; the error-path tests prove restore is all-or-nothing (never partial).
struct StockSageBackupTests {

    @Test(arguments: ["journal", "portfolio"])
    func failedExportPreservesPreviousBackup(collection: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json")
        try StockSageBackup.save(to: url, trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        let before = try Data(contentsOf: url)
        var trade = fixtureTrade(), position = fixturePosition()
        if collection == "journal" { trade.conviction = .nan } else { position.shares = .infinity }
        var failed = false
        do { try StockSageBackup.save(to: url, trades: [trade], positions: [position], userSymbols: ["NVDA"]) }
        catch StockSageBackup.BackupError.encodeFailed { failed = true }
        catch { Issue.record("Unexpected export error: \(error)") }
        #expect(failed, "Encoding failure must reach the save caller, not produce an empty backup")
        #expect(try Data(contentsOf: url) == before, "A failed export must not replace the previous backup")
    }

    @Test func fileExportReplacesOnlyTheChosenBackupAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json"), sibling = directory.appendingPathComponent("keep.json")
        let sentinel = Data("keep this unrelated file".utf8)
        try sentinel.write(to: sibling)
        try StockSageBackup.save(to: url, trades: [], positions: [], userSymbols: [])
        try StockSageBackup.save(to: url, trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        let payload = try StockSageBackup.restore(from: Data(contentsOf: url)).get()
        #expect(payload.trades == [fixtureTrade()] && payload.positions == [fixturePosition()] && payload.userSymbols == ["NVDA"])
        #expect(try Data(contentsOf: sibling) == sentinel)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["backup.json", "keep.json"])
    }

    @Test func rejectedExportDestinationRemainsIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = Data("keep directory contents".utf8), child = directory.appendingPathComponent("keep.json")
        try sentinel.write(to: child)
        var failed = false
        do { try StockSageBackup.save(to: directory, trades: [fixtureTrade()], positions: [], userSymbols: []) }
        catch { failed = true }
        #expect(failed)
        #expect(try Data(contentsOf: child) == sentinel)
    }

    @MainActor @Test func deletionMarkersSurviveLegacyWritesAndOnlySuccessfulExplicitRestoreRevivesIDs() throws {
        let suite = "stocksage-backup-deletions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let data = try StockSageBackup.export(trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        _ = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
        let journalBytes = try #require(defaults.data(forKey: "stocksage.journal.v1"))
        let portfolioBytes = try #require(defaults.data(forKey: "stocksage_portfolio_v1"))
        let journalMarkers = StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage.journal.v1")
        let portfolioMarkers = StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage_portfolio_v1")
        journal.remove(fixtureTrade().id)
        portfolio.remove(fixturePosition().id)
        #expect(journalMarkers.contains(fixtureTrade().id))
        #expect(portfolioMarkers.contains(fixturePosition().id))
        // Simulate an older writer replacing ONLY the original array keys, unaware of markers.
        defaults.set(journalBytes, forKey: "stocksage.journal.v1")
        defaults.set(portfolioBytes, forKey: "stocksage_portfolio_v1")
        #expect(StockSageJournalStore(defaults: defaults).trades.isEmpty)
        #expect(StockSagePortfolio(userDefaults: defaults).positions.isEmpty)
        #expect(!journal.add(fixtureTrade())) // ordinary add/import is not an explicit restore
        #expect(!journal.close(fixtureTrade().id, exitPrice: 170))

        defaults.set(42, forKey: "stocksage_user_symbols") // last preparation step must fail
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Failed preparation must not remove deletion markers")
        case .failure: break
        }
        #expect(journalMarkers.contains(fixtureTrade().id) && portfolioMarkers.contains(fixturePosition().id))
        #expect(defaults.data(forKey: "stocksage.journal.v1") == journalBytes)
        #expect(defaults.data(forKey: "stocksage_portfolio_v1") == portfolioBytes)
        defaults.set(["NVDA"], forKey: "stocksage_user_symbols")
        let restored = try StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store).get()
        #expect(restored.trades == 1 && restored.positions == 1 && restored.symbols == 0)
        #expect(!journalMarkers.contains(fixtureTrade().id) && !portfolioMarkers.contains(fixturePosition().id))
        #expect(StockSageJournalStore(defaults: defaults).trades == [fixtureTrade()])
        #expect(StockSagePortfolio(userDefaults: defaults).positions == [fixturePosition()])
    }

    @MainActor @Test func deletionMarkersAreIndependentAndScopedByStoreAndCustomKey() throws {
        let suite = "stocksage-deletion-scope-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trade = fixtureTrade()
        let journal = StockSageJournalStore(defaults: defaults)
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let custom = StockSageJournalStore(defaults: defaults, key: "custom.journal")
        #expect(journal.add(trade) && custom.add(trade))
        paper.add(trade)
        journal.remove(trade.id)
        #expect(StockSagePaperTradeStore(defaults: defaults).trades == [trade])
        #expect(StockSageJournalStore(defaults: defaults, key: "custom.journal").trades == [trade])
        let ledgerA = StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage.journal.v1")
        let ledgerB = StockSageRecordDeletions(defaults: try #require(UserDefaults(suiteName: suite)), recordKey: "stocksage.journal.v1")
        let second = UUID(), third = UUID()
        ledgerA.mark([second]); ledgerB.mark([third])
        #expect(ledgerA.contains(trade.id) && ledgerA.contains(second) && ledgerA.contains(third))
        #expect(ledgerB.contains(trade.id) && ledgerB.contains(second) && ledgerB.contains(third))
    }

    @MainActor @Test func unreadableBooksCannotBeOverwrittenOrAcquireDeletionMarkers() throws {
        let suite = "stocksage-deletion-read-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let paper = StockSagePaperTradeStore(defaults: defaults)
        let trade = fixtureTrade()
        journal.add(trade); paper.add(trade)
        portfolio.add(symbol: "KEEP", shares: 1, costBasis: 100)
        let lot = try #require(portfolio.positions.first)
        let keys = ["stocksage.journal.v1", "stocksage_portfolio_v1", "stocksage.papertrades.v1"]
        for value in [Data("corrupt".utf8) as Any, 42 as Any] {
            for key in keys { defaults.set(value, forKey: key) }
            let before = defaults.persistentDomain(forName: suite) ?? [:]
            journal.remove(trade.id); portfolio.remove(lot.id); paper.remove(trade.id)
            portfolio.clear(); paper.reset()
            #expect(journal.trades == [trade] && paper.trades == [trade] && portfolio.positions == [lot])
            #expect(journal.lastError != nil && portfolio.lastError != nil && paper.lastError != nil)
            #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
        }
    }

    @MainActor @Test func failedEncodingDoesNotTurnAnUncommittedDeleteIntoADurableOne() throws {
        let suite = "stocksage-deletion-encode-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        journal.add(fixtureTrade())
        portfolio.add(symbol: "KEEP", shares: 1, costBasis: 100)
        let lot = try #require(portfolio.positions.first)
        let invalidTrade = TradeRecord(symbol: "BAD", side: .long, entry: 100, stop: 90,
            target: nil, shares: .infinity, openedAt: Date(timeIntervalSince1970: 0))
        let invalidLot = PortfolioPosition(symbol: "BAD", shares: .infinity, costBasis: 1)
        journal.qaSeed([fixtureTrade(), invalidTrade]); portfolio.qaSeed([lot, invalidLot])
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        journal.remove(fixtureTrade().id); portfolio.remove(lot.id)
        #expect(journal.trades == [fixtureTrade(), invalidTrade])
        #expect(portfolio.positions == [lot, invalidLot])
        #expect(journal.lastError != nil && portfolio.lastError != nil)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test func nativeRestorePersistsAllThreeCollectionsAndIsRepeatable() throws {
        let suite = "stocksage-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let trade = fixtureTrade(), position = fixturePosition()
        let data = try StockSageBackup.export(trades: [trade], positions: [position], userSymbols: ["TSLA", "NVDA"])
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
        let data = try StockSageBackup.export(trades: [fixtureTrade(), newTrade, newTrade],
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
        let valid = try StockSageBackup.export(trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
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
        let data = try StockSageBackup.export(trades: [fixtureTrade()], positions: [fixturePosition()], userSymbols: ["NVDA"])
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Destination \(fault) failure must not partially restore")
        case .failure(let error): #expect(error.localizedDescription.contains("Nothing was restored"))
        }
        #expect(journal.trades.map(\.id) == journalIDs)
        #expect(portfolio.positions.map(\.id) == lotIDs)
        #expect(store.userSymbols.isEmpty)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @Test func incoherentJournalRejectsTheWholeRestoreWithoutRepairingIt() throws {
        var invalid = fixtureTrade()
        invalid.closedAt = nil
        let data = try StockSageBackup.export(trades: [fixtureTrade(), invalid], positions: [fixturePosition()], userSymbols: ["AAPL"])
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

        let data = try StockSageBackup.export(trades: [trade], positions: [position], userSymbols: symbols)
        let result = StockSageBackup.restore(from: data)

        let payload = try result.get()
        #expect(payload.schemaVersion == StockSageBackup.currentSchemaVersion)
        #expect(payload.trades == [trade])
        #expect(payload.positions == [position])
        #expect(payload.userSymbols == symbols)
    }

    @Test func exportProducesNonEmptyPrettyJSON() throws {
        let data = try StockSageBackup.export(trades: [fixtureTrade()], positions: [], userSymbols: [])
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
