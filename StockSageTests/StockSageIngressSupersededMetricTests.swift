import Testing
import Foundation
@testable import StockSage

// `rejected` used to count two unrelated things: genuinely malformed provider data, and ordinary
// healthy protocol outcomes (a duplicate or out-of-order trade, a quote that did not supersede).
// The whole-market socket republishes the last trade for every selected symbol on every cycle, so
// the second kind dominates by orders of magnitude during PERFECTLY NORMAL operation — which made
// a climbing `rejected` in the feed diagnostics read as a broken feed when nothing was wrong.
// Splitting them keeps `rejected` meaning "the provider sent something we could not parse".
@MainActor struct StockSageIngressSupersededMetricTests {
    typealias I = StockSageFeedIngress
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var auth: Data { Data(#"[{"ev":"status","status":"auth_success"}]"#.utf8) }

    // Same drain discipline as StockSageFeedIngressTests.drained: wait until the mailbox is empty
    // (or the session failed) so the metrics being asserted are settled, not mid-drain.
    private func drained(_ ingress: I, symbols: [String] = []) async throws -> I.Snapshot {
        for _ in 0..<10_000 {
            let snapshot = await ingress.snapshot(symbols: symbols)
            if snapshot.metrics.failure != nil || snapshot.metrics.queuedFrames == 0 { return snapshot }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func aRepublishedTradeCountsAsSupersededRatherThanRejected() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        let trade = Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1700000000000,"q":5}]"#.utf8)
        ingress.offer(trade, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        let before = try await drained(ingress, symbols: ["AAPL"]).metrics
        // The identical trade again: healthy coalescing, not a data problem.
        ingress.offer(trade, at: now)
        let after = try await drained(ingress, symbols: ["AAPL"]).metrics
        #expect(after.superseded > before.superseded, "A republished trade must be counted as superseded")
        #expect(after.rejected == before.rejected, "A republished trade is not malformed provider data")
        ingress.invalidate()
    }

    @Test func malformedProviderDataStillCountsAsRejected() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        // A trade row with no timestamp cannot be decoded into a tick at all.
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100}]"#.utf8), at: now)
        let metrics = try await drained(ingress, symbols: ["AAPL"]).metrics
        #expect(metrics.rejected >= 1, "Undecodable provider data must still land in rejected")
        ingress.invalidate()
    }
}
