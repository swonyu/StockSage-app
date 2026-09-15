import Testing
import Foundation
@testable import StockSage

// BATCH 11.2 (2026-09-12) — the off-board surfaces must date what they say.
//
// `BestOpportunityIntent` (Shortcuts / Spotlight) and the menu bar disclosed only SAMPLE and
// CACHED. `loadedFromCache` clears on the next successful refresh, so a board refreshed Friday and
// asked on Sunday is neither — and both surfaces spoke a two-day-old recommendation with no date
// on it at all. These have zero test references today.
//
// The clock is `closeableQuoteAsOf ?? quoteAsOf`, NOT `quoteAsOf`. StockSageStore:216-217 states
// that quoteAsOf is the max across ALL symbols, so one always-on crypto ticker keeps it ~now; the
// shipped banner at MarketsView:818 uses the closeable form for exactly this reason. Pinned below,
// because a green suite on the pure helper alone would not catch reading the wrong property.
@Suite("Spoken provenance — off-board surfaces")
struct StockSageSpokenProvenanceTests {

    private typealias P = StockSageSpokenProvenance
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }

    // Straddle every boundary from both sides. These are read aloud, so the wording matters as
    // much as the bucket.
    @Test func spokenAgeStraddlesEveryBoundary() {
        #expect(P.spokenAge(from: ago(0), now: now) == "less than a minute old")
        #expect(P.spokenAge(from: ago(59), now: now) == "less than a minute old")
        #expect(P.spokenAge(from: ago(60), now: now) == "1 minute old")
        #expect(P.spokenAge(from: ago(119), now: now) == "1 minute old")
        #expect(P.spokenAge(from: ago(120), now: now) == "2 minutes old")
        #expect(P.spokenAge(from: ago(3_599), now: now) == "59 minutes old")
        #expect(P.spokenAge(from: ago(3_600), now: now) == "1 hour old")
        #expect(P.spokenAge(from: ago(86_399), now: now) == "23 hours old")
        #expect(P.spokenAge(from: ago(86_400), now: now) == "1 day old")
        #expect(P.spokenAge(from: ago(172_800), now: now) == "2 days old")
    }

    // Keep the answer, but explicitly disclose when its price age cannot be established.
    @Test func anUnjudgeableClockDisclosesUnavailableFreshness() {
        #expect(P.spokenAge(from: nil, now: now) == nil)
        #expect(P.spokenAge(from: now.addingTimeInterval(3_600), now: now) == nil, "a future stamp is not freshness")
        #expect(P.spokenAge(from: Date(timeIntervalSince1970: .infinity), now: now) == nil)
        for stamp in [nil, now.addingTimeInterval(3_600), Date(timeIntervalSince1970: .infinity)] {
            #expect(P.ageClause(isSampleData: false, loadedFromCache: false, asOf: stamp, now: now)
                    == " (price timestamp unavailable — freshness unverified)")
        }
    }

    // Precedence matches MarketsView.sourceTagLabel: sample beats cached beats age.
    @Test func precedenceIsSampleThenCachedThenAge() {
        let old = ago(90_000)
        #expect(P.ageClause(isSampleData: true, loadedFromCache: true, asOf: old, now: now)
                == " (SAMPLE data — not live prices)")
        #expect(P.ageClause(isSampleData: false, loadedFromCache: true, asOf: old, now: now)
                == " (last-session prices — not live)")
        #expect(P.ageClause(isSampleData: false, loadedFromCache: false, asOf: old, now: now)
                == " (prices 1 day old)")
        // The gap this closed: not sample, not cached, and days old.
        #expect(P.ageClause(isSampleData: false, loadedFromCache: false, asOf: ago(172_800), now: now)
                .contains("2 days old"))
    }

    // THE REFUTED EDIT, pinned at the property level. A board whose equities closed 72h ago but
    // which carries one always-on crypto ticker must not speak "less than a minute old".
    @Test func theBoardClockIgnoresAnAlwaysOnCryptoTicker() throws {
        let staleEquity = ago(72 * 3_600)
        let symbols = [
            StockSageSymbol(symbol: "AAPL", market: "NASDAQ",
                            quotes: [StockSageQuote(price: 100, previousPrice: 99, marketTime: staleEquity)]),
            StockSageSymbol(symbol: "BTC-USD", market: "Crypto",
                            quotes: [StockSageQuote(price: 100, previousPrice: 99, marketTime: ago(5))])
        ]
        let closeable = try #require(StockSageStore.closeableQuoteAsOf(symbols))
        #expect(abs(closeable.timeIntervalSince(staleEquity)) < 1,
                "premise: the closeable clock is the equity's, not the crypto's")
        #expect(P.ageClause(isSampleData: false, loadedFromCache: false, asOf: closeable, now: now)
                == " (prices 3 days old)")
        // Reading quoteAsOf instead — the property the spec originally named — would have said this:
        #expect(P.ageClause(isSampleData: false, loadedFromCache: false, asOf: ago(5), now: now)
                == " (prices less than a minute old)")
    }
}
