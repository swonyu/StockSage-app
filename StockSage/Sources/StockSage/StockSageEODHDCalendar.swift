import Foundation

/// EODHD earnings-calendar coverage: the calendar endpoint (a genuine next-earnings DATE, US
/// only — Tadawul has no EODHD coverage at any tier, StockSageEODHD.swift's own measured gap),
/// PLUS the fundamentals endpoint's `Earnings.History` (past dates, the PROJECTION source when
/// the calendar and Yahoo both come up empty). Plan-gated (research_earnings_sources_2026-09-06.md):
/// this account's tier for `/calendar/earnings` is UNKNOWN until probed — `probeCalendarAvailability`
/// makes exactly ONE request and records ONLY the resulting HTTP status, never the key or the URL
/// carrying it, so the chain can skip this source for 24h on a plan-tier rejection (401/402/403)
/// instead of burning a request per symbol against an endpoint this account can't use.
@MainActor
enum StockSageEODHDCalendar {

    // MARK: - Calendar row (next-earnings DATE)

    /// One row of `/api/calendar/earnings`. Only the fields this app actually uses are parsed
    /// (code, report_date, date, before_after_market, estimate, actual) — currency/difference/
    /// percent exist in the real payload but are unused here.
    nonisolated struct Row: Sendable, Equatable {
        let code: String
        /// Fiscal period this report covers (EODHD's `report_date`) — informational only.
        let reportPeriod: Date?
        /// The announcement date itself — what the chain actually wants.
        let date: Date
        let beforeAfterMarket: String?
        let estimate: Double?
        let actual: Double?
    }

