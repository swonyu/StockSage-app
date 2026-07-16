import Testing
@testable import StockSage

// MARK: - Crypto liquidity gate (CRYPTO_RISK #3). Literals from /tmp/derive_cryptorisk.swift.

struct StockSageCryptoLiquidityGateTests {
    typealias Gate = StockSageCryptoLiquidityGate

    @Test func adverseGapIsWorstPriorCloseToOpenDrop() {
        // derive: max((100−85)/100, (102−101)/102) = 0.15
        #expect(abs(Gate.maxAdverseOvernightGapPct(opens: [100, 85, 101], closes: [100, 102, 101]) - 0.15) < 1e-9)
        #expect(Gate.maxAdverseOvernightGapPct(opens: [100, 101, 102], closes: [100, 101, 102]) == 0)  // no drop
        #expect(Gate.maxAdverseOvernightGapPct(opens: [100, 85], closes: [100, 102, 101]) == 0)        // mismatch → 0, no crash
        #expect(Gate.maxAdverseOvernightGapPct(opens: [100], closes: [100]) == 0)                      // <2 bars
    }

    @Test func nonCryptoIsNilAndUnknownDepthIsNeverAssumedLiquid() {
        #expect(Gate.assess(symbol: "AAPL", closes: [100, 100], opens: [100, 100], volumes: [1e6, 1e6]) == nil)
        // No usable volume → advDollar nil, NOT thin (no fabricated read), middle recommendation.
        let unknown = Gate.assess(symbol: "ALT-USD", closes: [100, 100], opens: [100, 100], volumes: [0, 0])
        guard let unknown else { Issue.record("crypto assess returned nil"); return }
        #expect(unknown.advDollar == nil && !unknown.isThinForCrypto)
        #expect(unknown.recommendation == "limit-only, size down")
        #expect(unknown.note.lowercased().contains("unknown"))
    }

    @Test func recommendationTiersStraddleTheLabeledFloors() {
        func gate(_ v0: Double, _ v1: Double) -> CryptoLiquidityGate? {
            Gate.assess(symbol: "ALT-USD", closes: [100, 100], opens: [100, 100], volumes: [v0, v1])
        }
        // derive: 4_999_900 < 5M → thin/skip ; 5_000_000 == floor → limit-only ;
        //         19_999_950 < 20M → limit-only ; 20_000_000 == ceiling → tradeable.
        #expect(gate(40_000, 59_998)?.isThinForCrypto == true && gate(40_000, 59_998)?.recommendation == "skip")
        #expect(gate(40_000, 60_000)?.isThinForCrypto == false && gate(40_000, 60_000)?.recommendation == "limit-only, size down")
        #expect(gate(200_000, 199_999)?.recommendation == "limit-only, size down")
        #expect(gate(200_000, 200_000)?.recommendation == "tradeable")
    }

    @Test func notesStayHonest() {
        let thin = Gate.assess(symbol: "ALT-USD", closes: [100, 100], opens: [100, 100], volumes: [40_000, 59_998])
        guard let thin else { Issue.record("thin gate nil"); return }
        let n = thin.note.lowercased()
        #expect(n.contains("thin") && n.contains("optimistic") && n.contains("est"))
        for g in [thin] {
            let all = (g.note + " " + g.recommendation).lowercased()
            #expect(!all.contains("guarantee") && !all.contains("risk-free") && !all.contains("safe"))
        }
    }
}
