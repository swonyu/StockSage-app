import Testing
import Foundation
@testable import StockSage

// EODHD hybrid source (owner key, 2026-07-28). Coverage claims here are MEASURED against the
// live API, not assumed: US works; Tadawul is absent from EODHD's exchange list entirely.

@Suite("EODHD hybrid quote source")
struct StockSageEODHDTests {

    typealias E = StockSageEODHD

    @Test("routing whitelist: bare US tickers only, never Saudi/FX/crypto/index")
    func coverageWhitelist() {
        // US listings in this universe are bare alphabetic tickers.
        #expect(E.covers("AAPL"))
        #expect(E.covers("NVDA"))
        #expect(E.covers("msft"))                 // case-insensitive
        // Tadawul carries .SR and is NOT offered by EODHD — must never route here.
        #expect(!E.covers("2222.SR"))
        #expect(!E.covers("1120.SR"))
        // FX / crypto / indices are out of scope for this source.
        #expect(!E.covers("EURUSD=X"))
        #expect(!E.covers("BTC-USD"))
        #expect(!E.covers("^VIX"))
        #expect(!E.covers(""))
    }

    @Test("symbol mapping appends the .US exchange suffix")
    func symbolMapping() {
        #expect(E.eodhdSymbol("AAPL") == "AAPL.US")
        #expect(E.eodhdSymbol("nvda") == "NVDA.US")
    }

    @Test("a real US payload parses to price, previous close, and market time")
    func parsesRealPayload() throws {
        // Verbatim shape of a live EODHD real-time response (AAPL, 2026-07-28).
        let json = """
        {"code":"AAPL.US","timestamp":1785184080,"gmtoffset":0,"open":334.54,"high":339.57,
         "low":334.02,"close":336.91,"volume":49256009,"previousClose":333.02,
         "change":3.89,"change_p":1.1681}
        """.data(using: .utf8)!
        let q = try #require(E.parseRealTime(json, requestedSymbol: "AAPL"))
        #expect(q.symbol == "AAPL")                       // the symbol WE asked for is preserved
        #expect(abs(q.price - 336.91) < 1e-9)
        #expect(abs(q.previousClose - 333.02) < 1e-9)
        #expect(q.marketTime == Date(timeIntervalSince1970: 1785184080))
        #expect(!q.isNewListing)
    }

    @Test("the NA placeholder for an unsubscribed exchange is rejected, never read as a price")
    func naPlaceholderRejected() {
        // EXACT payload EODHD returns for Saudi on this account — every field the string "NA".
        // Parsing this as a quote would put a fabricated price on the board.
        let na = """
        {"code":"2222.SAU","timestamp":"NA","gmtoffset":0,"open":"NA","high":"NA","low":"NA",
         "close":"NA","volume":"NA","previousClose":"NA","change":"NA","change_p":"NA"}
        """.data(using: .utf8)!
        #expect(E.parseRealTime(na, requestedSymbol: "2222.SR") == nil)
    }

    @Test("malformed, empty, and zero-price responses all return nil")
    func malformedRejected() {
        #expect(E.parseRealTime(Data(), requestedSymbol: "AAPL") == nil)
        #expect(E.parseRealTime("not json".data(using: .utf8)!, requestedSymbol: "AAPL") == nil)
        #expect(E.parseRealTime("{}".data(using: .utf8)!, requestedSymbol: "AAPL") == nil)
        let zero = #"{"code":"X.US","close":0,"previousClose":10}"#.data(using: .utf8)!
        #expect(E.parseRealTime(zero, requestedSymbol: "X") == nil)
    }

    @Test("a missing previousClose falls back to the close and flags isNewListing (Q10, 2026-07-28)")
    func missingPreviousCloseIsFlat() throws {
        let j = #"{"code":"X.US","timestamp":1785184080,"close":50.0,"previousClose":"NA"}"#.data(using: .utf8)!
        let q = try #require(E.parseRealTime(j, requestedSymbol: "X"))
        #expect(q.previousClose == q.price)     // flat, not a fabricated percentage
        #expect(q.isNewListing)                 // must be flagged, never hardcoded false (Q10)
    }

    @Test("a zero previousClose is exactly as unusable as a missing one (L3-08 parity, Q10)")
    func zeroPreviousCloseIsFlaggedNotFabricated() throws {
        let j = #"{"code":"X.US","timestamp":1785184080,"close":50.0,"previousClose":0}"#.data(using: .utf8)!
        let q = try #require(E.parseRealTime(j, requestedSymbol: "X"))
        #expect(q.previousClose == q.price)     // routed through the same missing-previousClose fallback
        #expect(q.isNewListing)
    }

    @Test("a non-finite close (Double.infinity / .nan) is rejected, never treated as a price (Q10 fixup, 2026-09-06)")
    func nonFiniteCloseRejected() {
        // Genuine non-finite values, injected directly against the decoded-payload overload — NOT
        // JSON text. A JSON literal like "close":1e400 overflows Double, but JSONSerialization then
        // fails the WHOLE document (returns nil) before num() ever runs, so a JSON-level test would
        // pass identically whether or not num()'s isFinite guard exists. Verified empirically against
        // this project's own toolchain (review fixup finding, 2026-09-06) — see
        // StockSageEODHD.parseRealTime(_:requestedSymbol:) for the [String: Any] overload this uses.
        let inf: [String: Any] = ["code": "X.US", "timestamp": 1785184080, "close": Double.infinity, "previousClose": 10]
        #expect(E.parseRealTime(inf, requestedSymbol: "X") == nil)
        let nan: [String: Any] = ["code": "X.US", "timestamp": 1785184080, "close": Double.nan, "previousClose": 10]
        #expect(E.parseRealTime(nan, requestedSymbol: "X") == nil)
    }

    @Test("a JSON payload that overflows Double anywhere fails to parse at all, wholesale (documents the boundary above)")
    func jsonNumericOverflowFailsWholeDocument() {
        // 1e400 is lexically valid JSON but overflows Double to +Infinity, which Foundation's
        // JSONSerialization rejects for the ENTIRE object, not just that field. This is why the
        // isFinite guard above must be tested with a direct Double, not a JSON literal.
        let j = #"{"code":"X.US","timestamp":1785184080,"close":1e400,"previousClose":10}"#.data(using: .utf8)!
        #expect(E.parseRealTime(j, requestedSymbol: "X") == nil)
    }

    @Test("a Settings override replaces the embedded key")
    func overrideWins() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: E.overrideDefaultsKey)
        defer { saved.map { d.set($0, forKey: E.overrideDefaultsKey) } ?? d.removeObject(forKey: E.overrideDefaultsKey) }

        d.removeObject(forKey: E.overrideDefaultsKey)
        #expect(E.apiKey == E.embeddedKey)
        d.set("  rotated-key-123  ", forKey: E.overrideDefaultsKey)
        #expect(E.apiKey == "rotated-key-123")      // trimmed
        d.set("   ", forKey: E.overrideDefaultsKey)
        #expect(E.apiKey == E.embeddedKey)          // whitespace-only override ignored
    }
}
