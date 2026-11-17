import Foundation

// MARK: - Allocation breakdown (by asset class & region)
//
// Concentration is risk (MARKETS_INTELLIGENCE_RESEARCH.md §6): a book that's 90%
// one asset class or one country isn't diversified no matter how many tickers it
// holds. This maps each holding to its asset class and region (purely from the
// Yahoo symbol convention) and computes the % allocation by value. Pure + tested.

struct AllocationBreakdown: Sendable, Equatable {
    struct Slice: Sendable, Equatable, Identifiable {
        let label: String
        let value: Double
        let fraction: Double   // 0…1
        var id: String { label }
    }
    let byClass: [Slice]       // sorted desc by fraction
    let byRegion: [Slice]
    let totalValue: Double
    /// Largest single asset-class share — a one-glance concentration read.
    var topClassConcentration: Double { byClass.first?.fraction ?? 0 }
}

enum StockSageAllocation {
    /// Asset class from the Yahoo symbol convention: `^…` index, `…=X` forex,
    /// `…-USD` crypto, otherwise an equity.
    nonisolated static func assetClass(_ symbol: String) -> String {
        let s = symbol.uppercased()
        if s.hasPrefix("^") { return "Index" }
        if s.hasSuffix("=X") { return "Forex" }
        if s.hasSuffix("-USD") { return "Crypto" }
        return "Equity"
    }

    /// Region from the exchange suffix (`.SR` Saudi, `.L` UK, …); US for no suffix.
    /// FX/crypto are Global; indices are grouped as Index.
    nonisolated static func region(_ symbol: String) -> String {
        let s = symbol.uppercased()
        if s.hasPrefix("^") { return "Index" }
        if s.hasSuffix("=X") || s.hasSuffix("-USD") { return "Global" }
        if let dot = s.lastIndex(of: "."), s.index(after: dot) < s.endIndex {
            let suffix = String(s[s.index(after: dot)...])
            return regionForSuffix[suffix] ?? "Other"
        }
        return "United States"   // no suffix = US-listed
    }

    private nonisolated static let regionForSuffix: [String: String] = [
        "SR": "Saudi", "L": "UK", "DE": "Germany", "PA": "France", "T": "Japan",
        "HK": "Hong Kong", "SS": "China", "KS": "South Korea", "NS": "India",
        "AX": "Australia", "SA": "Brazil", "TO": "Canada", "SW": "Switzerland",
        "AS": "Netherlands", "MC": "Spain", "MI": "Italy", "ST": "Sweden",
        "AD": "UAE", "DU": "UAE", "QA": "Qatar", "CA": "Egypt", "JO": "South Africa",
        "TW": "Taiwan", "SI": "Singapore", "MX": "Mexico",
    ]

    /// A percentage safe for integer labels and the corresponding fraction safe
    /// for geometry. Invalid fractions stay unavailable instead of trapping or clamping.
    nonisolated static func percentage(_ fraction: Double) -> Int? {
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return Int(exactly: (fraction * 100).rounded())
    }

    /// Value-weighted slices. Finite zero/negative amounts retain the established
    /// long-exposure convention; invalid values or aggregates make the whole split
    /// unavailable. An empty/zero book is a valid empty array, not an arithmetic error.
    nonisolated static func slices(_ holdings: [(symbol: String, value: Double)],
                                   by key: (String) -> String) -> [AllocationBreakdown.Slice]? {
        guard holdings.allSatisfy({ $0.value.isFinite }) else { return nil }
        let total = holdings.reduce(0.0) { $0 + Swift.max($1.value, 0) }
        guard total.isFinite else { return nil }
        guard total > 0 else { return [] }
        var sums: [String: Double] = [:]
        for holding in holdings where holding.value > 0 {
            let label = key(holding.symbol)
            let sum = sums[label, default: 0] + holding.value
            guard sum.isFinite else { return nil }
            sums[label] = sum
        }
        var result: [AllocationBreakdown.Slice] = []
        for (label, value) in sums {
            let fraction = value / total
            guard fraction > 0, percentage(fraction) != nil else { return nil }
            result.append(.init(label: label, value: value, fraction: fraction))
        }
        return result.sorted { $0.fraction != $1.fraction ? $0.fraction > $1.fraction : $0.label < $1.label }
    }

    /// Allocation by class and region; nil means the complete supplied scope cannot
    /// be represented. Callers must display unavailable, not a fabricated empty book.
    nonisolated static func breakdown(_ holdings: [(symbol: String, value: Double)]) -> AllocationBreakdown? {
        guard let classes = slices(holdings, by: assetClass),
              let regions = slices(holdings, by: region) else { return nil }
        let total = holdings.reduce(0.0) { $0 + Swift.max($1.value, 0) }
        guard total.isFinite else { return nil }
        return AllocationBreakdown(byClass: classes, byRegion: regions, totalValue: total)
    }
}
