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
    /// `.answered(date)` — a valid complete calendar response; `date` is nil for an explicit
    /// empty date array. `.unavailable` — no usable observation was made at
    /// all; the caller must NOT stamp anything (honesty floor: unknown stays unknown).
    enum EarningsFetch: Sendable { case answered(Date?), unavailable }

    /// Best-effort next-earnings date via Yahoo quoteSummary `calendarEvents`.
    /// Equities only (FX/crypto/index have no earnings — `.unavailable`, never stamped as
    /// "checked"); `.unavailable` when access is off or the request never got a 200 back — the
    /// warning simply doesn't appear, never blocks.
    static func fetchNextEarningsOutcome(for symbol: String) async -> EarningsFetch {
        switch await fetchEarningsCalendarOutcome(for: symbol) {
        case .answered(let info): return .answered(info?.date)
        case .unavailable: return .unavailable
        }
    }

    /// Parse the soonest earnings epoch from a quoteSummary `calendarEvents` body.
    nonisolated static func parseEarningsDate(_ data: Data) -> Date? {
        parseEarningsCalendar(data)?.date
    }

    // MARK: - W1 (2026-09-06): the date RANGE + the provider's own estimate flag
    //
    // Both legacy and richer fetches share the validated outcome. Optional convenience
    // parsers remain for display/tests; they must not be re-wrapped as a successful fetch.

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
        return parseCalendarOutcome(data)
    }

    /// Parses `earningsDate` (min = `date`, max = `dateRangeEnd` when a genuine 2-element range;
    /// a single-element array leaves `dateRangeEnd` nil rather than duplicating `date` into it) and
    /// `isEarningsDateEstimate` (defaults to `true` — Yahoo doesn't always populate the flag, and
    /// an unconfirmed date is the SAFER default than a false "confirmed").
    nonisolated static func parseEarningsCalendar(_ data: Data) -> EarningsCalendarInfo? {
        guard case .answered(let info) = parseCalendarOutcome(data) else { return nil }
        return info
    }

    /// Only a complete valid module can establish "checked, no date". Dropping a malformed
    /// range endpoint could hide an earlier event, so partial observations stay unavailable.
    nonisolated static func parseCalendarOutcome(_ data: Data) -> CalendarFetch {
        guard let cal = module(data, named: "calendarEvents"),
              let earnings = cal["earnings"] as? [String: Any],
              let dates = earnings["earningsDate"] as? [[String: Any]], dates.count <= 2 else { return .unavailable }
        let parsed = dates.compactMap { epoch($0["raw"]) }.sorted()
        guard parsed.count == dates.count else { return .unavailable }
        guard let soonest = parsed.first else { return .answered(nil) }
        let estimate = earnings["isEarningsDateEstimate"] as? NSNumber
        let isEstimate = estimate.map { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : true } ?? true
        return .answered(EarningsCalendarInfo(date: soonest,
                                              dateRangeEnd: parsed.count == 2 ? parsed.last : nil,
                                              isEstimate: isEstimate))
    }

    private nonisolated static func module(_ data: Data, named name: String) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil || root["error"] is NSNull,
              let qs = root["quoteSummary"] as? [String: Any],
              qs["error"] == nil || qs["error"] is NSNull,
              let results = qs["result"] as? [[String: Any]], results.count == 1 else { return nil }
        return results[0][name] as? [String: Any]
    }

    private nonisolated static func epoch(_ value: Any?) -> Date? {
        guard let seconds = StockSageMassive.finite(value), seconds > 0,
              seconds < Date.distantFuture.timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
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
    /// ends" for exactly this source). Missing/malformed/partial modules are unavailable;
    /// an explicit empty history array is a valid observation.
    nonisolated static func parseEarningsHistory(_ data: Data) -> [Date]? {
        guard let hist = module(data, named: "earningsHistory"),
              let rows = hist["history"] as? [[String: Any]] else { return nil }
        let dates = rows.compactMap { epoch(($0["quarter"] as? [String: Any])?["raw"]) }
        return dates.count == rows.count ? dates.sorted() : nil
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
