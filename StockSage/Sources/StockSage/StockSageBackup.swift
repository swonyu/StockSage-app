import Foundation

// MARK: - Full backup / restore + parent-app (Salehman AI) migration
//
// Journal + portfolio + watchlist + price alerts live in four separate UserDefaults keys. This
// snapshot excludes settings, credentials, chat and research. The "don't lose it" escape
// hatch: one JSON snapshot, validate/prepare before applying any collection (never
// partially apply a corrupt or mismatched file), plus a one-time read of the PARENT
// app's (Salehman AI) defaults domain so a StockSage install started fresh from the
// parent's existing journal/portfolio instead of an empty board.
//
// HONESTY FLOOR: merge missing record IDs only; existing records win, never guess or
// overwrite quantities/costs. The two file pickers share the same application path.
// A successful restore commits all four collections and record-deletion markers as
// one atomic image; subsequent reads/edits use that image instead of legacy preferences.
enum StockSageBackup {

    // MARK: Payload

    struct BackupPayload: Codable, Sendable {
        var schemaVersion: Int = 2
        var exportedAt: Date
        var trades: [TradeRecord]
        var positions: [PortfolioPosition]
        var userSymbols: [String]
        var priceAlerts: [PriceAlert]? = nil
    }

    enum BackupError: Error, LocalizedError {
        case encodeFailed
        case sourceReadFailed(String)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case decodeFailed(String)
        case invalidJournalRecord(index: Int, reason: String)
        case invalidPosition(index: Int)
        case invalidSymbol(index: Int, reason: String)
        case invalidPriceAlert(index: Int, reason: String)
        case conflictingRecordID(collection: String, index: Int)
        case restoreFailed(String)
        case restoreDurabilityUnconfirmed

        var errorDescription: String? {
            switch self {
            case .encodeFailed:
                return "Couldn't create a backup because a record could not be encoded. Check journal, portfolio and price-alert values, then retry. No backup was saved."
            case .sourceReadFailed(let collection):
                return "Couldn't read the saved \(collection). Existing data was preserved."
            case .unsupportedSchemaVersion(let found, let supported):
                return "This backup file is schema version \(found); this app reads versions 1 through \(supported). It may be from a newer or older version of StockSage."
            case .decodeFailed(let reason):
                return "Couldn't read this backup file — it may be corrupt or not a StockSage backup. (\(reason))"
            case .invalidJournalRecord(let index, let reason):
                return "Invalid journal trade \(index): \(reason) Nothing was restored."
            case .invalidPosition(let index):
                return "Invalid portfolio position \(index): ticker, positive finite shares and nonnegative finite cost basis are required. Nothing was restored."
            case .invalidSymbol(let index, let reason):
                return "Invalid watchlist entry \(index): \(reason) Nothing was restored."
            case .invalidPriceAlert(let index, let reason):
                return "Invalid price alert \(index): \(reason) Nothing was restored."
            case .conflictingRecordID(let collection, let index):
                return "Invalid \(collection) record \(index): its ID conflicts with an earlier record. Nothing was restored."
            case .restoreFailed(let reason):
                return "Couldn't prepare the saved records: \(reason) Nothing was restored."
            case .restoreDurabilityUnconfirmed:
                return StockSageRecordStorage.Failure.durabilityUnconfirmed.localizedDescription
            }
        }
    }

    /// Schema 2 preserves Date's exact seconds since 2001-01-01T00:00:00Z.
    /// Schema 1's ISO-8601 dates remain readable at their original second precision.
    static let currentSchemaVersion = 2

    // MARK: Export

    /// Read committed sources at the action, including after a native save panel returns.
    /// Restored profiles read the leased atomic image; legacy profiles retain their preferences.
    @MainActor static func save(to url: URL, journal: StockSageJournalStore,
                                portfolio: StockSagePortfolio, store: StockSageStore) throws {
        let data = try export(journal: journal, portfolio: portfolio, store: store)
        try data.write(to: url, options: .atomic)
    }

    @MainActor static func export(journal: StockSageJournalStore,
                                  portfolio: StockSagePortfolio, store: StockSageStore) throws -> Data {
        try export(trades: journal.backupRecords(), positions: portfolio.backupRecords(),
                   userSymbols: store.backupSymbols(), priceAlerts: store.backupPriceAlerts())
    }

