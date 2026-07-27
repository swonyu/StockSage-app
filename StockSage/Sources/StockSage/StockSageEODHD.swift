import Foundation

/// EODHD quote source — the authenticated feed for US names (owner-provided key, 2026-07-28).
///
/// WHY THIS EXISTS: the Yahoo chart endpoint is unauthenticated and rate-limits hard under a
/// 901-name scan (429/503), which is exactly how a symbol ends up displaying a days-old price.
/// EODHD is contractual: a paid key with a 100k/day allowance, so the US half of the universe
/// stops competing for anonymous quota.
///
/// COVERAGE — MEASURED 2026-07-28, not assumed:
///   • US (.US) — full real-time payload (open/high/low/close/volume/previousClose). WORKS.
///   • Tadawul (.SR) — NOT AVAILABLE AT ANY TIER. EODHD's exchange list for this account
///     carries 70 exchanges and no Saudi market (the only Middle East entry is Egypt). The
///     `2222.SAU`-style codes resolve but return literal "NA" for every field, and `.SR`
///     404s. Saudi names therefore stay on Yahoo — this is a vendor limitation, not a
///     configuration gap, and no upgrade fixes it.
///
/// KEY HANDLING: embedded because the owner confirmed this repository is private
/// (swonyu/StockSage-app). An @AppStorage override wins when set, so the key can be rotated
/// from Settings without a rebuild. If the repo ever goes public this constant must be pulled.
@MainActor
enum StockSageEODHD {

    /// Owner's key (private repo). Overridable at runtime via Settings.
    nonisolated static let embeddedKey = "6a48aed005ce91.66058292"

    /// UserDefaults key for a runtime override (Settings field on both platforms).
    nonisolated static let overrideDefaultsKey = "stocksage.eodhd.key"

    static var apiKey: String {
        let override = UserDefaults.standard.string(forKey: overrideDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? embeddedKey : override
    }

    /// Whether EODHD can serve this symbol. Deliberately a WHITELIST: only symbols we have
    /// MEASURED as covered route here. Everything else (.SR, FX, crypto, indices) stays on the
    /// existing source rather than silently returning nothing.
    nonisolated static func covers(_ symbol: String) -> Bool {
        let s = symbol.uppercased()
        // Suffixed foreign listings, FX pairs, crypto and index markers are out of scope.
        guard !s.contains("."), !s.contains("="), !s.contains("-"), !s.hasPrefix("^") else { return false }
        // A bare ticker in this app's universe is a US listing (Tadawul names carry .SR).
        return !s.isEmpty && s.allSatisfy { $0.isLetter }
    }

    /// EODHD's symbol form for a US ticker.
    nonisolated static func eodhdSymbol(_ symbol: String) -> String { symbol.uppercased() + ".US" }

    /// Parsed real-time payload. Returns nil when the response is missing, malformed, or the
    /// "NA" placeholder EODHD emits for an exchange outside the subscription — never a guess.
    static func parseRealTime(_ data: Data, requestedSymbol: String) -> StockSageQuoteService.LiveQuote? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Every numeric field arrives as a number OR the string "NA".
        func num(_ key: String) -> Double? {
            if let d = obj[key] as? Double { return d }
            if let i = obj[key] as? Int { return Double(i) }
            return nil                      // "NA" (String) lands here → treated as absent
        }
        guard let close = num("close"), close > 0 else { return nil }
        let prev = num("previousClose") ?? close
        let marketTime = num("timestamp").map { Date(timeIntervalSince1970: $0) }
        return StockSageQuoteService.LiveQuote(symbol: requestedSymbol, price: close,
                                               previousClose: prev, marketTime: marketTime,
                                               isNewListing: false)
    }

    /// Fetch one US symbol. nil on any failure so the caller can fall back to Yahoo.
    static func fetchOne(_ symbol: String) async -> StockSageQuoteService.LiveQuote? {
        guard covers(symbol) else { return nil }
        let key = apiKey
        guard !key.isEmpty,
              let url = URL(string: "https://eodhd.com/api/real-time/\(eodhdSymbol(symbol))?api_token=\(key)&fmt=json")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseRealTime(data, requestedSymbol: symbol)
    }
}
