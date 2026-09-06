import Foundation

// MARK: - Earnings-date proximity warning
//
// A protective stop is an INTRADAY promise — it can't save you from an overnight
// earnings gap that opens straight through it. So before an event, the risk you
// sized at entry is not the risk you actually hold. This flags how close the next
// earnings report is. The days/severity math is pure + tested; the date fetch is
// best-effort (Yahoo's quoteSummary sometimes needs a crumb) and degrades silently.

struct EarningsProximity: Sendable, Equatable {
    enum Severity: String, Sendable {
        case imminent = "Imminent"   // ≤3 days
        case soon     = "Soon"       // ≤10 days
        case clear    = "Clear"      // >10 days
    }
    let daysUntil: Int
    let severity: Severity

    nonisolated var isWarning: Bool { severity == .imminent || severity == .soon }

    nonisolated var note: String {
        switch severity {
        case .imminent:
            return "Earnings in ~\(daysUntil) day\(daysUntil == 1 ? "" : "s") — expect an overnight gap; a protective stop may NOT hold through it. Size for that or wait until after."
        case .soon:
            return "Earnings in ~\(daysUntil) days — event risk is approaching; decide now whether you'll hold through the report."
        case .clear:
            return "Next earnings ~\(daysUntil) days out — no immediate event risk."
        }
    }
}

enum StockSageEarnings {
    nonisolated static func severity(daysUntil: Int) -> EarningsProximity.Severity {
        if daysUntil <= 3 { return .imminent }
        if daysUntil <= 10 { return .soon }
        return .clear
    }

    /// Days from `now` to `earnings` (rounded to nearest day, floored at 0 so a
    /// just-passed date reads 0 rather than negative).
    nonisolated static func proximity(now: Date, earnings: Date) -> EarningsProximity {
        let days = Int((earnings.timeIntervalSince(now) / 86_400).rounded())
        let d = Swift.max(0, days)
        return EarningsProximity(daysUntil: d, severity: severity(daysUntil: d))
    }

    // UA shared with StockSageQuoteService — one source of truth so a Yahoo UA fix
    // lands in exactly one place (F39 2026-07-02). MediaSearch has its own copy outside
    // the Markets fence and is intentionally left untouched.
    private static let ua = StockSageQuoteService.ua

    /// Whether a `calendarEvents` request was actually ANSWERED by the provider, distinct from
    /// never having asked at all (blocker fix, 2026-09-06). Before this, `fetchNextEarnings`
    /// returned `nil` identically for "asked, got a 200 with no date" AND for "never asked —
    /// external access off / non-equity / timeout / non-200 / parse failure", so the store
    /// stamped a dated "none known" record for cases where nothing was ever actually observed.
    /// `.answered(date)` — the provider was asked and responded 200; `date` is nil when the body
    /// carried no earnings date, non-nil otherwise. `.unavailable` — no observation was made at
    /// all; the caller must NOT stamp anything (honesty floor: unknown stays unknown).
    enum EarningsFetch: Sendable { case answered(Date?), unavailable }

    /// Best-effort next-earnings date via Yahoo quoteSummary `calendarEvents`.
    /// Equities only (FX/crypto/index have no earnings — `.unavailable`, never stamped as
    /// "checked"); `.unavailable` when access is off or the request never got a 200 back — the
    /// warning simply doesn't appear, never blocks.
    static func fetchNextEarningsOutcome(for symbol: String) async -> EarningsFetch {
        guard ToolPolicy.isExternalAllowed else { return .unavailable }
        guard StockSageAllocation.assetClass(symbol) == "Equity" else { return .unavailable }
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(encoded)?modules=calendarEvents")
        else { return .unavailable }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let data = await get(req) else { return .unavailable }
        return .answered(parseEarningsDate(data))   // a 200 body IS an answer, date or not
    }

    /// Parse the soonest earnings epoch from a quoteSummary `calendarEvents` body.
    nonisolated static func parseEarningsDate(_ data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qs = root["quoteSummary"] as? [String: Any],
              let results = qs["result"] as? [[String: Any]],
              let first = results.first,
              let cal = first["calendarEvents"] as? [String: Any],
              let earnings = cal["earnings"] as? [String: Any],
              let dates = earnings["earningsDate"] as? [[String: Any]] else { return nil }
        // earningsDate is [{raw: epoch, fmt: "..."}] (sometimes a start/end range).
        let epochs = dates.compactMap { $0["raw"] as? Double }.filter { $0 > 0 }
        guard let soonest = epochs.min() else { return nil }
        return Date(timeIntervalSince1970: soonest)
    }

    // MARK: - W1 (2026-09-06): the date RANGE + the provider's own estimate flag
    //
    // Pre-W1 `parseEarningsDate`/`fetchNextEarningsOutcome` above are UNCHANGED (min-epoch
    // behaviour preserved, per the step's own instruction) — every existing caller/test keeps
    // working. This is an ADDITIONAL, richer read of the exact same `calendarEvents` body for the
    // new chain (StockSageCatalystChain), which needs the range end and the estimate flag to fill
    // `Record.dateRangeEnd`/`confirmed`.

    /// One `calendarEvents` observation: the soonest date (same min-epoch as `parseEarningsDate`),
    /// the range's upper bound when Yahoo supplied two dates (nil for a single date), and whether
    /// Yahoo itself flags the date as an estimate.
    nonisolated struct EarningsCalendarInfo: Sendable, Equatable {
        let date: Date
        let dateRangeEnd: Date?
        let isEstimate: Bool
    }

    nonisolated enum CalendarFetch: Sendable { case answered(EarningsCalendarInfo?), unavailable }

