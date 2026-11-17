import Testing
import Foundation
@testable import StockSage

// MARK: - healStaleQuotes candidate selection (review 2026-07-28 Q1, CRITICAL)
//
// Pins StockSageStore.healCandidates(symbols:scope:backoff:cap:asOf:) — the pure extraction of
// the heal sweep's four brakes (scope, staleness, backoff, cap) with no Store instance and no
// network fetch. `marketIsTrading` is a separate pre-filter applied by the caller and isn't
// exercised here (see StockSageStore.swift healStaleQuotes(scopedTo:)).
//
// Every original fixture below was already stale, so the staleness brake itself — the hand-
// inlined `StockSageQuoteFreshness.isStale` substitution (deviation (2) from the review's
// snippet) — went unpinned: deleting that guard clause left all four original tests green.
// freshInScopeRowIsExcluded and nilMarketTimeIsStaleFailClosed (fix-pass, adversarial review)
// close that gap: the first fails on revert to `return false` (unconditionally stale), the
// second fails on revert to `return true` (unconditionally fresh) or to a force-unwrap.

@Suite("healStaleQuotes candidate selection")
struct StockSageHealStaleQuotesTests {
    typealias S = StockSageStore

    private static let asOf = Date(timeIntervalSince1970: 1_000_000_000)
    // 50h before asOf: past the 48h equity staleness tolerance (StockSageQuoteFreshness).
    private static let staleTime = asOf.addingTimeInterval(-50 * 3600)
    private static let olderStaleTime = asOf.addingTimeInterval(-72 * 3600)

    private static func sym(_ symbol: String, marketTime: Date?) -> StockSageSymbol {
        StockSageSymbol(symbol: symbol, market: "NASDAQ", quotes: [
            StockSageQuote(price: 100, previousPrice: 100, marketTime: marketTime),
        ])
    }

    @Test("scope filter excludes out-of-scope stale rows")
    func scopeExcludesOutOfScope() {
        let symbols = [Self.sym("AAPL", marketTime: Self.staleTime), Self.sym("MSFT", marketTime: Self.staleTime)]
        let result = S.healCandidates(symbols: symbols, scope: ["AAPL"], backoff: [:], cap: 40, asOf: Self.asOf)
        #expect(result == ["AAPL"])
    }

    @Test("cap truncates to 40")
    func capTruncates() {
        // n=45 in-scope stale candidates, cap=40 -> exactly 40 survive, in input order.
        let symbols = (0..<45).map { Self.sym("S\($0)", marketTime: Self.staleTime) }
        let scope = Set(symbols.map(\.symbol))
        let result = S.healCandidates(symbols: symbols, scope: scope, backoff: [:], cap: 40, asOf: Self.asOf)
        #expect(result.count == 40)
        #expect(result == symbols.prefix(40).map(\.symbol))
    }

    @Test("backoff stamp equal to current marketTime is skipped")
    func backoffStampEqualIsSkipped() {
        let symbols = [Self.sym("AAPL", marketTime: Self.staleTime)]
        // Last heal recorded THIS SAME marketTime -> feed had nothing newer -> don't re-ask.
        let result = S.healCandidates(
            symbols: symbols, scope: ["AAPL"], backoff: ["AAPL": Self.staleTime], cap: 40, asOf: Self.asOf
        )
        #expect(result.isEmpty)
    }

    @Test("marketTime advanced past backoff stamp is included")
    func advancedMarketTimeIsIncluded() {
        // Backoff recorded an OLDER stamp than the row's current (still-stale) marketTime ->
        // the feed advanced since the last backoff -> worth asking again.
        let symbols = [Self.sym("AAPL", marketTime: Self.staleTime)]
        let result = S.healCandidates(
            symbols: symbols, scope: ["AAPL"], backoff: ["AAPL": Self.olderStaleTime], cap: 40, asOf: Self.asOf
        )
        #expect(result == ["AAPL"])
    }

    @Test("fresh in-scope row is excluded")
    func freshInScopeRowIsExcluded() {
        // 1h old, well inside the 48h equity tolerance -> not stale -> not a heal candidate,
        // even though it's in scope with no backoff recorded. Pins the staleness brake itself.
        let freshTime = Self.asOf.addingTimeInterval(-3600)
        let symbols = [Self.sym("AAPL", marketTime: freshTime)]
        let result = S.healCandidates(symbols: symbols, scope: ["AAPL"], backoff: [:], cap: 40, asOf: Self.asOf)
        #expect(result.isEmpty)
    }

    @Test("nil marketTime is stale fail-closed")
    func nilMarketTimeIsStaleFailClosed() {
        // Owner-signed 2026-07-27 fail-closed contract: a timestamp-less quote can't be judged
        // fresh, so it must be treated as stale and healed, not skipped.
        let symbols = [Self.sym("AAPL", marketTime: nil)]
        let result = S.healCandidates(symbols: symbols, scope: ["AAPL"], backoff: [:], cap: 40, asOf: Self.asOf)
        #expect(result == ["AAPL"])
    }
}
