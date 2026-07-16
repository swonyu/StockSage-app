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

    /// Value-weighted % slices grouped by an arbitrary key (asset class, region,
    /// sector, …), sorted desc. Zero/negative-value holdings are dropped.
    nonisolated static func slices(_ holdings: [(symbol: String, value: Double)],
                                   by key: (String) -> String) -> [AllocationBreakdown.Slice] {
        let total = holdings.reduce(0.0) { $0 + Swift.max($1.value, 0) }
        var sums: [String: Double] = [:]
        for h in holdings where h.value > 0 { sums[key(h.symbol), default: 0] += h.value }
        return sums.map { AllocationBreakdown.Slice(label: $0.key, value: $0.value,
                                                    fraction: total > 0 ? $0.value / total : 0) }
            .sorted { $0.fraction != $1.fraction ? $0.fraction > $1.fraction : $0.label < $1.label }
    }

    /// Allocation by class and by region from (symbol, current value) holdings.
    nonisolated static func breakdown(_ holdings: [(symbol: String, value: Double)]) -> AllocationBreakdown {
        AllocationBreakdown(byClass: slices(holdings, by: assetClass),
                            byRegion: slices(holdings, by: region),
                            totalValue: holdings.reduce(0.0) { $0 + Swift.max($1.value, 0) })
    }
}
