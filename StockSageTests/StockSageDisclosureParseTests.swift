import Testing
import Foundation
@testable import StockSage

// MARK: - Disclosure feed parsing
//
// `StockSageDisclosureService` answers one question — "has this been publicly
// disclosed, and exactly when?" — so the parse has to be right about *time* and
// about *which* filing, or the answer is worse than useless.
//
// The fixture below is hand-authored against the SEC submissions payload SHAPE
// (verified 2026-07-28 against `data.sec.gov/submissions/CIK0000320193.json`):
// column-oriented parallel arrays under `filings.recent`. Values are invented for
// the test — they are NOT copied from a run of the code under test, so these
// assertions can actually fail if the parse regresses.

struct StockSageDisclosureParseTests {

    /// Two 8-Ks and one Form 4, deliberately interleaved so a form filter that
    /// silently keeps everything, or drops the wrong index, shows up.
    private func fixture() -> [String: Any] {
        [
            "filings": [
                "recent": [
                    "accessionNumber": ["0000320193-26-000011",
                                        "0001140361-26-015711",
                                        "0000320193-26-000005"],
                    "form": ["8-K", "4", "8-K"],
                    "filingDate": ["2026-04-30", "2026-04-20", "2026-01-29"],
                    // Note the ET-evening acceptance on the FIRST row: accepted
                    // 2026-04-29T17:40 but stamped filingDate 2026-04-30.
                    // Fractional seconds are the LIVE SEC shape (real AAPL 8-K, accession
                    // 0000320193-26-000018). The bare-seconds formatter returned nil for every
                    // one of them, so acceptedAt was nil for all filings and the disclosure clock
                    // silently used the filing date. Row 2 stays bare-seconds so both parse.
                    "acceptanceDateTime": ["2026-04-29T17:40:12.000Z",
                                           "2026-04-20T16:05:00Z",
                                           "2026-01-29T16:30:00Z"],
                    "items": ["2.02,9.01", "", "5.02"],
                    "primaryDocument": ["aapl-20260430.htm", "xslF345X05/doc4.xml", "aapl-20260129.htm"],
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    @Test("keeps only the requested forms")
    func filtersByForm() {
        let out = StockSageDisclosureService.parseFilings(fixture(), cik: "0000320193")
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.form == "8-K" })
        #expect(out.map(\.accessionNumber) == ["0000320193-26-000011", "0000320193-26-000005"])
    }

    @Test("acceptance time is the public moment, and can precede the filing date")
    func acceptancePrecedesFilingDate() throws {
        let out = StockSageDisclosureService.parseFilings(fixture(), cik: "0000320193")
        let first = try #require(out.first)
        let accepted = try #require(first.acceptedAt)
        // Accepted 17:40Z on the 29th; filingDate is the 30th. The whole point of
        // reading acceptanceDateTime is that these differ — if the parse fell back
        // to filingDate this comparison flips.
        #expect(accepted < first.filingDate)
    }

    @Test("splits item codes and leaves unknown ones unguessed")
    func parsesItems() {
        let out = StockSageDisclosureService.parseFilings(fixture(), cik: "0000320193")
        #expect(out[0].items == ["2.02", "9.01"])
        #expect(out[0].itemDescriptions.contains("Earnings released"))
        #expect(out[1].items == ["5.02"])
        #expect(out[1].itemDescriptions == ["Director or officer change"])
    }

    @Test("unknown item codes pass through rather than being mislabeled")
    func unknownItemPassesThrough() {
        var f = fixture()
        var filings = f["filings"] as! [String: Any]
        var recent = filings["recent"] as! [String: Any]
        recent["items"] = ["9.99", "", "5.02"]
        filings["recent"] = recent
        f["filings"] = filings
        let out = StockSageDisclosureService.parseFilings(f, cik: "0000320193")
        // A wrong label is worse than no label — an unmapped code stays visibly raw.
        #expect(out[0].itemDescriptions == ["Item 9.99"])
    }

    @Test("document URL strips dashes from the path but keeps the filename")
    func documentURLQuirk() throws {
        let out = StockSageDisclosureService.parseFilings(fixture(), cik: "0000320193")
        let url = try #require(out.first?.documentURL?.absoluteString)
        // EDGAR wants the accession number bare in the directory segment.
        #expect(url.contains("/000032019326000011/"))
        #expect(url.hasSuffix("aapl-20260430.htm"))
        #expect(!url.contains("0000320193-26-000011/"))
    }

    @Test("ragged columns cannot index out of range")
    func raggedColumnsAreSafe() {
        var f = fixture()
        var filings = f["filings"] as! [String: Any]
        var recent = filings["recent"] as! [String: Any]
        // A truncated feed: form has 3 entries, filingDate only 1.
        recent["filingDate"] = ["2026-04-30"]
        filings["recent"] = recent
        f["filings"] = filings
        let out = StockSageDisclosureService.parseFilings(f, cik: "0000320193")
        #expect(out.count == 1)
    }

    @Test("limit is honored")
    func honorsLimit() {
        let out = StockSageDisclosureService.parseFilings(fixture(), cik: "0000320193", limit: 1)
        #expect(out.count == 1)
    }

    @Test("malformed payload yields empty, never a crash")
    func malformedIsEmpty() {
        #expect(StockSageDisclosureService.parseFilings([:], cik: "0000320193").isEmpty)
        #expect(StockSageDisclosureService.parseFilings(["filings": "nope"], cik: "0").isEmpty)
    }

    // MARK: - publicFor: the disclosure clock (added 2026-07-28 when the service went LIVE on
    // the idea sheet). "8-K filed 2h ago" next to a price move is a claim about WHEN news became
    // public — the one number here a person would actually act on, so it gets its own coverage.

    private func filing(acceptedAt: Date?) -> StockSageDisclosureService.Filing {
        StockSageDisclosureService.Filing(
            accessionNumber: "0000000000-26-000001", form: "8-K",
            filingDate: Date(timeIntervalSince1970: 1_700_000_000),
            acceptedAt: acceptedAt, items: [], documentURL: nil)
    }

    @Test("elapsed time reads in the plain words a person would use")
    func publicForPlainWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(-60)), now: now) == "just now")
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(-3600)), now: now) == "1h ago")
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(-23 * 3600)), now: now) == "23h ago")
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(-25 * 3600)), now: now) == "yesterday")
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(-72 * 3600)), now: now) == "3d ago")
    }

    @Test("refuses to guess when the feed omits the acceptance time")
    func publicForRefusesToGuess() {
        // acceptanceDateTime IS the disclosure instant; filingDate can be a full business day
        // later, so substituting it would overstate how long the news has been public.
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: nil)) == nil)
    }

    @Test("device clock ahead of the SEC renders nothing, never negative time")
    func publicForHandlesClockSkew() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(StockSageDisclosureService.publicFor(filing(acceptedAt: now.addingTimeInterval(600)), now: now) == nil)
    }

    @Test("the caveat refuses to let absence read as evidence")
    func caveatIsHonestAboutBothLimits() {
        #expect(StockSageDisclosureService.caveat.localizedCaseInsensitiveContains("not evidence"))
        #expect(StockSageDisclosureService.caveat.localizedCaseInsensitiveContains("not a prediction"))
    }
}
