import Testing
import Foundation
@testable import StockSage

/// Hand-built fixtures — a small, fully-specified trade + position + symbol set, not
/// anything derived from the code under test. Round-trip proves export→restore preserves
/// every field; the error-path tests prove restore is all-or-nothing (never partial).
struct StockSageBackupTests {

    @MainActor @Test(arguments: ["journal", "portfolio", "watchlist", "journal-type", "portfolio-type",
        "price-alerts", "price-alerts-type", "price-alerts-invalid"], [false, true])
    func fullBackupRejectsUnreadableCommittedSource(fault: String, changedAfterLoad: Bool) throws {
        let suite = "stocksage-backup-source-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([fixtureTrade()]), forKey: "stocksage.journal.v1")
        defaults.set(try JSONEncoder().encode([fixturePosition()]), forKey: "stocksage_portfolio_v1")
        defaults.set(["NVDA"], forKey: "stocksage_user_symbols")
        defaults.set(try JSONEncoder().encode([fixturePriceAlert()]), forKey: "stocksage_price_alerts")
        let key = fault.hasPrefix("journal") ? "stocksage.journal.v1"
            : fault.hasPrefix("portfolio") ? "stocksage_portfolio_v1"
            : fault == "watchlist" ? "stocksage_user_symbols" : "stocksage_price_alerts"
        let corrupt: Any = fault == "price-alerts-invalid"
            ? try JSONEncoder().encode([fixturePriceAlert(target: 0)])
            : fault.hasSuffix("-type") || fault == "watchlist" ? 42 as Any : Data("{bad".utf8) as Any
        if !changedAfterLoad { defaults.set(corrupt, forKey: key) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        if changedAfterLoad { defaults.set(corrupt, forKey: key) }
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let trades = journal.trades, positions = portfolio.positions, symbols = store.userSymbols, alerts = store.priceAlerts
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-backup-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.json")
        let sentinel = Data("previous recovery copy".utf8)
        try sentinel.write(to: url)
        var failed = false
        do { try StockSageBackup.save(to: url, journal: journal, portfolio: portfolio, store: store) }
        catch {
            failed = true
            #expect(error.localizedDescription.contains(fault.components(separatedBy: "-")[0]))
        }
        #expect(failed, "An unreadable committed source is not an empty or stale full backup")
        #expect(try Data(contentsOf: url) == sentinel)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
        #expect(journal.trades == trades && portfolio.positions == positions && store.userSymbols == symbols
            && store.priceAlerts == alerts)
    }

