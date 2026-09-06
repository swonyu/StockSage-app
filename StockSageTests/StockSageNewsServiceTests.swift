import Testing
import Foundation
@testable import StockSage

// EODHD news — pure parse tests. `parseNews` is the ONLY thing exercised here (no network); the
// fixture rows use the vendor's documented field names (date/title/content/link/sentiment).

@Suite("EODHD news service (pure parse)")
struct StockSageNewsServiceTests {

    typealias NS = StockSageNewsService

    /// Fixed "now" so the 7-day freshness cutoff is a hand-derived boundary, not a moving target.
    static let now = Date(timeIntervalSince1970: 1_788_220_800)   // 2026-09-01T00:00:00Z

    private func row(date: Any? = "2026-08-30T12:00:00Z", title: Any? = "Guidance raised",
                     content: Any? = "Company raised full-year guidance. Shares rose in after-hours trading. Analysts had expected a cut.",
                     link: Any? = "https://eodhd.com/news/1",
                     sentiment: [String: Any]? = ["polarity": 0.42]) -> [String: Any] {
        var r: [String: Any] = [:]
        if let date { r["date"] = date }
        if let title { r["title"] = title }
        if let content { r["content"] = content }
        if let link { r["link"] = link }
        if let sentiment { r["sentiment"] = sentiment }
        return r
    }

    @Test("a well-formed row parses date, title, a 1-2 sentence snippet, link, and sentiment")
    func parsesWellFormedRow() throws {
        let items = NS.parseNews([row()], now: Self.now)
        let item = try #require(items.first)
        #expect(item.title == "Guidance raised")
        #expect(item.snippet == "Company raised full-year guidance. Shares rose in after-hours trading.")
        #expect(item.link == URL(string: "https://eodhd.com/news/1"))
        #expect(item.sentiment == 0.42)
        #expect(item.date == ISO8601DateFormatter().date(from: "2026-08-30T12:00:00Z"))
    }

    @Test("sentiment is optional — its absence is not an error")
    func sentimentOptionalWhenAbsent() throws {
        let items = NS.parseNews([row(sentiment: nil)], now: Self.now)
        let item = try #require(items.first)
        #expect(item.sentiment == nil)
    }

    // MARK: malformed rows are skipped, never crash the parse

    @Test("a row missing a title is skipped")
    func missingTitleSkipped() {
        #expect(NS.parseNews([row(title: nil)], now: Self.now).isEmpty)
    }

    @Test("a row with an empty title is skipped")
    func emptyTitleSkipped() {
        #expect(NS.parseNews([row(title: "")], now: Self.now).isEmpty)
    }

    @Test("a row missing a date is skipped")
    func missingDateSkipped() {
        #expect(NS.parseNews([row(date: nil)], now: Self.now).isEmpty)
    }

    @Test("a row with an unparseable date is skipped")
    func unparseableDateSkipped() {
        #expect(NS.parseNews([row(date: "not-a-date")], now: Self.now).isEmpty)
    }

    @Test("a row with the wrong type for date/title is skipped, not force-cast")
    func wrongTypesSkipped() {
        #expect(NS.parseNews([row(date: 12345)], now: Self.now).isEmpty)
        #expect(NS.parseNews([row(title: 999)], now: Self.now).isEmpty)
    }

    @Test("one malformed row among good ones is dropped without dropping the rest")
    func oneMalformedRowAmongGoodOnes() {
        let raw = [row(title: "First"), row(title: nil), row(title: "Second")]
        let items = NS.parseNews(raw, now: Self.now)
        #expect(items.map(\.title).sorted() == ["First", "Second"])
    }

    // MARK: freshness cutoff straddle — hand-derived: now = 2026-09-01T00:00:00Z, so exactly 7
    // days back is 2026-08-25T00:00:00Z (≤7 days ⇒ kept) and one second further back is
    // 2026-08-24T23:59:59Z (>7 days ⇒ dropped).

    @Test("a row dated exactly 7 days ago passes the cutoff (inclusive)")
    func cutoffStraddleExactly7DaysPasses() {
        let items = NS.parseNews([row(date: "2026-08-25T00:00:00Z")], now: Self.now)
        #expect(items.count == 1)
    }

    @Test("a row dated 7 days and 1 second ago is dropped")
    func cutoffStraddleJustPast7DaysDropped() {
        let items = NS.parseNews([row(date: "2026-08-24T23:59:59Z")], now: Self.now)
        #expect(items.isEmpty)
    }

    @Test("limit caps the returned count, newest first")
    func limitCapsNewestFirst() {
        let raw = [row(date: "2026-08-30T00:00:00Z", title: "Older"),
                   row(date: "2026-08-31T00:00:00Z", title: "Newer")]
        let items = NS.parseNews(raw, limit: 1, now: Self.now)
        #expect(items.count == 1)
        #expect(items.first?.title == "Newer")
    }

    // MARK: snippet(from:)

    @Test("snippet keeps at most 2 sentences and stays empty for empty content")
    func snippetTruncatesToTwoSentences() {
        #expect(NS.snippet(from: "One. Two. Three.") == "One. Two.")
        #expect(NS.snippet(from: "Only one sentence.") == "Only one sentence.")
        #expect(NS.snippet(from: "") == "")
        #expect(NS.snippet(from: "   ") == "")
    }
}