    /// Shared native export path; keep encoding before any destination write.
    static func save(to url: URL, trades: [TradeRecord], positions: [PortfolioPosition],
                     userSymbols: [String], priceAlerts: [PriceAlert] = []) throws {
        let data = try export(trades: trades, positions: positions, userSymbols: userSymbols,
                              priceAlerts: priceAlerts)
        try data.write(to: url, options: .atomic)
    }

    /// Builds a pretty-printed JSON snapshot with lossless Foundation Date values.
    /// Pure value encoder for fixtures and recovery, including retained invalid closures.
    /// Native full-backup actions use the store-taking overload to check committed sources.
    static func export(trades: [TradeRecord], positions: [PortfolioPosition], userSymbols: [String],
                       priceAlerts: [PriceAlert] = []) throws -> Data {
        let payload = BackupPayload(
            schemaVersion: currentSchemaVersion,
            exportedAt: Date(),
            trades: trades,
            positions: positions,
            userSymbols: userSymbols,
            priceAlerts: priceAlerts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        do { return try encoder.encode(payload) }
        catch { throw BackupError.encodeFailed }
    }

    // MARK: Restore

    struct RestoreSummary {
        var trades = 0
        var positions = 0
        var symbols = 0
        var priceAlerts = 0
        var skipped = 0

        var message: String {
            "Restored \(trades) trade(s), \(positions) portfolio position(s), \(symbols) watchlist entry/entries, \(priceAlerts) price alert(s). Kept \(skipped) existing/duplicate record(s); no existing records replaced."
        }
    }

    /// Shared application path for both native file pickers; injectable stores keep tests
    /// off the owner's journal, portfolio, watchlist and price alerts.
    @MainActor static func restore(from data: Data, journal: StockSageJournalStore,
                                   portfolio: StockSagePortfolio, store: StockSageStore) -> Result<RestoreSummary, BackupError> {
        restore(from: data).flatMap { payload in
            do {
                let trades = try journal.prepareBackupImport(payload.trades)
                let positions = try portfolio.prepareBackupImport(payload.positions)
                let symbols = try store.prepareBackupImport(payload.userSymbols)
                // Old backups omit alerts; retain their committed records and refresh stale memory.
                let alerts = try store.preparePriceAlertBackupImport(payload.priceAlerts ?? [])
                // Validation/preparation is complete before the one durable commit and publication.
                let warning = try StockSageRecordStorage.commit([trades, positions, symbols, alerts])
                if warning != nil { return .failure(.restoreDurabilityUnconfirmed) }
                let alertCount = payload.priceAlerts?.count ?? 0
                let alertsAdded = alerts.added
                return .success(RestoreSummary(trades: trades.added, positions: positions.added,
                    symbols: symbols.added, priceAlerts: alertsAdded,
                    skipped: payload.trades.count + payload.positions.count + payload.userSymbols.count
                        + alertCount - trades.added - positions.added - symbols.added - alertsAdded))
            } catch let error as BackupError {
                if case .sourceReadFailed = error {
                    return .failure(.restoreFailed(error.localizedDescription))
                }
                return .failure(error)
            } catch {
                return .failure(.restoreFailed(error.localizedDescription))
            }
        }
    }

    /// Decode/validate only, with watchlist normalization. Use the store-taking overload
    /// to apply all four collections; this overload never writes any state.
    static func restore(from data: Data) -> Result<BackupPayload, BackupError> {
        // Schema version is checked from the raw JSON first (via a minimal probe struct
        // that only cares about that one field), so a version mismatch reports as
        // `unsupportedSchemaVersion` even for a future shape whose other fields wouldn't
        // otherwise decode under this build's BackupPayload.
        struct SchemaProbe: Decodable { let schemaVersion: Int }
        do {
            let version = try JSONDecoder().decode(SchemaProbe.self, from: data).schemaVersion
            guard (1...currentSchemaVersion).contains(version) else {
                return .failure(.unsupportedSchemaVersion(found: version, supported: currentSchemaVersion))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = version == 1 ? .iso8601 : .deferredToDate
            var payload = try decoder.decode(BackupPayload.self, from: data)
            var seenTrades: [UUID: TradeRecord] = [:]
            for (index, trade) in payload.trades.enumerated() {
                if let error = trade.ownerJournalError { return .failure(.invalidJournalRecord(index: index + 1, reason: error)) }
                guard !trade.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      [trade.entry, trade.stop, trade.shares].allSatisfy({ $0 > 0 && $0.isFinite }),
                      [trade.target, trade.plannedEntry, trade.entryFill, trade.plannedExit, trade.exitFill]
                        .compactMap({ $0 }).allSatisfy({ $0 > 0 && $0.isFinite }),
                      trade.conviction.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                    return .failure(.invalidJournalRecord(index: index + 1, reason: "Invalid ticker, price, size or conviction."))
                }
                if let prior = seenTrades[trade.id], prior != trade {
                    return .failure(.conflictingRecordID(collection: "journal", index: index + 1))
                }
                seenTrades[trade.id] = trade
            }
            var seenPositions: [UUID: PortfolioPosition] = [:]
            for (index, position) in payload.positions.enumerated() {
                guard !position.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      position.shares > 0, position.shares.isFinite,
                      position.costBasis >= 0, position.costBasis.isFinite,
                      position.totalCost.isFinite else { return .failure(.invalidPosition(index: index + 1)) }
                if let prior = seenPositions[position.id], prior != position {
                    return .failure(.conflictingRecordID(collection: "portfolio", index: index + 1))
                }
                seenPositions[position.id] = position
            }
            for (index, raw) in payload.userSymbols.enumerated() {
                let validated = StockSageStore.validateNewSymbol(raw, alreadyTracked: [])
                guard let symbol = validated.symbol else {
                    return .failure(.invalidSymbol(index: index + 1, reason: validated.error ?? "Invalid ticker."))
                }
                payload.userSymbols[index] = symbol
            }
            if let alerts = payload.priceAlerts, let error = priceAlertValidationError(in: alerts) {
                return .failure(error)
            }
            return .success(payload)
        } catch {
            return .failure(.decodeFailed(String(describing: error)))
        }
    }

    /// Exact duplicates are repeatable restore inputs; one ID carrying different intent is
    /// ambiguous and rejects the whole file before any destination preparation or mutation.
    static func priceAlertValidationError(in alerts: [PriceAlert]) -> BackupError? {
        var seen: [UUID: PriceAlert] = [:]
        for (index, alert) in alerts.enumerated() {
            if let reason = alert.validationError {
                return .invalidPriceAlert(index: index + 1, reason: reason)
            }
            if let prior = seen[alert.id], prior != alert {
                return .invalidPriceAlert(index: index + 1,
                    reason: "its ID conflicts with an earlier price alert.")
            }
            seen[alert.id] = alert
        }
        return nil
    }

    // MARK: Parent-app (Salehman AI) migration

    struct ParentImport: Sendable {
        var trades: [TradeRecord]
        var positions: [PortfolioPosition]
        var tradeCount: Int { trades.count }
        var positionCount: Int { positions.count }
    }

    /// Reads the PARENT app's (Salehman AI, the app StockSage was extracted from)
    /// UserDefaults domain for its journal + portfolio JSON, using the exact same keys and
    /// decoders those stores use (`StockSageJournalStore`/`StockSagePortfolio`: default
    /// `JSONDecoder()`, no custom date strategy — `Date` as `.deferredToDate`).
    ///
    /// HONEST CONSTRAINT: this only works because neither app is sandboxed — an
    /// `UserDefaults(suiteName:)` cross-app read is a normal (if unusual) API, but under
    /// the App Sandbox each app's defaults are container-isolated and this would silently
    /// return nil forever. If either app is ever sandboxed, this migration path goes dark;
    /// document that at the call site rather than resurrecting it as a "bug".
    ///
    /// Returns nil for missing/empty effective records; throws for unreadable collections.
    /// Defaults injection keeps migration tests out of the real parent-app domain.
    static func importFromParentApp(defaults: UserDefaults? = UserDefaults(suiteName: "SA.Salehman-AI")) throws -> ParentImport? {
        guard let parentDefaults = defaults else { throw BackupError.sourceReadFailed("Salehman AI data") }
        let journal = StockSageRecordDeletions(defaults: parentDefaults, recordKey: "stocksage.journal.v1")
        let portfolio = StockSageRecordDeletions(defaults: parentDefaults, recordKey: "stocksage_portfolio_v1")
        let trades: [TradeRecord]
        let positions: [PortfolioPosition]
        do { trades = try journal.read(TradeRecord.self).filter { !journal.contains($0.id) } }
        catch { throw BackupError.sourceReadFailed("Salehman AI journal") }
        do { positions = try portfolio.read(PortfolioPosition.self).filter { !portfolio.contains($0.id) } }
        catch { throw BackupError.sourceReadFailed("Salehman AI portfolio") }

        guard !trades.isEmpty || !positions.isEmpty else { return nil }
        return ParentImport(trades: trades, positions: positions)
    }
}