    @MainActor @Test func fullBackupRoundTripsLatestCommittedPriceAlertsAndReportsCount() throws {
        let sourceSuite = "stocksage-backup-alert-source-\(UUID().uuidString)"
        let sourceDefaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let displayed = fixturePriceAlert(target: 100)
        sourceDefaults.set(try JSONEncoder().encode([displayed]), forKey: "stocksage_price_alerts")
        let journal = StockSageJournalStore(defaults: sourceDefaults)
        let portfolio = StockSagePortfolio(userDefaults: sourceDefaults)
        let sourceStore = StockSageStore(defaults: sourceDefaults, heldSymbols: { [] })
        let committed = fixturePriceAlert(symbol: "MSFT", target: 321.5, direction: .above,
            triggeredAt: Date(timeIntervalSince1970: 1_701_000_000))
        sourceDefaults.set(try JSONEncoder().encode([committed]), forKey: "stocksage_price_alerts")
        let sourceBefore = sourceDefaults.persistentDomain(forName: sourceSuite) ?? [:]

        let data = try StockSageBackup.export(journal: journal, portfolio: portfolio, store: sourceStore)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["priceAlerts"] as? [[String: Any]])?.count == 1)
        #expect(sourceStore.priceAlerts == [displayed])
        #expect(NSDictionary(dictionary: sourceBefore).isEqual(to: sourceDefaults.persistentDomain(forName: sourceSuite) ?? [:]))

        let targetSuite = "stocksage-backup-alert-target-\(UUID().uuidString)"
        let targetDefaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let targetStore = StockSageStore(defaults: targetDefaults, heldSymbols: { [] })
        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: targetDefaults),
            portfolio: StockSagePortfolio(userDefaults: targetDefaults), store: targetStore).get()
        #expect(targetStore.priceAlerts == [committed])
        #expect(StockSageStore(defaults: targetDefaults, heldSymbols: { [] }).priceAlerts == [committed])
        #expect(summary.skipped == 0 && summary.message.contains("1 price alert"))
    }

    @MainActor @Test func oldBackupWithoutPriceAlertsPreservesExistingAlerts() throws {
        let suite = "stocksage-backup-alert-legacy-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = fixturePriceAlert()
        defaults.set(try JSONEncoder().encode([existing]), forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let data = try backupData(priceAlerts: nil)

        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: store).get()
        #expect(store.priceAlerts == [existing])
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).priceAlerts == [existing])
        #expect(summary.skipped == 0)
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func alertRestoreDoesNotResurrectStaleMemory(rearmed: Bool, includesAddition: Bool) throws {
        let suite = "stocksage-backup-alert-stale-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = fixturePriceAlert(triggeredAt: nil)
        defaults.set(try JSONEncoder().encode([old]), forKey: "stocksage_price_alerts")
        let staleStore = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let writer = StockSageStore(defaults: defaults, heldSymbols: { [] })
        if rearmed { writer.resetPriceAlert(old.id) }
        else { writer.removePriceAlert(old.id) }
        let committed = writer.priceAlerts
        #expect(staleStore.priceAlerts == [old])
        #expect(!committed.contains(where: { $0.id == old.id }))
        let incoming = includesAddition ? [fixturePriceAlert(id: UUID(), symbol: "OTHER")] : []
        let data = try backupData(userSymbols: ["NVDA"], priceAlerts: incoming)

        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: staleStore).get()
        let expected = committed + incoming
        #expect(staleStore.priceAlerts == expected)
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).priceAlerts == expected)
        #expect(summary.priceAlerts == incoming.count && summary.symbols == 1 && summary.skipped == 0)
    }

    @MainActor @Test(arguments: [String(repeating: "A", count: 21), "NV DA"])
    func authoredAlertSymbolsRemainLoadableAndBackupCompatible(symbol: String) throws {
        let suite = "stocksage-backup-alert-authored-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let author = StockSageStore(defaults: defaults, heldSymbols: { [] })
        author.addPriceAlert(symbol: symbol, target: 100, direction: .above)
        author.addPriceAlert(symbol: "KEEP", target: 90, direction: .below)
        let authored = author.priceAlerts
        #expect(authored.count == 2)
        let reloaded = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(reloaded.priceAlerts == authored)
        reloaded.addPriceAlert(symbol: "AFTER", target: 120, direction: .above)
        #expect(Array(reloaded.priceAlerts.prefix(2)) == authored,
                "A normal save after load must not discard previously authored alerts")
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).priceAlerts == reloaded.priceAlerts)

        let data = try StockSageBackup.export(journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: reloaded)
        let targetSuite = "stocksage-backup-alert-compatible-\(UUID().uuidString)"
        let targetDefaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = StockSageStore(defaults: targetDefaults, heldSymbols: { [] })
        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: targetDefaults),
            portfolio: StockSagePortfolio(userDefaults: targetDefaults), store: target).get()
        #expect(target.priceAlerts == reloaded.priceAlerts)
        #expect(summary.priceAlerts == 3 && summary.skipped == 0)
        #expect(StockSageStore(defaults: targetDefaults, heldSymbols: { [] }).priceAlerts == target.priceAlerts)
    }

    @MainActor @Test(arguments: ["nvda", " NVDA "])
    func legacyDecodedAlertSymbolsRoundTripWithoutNormalization(symbol: String) throws {
        let suite = "stocksage-backup-alert-spelling-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let encoded = try JSONEncoder().encode([fixturePriceAlert()])
        var rows = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        rows[0]["symbol"] = symbol // Legacy Codable storage does not call PriceAlert.init.
        let stored = try JSONSerialization.data(withJSONObject: rows)
        let expected = try JSONDecoder().decode([PriceAlert].self, from: stored)
        defaults.set(stored, forKey: "stocksage_price_alerts")
        let source = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(source.priceAlerts == expected)
        let data = try StockSageBackup.export(journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: source)
        #expect(try StockSageBackup.restore(from: data).get().priceAlerts == expected)
        #expect(defaults.data(forKey: "stocksage_price_alerts") == stored)
    }

    @MainActor @Test func normalAlertLoadRetainsDecodableValuesWhenCheckedBackupRejectsThem() throws {
        let suite = "stocksage-backup-alert-load-policy-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let records = [fixturePriceAlert(target: 0), fixturePriceAlert(id: UUID(), symbol: "KEEP")]
        let stored = try JSONEncoder().encode(records)
        defaults.set(stored, forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(store.priceAlerts == records, "Backup validation must not silently empty normal loading")
        var rejected = false
        do {
            _ = try StockSageBackup.export(journal: StockSageJournalStore(defaults: defaults),
                portfolio: StockSagePortfolio(userDefaults: defaults), store: store)
        } catch { rejected = true }
        #expect(rejected, "A checked full backup must still reject a nonpositive target")
        #expect(store.priceAlerts == records && defaults.data(forKey: "stocksage_price_alerts") == stored)
    }

    @MainActor @Test(arguments: [false, true])
    func omittedOrNullAlertFieldLeavesUnreadableDestinationUntouched(explicitNull: Bool) throws {
        let suite = "stocksage-backup-alert-untouched-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = fixturePriceAlert()
        defaults.set(try JSONEncoder().encode([existing]), forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let unreadable = Data("{bad".utf8)
        defaults.set(unreadable, forKey: "stocksage_price_alerts")
        let omitted = try backupData(priceAlerts: nil)
        var json = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        if explicitNull { json["priceAlerts"] = NSNull() }
        let data = try JSONSerialization.data(withJSONObject: json)

        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: store).get()
        #expect(summary.priceAlerts == 0 && summary.skipped == 0)
        #expect(store.priceAlerts == [existing])
        #expect(defaults.data(forKey: "stocksage_price_alerts") == unreadable)
    }

    @MainActor @Test func fullBackupReadsCommittedUpdatesAndDeletionMarkersWithoutChangingViews() throws {
        let suite = "stocksage-backup-current-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var open = fixtureTrade()
        open.exitPrice = nil; open.closedAt = nil
        let deleted = TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 95,
            target: nil, shares: 2, openedAt: open.openedAt)
        defaults.set(try JSONEncoder().encode([open, deleted]), forKey: "stocksage.journal.v1")
        defaults.set(try JSONEncoder().encode([fixturePosition()]), forKey: "stocksage_portfolio_v1")
        defaults.set(["AAPL"], forKey: "stocksage_user_symbols")
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        // A different writer commits while the displayed stores (or save panel) remain open.
        let foreign = TradeRecord(symbol: "NVDA", side: .long, entry: 100, stop: 95,
            target: nil, shares: 2, openedAt: open.openedAt)
        let lot = PortfolioPosition(symbol: "NVDA", shares: 2, costBasis: 100)
        defaults.set(try JSONEncoder().encode([fixtureTrade(), deleted, foreign]), forKey: "stocksage.journal.v1")
        defaults.set(try JSONEncoder().encode([fixturePosition(), lot]), forKey: "stocksage_portfolio_v1")
        defaults.set(["NVDA"], forKey: "stocksage_user_symbols")
        try StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage.journal.v1").mark([deleted.id])
        try StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage_portfolio_v1").mark([fixturePosition().id])
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let data = try StockSageBackup.export(journal: journal, portfolio: portfolio, store: store)
        let payload = try StockSageBackup.restore(from: data).get()
        #expect(payload.trades == [fixtureTrade(), foreign])
        #expect(payload.positions == [lot] && payload.userSymbols == ["NVDA"])
        #expect(journal.trades == [open, deleted] && portfolio.positions == [fixturePosition()] && store.userSymbols == ["AAPL"])
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test(arguments: [false, true])
    func fullBackupAllowsMissingOrValidEmptySources(explicitEmpty: Bool) throws {
        let suite = "stocksage-backup-empty-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if explicitEmpty {
            defaults.set(Data("[]".utf8), forKey: "stocksage.journal.v1")
            defaults.set(Data("[]".utf8), forKey: "stocksage_portfolio_v1")
            defaults.set([String](), forKey: "stocksage_user_symbols")
        }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let data = try StockSageBackup.export(journal: journal, portfolio: portfolio, store: store)
        let payload = try StockSageBackup.restore(from: data).get()
        #expect(payload.trades.isEmpty && payload.positions.isEmpty && payload.userSymbols.isEmpty)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test func fullBackupRetainsDecodableInvalidClosuresForRecovery() throws {
        let suite = "stocksage-backup-recovery-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var invalid = fixtureTrade(); invalid.closedAt = nil
        #expect(invalid.closureError != nil)
        defaults.set(try JSONEncoder().encode([invalid]), forKey: "stocksage.journal.v1")
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let data = try StockSageBackup.export(journal: journal, portfolio: portfolio, store: store)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(StockSageBackup.BackupPayload.self, from: data)
        #expect(payload.trades == [invalid]) // export is recovery, not restore validation/repair
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

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
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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
        let ledgerB = StockSageRecordDeletions(defaults: try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite)), recordKey: "stocksage.journal.v1")
        let second = UUID(), third = UUID()
        try ledgerA.mark([second]); try ledgerB.mark([third])
        #expect(ledgerA.contains(trade.id) && ledgerA.contains(second) && ledgerA.contains(third))
        #expect(ledgerB.contains(trade.id) && ledgerB.contains(second) && ledgerB.contains(third))
    }

    @MainActor @Test func unreadableBooksCannotBeOverwrittenOrAcquireDeletionMarkers() throws {
        let suite = "stocksage-deletion-read-failure-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
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

    @MainActor @Test func identicalPriceAlertIDsRestoreOnceAndCountTheDuplicate() throws {
        let suite = "stocksage-backup-alert-duplicate-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let alert = fixturePriceAlert()
        let data = try backupData(priceAlerts: [alert, alert])

        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: store).get()
        #expect(store.priceAlerts == [alert])
        #expect(summary.skipped == 1)
        #expect(summary.message.contains("1 price alert") && summary.message.contains("Kept 1"))
    }

    @MainActor @Test func conflictingPriceAlertIDsRejectTheWholeRestore() throws {
        let suite = "stocksage-backup-alert-conflict-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let first = fixturePriceAlert(target: 100)
        let conflicting = fixturePriceAlert(target: 200)
        let data = try backupData(trades: [fixtureTrade()], positions: [fixturePosition()],
            userSymbols: ["NVDA"], priceAlerts: [first, conflicting])
        let before = defaults.persistentDomain(forName: suite) ?? [:]

        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Conflicting price alerts with one ID must reject the entire restore")
        case .failure(let error): #expect(error.localizedDescription.contains("price alert"))
        }
        #expect(journal.trades.isEmpty && portfolio.positions.isEmpty && store.userSymbols.isEmpty
            && store.priceAlerts.isEmpty)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test func existingPriceAlertIDWinsWithoutChangingItsValues() throws {
        let suite = "stocksage-backup-alert-existing-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = fixturePriceAlert(symbol: "KEEP", target: 75, direction: .below,
            triggeredAt: Date(timeIntervalSince1970: 1_700_900_000))
        defaults.set(try JSONEncoder().encode([existing]), forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let incoming = fixturePriceAlert(symbol: "CHANGED", target: 999, direction: .above,
            triggeredAt: nil)
        let data = try backupData(priceAlerts: [incoming])

        let summary = try StockSageBackup.restore(from: data,
            journal: StockSageJournalStore(defaults: defaults),
            portfolio: StockSagePortfolio(userDefaults: defaults), store: store).get()
        #expect(store.priceAlerts == [existing] && !store.priceAlerts[0].isArmed)
        #expect(StockSageStore(defaults: defaults, heldSymbols: { [] }).priceAlerts == [existing])
        #expect(summary.skipped == 1 && summary.message.contains("0 price alert"))
    }

    @MainActor @Test(arguments: ["journal", "position", "watchlist", "price-alert-symbol-empty",
        "price-alert-symbol-blank",
        "price-alert-target", "price-alert-direction", "price-alert-id", "price-alert-triggered",
        "schema", "truncated", "corrupt"])
    func invalidBackupCannotChangeAnyCollection(fault: String) throws {
        let suite = "stocksage-backup-invalid-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        portfolio.add(symbol: "TEST", shares: 3, costBasis: 12)
        defaults.set(["TEST"], forKey: "stocksage_user_symbols")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let positionsBefore = portfolio.positions
        let valid = try backupData(trades: [fixtureTrade()], positions: [fixturePosition()],
            userSymbols: ["NVDA"], priceAlerts: [fixturePriceAlert()])
        var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var alerts = try #require(json["priceAlerts"] as? [[String: Any]])
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
        case "price-alert-symbol-empty": alerts[0]["symbol"] = ""
        case "price-alert-symbol-blank": alerts[0]["symbol"] = " \n\t "
        case "price-alert-target": alerts[0]["target"] = 0
        case "price-alert-direction": alerts[0]["direction"] = "sideways"
        case "price-alert-id": alerts[0]["id"] = "not-a-uuid"
        case "price-alert-triggered": alerts[0]["triggeredAt"] = "not-a-date"
        case "schema": json["schemaVersion"] = 99
        case "truncated": json.removeValue(forKey: "positions")
        default: break
        }
        if fault.hasPrefix("price-alert-") { json["priceAlerts"] = alerts }
        let data = fault == "corrupt" ? Data("{bad".utf8) : try JSONSerialization.data(withJSONObject: json)
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Invalid \(fault) must reject the entire restore")
        case .failure: break
        }
        #expect(journal.trades.isEmpty)
        #expect(portfolio.positions == positionsBefore)
        #expect(store.userSymbols == ["TEST"])
        #expect(store.priceAlerts.isEmpty)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @MainActor @Test(arguments: ["journal", "portfolio", "watchlist", "price-alerts", "price-alerts-type",
        "journal-type", "portfolio-type", "journal-encode", "portfolio-encode", "journal-conflict"])
    func preparationFailureCannotPartiallyApplyAValidBackup(fault: String) throws {
        let suite = "stocksage-backup-prepare-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = StockSageJournalStore(defaults: defaults)
        let portfolio = StockSagePortfolio(userDefaults: defaults)
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        switch fault {
        case "journal": defaults.set(Data("bad".utf8), forKey: "stocksage.journal.v1")
        case "portfolio": defaults.set(Data("bad".utf8), forKey: "stocksage_portfolio_v1")
        case "watchlist": defaults.set(42, forKey: "stocksage_user_symbols")
        case "price-alerts": defaults.set(Data("bad".utf8), forKey: "stocksage_price_alerts")
        case "price-alerts-type": defaults.set(42, forKey: "stocksage_price_alerts")
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
        let journalIDs = journal.trades.map(\.id), lotIDs = portfolio.positions.map(\.id), alertIDs = store.priceAlerts.map(\.id)
        let data = try backupData(trades: [fixtureTrade()], positions: [fixturePosition()],
            userSymbols: ["NVDA"], priceAlerts: [fixturePriceAlert()])
        switch StockSageBackup.restore(from: data, journal: journal, portfolio: portfolio, store: store) {
        case .success: Issue.record("Destination \(fault) failure must not partially restore")
        case .failure(let error): #expect(error.localizedDescription.contains("Nothing was restored"))
        }
        #expect(journal.trades.map(\.id) == journalIDs)
        #expect(portfolio.positions.map(\.id) == lotIDs)
        #expect(store.userSymbols.isEmpty)
        #expect(store.priceAlerts.map(\.id) == alertIDs)
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

    private func fixturePriceAlert(
        id: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        symbol: String = "NVDA", target: Double = 123.45,
        direction: PriceAlert.Direction = .below,
        triggeredAt: Date? = Date(timeIntervalSince1970: 1_700_600_000)
    ) -> PriceAlert {
        PriceAlert(id: id, symbol: symbol, target: target, direction: direction, triggeredAt: triggeredAt)
    }

    private func backupData(trades: [TradeRecord] = [], positions: [PortfolioPosition] = [],
                            userSymbols: [String] = [], priceAlerts: [PriceAlert]?) throws -> Data {
        let data = try StockSageBackup.export(trades: trades, positions: positions, userSymbols: userSymbols)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "priceAlerts")
        if let priceAlerts {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            json["priceAlerts"] = try JSONSerialization.jsonObject(with: encoder.encode(priceAlerts))
        }
        return try JSONSerialization.data(withJSONObject: json)
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

    @Test(arguments: [false, true])
    func importFromParentAppNilWhenDomainEmpty(explicitEmpty: Bool) throws {
        let suite = "stocksage-parent-empty-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if explicitEmpty {
            defaults.set(Data("[]".utf8), forKey: "stocksage.journal.v1")
            defaults.set(Data("[]".utf8), forKey: "stocksage_portfolio_v1")
        }
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let result = try StockSageBackup.importFromParentApp(defaults: defaults)
        #expect(result == nil)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @Test(arguments: ["journal", "portfolio", "journal-type", "portfolio-type"])
    func parentImportReportsUnreadableCollectionWithoutChangingSource(fault: String) throws {
        let suite = "stocksage-parent-corrupt-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([fixtureTrade()]), forKey: "stocksage.journal.v1")
        defaults.set(try JSONEncoder().encode([fixturePosition()]), forKey: "stocksage_portfolio_v1")
        let key = fault.hasPrefix("journal") ? "stocksage.journal.v1" : "stocksage_portfolio_v1"
        let corrupt: Any = fault.hasSuffix("-type") ? 42 as Any : Data("{bad".utf8) as Any
        defaults.set(corrupt, forKey: key)
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        var failed = false
        do { _ = try StockSageBackup.importFromParentApp(defaults: defaults) }
        catch {
            failed = true
            #expect(error.localizedDescription.contains(fault.components(separatedBy: "-")[0]))
        }
        #expect(failed, "Do not turn an unreadable collection into no data or partial success")
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }

    @Test(arguments: [false, true])
    func parentImportPreservesRecordsAndHonorsDeletionMarkers(deleted: Bool) throws {
        let suite = "stocksage-parent-records-\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([fixtureTrade()]), forKey: "stocksage.journal.v1")
        defaults.set(try JSONEncoder().encode([fixturePosition()]), forKey: "stocksage_portfolio_v1")
        if deleted {
            try StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage.journal.v1").mark([fixtureTrade().id])
            try StockSageRecordDeletions(defaults: defaults, recordKey: "stocksage_portfolio_v1").mark([fixturePosition().id])
        }
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let result = try StockSageBackup.importFromParentApp(defaults: defaults)
        if deleted { #expect(result == nil) }
        else {
            let records = try #require(result)
            #expect(records.trades == [fixtureTrade()] && records.positions == [fixturePosition()])
        }
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
    }
}
