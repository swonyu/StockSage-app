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
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unavailable }
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
}
