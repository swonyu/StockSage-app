import Foundation

// MARK: - Journal CSV export
//
// The owner's trade record shouldn't be trapped in the app — this renders the
// journal as standard RFC-4180 CSV (Excel / Sheets / Python-ready). Pure + tested.
// Notes are escaped correctly so a comma or quote in a note can't corrupt the file.

enum StockSageJournalCSV {
    nonisolated static let header =
        "symbol,side,entry,stop,target,shares,openedAt,exitPrice,closedAt,realizedR,note"

    nonisolated static func csv(_ trades: [TradeRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var rows = [header]
        for t in trades {
            var f: [String] = []
            f.append(t.symbol)
            f.append(t.side.rawValue)
            f.append(String(t.entry))
            f.append(String(t.stop))
            f.append(t.target.map { String($0) } ?? "")
            f.append(String(t.shares))
            f.append(iso.string(from: t.openedAt))
            f.append(t.exitPrice.map { String($0) } ?? "")
            f.append(t.closedAt.map { iso.string(from: $0) } ?? "")
            f.append(t.realizedR.map { String($0) } ?? "")
            f.append(t.note ?? "")
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
