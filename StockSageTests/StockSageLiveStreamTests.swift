import Testing
import Foundation
@testable import StockSage

// Real-time streaming (owner directive 2026-07-28). The socket itself needs a network, but
// every DECISION the stream makes is pure — parsing, routing, and backoff are pinned here.

@Suite("Live stream (EODHD WebSocket)")
struct StockSageLiveStreamTests {

    typealias L = StockSageLiveStream

    @Test("a real trade frame parses to symbol, price and millisecond timestamp")
    func parsesTradeFrame() throws {
        // EODHD US stream shape: s=symbol, p=price, t=epoch MILLISECONDS.
        let f = #"{"s":"AAPL","p":336.91,"t":1785184080000,"v":100}"#
        let tick = try #require(L.parseTick(f))
        #expect(tick.symbol == "AAPL")
        #expect(abs(tick.price - 336.91) < 1e-9)
        // 1785184080000 ms == 1785184080 s — a millisecond/second mix-up here would date the
        // tick to 1970 and make every quote look infinitely stale.
        #expect(tick.timestamp == Date(timeIntervalSince1970: 1785184080))
    }

    @Test("price arriving as a numeric STRING still parses")
    func parsesStringPrice() throws {
        let tick = try #require(L.parseTick(#"{"s":"msft","p":"389.10","t":1785184080000}"#))
        #expect(tick.symbol == "MSFT")            // normalised upper
        #expect(abs(tick.price - 389.10) < 1e-9)
    }

    @Test("the authorization frame is NOT a tick")
    func authFrameIsNotATick() {
        // This is the literal first frame the server sends. Treating it as a tick would push a
        // nil/zero price onto the board.
        #expect(L.parseTick(#"{"status_code":200,"message":"Authorized"}"#) == nil)
        #expect(L.parseTick(#"{"status_code":401,"message":"Unauthorized"}"#) == nil)
    }

    @Test func statusFramesClassifyAndTradeFramesDoNot() {
        #expect(L.authStatus(#"{"status_code":200,"message":"Authorized"}"#) == 200)
        #expect(L.authStatus(#"{"status_code":401,"message":"Unauthorized"}"#) == 401)
        #expect(L.authStatus(#"{"s":"AAPL","p":336.91,"t":1785184080000}"#) == nil)
    }

    @Test("malformed, empty, zero and non-finite prices are all rejected")
    func rejectsGarbage() {
        #expect(L.parseTick("") == nil)
        #expect(L.parseTick("not json") == nil)
        #expect(L.parseTick("{}") == nil)
        #expect(L.parseTick(#"{"s":"AAPL"}"#) == nil)                 // no price
        #expect(L.parseTick(#"{"p":100,"t":1}"#) == nil)              // no symbol
        #expect(L.parseTick(#"{"s":"","p":100}"#) == nil)             // empty symbol
        #expect(L.parseTick(#"{"s":"AAPL","p":0}"#) == nil)           // zero price
        #expect(L.parseTick(#"{"s":"AAPL","p":-5}"#) == nil)          // negative
        #expect(L.parseTick(#"{"s":"AAPL","p":"abc"}"#) == nil)       // unparseable string
    }

    @Test("a tick with no timestamp still parses, with nil time rather than a fake one")
    func missingTimestampIsNil() throws {
        let tick = try #require(L.parseTick(#"{"s":"NVDA","p":196.51}"#))
        #expect(tick.timestamp == nil)
    }

    @Test("only US-coverable symbols are streamable — Saudi/FX/crypto are excluded")
    func streamableMatchesCoverage() {
        // EODHD has no Saudi exchange, so subscribing 2222.SR would be a silent no-op forever.
        let out = L.streamable(["AAPL", "2222.SR", "BTC-USD", "EURUSD=X", "^VIX", "msft"])
        #expect(out == ["AAPL", "MSFT"])
    }

    @Test("reconnect backoff doubles then caps at 30s")
    func backoffDoublesAndCaps() {
        #expect(L.backoffSeconds(attempt: 0) == 1)
        #expect(L.backoffSeconds(attempt: 1) == 2)
        #expect(L.backoffSeconds(attempt: 2) == 4)
        #expect(L.backoffSeconds(attempt: 3) == 8)
        #expect(L.backoffSeconds(attempt: 4) == 16)
        #expect(L.backoffSeconds(attempt: 5) == 30)     // 32 clamped
        #expect(L.backoffSeconds(attempt: 99) == 30)    // never drifts to hours
        #expect(L.backoffSeconds(attempt: -3) == 1)     // defensive
    }
}
