import Foundation

// MARK: - Full backup / restore + parent-app (Salehman AI) migration
//
// The owner's whole StockSage state (journal + portfolio + watchlist) lives in three
// separate UserDefaults keys with no combined export. This is the "don't lose it" escape
// hatch: one JSON snapshot, all-or-nothing restore (never partially apply a corrupt or
// mismatched file onto real trade/position data), plus a one-time read of the PARENT
// app's (Salehman AI) defaults domain so a StockSage install started fresh from the
// parent's existing journal/portfolio instead of an empty board.
//
// HONESTY FLOOR: this touches money records. Restore never merges or guesses — a bad
// decode is surfaced as an error, not silently dropped or partially applied. The caller
// (UI) applies the returned payload explicitly, after an owner confirmation.
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
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let found, let supported):
                return "This backup file is schema version \(found); this app reads version \(supported). It may be from a newer or older version of StockSage."
            case .decodeFailed(let reason):
                return "Couldn't read this backup file — it may be corrupt or not a StockSage backup. (\(reason))"
            }
        }
    }

    /// Current schema version this build writes and reads. Bump when `BackupPayload`'s
    /// shape changes in a way older readers can't handle.
    static let currentSchemaVersion = 1

    // MARK: Export

    /// Builds a pretty-printed, ISO-8601-dated JSON snapshot of everything passed in.
    /// Pure — callers read `StockSageJournalStore.shared.trades`,
    /// `StockSagePortfolio.shared.positions`, `StockSageStore.shared.userSymbols` and pass
    /// them in, so this file never needs to import/depend on those stores directly.
    static func export(trades: [TradeRecord], positions: [PortfolioPosition], userSymbols: [String]) -> Data {
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
        // A payload built from Codable structs with only finite Doubles can't fail to
        // encode; a force-try here would be reachable only by a future field breaking
        // that invariant, so encode defensively and return empty JSON rather than crash.
        guard let data = try? encoder.encode(payload) else { return Data("{}".utf8) }
        return data
    }

    // MARK: Restore

    /// Decodes a backup file. NEVER partially applies — either the whole payload decodes
    /// cleanly and the schema version matches, or an error is returned and the caller's
    /// existing state is untouched. The caller (UI) is responsible for actually writing
    /// the returned payload's trades/positions/userSymbols into the live stores.
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
            let payload = try decoder.decode(BackupPayload.self, from: data)
            guard payload.schemaVersion == currentSchemaVersion else {
                return .failure(.unsupportedSchemaVersion(found: payload.schemaVersion, supported: currentSchemaVersion))
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
    /// Returns nil when the parent domain has no data for either key (nothing to migrate).
    static func importFromParentApp() -> ParentImport? {
        guard let parentDefaults = UserDefaults(suiteName: "SA.Salehman-AI") else { return nil }

        let decoder = JSONDecoder()   // matches StockSageJournalStore/StockSagePortfolio: no custom strategy

        let trades: [TradeRecord] = parentDefaults.data(forKey: "stocksage.journal.v1")
            .flatMap { try? decoder.decode([TradeRecord].self, from: $0) } ?? []
        let positions: [PortfolioPosition] = parentDefaults.data(forKey: "stocksage_portfolio_v1")
            .flatMap { try? decoder.decode([PortfolioPosition].self, from: $0) } ?? []

        guard !trades.isEmpty || !positions.isEmpty else { return nil }
        return ParentImport(trades: trades, positions: positions)
    }
}
