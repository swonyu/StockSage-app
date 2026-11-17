import Foundation

// MARK: - Sector tags
//
// Asset-class concentration is coarse — a book of 8 different "Equity" names can
// still be 8 ways to bet on semiconductors. This tags the universe's well-known
// US names with a GICS-style sector so concentration can be read by industry too.
// Honest about coverage: a curated static map (not a full classification service)
// — unmapped equities fall to "Other", and non-equities to their asset class.

enum StockSageSector {
    nonisolated static func sector(_ symbol: String) -> String {
        if let s = map[symbol.uppercased()] { return s }
        switch StockSageAllocation.assetClass(symbol) {
        case "Crypto": return "Crypto"
        case "Forex":  return "Forex"
        case "Index":  return "Index"
        default:       return "Other"
        }
    }

    private nonisolated static let map: [String: String] = [
        // Technology
        "AAPL": "Technology", "MSFT": "Technology", "NVDA": "Technology", "GOOGL": "Technology",
        "GOOG": "Technology", "META": "Technology", "AVGO": "Technology", "ORCL": "Technology",
        "CRM": "Technology", "ADBE": "Technology", "AMD": "Technology", "INTC": "Technology",
        "CSCO": "Technology", "QCOM": "Technology", "TXN": "Technology", "IBM": "Technology",
        // Consumer
        "AMZN": "Consumer", "TSLA": "Consumer", "HD": "Consumer", "MCD": "Consumer", "NKE": "Consumer",
        "SBUX": "Consumer", "WMT": "Consumer", "COST": "Consumer", "PG": "Consumer", "KO": "Consumer",
        "PEP": "Consumer", "TGT": "Consumer",
        // Financials
        "JPM": "Financials", "BAC": "Financials", "WFC": "Financials", "GS": "Financials",
        "MS": "Financials", "C": "Financials", "BRK-B": "Financials", "V": "Financials",
        "MA": "Financials", "AXP": "Financials", "BLK": "Financials",
        // Healthcare
        "JNJ": "Healthcare", "UNH": "Healthcare", "LLY": "Healthcare", "PFE": "Healthcare",
        "MRK": "Healthcare", "ABBV": "Healthcare", "TMO": "Healthcare", "ABT": "Healthcare",
        // Energy
        "XOM": "Energy", "CVX": "Energy", "COP": "Energy", "SLB": "Energy",
        // Industrials
        "BA": "Industrials", "CAT": "Industrials", "GE": "Industrials", "HON": "Industrials", "UPS": "Industrials",
        // Communication
        "NFLX": "Communication", "T": "Communication", "VZ": "Communication", "CMCSA": "Communication", "DIS": "Communication",
    ]
}
