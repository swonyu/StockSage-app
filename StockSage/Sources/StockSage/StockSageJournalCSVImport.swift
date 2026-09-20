import Foundation

// MARK: - Journal CSV import
//
// Imports StockSageJournalCSV's 11-column interchange format with RFC-4180 escaping
// and ISO8601 dates. CSV omits IDs and extra journal metadata; use JSON for backups.
// Pure parser — never touches the store; the caller decides what to do with the result.
// HONESTY FLOOR: a row that doesn't
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
    /// `line` is the record's 1-based starting physical file line (header = line 1),
    /// including newlines inside quoted fields, matching a text editor rather than Excel rows.
    static func parse(_ csv: String, existing: [TradeRecord] = []) -> (trades: [TradeRecord], rowErrors: [(line: Int, reason: String)]) {
        let rawRows = splitRFC4180(csv)
        guard let headerRow = rawRows.first else { return ([], [(1, "empty file")]) }
        guard headerRow.error == nil,
              headerRow.fields == StockSageJournalCSV.header.components(separatedBy: ",") else {
            return ([], [(1, "header doesn't match the export format — expected: \(StockSageJournalCSV.header)")])
        }

        let iso = ISO8601DateFormatter()
        // CSV has no record IDs. Match complete exported rows with multiplicity:
        // repeated imports are idempotent, but separate identical executions survive.
        var existingCounts = Dictionary(grouping: existing, by: { dupeKey($0, iso: iso) }).mapValues(\.count)

        var trades: [TradeRecord] = []
        var errors: [(line: Int, reason: String)] = []

        for row in rawRows.dropFirst() {
            let line = row.line, fields = row.fields
            if let error = row.error { errors.append((line, error)); continue }
            guard fields.count == 11 else {
                errors.append((line, "expected 11 columns, found \(fields.count)"))
                continue
            }
            let symbol = fields[0].trimmingCharacters(in: .whitespaces)
            guard !symbol.isEmpty else { errors.append((line, "symbol is blank")); continue }
            guard let side = TradeRecord.Side(rawValue: fields[1]) else {
                errors.append((line, "side must be \"Long\" or \"Short\", found \"\(fields[1])\"")); continue
            }
            guard let entry = positiveCSVNumber(fields[2]) else {
                errors.append((line, "entry must be a positive number, found \"\(fields[2])\"")); continue
            }
            guard let stop = positiveCSVNumber(fields[3]) else {
                errors.append((line, "stop must be a positive number, found \"\(fields[3])\"")); continue
            }
            let target: Double?
            if fields[4].isEmpty {
                target = nil
            } else if let t = positiveCSVNumber(fields[4]) {
                target = t
            } else {
                errors.append((line, "target must be blank or a positive number, found \"\(fields[4])\"")); continue
            }
            guard let shares = positiveCSVNumber(fields[5]) else {
                errors.append((line, "shares must be a positive number, found \"\(fields[5])\"")); continue
            }
            guard !fields[6].isEmpty, let openedAt = iso.date(from: fields[6]) else {
                errors.append((line, "openedAt must be a valid ISO8601 date, found \"\(fields[6])\"")); continue
            }
            let exitPrice: Double?
            if fields[7].isEmpty {
                exitPrice = nil
            } else if let e = positiveCSVNumber(fields[7]) {
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
            // fields[9] (realizedR) is DERIVED from accepted exit/entry/stop values;
            // ignore the incoming text, never store it as an asserted performance figure.
            let note = fields[10].isEmpty ? nil : fields[10]

            let trade = TradeRecord(symbol: symbol, side: side, entry: entry, stop: stop, target: target,
                                    shares: shares, openedAt: openedAt, exitPrice: exitPrice, closedAt: closedAt,
                                    note: note)
            if let error = trade.closureError { errors.append((line, error)); continue }
            let key = dupeKey(trade, iso: iso)
            if let remaining = existingCounts[key], remaining > 0 {
                existingCounts[key] = remaining - 1
                errors.append((line, Self.duplicateReason)); continue
            }
            trades.append(trade)
        }
        return (trades, errors)
    }

    /// The one row-error reason that is an intentional skip, not a failure — shared between
    /// parse()'s append and preview()'s partition so the two can never drift.
    static let duplicateReason = "matches an existing exported trade row — skipped"

    /// CSV must accept String(Double)'s decimal exponents without loosening human-input
    /// rules. Keep the existing unambiguous comma policy; never admit hex, NaN or infinity.
    private static func positiveCSVNumber(_ raw: String) -> Double? {
        if let value = StockSageInput.positiveAmount(raw) { return value }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)[eE][+-]?[0-9]+$"#,
                         options: .regularExpression) != nil,
              let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Same as `parse(_:existing:)` but wrapped as an `ImportPreview` for the UI's confirmation
    /// alert. Duplicates are intentional SKIPS, failures are FAILURES — partitioned so the UI's
    /// "skipped N duplicates" and "M rows failed" count disjoint sets (review fix 2026-07-16:
    /// `skipped` was errors.count, so every parse failure displayed as a fabricated "duplicate"
    /// and every duplicate double-reported as a "failed row").
    static func preview(_ csv: String, existing: [TradeRecord] = []) -> ImportPreview {
        let (trades, rowErrors) = parse(csv, existing: existing)
        let dupes = rowErrors.filter { $0.reason == duplicateReason }
        let failures = rowErrors.filter { $0.reason != duplicateReason }
        return ImportPreview(trades: trades, imported: trades.count, skipped: dupes.count, errors: failures)
    }

    private static func dupeKey(_ trade: TradeRecord, iso: ISO8601DateFormatter) -> [String] {
        [trade.symbol.uppercased(), trade.side.rawValue, String(trade.entry), String(trade.stop),
         trade.target.map { String($0) } ?? "", String(trade.shares), iso.string(from: trade.openedAt),
         trade.exitPrice.map { String($0) } ?? "", trade.closedAt.map { iso.string(from: $0) } ?? "",
         trade.note ?? ""]
    }

    /// RFC-4180 row splitter: handles quoted fields containing commas, doubled quotes, and
    /// embedded newlines (CR, LF, CRLF) — a naive `.split(separator: "\n")` would break a
    /// multi-line quoted note into multiple fake rows.
    private static func splitRFC4180(_ csv: String) -> [(line: Int, fields: [String], error: String?)] {
        var rows: [(line: Int, fields: [String], error: String?)] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var closedQuote = false
        var rowError: String?
        let chars = Array(csv)
        var i = 0
        var sawAnyContent = false
        var physicalLine = 1, rowStart = 1

        func endField() { fields.append(field); field = ""; closedQuote = false }
        func endRow() {
            endField(); rows.append((rowStart, fields, rowError))
            fields = []; rowError = nil; rowStart = physicalLine
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\r" || c == "\n" || c == "\r\n" { physicalLine += 1 }
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 2; continue
                    }
                    inQuotes = false; closedQuote = true; i += 1; continue
                }
                field.append(c); i += 1; continue
            }
            switch c {
            case "\"":
                if field.isEmpty && !closedQuote { inQuotes = true }
                else { rowError = "unexpected quote in an unquoted field" }
                sawAnyContent = true; i += 1
            case ",":
                sawAnyContent = true; endField(); i += 1
            case "\r", "\n", "\r\n":
                // Swift treats CRLF as ONE extended-grapheme Character.
                sawAnyContent = true; endRow(); i += 1
            default:
                if closedQuote { rowError = "unexpected text after a closing quote" }
                sawAnyContent = true; field.append(c); i += 1
            }
        }
        // Trailing row with no terminating newline.
        if inQuotes { rowError = "unterminated quoted field" }
        if sawAnyContent, !field.isEmpty || !fields.isEmpty || inQuotes || closedQuote { endRow() }
        return rows
    }
}
