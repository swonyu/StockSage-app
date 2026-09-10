import Foundation

// MARK: - Full backup / restore + parent-app (Salehman AI) migration
//
// Journal + portfolio + watchlist live in three separate UserDefaults keys. This
// snapshot excludes settings, credentials, chat and research. The "don't lose it" escape
// hatch: one JSON snapshot, validate/prepare before applying any collection (never
// partially apply a corrupt or mismatched file), plus a one-time read of the PARENT
// app's (Salehman AI) defaults domain so a StockSage install started fresh from the
// parent's existing journal/portfolio instead of an empty board.
//
// HONESTY FLOOR: merge missing record IDs only; existing records win, never guess or
// overwrite quantities/costs. The two file pickers share the same application path.
// ponytail: three UserDefaults writes are not crash-atomic or cross-process locked;
// a transactional store is needed for that stronger guarantee.
enum StockSageBackup {

    // MARK: Payload

    struct BackupPayload: Codable, Sendable {
        var schemaVersion: Int = 1
        var exportedAt: Date
        var trades: [TradeRecord]
        var positions: [PortfolioPosition]
        var userSymbols: [String]
    }

    enum BackupError: Error, LocalizedError {
        case encodeFailed
        case sourceReadFailed(String)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case decodeFailed(String)
        case invalidJournalRecord(index: Int, reason: String)
        case invalidPosition(index: Int)
        case invalidSymbol(index: Int, reason: String)
        case restoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodeFailed:
                return "Couldn't create a backup because a record could not be encoded. Check journal and portfolio values, then retry. No backup was saved."
            case .sourceReadFailed(let collection):
                return "Couldn't read the saved \(collection). Existing data was preserved."
            case .unsupportedSchemaVersion(let found, let supported):
                return "This backup file is schema version \(found); this app reads version \(supported). It may be from a newer or older version of StockSage."
            case .decodeFailed(let reason):
                return "Couldn't read this backup file — it may be corrupt or not a StockSage backup. (\(reason))"
            case .invalidJournalRecord(let index, let reason):
                return "Invalid journal trade \(index): \(reason) Nothing was restored."
            case .invalidPosition(let index):
                return "Invalid portfolio position \(index): ticker, positive finite shares and nonnegative finite cost basis are required. Nothing was restored."
            case .invalidSymbol(let index, let reason):
                return "Invalid watchlist entry \(index): \(reason) Nothing was restored."
            case .restoreFailed(let reason):
                return "Couldn't prepare the saved records: \(reason) Nothing was restored."
            }
        }
    }

    /// Current schema version this build writes and reads. Bump when `BackupPayload`'s
    /// shape changes in a way older readers can't handle.
    static let currentSchemaVersion = 1

    // MARK: Export

    /// Read committed sources at the action, including after a native save panel returns.
    /// These sequential defaults reads are not a cross-process transactional snapshot.
    @MainActor static func save(to url: URL, journal: StockSageJournalStore,
                                portfolio: StockSagePortfolio, store: StockSageStore) throws {
        let data = try export(journal: journal, portfolio: portfolio, store: store)
        try data.write(to: url, options: .atomic)
    }

    @MainActor static func export(journal: StockSageJournalStore,
                                  portfolio: StockSagePortfolio, store: StockSageStore) throws -> Data {
        try export(trades: journal.backupRecords(), positions: portfolio.backupRecords(),
                   userSymbols: store.backupSymbols())
    }

    /// Shared native export path; keep encoding before any destination write.
    static func save(to url: URL, trades: [TradeRecord], positions: [PortfolioPosition], userSymbols: [String]) throws {
        let data = try export(trades: trades, positions: positions, userSymbols: userSymbols)
        try data.write(to: url, options: .atomic)
    }

    /// Builds a pretty-printed, ISO-8601-dated JSON snapshot of everything passed in.
    /// Pure value encoder for fixtures and recovery, including retained invalid closures.
    /// Native full-backup actions use the store-taking overload to check committed sources.
    static func export(trades: [TradeRecord], positions: [PortfolioPosition], userSymbols: [String]) throws -> Data {
        let payload = BackupPayload(
            schemaVersion: currentSchemaVersion,
            exportedAt: Date(),
            trades: trades,
            positions: positions,
            userSymbols: userSymbols
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { return try encoder.encode(payload) }
        catch { throw BackupError.encodeFailed }
    }

    // MARK: Restore

    struct RestoreSummary {
        var trades = 0
        var positions = 0
        var symbols = 0
        var skipped = 0

        var message: String {
            "Restored \(trades) trade(s), \(positions) portfolio position(s), \(symbols) watchlist entry/entries. Kept \(skipped) existing/duplicate record(s); no existing records replaced."
        }
    }

    /// Shared application path for both native file pickers; injectable stores keep tests
    /// off the owner's journal, portfolio and watchlist.
    @MainActor static func restore(from data: Data, journal: StockSageJournalStore,
                                   portfolio: StockSagePortfolio, store: StockSageStore) -> Result<RestoreSummary, BackupError> {
        restore(from: data).flatMap { payload in
            do {
                let trades = try journal.prepareBackupImport(payload.trades)
                let positions = try portfolio.prepareBackupImport(payload.positions)
                let symbols = try store.prepareBackupImport(payload.userSymbols)
                // All decoding, reconciliation and encoding succeeded; no await between writes.
                trades.apply()
                positions.apply()
                symbols.apply()
                return .success(RestoreSummary(trades: trades.added, positions: positions.added,
                    symbols: symbols.added, skipped: payload.trades.count + payload.positions.count
                        + payload.userSymbols.count - trades.added - positions.added - symbols.added))
            } catch let error as BackupError {
                return .failure(error)
            } catch {
                return .failure(.restoreFailed(error.localizedDescription))
            }
        }
    }

    /// Decode/validate only, with watchlist normalization. Use the store-taking overload
    /// to apply all three collections; this overload never writes any state.
    static func restore(from data: Data) -> Result<BackupPayload, BackupError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Schema version is checked from the raw JSON first (via a minimal probe struct
        // that only cares about that one field), so a version mismatch reports as
        // `unsupportedSchemaVersion` even for a future shape whose other fields wouldn't
        // otherwise decode under this build's BackupPayload.
        struct SchemaProbe: Decodable { let schemaVersion: Int }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           probe.schemaVersion != currentSchemaVersion {
            return .failure(.unsupportedSchemaVersion(found: probe.schemaVersion, supported: currentSchemaVersion))
        }
        do {
            var payload = try decoder.decode(BackupPayload.self, from: data)
            guard payload.schemaVersion == currentSchemaVersion else {
                return .failure(.unsupportedSchemaVersion(found: payload.schemaVersion, supported: currentSchemaVersion))
            }
            for (index, trade) in payload.trades.enumerated() {
                if let error = trade.closureError { return .failure(.invalidJournalRecord(index: index + 1, reason: error)) }
                guard !trade.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      [trade.entry, trade.stop, trade.shares].allSatisfy({ $0 > 0 && $0.isFinite }),
                      [trade.target, trade.plannedEntry, trade.entryFill, trade.plannedExit, trade.exitFill]
                        .compactMap({ $0 }).allSatisfy({ $0 > 0 && $0.isFinite }),
                      trade.conviction.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                    return .failure(.invalidJournalRecord(index: index + 1, reason: "Invalid ticker, price, size or conviction."))
                }
            }
            for (index, position) in payload.positions.enumerated() {
                guard !position.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      position.shares > 0, position.shares.isFinite,
                      position.costBasis >= 0, position.costBasis.isFinite,
                      position.totalCost.isFinite else { return .failure(.invalidPosition(index: index + 1)) }
            }
            for (index, raw) in payload.userSymbols.enumerated() {
                let validated = StockSageStore.validateNewSymbol(raw, alreadyTracked: [])
                guard let symbol = validated.symbol else {
                    return .failure(.invalidSymbol(index: index + 1, reason: validated.error ?? "Invalid ticker."))
                }
                payload.userSymbols[index] = symbol
            }
            return .success(payload)
        } catch {
            return .failure(.decodeFailed(String(describing: error)))
        }
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