    /// Same call as `fetchNextEarningsOutcome`, richer answer. Kept as a SEPARATE function (not a
    /// signature change to the original) so pipeline-1's `EarningsFetch`/`fetchNextEarningsOutcome`
    /// and every test pinned to them are untouched.
    static func fetchEarningsCalendarOutcome(for symbol: String) async -> CalendarFetch {
        guard ToolPolicy.isExternalAllowed else { return .unavailable }
        guard StockSageAllocation.assetClass(symbol) == "Equity" else { return .unavailable }
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(encoded)?modules=calendarEvents")
        else { return .unavailable }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let data = await get(req) else { return .unavailable }
        return .answered(parseEarningsCalendar(data))
    }

    /// Parses `earningsDate` (min = `date`, max = `dateRangeEnd` when a genuine 2-element range;
    /// a single-element array leaves `dateRangeEnd` nil rather than duplicating `date` into it) and
    /// `isEarningsDateEstimate` (defaults to `true` — Yahoo doesn't always populate the flag, and
    /// an unconfirmed date is the SAFER default than a false "confirmed").
    nonisolated static func parseEarningsCalendar(_ data: Data) -> EarningsCalendarInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qs = root["quoteSummary"] as? [String: Any],
              let results = qs["result"] as? [[String: Any]],
              let first = results.first,
              let cal = first["calendarEvents"] as? [String: Any],
              let earnings = cal["earnings"] as? [String: Any],
              let dates = earnings["earningsDate"] as? [[String: Any]] else { return nil }
        let epochs = dates.compactMap { $0["raw"] as? Double }.filter { $0 > 0 }.sorted()
        guard let soonest = epochs.first else { return nil }
        let rangeEnd = epochs.count >= 2 ? epochs.last : nil
        let isEstimate = (earnings["isEarningsDateEstimate"] as? Bool) ?? true
        return EarningsCalendarInfo(date: Date(timeIntervalSince1970: soonest),
                                    dateRangeEnd: rangeEnd.map { Date(timeIntervalSince1970: $0) },
                                    isEstimate: isEstimate)
    }

    // MARK: - Tadawul projection source: Yahoo `earningsHistory`
    //
    // EODHD has no Tadawul coverage at any tier (StockSageEODHD.swift's own measured gap), so a
    // `.SR` equity's only candidate projection source is Yahoo's own past-earnings module.
    // UNVERIFIED LIVE (2026-09-06): Yahoo's keyless endpoint was 429-rate-limited on this Mac's IP
    // all day (research_earnings_sources_2026-09-06.md), so a live probe of a `.SR` symbol's
    // `earningsHistory` module could not be confirmed this session. Written defensively against
    // Yahoo's documented `quoteSummary?modules=earningsHistory` shape (`earningsHistory.history`:
    // an array of `{quarter: {raw: epoch}, ...}`) — if Tadawul carries no such module, or the
    // request never lands, this returns `nil` (UNAVAILABLE — never asked) and the chain correctly
    // falls through to `.unchecked` with a SAHMK TODO, never a guess. `nil` also distinguishes
    // "never answered" from "answered, empty" (blocker fix 2026-09-06 — this used to return `[]`
    // identically for both, letting the caller wrongly count an unreachable provider as asked).
    static func fetchEarningsHistory(for symbol: String) async -> [Date]? {
        guard ToolPolicy.isExternalAllowed else { return nil }
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(encoded)?modules=earningsHistory")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        guard let data = await get(req) else { return nil }
        return parseEarningsHistory(data)
    }

    /// Past fiscal QUARTER-END dates, oldest-first — Yahoo's `earningsHistory.history[].quarter`
    /// is the PERIOD a report covers (e.g. the quarter ended 2026-06-30), NOT the announcement
    /// date; this module carries no announcement date at all (major fix 2026-09-06: the field was
    /// previously documented ambiguously as "past report dates", which let a projection built off
    /// these dates get labelled "reports" in its basis string — systematically early by the whole
    /// reporting lag, typically 3-6 weeks, while claiming to be projected from prior REPORTS. See
    /// `StockSageCatalystChain.resolve`'s `historyUnitLabel`, which the store sets to "quarter
    /// ends" for exactly this source). Malformed/missing rows are skipped, never guessed.
    nonisolated static func parseEarningsHistory(_ data: Data) -> [Date] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qs = root["quoteSummary"] as? [String: Any],
              let results = qs["result"] as? [[String: Any]],
              let first = results.first,
              let hist = first["earningsHistory"] as? [String: Any],
              let rows = hist["history"] as? [[String: Any]] else { return [] }
        let epochs = rows.compactMap { row -> Double? in
            (row["quarter"] as? [String: Any])?["raw"] as? Double
        }.filter { $0 > 0 }
        return epochs.sorted().map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Pacing + exponential backoff (W1, 2026-09-06)
    //
    // Yahoo's keyless endpoint is 429/503-rate-limiting this Mac's IP as of today (STANDING
    // RULES). A single fixed-delay retry (StockSageQuoteService.get's ~1.5s) isn't enough headroom
    // for a sustained throttle — this is a genuine EXPONENTIAL backoff (1s, then 2s) between up to
    // 3 attempts total, never a tight loop, and gives up (nil) on any other status or transport error.
    private nonisolated static func get(_ req: URLRequest) async -> Data? {
        for attempt in 0..<3 {
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if (code == 429 || code == 503), attempt < 2 {
                let seconds = pow(2.0, Double(attempt))   // 1, 2 (attempt 0, 1) — 3rd attempt never sleeps again
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continue
            }
            return nil
        }
        return nil
    }
}
