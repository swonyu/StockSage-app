import Testing
import Foundation
@testable import StockSage

// The STALE caption must be dated by the same clock the STALE verdict is made on.
// `StockSageSymbol.isStale` judges on `latest?.marketTime`, but both render sites used
// `latest?.time` — the FETCH clock — so a Friday-close quote pulled two minutes ago announced
// itself as "STALE: last quote 2 minutes ago". That reads a fetch as a market observation, which
// is exactly the "stale data presented as fresh" failure this codebase refuses.
struct MarketsStaleQuoteAgeTests {
    // `.relative` formats against the real wall clock, so these offsets are anchored to Date()
    // rather than a fixed epoch — otherwise both timestamps round to the same coarse string
    // ("5 years ago") and the test proves nothing.
    private let now = Date()

    @Test func theCaptionIsDatedByTheMarketClockNotTheFetchClock() {
        let marketTime = now.addingTimeInterval(-3 * 86_400)   // Friday's close
        let quote = StockSageQuote(price: 100, previousPrice: 99, time: now.addingTimeInterval(-120),
                                   marketTime: marketTime, priceSource: .massiveSIP)
        let caption = MarketsView.staleQuoteAge(quote)
        #expect(caption == marketTime.formatted(.relative(presentation: .named)))
        #expect(caption != quote.time.formatted(.relative(presentation: .named)),
                "A two-minute-old fetch of a three-day-old quote must not read as two minutes old")
    }

    // No market timestamp means the age is genuinely unknown. isStale already refuses to cry wolf
    // in that case, and the caption must not invent a number either.
    @Test func aQuoteWithNoMarketTimeReportsAnUnknownAgeRatherThanTheFetchTime() {
        let quote = StockSageQuote(price: 100, previousPrice: 99, time: now, marketTime: nil)
        #expect(MarketsView.staleQuoteAge(quote) == "unknown")
    }

    @Test func aMissingQuoteReportsAnUnknownAge() {
        #expect(MarketsView.staleQuoteAge(nil) == "unknown")
    }
}
