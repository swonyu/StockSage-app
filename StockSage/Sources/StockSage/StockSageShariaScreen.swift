import Foundation

// MARK: - Sharia business-activity screen (COARSE — exclusion only, NOT certification)
//
// Owner request (2026-07-23): "make NASDAQ stocks only Sharia-compliant." A TRUE compliance
// determination has two legs — a business-activity screen AND a quarterly financial-ratio screen
// (debt / market-cap, interest-bearing securities, non-compliant income vs an AAOIFI-style
// threshold). This app has FREE, keyless PRICE data only — NO fundamentals — so the financial-ratio
// leg is IMPOSSIBLE here, and a stock's status genuinely FLIPS quarter to quarter on those ratios.
//
// Therefore this is deliberately NOT a "halal list." It is a one-directional EXCLUSION: it removes
// names whose CORE BUSINESS is unambiguously prohibited (conventional banks/insurers, alcohol,
// tobacco, gambling, adult content, pork, conventional-defense primes). Everything it does NOT
// exclude is returned as `.unscreened` — meaning "not on the prohibited list," which is NOT the same
// as cleared. The owner MUST verify each name against a real authority (their bank's Islamic screen,
// an S&P/DJ or MSCI Islamic index, or a certified app like Zoya / Musaffa / IdealRatings) before
// trading. Every surface that uses this MUST say so — mislabelling a stock as compliant is a
// religious harm, not a cosmetic bug (honesty floor).
//
// The prohibited set is a CURATED static list of well-known NASDAQ-listed tickers — it cannot be
// exhaustive over ~872 names, so an unrecognised prohibited business will read `.unscreened`. That is
// the screen's KNOWN CEILING (ponytail): it reliably removes the obvious, never certifies the rest.
enum StockSageShariaScreen {

    /// The screen's verdict for one symbol. There is deliberately NO `.compliant` case — this screen
    /// can only ever say "known-prohibited" or "not on the list"; it never certifies compliance.
    enum Verdict: String, Sendable, Equatable {
        case prohibited   // core business is unambiguously non-compliant → excluded
        case unscreened   // not on the prohibited list — NOT cleared; verify with a real authority
    }

    /// Why a name is prohibited (shown to the owner so the exclusion is auditable, not a black box).
    enum Reason: String, Sendable, Equatable, CaseIterable {
        case conventionalFinance = "Conventional bank / lender (riba)"
        case insurance           = "Conventional insurance (gharar/riba)"
        case alcohol             = "Alcohol"
        case tobacco             = "Tobacco / vaping"
        case gambling            = "Gambling / casinos"
        case adult               = "Adult entertainment"
        case pork                = "Pork / non-halal food"
        case defense             = "Defense / weapons prime"
        case cannabis            = "Cannabis"
    }

    /// Curated, AUDITABLE set of well-known NASDAQ-listed tickers whose CORE business is prohibited.
    /// Keyed by uppercased ticker. Not exhaustive — see the file header's known-ceiling note. Kept in
    /// one literal so the owner (or a reviewer) can read exactly what is excluded and why.
    nonisolated static let prohibited: [String: Reason] = [
        // Conventional banks & lenders on NASDAQ (interest-based core business).
        "FITB": .conventionalFinance, "USB": .conventionalFinance, "PNC": .conventionalFinance,
        "TFC": .conventionalFinance, "MTB": .conventionalFinance, "FFIN": .conventionalFinance,
        "CLBK": .conventionalFinance, "NTRS": .conventionalFinance, "CBSH": .conventionalFinance,
        "COLB": .conventionalFinance, "ONB": .conventionalFinance, "WBS": .conventionalFinance,
        "ZION": .conventionalFinance, "GBCI": .conventionalFinance, "FHN": .conventionalFinance,
        "SOFI": .conventionalFinance, "ALLY": .conventionalFinance, "SLM": .conventionalFinance,
        "NAVI": .conventionalFinance, "COF": .conventionalFinance, "SYF": .conventionalFinance,
        // Insurance.
        "PGR": .insurance, "CINF": .insurance, "ERIE": .insurance, "KNSL": .insurance,
        // Alcohol.
        "SAM": .alcohol, "STZ": .alcohol, "TAP": .alcohol, "BUD": .alcohol,
        // Tobacco / vaping.
        "PM": .tobacco, "MO": .tobacco, "TPB": .tobacco,
        // Gambling / casinos.
        "DKNG": .gambling, "PENN": .gambling, "CZR": .gambling, "WYNN": .gambling,
        "MGM": .gambling, "RSI": .gambling, "GDEN": .gambling, "BYD": .gambling,
        // Adult / non-compliant media.
        "RICK": .adult,
        // Cannabis.
        "TLRY": .cannabis, "CGC": .cannabis, "SNDL": .cannabis,
        // Pork / non-halal food processors.
        "HRL": .pork, "TSN": .pork,
    ]

    /// The screen verdict for a symbol. `.SR` (Tadawul) names pass through as `.unscreened` — the
    /// screen only exists for the NASDAQ leg (Tadawul has its own Sharia landscape the owner tracks
    /// separately); a non-NASDAQ symbol is never falsely marked prohibited by this NASDAQ list.
    nonisolated static func verdict(_ symbol: String) -> Verdict {
        prohibited[symbol.uppercased()] == nil ? .unscreened : .prohibited
    }

    /// True when the symbol is on the known-prohibited list. Convenience for filter predicates.
    nonisolated static func isProhibited(_ symbol: String) -> Bool {
        prohibited[symbol.uppercased()] != nil
    }

    /// The prohibition reason, if any (nil ⇒ not on the list ⇒ unscreened, NOT cleared).
    nonisolated static func reason(_ symbol: String) -> Reason? {
        prohibited[symbol.uppercased()]
    }

    /// The MANDATORY disclosure any surface using this screen must show. States plainly that this is a
    /// coarse exclusion, not certification, and that unrecognised names are unscreened, not cleared.
    nonisolated static let caveat =
        "Coarse Sharia screen: EXCLUDES known-prohibited NASDAQ businesses (conventional finance, "
        + "alcohol, tobacco, gambling, etc.) only. It does NOT run the financial-ratio screen "
        + "(debt/market-cap, interest income) — the app has no fundamentals data for that, and those "
        + "ratios flip quarterly. A name that is NOT excluded is UNSCREENED, not certified compliant. "
        + "Verify every name against a real authority (your bank's Islamic screen, an S&P/DJ or MSCI "
        + "Islamic index, or a certified app) before trading. Not a fatwa; not financial advice."
}
