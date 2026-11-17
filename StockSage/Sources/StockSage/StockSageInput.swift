import Foundation

// MARK: - Numeric input validation
//
// The UI parses free-text numeric fields (account size, risk %, journal prices, GE
// budget) with `Double(text) ?? 0` — so "abc", "1.2.3", a negative, or an out-of-range
// percent silently become 0/default and quietly produce a wrong $-estimate or P&L.
// These pure validators return nil on bad input so callers can show an honest hint
// instead of computing on a fabricated zero.
//
// F10 (comma policy — Saudi-first, owner-approved 2026-07-04): commas are GROUPING-AWARE,
// never blindly stripped (the old `replacingOccurrences(of: ",", with: "")` read the Saudi
// decimal "2,5" as 25 — a silent 10× risk error that passed the percent 100-cap):
//   • comma(s) forming valid thousands groups → thousands separator ("10,000"→10000,
//     "1,234.56"→1234.56, "1,234,567"→1234567);
//   • a single comma with 1–2 trailing digits and NO period → the Saudi decimal separator
//     ("2,5"→2.5, "12,34"→12.34) — a pattern US thousands never produces, so it is unambiguous;
//   • anything else (a comma in the decimals "1.000,50", a bad group "2,5000"/"1,23,45",
//     multiple periods) → nil (reject honestly rather than fabricate a number).

enum StockSageInput {
    nonisolated static func journalTargetIsValid(_ text: String, entry: Double, isLong: Bool) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let target = positiveAmount(text) else { return false }
        return isLong ? target > entry : target < entry
    }

    /// Numeric grammar checks use explicit separators after decimal-digit normalization.
    /// The original grouping-aware ASCII-comma policy remains separate from Arabic marks.
    private nonisolated static func matches(_ str: String, _ pat: String) -> Bool {
        str.range(of: pat, options: .regularExpression) != nil
    }

    /// Plain-decimal shape gate: optional sign, digits, at most one ".", optional decimal digits.
    /// `Double`/`Int` also parse C-style hex ("0x64"→100), binary/octal exponent forms ("0x1p4"→16),
    /// and other non-decimal notations Foundation accepts — this affirmatively requires the
    /// ordinary decimal shape BEFORE handing the string to Double()/Int(), so a hex string is
    /// rejected (nil) rather than silently returning a fabricated number.
    private nonisolated static func isPlainDecimal(_ s: String) -> Bool {
        matches(s, #"^[+-]?[0-9]*\.?[0-9]+$"#)
    }

    /// Convert only Unicode decimal digits (Nd), never superscript/circled/fraction
    /// numerals or compatibility characters. No NFKC or locale-dependent guessing.
    private nonisolated static func decimalDigits(_ text: String) -> String? {
        var normalized = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber {
                guard let digit = Character(String(scalar)).wholeNumberValue, (0...9).contains(digit) else { return nil }
                normalized += String(digit)
            } else {
                normalized.unicodeScalars.append(scalar)
            }
        }
        return normalized
    }

    private nonisolated static func clean(_ s: String) -> String? {
        guard let t = decimalDigits(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if t.contains("٫") || t.contains("٬") {
            // Arabic decimal/group marks have explicit meanings. Do not feed an
            // Arabic grouping mark through the owner's separate ASCII-comma rule.
            guard !t.contains(".") && !t.contains(",") else { return nil }
            let parts = t.split(separator: "٫", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 2 else { return nil }
            let integer = parts[0]
            let fraction = parts.count == 2 ? parts[1] : nil
            if let fraction, fraction.contains("٬") { return nil }
            let plainInteger: String
            if integer.contains("٬") {
                guard matches(integer, #"^[0-9]{1,3}(٬[0-9]{3})+$"#) else { return nil }
                plainInteger = integer.replacingOccurrences(of: "٬", with: "")
            } else { plainInteger = integer }
            let result = fraction.map { plainInteger + "." + $0 } ?? plainInteger
            return isPlainDecimal(result) ? result : nil
        }
        guard t.contains(",") else {
            return isPlainDecimal(t) ? t : nil
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }               // >1 period → malformed
        let intPart = parts[0]
        let fracPart = parts.count == 2 ? parts[1] : nil
        if let f = fracPart, f.contains(",") { return nil }      // comma in the decimals (EU-full) → reject
        if matches(intPart, #"^\d{1,3}(,\d{3})+$"#) {            // valid thousands grouping
            let stripped = intPart.replacingOccurrences(of: ",", with: "")
            let result = fracPart != nil ? stripped + "." + fracPart! : stripped
            return isPlainDecimal(result) ? result : nil
        }
        if fracPart == nil, matches(intPart, #"^\d+,\d{1,2}$"#) { // Saudi decimal-comma (no period, 1–2 digits)
            let result = intPart.replacingOccurrences(of: ",", with: ".")
            return isPlainDecimal(result) ? result : nil
        }
        return nil                                               // ambiguous comma usage → reject
    }

    /// A finite amount > 0 (money / budget / price). nil otherwise.
    nonisolated static func positiveAmount(_ s: String) -> Double? {
        guard let c = clean(s), let v = Double(c), v.isFinite, v > 0 else { return nil }
        return v
    }

    /// A finite amount >= 0 (cost basis — 0 is legal for gifted/granted shares, but it must be
    /// TYPED, never defaulted-in by a failed parse). nil on blank/unparseable/negative/non-finite.
    nonisolated static func nonNegativeAmount(_ s: String) -> Double? {
        guard let c = clean(s), let v = Double(c), v.isFinite, v >= 0 else { return nil }
        // Double can round a syntactically nonzero decimal down to zero. A real
        // nonzero cost must never become a gifted/free holding through underflow.
        guard v != 0 || !c.contains(where: { "123456789".contains($0) }) else { return nil }
        return v
    }

    /// A percent in (0, max]. nil otherwise (default cap 100). For Kelly / risk %.
    nonisolated static func percent(_ s: String, max: Double = 100) -> Double? {
        guard let c = clean(s), let v = Double(c), v.isFinite, v > 0, v <= max else { return nil }
        return v
    }

    /// A whole count > 0 (GE budget gp, share count). Rejects decimals + non-numbers.
    nonisolated static func positiveInt(_ s: String) -> Int? {
        guard let c = clean(s), let v = Int(c), v > 0 else { return nil }
        return v
    }
}