    private nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parses EODHD's `/api/calendar/earnings` body — either a bare array or `{"earnings": [...]}`
    /// (EODHD has shipped both shapes across sibling endpoints; this accepts either). A row
    /// missing `code`, or carrying an unparseable `date`, is SKIPPED, never defaulted.
    nonisolated static func parseCalendar(_ data: Data) -> [Row] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // `as? [Any]` first, THEN `compactMap` each element to `[String: Any]` — casting the
        // whole array straight to `[[String: Any]]` fails closed (returns nil) the instant ONE
        // element isn't a dictionary (e.g. a stray string), which would silently drop every
        // OTHER, perfectly valid row in the same batch. Per-element casting is what actually
        // delivers "malformed rows skipped", not "one malformed row voids the whole response".
        let raw: [Any]
        if let arr = root as? [Any] {
            raw = arr
        } else if let obj = root as? [String: Any], let arr = obj["earnings"] as? [Any] {
            raw = arr
        } else {
            return []
        }
        return raw.compactMap { element -> Row? in
            guard let row = element as? [String: Any],
                  let code = row["code"] as? String,
                  let dateStr = row["date"] as? String,
                  let date = dayFormatter.date(from: dateStr) else { return nil }
            let reportPeriod = (row["report_date"] as? String).flatMap { dayFormatter.date(from: $0) }
            return Row(code: code, reportPeriod: reportPeriod, date: date,
                      beforeAfterMarket: row["before_after_market"] as? String,
                      estimate: row["estimate"] as? Double, actual: row["actual"] as? Double)
        }
    }

    /// Soonest row at/after `now` — the "next earnings" answer, mirroring the Yahoo/EODHD
    /// min-epoch convention used everywhere else in this file's family.
    nonisolated static func nextRow(_ rows: [Row], now: Date) -> Row? {
        rows.filter { $0.date >= now }.min { $0.date < $1.date }
    }

    /// EODHD's calendar carries no explicit confirmation flag (unlike Yahoo's
    /// `isEarningsDateEstimate`). `actual` is populated only once a report has ALREADY
    /// happened — for a next-earnings (future) row `actual` is therefore always nil, so every
    /// such row is treated as an ESTIMATE (`confirmed: false`), refined as the date approaches
    /// but never guaranteed until reported. Documented here, not guessed — revisit if EODHD ever
    /// starts populating `actual` on a forward-looking row.
    nonisolated static func confirmed(for row: Row) -> Bool { false }

    /// One US symbol's calendar rows for the next `days` days. `nil` on any failure, when the
    /// symbol isn't EODHD-covered, or while the 24h `calendarUnavailableUntil` window is open.
    static func fetchCalendar(_ symbol: String, from: Date = Date(), days: Int = 400) async -> [Row]? {
        guard StockSageEODHD.covers(symbol) else { return nil }
        guard isAvailable(now: from) else { return nil }
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty else { return nil }
        let sym = StockSageEODHD.eodhdSymbol(symbol)
        let fromStr = dayFormatter.string(from: from)
        let toStr = dayFormatter.string(from: from.addingTimeInterval(Double(days) * 86_400))
        guard let url = URL(string: "https://eodhd.com/api/calendar/earnings?symbols=\(sym)&from=\(fromStr)&to=\(toStr)&fmt=json&api_token=\(key)")
        else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseCalendar(data)
    }

    // MARK: - Plan-tier availability gate (probe once, skip for 24h on rejection)

    private nonisolated static let unavailableUntilKey = "stocksage.eodhd.calendarUnavailableUntil"

    private static var calendarUnavailableUntil: Date? {
        get { UserDefaults.standard.object(forKey: unavailableUntilKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: unavailableUntilKey) }
    }

    /// Pure boundary check — directly testable without UserDefaults or the network. `nil`
    /// (never probed, or the last probe succeeded) ⇒ available.
    nonisolated static func isAvailable(unavailableUntil: Date?, now: Date) -> Bool {
        guard let unavailableUntil else { return true }
        return now >= unavailableUntil
    }

    static func isAvailable(now: Date = Date()) -> Bool {
        Self.isAvailable(unavailableUntil: calendarUnavailableUntil, now: now)
    }

    /// Pure core: given the probe's HTTP status, the new `calendarUnavailableUntil` (nil = stays
    /// available). Only a plan-tier rejection (401/402/403) closes the gate — any other status
    /// (200, a transient 5xx, a timeout ⇒ `nil` status) leaves it open, since those aren't
    /// evidence the TIER itself is wrong.
    nonisolated static func availabilityOutcome(statusCode: Int?, now: Date) -> Date? {
        guard let statusCode, [401, 402, 403].contains(statusCode) else { return nil }
        return now.addingTimeInterval(24 * 3600)
    }

    /// ONE request for AAPL.US. Records ONLY the resulting status via `availabilityOutcome` —
    /// never logs the key or the URL carrying it (STANDING RULES: secrets by NAME only).
    static func probeCalendarAvailability() async {
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty,
              let url = URL(string: "https://eodhd.com/api/calendar/earnings?symbols=AAPL.US&fmt=json&api_token=\(key)")
        else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        let statusCode: Int? = (try? await URLSession.shared.data(for: req)).flatMap { (_, resp) in
            (resp as? HTTPURLResponse)?.statusCode
        }
        if let until = availabilityOutcome(statusCode: statusCode, now: Date()) {
            calendarUnavailableUntil = until
        }
    }

    // MARK: - Fundamentals `Earnings.History` (PROJECTION source for US names)

    /// Past report dates from EODHD's `/api/fundamentals/<SYM>.US` `Earnings.History` object (a
    /// dict keyed by date string, each entry carrying its own `date`). Malformed entries are
    /// skipped; result is oldest-first.
    nonisolated static func parseEarningsHistory(_ data: Data) -> [Date] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let earnings = root["Earnings"] as? [String: Any],
              let history = earnings["History"] as? [String: Any] else { return [] }
        let dates = history.values.compactMap { entry -> Date? in
            guard let obj = entry as? [String: Any] else { return nil }
            let dateStr = (obj["date"] as? String) ?? (obj["reportDate"] as? String)
            return dateStr.flatMap { dayFormatter.date(from: $0) }
        }
        return dates.sorted()
    }

    /// 10 API calls/request (owner waived the cost, 2026-09-06) — only called for a US equity
    /// whose calendar AND Yahoo calendarEvents both came up empty (the chain's last resort
    /// before `.unchecked`).
    static func fetchEarningsHistory(_ symbol: String) async -> [Date] {
        guard StockSageEODHD.covers(symbol) else { return [] }
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty else { return [] }
        let sym = StockSageEODHD.eodhdSymbol(symbol)
        guard let url = URL(string: "https://eodhd.com/api/fundamentals/\(sym)?api_token=\(key)&fmt=json")
        else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseEarningsHistory(data)
    }
}
