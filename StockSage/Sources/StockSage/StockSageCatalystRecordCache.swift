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
        /// Classification of what we actually know for this symbol (W1, 2026-09-06). Every
        /// tracked equity gets exactly one of these; a non-equity (index/ETF/^TASI.SR) is
        /// `notApplicable` without ever being asked. `unchecked` covers BOTH "never asked" and
        /// "asked every source, nothing usable" — `sourcesAsked` (below) is what tells the two
        /// apart, mirroring the pre-W1 pattern where `checkedAt == nil` meant never-asked.
        nonisolated enum Status: String, Codable, Sendable {
            case dateKnown, projected, notApplicable, unchecked
        }

        /// Always uppercased on construction so the same ticker never splits into two
        /// entries by case (StockSageStore.userSymbols/ideas keys are uppercase too).
        let symbol: String
        /// nil means "asked, provider returned no catalyst" — the honest negative. This is
        /// never synthesized; it only ever reflects what the provider actually returned.
        /// For `status == .projected` this is the PROJECTED date, never an announced one.
        let earningsDate: Date?
        /// When we asked. This is the date that makes a negative result honest instead of
        /// stale-forever: "none known as of checkedAt", not "none known" full stop.
        let checkedAt: Date
        /// Where the observation came from (e.g. "yahoo", "eodhd calendar", "projection"), for
        /// auditability.
        let source: String
        /// W1 additions (2026-09-06) — all DEFAULTED (see `init(from:)` below) so a pipeline-1
        /// record on disk, written before any of these fields existed, still decodes.
        var status: Status
        /// The provider's own confirmation flag, when it has one (Yahoo's `isEarningsDateEstimate`
        /// inverted; legacy observations from providers without a flag may carry `false`). `nil`
        /// when no source supplied a flag at all.
        var confirmed: Bool?
        /// Upper bound of a provider-supplied date RANGE (Yahoo's 2-element `earningsDate`), or the
        /// ±7-day projection window's upper bound for `status == .projected`. `nil` for a single
        /// exact date (EODHD calendar) or when nothing dated is known.
        var dateRangeEnd: Date?
        /// Every source this chain actually asked, in order, for auditability — e.g.
        /// `["eodhd calendar", "yahoo calendarEvents"]`. Empty means never asked (mirrors
        /// `checkedAt == nil` in spirit; `checkedAt` itself is still stamped once the chain runs
        /// so the 24h TTL guard has something to gate on).
        var sourcesAsked: [String]
        /// Human-readable derivation for a `.projected` date, e.g. "median gap of last 6 reports =
        /// 91 d from 2026-07-30" — always present when `status == .projected`, always nil otherwise.
        var projectionBasis: String?

        init(symbol: String, earningsDate: Date?, checkedAt: Date, source: String,
             status: Status = .unchecked, confirmed: Bool? = nil, dateRangeEnd: Date? = nil,
             sourcesAsked: [String] = [], projectionBasis: String? = nil) {
            self.symbol = symbol.uppercased()
            self.earningsDate = earningsDate
            self.checkedAt = checkedAt
            self.source = source
            self.status = status
            self.confirmed = confirmed
            self.dateRangeEnd = dateRangeEnd
            self.sourcesAsked = sourcesAsked
            self.projectionBasis = projectionBasis
        }

        /// Hand-written, not synthesized: verified empirically (2026-09-06) that Swift's
        /// synthesized `Decodable` does NOT fall back to a property's default value when a key is
        /// simply missing — it throws `keyNotFound` instead. Every W1 field below is
        /// `decodeIfPresent`'d with the SAME default its declaration above carries, so a
        /// pipeline-1 record (symbol/earningsDate/checkedAt/source only) still decodes. `encode`
        /// stays synthesized — providing a custom `init(from:)` alone doesn't disable it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try c.decode(String.self, forKey: .symbol)
            earningsDate = try c.decodeIfPresent(Date.self, forKey: .earningsDate)
            checkedAt = try c.decode(Date.self, forKey: .checkedAt)
            source = try c.decode(String.self, forKey: .source)
            status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .unchecked
            confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed)
            dateRangeEnd = try c.decodeIfPresent(Date.self, forKey: .dateRangeEnd)
            sourcesAsked = try c.decodeIfPresent([String].self, forKey: .sourcesAsked) ?? []
            projectionBasis = try c.decodeIfPresent(String.self, forKey: .projectionBasis)
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
