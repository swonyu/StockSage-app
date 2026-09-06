import Foundation

// MARK: - Disk catalyst-record cache
//
// Persists what we actually observed when we asked a data provider for a symbol's next
// catalyst (earnings date) — including the NEGATIVE result: "we asked Yahoo for SYM at
// checkedAt and it returned nothing." That negative record is the honest, dated
// "none known as of <checkedAt>" answer (OWNER DIRECTIVE 2026-09-06: "every stock to have
// a catalyst on file"). This cache NEVER stores a fabricated catalyst — a symbol we asked
// about but got nothing for gets a Record with `earningsDate == nil` and a real
// `checkedAt`/`source`, never an invented date. A symbol we never asked simply has no
// Record at all and keeps rendering as unchecked (never conflated with "checked, none").
// Shape copied from StockSageQuoteCache: Application Support directory, own filename,
// load()/save(), decode failure ⇒ nil, atomic write.

nonisolated struct StockSageCatalystRecordCache: Codable, Sendable, Equatable {
    nonisolated struct Record: Codable, Sendable, Equatable {
        /// Always uppercased on construction so the same ticker never splits into two
        /// entries by case (StockSageStore.userSymbols/ideas keys are uppercase too).
        let symbol: String
        /// nil means "asked, provider returned no catalyst" — the honest negative. This is
        /// never synthesized; it only ever reflects what the provider actually returned.
        let earningsDate: Date?
        /// When we asked. This is the date that makes a negative result honest instead of
        /// stale-forever: "none known as of checkedAt", not "none known" full stop.
        let checkedAt: Date
        /// Where the observation came from (e.g. "yahoo"), for auditability.
        let source: String

        init(symbol: String, earningsDate: Date?, checkedAt: Date, source: String) {
            self.symbol = symbol.uppercased()
            self.earningsDate = earningsDate
            self.checkedAt = checkedAt
            self.source = source
        }
    }

    var entries: [Record]
    var savedAt: Date

    // MARK: Thin file I/O (Application Support)

    nonisolated static func diskURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("catalyst_records_v1.json")
    }

    /// `url` overrides the real Application Support location — used by tests to round-trip
    /// through a temp directory instead of touching the real disk cache.
    nonisolated static func load(from url: URL? = nil) -> StockSageCatalystRecordCache? {
        guard let url = url ?? diskURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StockSageCatalystRecordCache.self, from: data)
    }

    nonisolated func save(to url: URL? = nil) {
        guard let url = url ?? Self.diskURL(), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
