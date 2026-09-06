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

    // B5: EODHD caps a single connection at 50 symbols ("Concurrent subscriptions: up to 50
    // symbols per connection by default" — eodhd.com/financial-apis/new-real-time-data-api-websockets,
    // fetched 2026-09-06). `chunked` is the pure batching math behind opening N connections
    // instead of silently over-subscribing one.

    @Test("the vendor-cited per-connection cap is 50, per the fetched docs sentence")
    func vendorCapIsFifty() {
        #expect(StockSageLiveStream.maxSubscriptionsPerConnection == 50)
    }

    @Test("chunking below the cap yields exactly one chunk holding everything")
    func chunkedUnderCapIsOneChunk() {
        let symbols = (1...49).map { "S\($0)" }
        let chunks = L.chunked(symbols, limit: 50)
        #expect(chunks.count == 1)
        #expect(chunks[0] == symbols)
    }

    @Test("n == c: exactly the cap still fits in one chunk (straddle low side)")
    func chunkedAtExactlyCapIsOneChunk() {
        let symbols = (1...50).map { "S\($0)" }
        let chunks = L.chunked(symbols, limit: 50)
        #expect(chunks.count == 1)                 // ceil(50/50) == 1
        #expect(chunks[0].count == 50)
        #expect(chunks.allSatisfy { $0.count <= 50 })
        #expect(Set(chunks.flatMap { $0 }) == Set(symbols))
    }

    @Test("n == c+1: one symbol over the cap spills into a second, smaller chunk (straddle high side)")
    func chunkedOneOverCapSpillsToSecondChunk() {
        let symbols = (1...51).map { "S\($0)" }
        let chunks = L.chunked(symbols, limit: 50)
        #expect(chunks.count == 2)                  // ceil(51/50) == 2
        #expect(chunks[0].count == 50)
        #expect(chunks[1].count == 1)
        #expect(chunks.allSatisfy { $0.count <= 50 })
        #expect(Set(chunks.flatMap { $0 }) == Set(symbols))
    }

    @Test("chunking never drops or duplicates a symbol, for a set well above the cap")
    func chunkedCoversEverySymbolExactlyOnceAboveCap() {
        // 872 mirrors the actual streamable-US universe size — the real n this ships with.
        let symbols = (1...872).map { "S\($0)" }
        let limit = 50
        let chunks = L.chunked(symbols, limit: limit)
        #expect(chunks.count == Int(ceil(Double(symbols.count) / Double(limit))))  // ceil(872/50) == 18
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit })
        #expect(chunks.flatMap { $0 } == symbols)          // order-preserving, no duplicates
        #expect(Set(chunks.flatMap { $0 }) == Set(symbols))
    }

    @Test("empty input chunks to no chunks at all")
    func chunkedEmptyInputIsEmpty() {
        #expect(L.chunked([], limit: 50).isEmpty)
    }

    @Test("a non-positive limit is treated as \"no cap\" — one chunk holding everything")
    func chunkedNonPositiveLimitIsOneChunk() {
        let symbols = ["AAPL", "MSFT", "NVDA"]
        #expect(L.chunked(symbols, limit: 0) == [symbols])
        #expect(L.chunked(symbols, limit: -1) == [symbols])
    }

    // MARK: subscribedSymbols — blocker fix 2026-09-06: `subscribed` must reflect only
    // AUTHORIZED-and-streaming connections, never a merely-requested chunk that hasn't (or never
    // will) come up — or StockSageStore.streamGapCandidates wrongly treats it as covered.

    @Test("a streaming connection's symbols are included; a non-streaming one's are not")
    func subscribedSymbolsOnlyCountsStreamingConnections() {
        let result = L.subscribedSymbols(from: [
            (symbols: ["AAPL", "MSFT"], isStreaming: true),
            (symbols: ["TSLA"], isStreaming: false),   // still connecting, or dropped/backing off
        ])
        #expect(result == ["AAPL", "MSFT"])
    }

    @Test("no connection streaming yields an empty subscribed set")
    func subscribedSymbolsEmptyWhenNothingStreaming() {
        let result = L.subscribedSymbols(from: [
            (symbols: ["AAPL"], isStreaming: false),
            (symbols: ["MSFT"], isStreaming: false),
        ])
        #expect(result.isEmpty)
    }

    @Test("every connection streaming unions all their symbols")
    func subscribedSymbolsUnionsAllStreamingChunks() {
        let result = L.subscribedSymbols(from: [
            (symbols: ["AAPL"], isStreaming: true),
            (symbols: ["MSFT", "NVDA"], isStreaming: true),
        ])
        #expect(result == ["AAPL", "MSFT", "NVDA"])
    }

    @Test("no connections at all yields an empty subscribed set")
    func subscribedSymbolsEmptyWhenNoConnections() {
        #expect(L.subscribedSymbols(from: []).isEmpty)
    }
}
