import Foundation

// MARK: - Journal CSV import
//
// Round-trips exactly what StockSageJournalCSV.csv(...) exports (same header, same 11
// columns, same RFC-4180 escaping, same ISO8601 dates). Pure parser — never touches the
// store; the caller decides what to do with the result. HONESTY FLOOR: a row that doesn't
// parse is never silently dropped — it comes back as a rowError the UI must show.

/// One imported trade's provenance: a fresh id (ids are per-store, never carried across a
/// CSV) and whether it collided with an existing journal trade.
struct ImportPreview: Sendable, Equatable {
    let trades: [TradeRecord]
    let imported: Int
    let skipped: Int
    let errors: [(line: Int, reason: String)]

    static func == (lhs: ImportPreview, rhs: ImportPreview) -> Bool {
        lhs.trades == rhs.trades && lhs.imported == rhs.imported && lhs.skipped == rhs.skipped
            && lhs.errors.count == rhs.errors.count
            && zip(lhs.errors, rhs.errors).allSatisfy { $0.line == $1.line && $0.reason == $1.reason }
    }
}

enum StockSageJournalCSVImport {
    /// `line` is 1-based over the RAW input lines (header = line 1), matching what a user
    /// sees if they open the file in a text editor / the row number Excel would report.
    static func parse(_ csv: String, existing: [TradeRecord] = []) -> (trades: [TradeRecord], rowErrors: [(line: Int, reason: String)]) {
        let rawRows = splitRFC4180(csv)
        guard let headerRow = rawRows.first else { return ([], [(1, "empty file")]) }
        guard headerRow.joined(separator: ",") == StockSageJournalCSV.header else {
            return ([], [(1, "header doesn't match the export format — expected: \(StockSageJournalCSV.header)")])
        }

        let iso = ISO8601DateFormatter()
        // Dedup key for existing trades: (symbol, side, entry, shares, openedAt-to-the-minute).
        let existingKeys = Set(existing.map { dupeKey(symbol: $0.symbol, side: $0.side, entry: $0.entry, shares: $0.shares, openedAt: $0.openedAt) })

        var trades: [TradeRecord] = []
        var errors: [(line: Int, reason: String)] = []

        for (i, fields) in rawRows.dropFirst().enumerated() {
            let line = i + 2   // 1-based, +1 for the header row already consumed
            guard fields.count == 11 else {
                errors.append((line, "expected 11 columns, found \(fields.count)"))
                continue
            }
            let symbol = fields[0].trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { errors.append((line, "symbol is blank")); continue }
            guard let side = TradeRecord.Side(rawValue: fields[1]) else {
                errors.append((line, "side must be \"Long\" or \"Short\", found \"\(fields[1])\"")); continue
            }
            guard let entry = StockSageInput.positiveAmount(fields[2]) else {
                errors.append((line, "entry must be a positive number, found \"\(fields[2])\"")); continue
            }
            guard let stop = StockSageInput.positiveAmount(fields[3]) else {
                errors.append((line, "stop must be a positive number, found \"\(fields[3])\"")); continue
            }
            let target: Double?
            if fields[4].isEmpty {
                target = nil
            } else if let t = StockSageInput.positiveAmount(fields[4]) {
                target = t
            } else {
                errors.append((line, "target must be blank or a positive number, found \"\(fields[4])\"")); continue
            }
            guard let shares = StockSageInput.positiveAmount(fields[5]) else {
                errors.append((line, "shares must be a positive number, found \"\(fields[5])\"")); continue
            }
            guard !fields[6].isEmpty, let openedAt = iso.date(from: fields[6]) else {
                errors.append((line, "openedAt must be a valid ISO8601 date, found \"\(fields[6])\"")); continue
            }
            let exitPrice: Double?
            if fields[7].isEmpty {
                exitPrice = nil
            } else if let e = StockSageInput.positiveAmount(fields[7]) {
                exitPrice = e
            } else {
                errors.append((line, "exitPrice must be blank or a positive number, found \"\(fields[7])\"")); continue
            }
            let closedAt: Date?
            if fields[8].isEmpty {
                closedAt = nil
            } else if let c = iso.date(from: fields[8]) {
                closedAt = c
            } else {
                errors.append((line, "closedAt must be blank or a valid ISO8601 date, found \"\(fields[8])\"")); continue
            }
            // fields[9] (realizedR) is DERIVED (TradeRecord.realizedR reads exitPrice/entry/stop
            // live) — never stored, so it's read only for a sanity mismatch, not assigned.
            let note = fields[10].isEmpty ? nil : fields[10]

            let key = dupeKey(symbol: symbol, side: side, entry: entry, shares: shares, openedAt: openedAt)
            if existingKeys.contains(key) {
                errors.append((line, "duplicate of existing trade — skipped"))
                continue
            }

            trades.append(TradeRecord(symbol: symbol, side: side, entry: entry, stop: stop, target: target,
                                      shares: shares, openedAt: openedAt, exitPrice: exitPrice, closedAt: closedAt,
                                      note: note))
        }
        return (trades, errors)
    }

    /// Same as `parse(_:existing:)` but wrapped as an `ImportPreview` for the UI's confirmation alert.
    static func preview(_ csv: String, existing: [TradeRecord] = []) -> ImportPreview {
        let (trades, errors) = parse(csv, existing: existing)
        return ImportPreview(trades: trades, imported: trades.count, skipped: errors.count, errors: errors)
    }

    private static func dupeKey(symbol: String, side: TradeRecord.Side, entry: Double, shares: Double, openedAt: Date) -> String {
        // "to-the-minute" — truncate the timestamp's seconds.
        let minuteEpoch = (openedAt.timeIntervalSince1970 / 60).rounded(.down)
        return "\(symbol.uppercased())|\(side.rawValue)|\(entry)|\(shares)|\(minuteEpoch)"
    }

    /// RFC-4180 row splitter: handles quoted fields containing commas, doubled quotes, and
    /// embedded newlines (CR, LF, CRLF) — a naive `.split(separator: "\n")` would break a
    /// multi-line quoted note into multiple fake rows.
    private static func splitRFC4180(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(csv)
        var i = 0
        var sawAnyContent = false

        func endField() { fields.append(field); field = "" }
        func endRow() { endField(); rows.append(fields); fields = [] }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue
                    }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1; continue
            }
            switch c {
            case "\"":
                inQuotes = true; sawAnyContent = true; i += 1
            case ",":
                sawAnyContent = true; endField(); i += 1
            case "\r":
                sawAnyContent = true
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRow(); i += 1
            case "\n":
                sawAnyContent = true; endRow(); i += 1
            default:
                sawAnyContent = true; field.append(c); i += 1
            }
        }
        // Trailing row with no terminating newline.
        if sawAnyContent, !field.isEmpty || !fields.isEmpty { endRow() }
        return rows
    }
}
