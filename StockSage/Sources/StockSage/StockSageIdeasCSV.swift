import Foundation

// MARK: - Ideas board CSV export
//
// Renders the ranked Trade-Ideas board as CSV (RFC-4180 quoting; LF line endings,
// which Excel / Sheets / Python all accept) so the board isn't trapped in the app.
// Pure + tested. `rank` reflects
// the on-screen order of the list passed in (already sorted by the chosen metric).
// Rationale bullets are joined with "; " and the whole field is CSV-escaped, so a
// comma or quote inside a reason can't corrupt the file.
enum StockSageIdeasCSV {
    nonisolated static let header =
        "rank,symbol,market,price,action,conviction,stop,target,weightPct,regime,rationale,heldShares,closedTrades,priceAsOf"

    /// EXPORT-04: optional held/journal context so the exported spreadsheet doesn't lose the
    /// doubling flag the on-screen card/sheet already carry. Keyed by uppercased symbol, same
    /// convention as StockSagePortfolio.holdingBySymbol / StockSageJournal.historyBySymbol —
    /// callers pass those batch dicts straight through. Defaulted to [:] so existing
    /// tests/callers are unchanged.
    nonisolated static func csv(
        _ ideas: [StockSageIdea],
        heldShares: [String: Double] = [:],
        closedTrades: [String: Int] = [:]
    ) -> String {
        var rows = [header]
        for (i, idea) in ideas.enumerated() {
            let a = idea.advice
            let sym = idea.symbol.uppercased()
            var f: [String] = []
            f.append(String(i + 1))
            f.append(idea.symbol)
            f.append(idea.market)
            f.append(String(idea.price))
            f.append(a.action.rawValue)
            // conviction/weight formatted to avoid float noise (0.12×100 = 12.000000002);
            // prices (price/stop/target) kept exact — don't round money.
            f.append(String(format: "%.2f", a.conviction))
            f.append(a.stopPrice.map { String($0) } ?? "")
            f.append(a.targetPrice.map { String($0) } ?? "")
            f.append(String(format: "%.1f", a.suggestedWeight * 100))
            f.append(a.regime.rawValue)
            f.append(a.rationale.joined(separator: "; "))
            f.append(heldShares[sym].map { String($0) } ?? "")
            f.append(closedTrades[sym].map { String($0) } ?? "")
            // A2: price-freshness column — the price bar's own UTC date (yyyy-MM-dd, GMT), so a
            // cache-served prior-day close isn't pasted into a spreadsheet as if it were live
            // (parity with every other broker-pasteable export's PRICE-NOT-LIVE flag). nil ⇒
            // empty (unknown, never a fabricated date — HONESTY_FLOOR).
            f.append(idea.priceAsOf.map { $0.formatted(.iso8601.year().month().day()) } ?? "")
            rows.append(f.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// RFC-4180: a field containing a comma, quote, CR or LF is wrapped in double
    /// quotes, with any internal double-quote doubled.
    nonisolated static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
