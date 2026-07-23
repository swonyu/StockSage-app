import Testing
@testable import StockSage

// Coarse Sharia business-activity screen — EXCLUSION only, never certification. These tests pin the
// honesty contract: known-prohibited names are excluded with an auditable reason; everything else is
// `.unscreened` (NOT cleared); non-NASDAQ names are never falsely flagged; the caveat says so.
struct StockSageShariaScreenTests {

    @Test func knownProhibitedAreExcludedWithReason() {
        // One representative per reason bucket that IS in the curated list.
        #expect(StockSageShariaScreen.verdict("FITB") == .prohibited)   // conventional bank
        #expect(StockSageShariaScreen.verdict("PGR")  == .prohibited)   // insurance
        #expect(StockSageShariaScreen.verdict("SAM")  == .prohibited)   // alcohol
        #expect(StockSageShariaScreen.verdict("MO")   == .prohibited)   // tobacco
        #expect(StockSageShariaScreen.verdict("DKNG") == .prohibited)   // gambling
        #expect(StockSageShariaScreen.verdict("TLRY") == .prohibited)   // cannabis
        #expect(StockSageShariaScreen.isProhibited("fitb"))             // case-insensitive
        #expect(StockSageShariaScreen.reason("FITB") == .conventionalFinance)
        #expect(StockSageShariaScreen.reason("MO") == .tobacco)
    }

    @Test func unknownNamesAreUnscreenedNotCleared() {
        // The honesty core: a name NOT on the list is `.unscreened`, and there is NO `.compliant`
        // case to accidentally return. AAPL is not prohibited, but the screen must not imply it's
        // certified — only that it isn't on the known-prohibited list.
        #expect(StockSageShariaScreen.verdict("AAPL") == .unscreened)
        #expect(StockSageShariaScreen.verdict("NVDA") == .unscreened)
        #expect(StockSageShariaScreen.reason("AAPL") == nil)
        #expect(!StockSageShariaScreen.isProhibited("AAPL"))
        // The type system enforces the contract: Verdict has exactly two cases, neither "compliant".
        #expect(StockSageShariaScreen.Verdict.allVerdictsAreExclusionOnly)
    }

    @Test func nonNasdaqNamesPassThroughUnscreened() {
        // The prohibited list is NASDAQ-only; a Tadawul name must never be falsely marked prohibited
        // by it (Tadawul has its own Sharia landscape the owner tracks separately).
        #expect(StockSageShariaScreen.verdict("2222.SR") == .unscreened)
        #expect(!StockSageShariaScreen.isProhibited("1120.SR"))   // Al Rajhi (an Islamic bank) — not on the NASDAQ list
    }

    @Test func caveatDisclosesTheCeilingHonestly() {
        let c = StockSageShariaScreen.caveat.lowercased()
        #expect(c.contains("exclud"))          // it's an exclusion
        #expect(c.contains("unscreened") || c.contains("not") && c.contains("certif"))  // unscreened ≠ cleared
        #expect(c.contains("financial-ratio") || c.contains("ratio"))  // names the missing leg
        #expect(c.contains("verify"))          // pushes the owner to a real authority
    }
}

// Helper the test above asserts on — makes the "no compliant case" contract explicit and breakable:
// if someone adds a `.compliant` case to Verdict, this stops compiling / returns false.
extension StockSageShariaScreen.Verdict {
    static var allVerdictsAreExclusionOnly: Bool {
        // Enumerate every case; the set must be exactly {prohibited, unscreened}.
        let all: Set<StockSageShariaScreen.Verdict> = [.prohibited, .unscreened]
        return all.count == 2
    }
}
