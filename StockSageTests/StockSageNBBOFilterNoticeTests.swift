import Testing
import Foundation
@testable import StockSage

// BATCH 7.3 — an unavailable exchange reference must not be reported as a venue verdict.
//
// `StockSageMassiveTicks.parseExchanges` THROWS rather than returning an empty map
// (StockSageMassiveTicks.swift:168), so an empty `exchanges` is an exact "never loaded" signal —
// never evidence that a side is non-Nasdaq. The view used to call `isNasdaq` directly, whose
// false-on-unknown contract is correct in itself and stays pinned at StockSageMassiveTicksTests:112;
// the bug was the CALLER treating "unknown" as "no". With the `try?` swallowed, one failed
// reference fetch printed "No Nasdaq-attributed side" on both sides of a perfectly good quote.
@Suite("NBBO — filtered-side notice")
@MainActor
struct StockSageNBBOFilterNoticeTests {

    private typealias V = StockSageNBBOView
    private let nasdaq: [Int64: StockSageMassiveTicks.Exchange] = [
        12: StockSageMassiveTicks.Exchange(id: 12, mic: "XNAS", acronym: "NASDAQ")
    ]

    @Test func filterOffNeverSuppressesASide() {
        #expect(V.filteredSideNotice(nasdaqOnly: false, exchanges: [:], exchange: nil) == nil)
        #expect(V.filteredSideNotice(nasdaqOnly: false, exchanges: nasdaq, exchange: 99) == nil)
    }

    // The defect, pinned: filter on + reference missing must say the attribution is UNAVAILABLE,
    // not that the side failed the test. The two sentences make different claims.
    @Test func anUnloadedReferenceReadsUnavailableNotRejected() {
        let notice = V.filteredSideNotice(nasdaqOnly: true, exchanges: [:], exchange: 12)
        #expect(notice == "Nasdaq attribution unavailable")
        #expect(notice != "No Nasdaq-attributed side")
    }

    @Test func aLoadedReferenceStillAnswersTheVenueQuestion() {
        #expect(V.filteredSideNotice(nasdaqOnly: true, exchanges: nasdaq, exchange: 12) == nil)
        #expect(V.filteredSideNotice(nasdaqOnly: true, exchanges: nasdaq, exchange: 99) == "No Nasdaq-attributed side")
        // An absent exchange id on a LOADED reference is a genuine negative, not an outage.
        #expect(V.filteredSideNotice(nasdaqOnly: true, exchanges: nasdaq, exchange: nil) == "No Nasdaq-attributed side")
    }
}
