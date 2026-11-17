import Testing
import Foundation
@testable import StockSage

// Owner decision 2026-07-28: "i dont want crypto in my app".
//
// Crypto had already left the CURATED universe in the 2026-07-16 Tadawul+NASDAQ restriction,
// but `addSymbol` still accepted a hand-typed ticker, and its own error copy advertised
// "BTC-USD" as an example. That made "no crypto" a property of the default symbol list rather
// than of the app — one typed ticker away from being false.
//
// The refusal now lives in `validateNewSymbol`, the single gate every hand-added symbol passes
// through, so it holds for every current and future caller. These tests pin that, because a
// scope decision that only the seed list enforces is a decision that quietly expires.
@MainActor
struct StockSageNoCryptoTests {

    @Test func handTypedCryptoTickerIsRefusedWithAPlainReason() {
        for raw in ["BTC-USD", "eth-usd", " SOL-USD ", "DOGE-USD"] {
            let v = StockSageStore.validateNewSymbol(raw, alreadyTracked: [])
            #expect(v.symbol == nil, "\(raw) must not be addable")
            #expect(v.error == "This app doesn't trade crypto.")
        }
    }

    @Test func equitiesOnBothVenuesStillPassTheSameGate() {
        // The guard must be surgical: refusing crypto must not cost a single legitimate ticker.
        for raw in ["AAPL", "2222.SR", "^TASI.SR", "QQQ", "USDSAR=X"] {
            let v = StockSageStore.validateNewSymbol(raw, alreadyTracked: [])
            #expect(v.symbol == raw.uppercased(), "\(raw) must remain addable")
            #expect(v.error == nil)
        }
    }

    @Test func refusalIsOrderedBeforeTheAlreadyTrackedCheck() {
        // If "already tracked" won this race, a crypto symbol somehow present in the tracked set
        // would report "already tracked" — implying the app holds it. The scope answer outranks
        // the bookkeeping one.
        let v = StockSageStore.validateNewSymbol("BTC-USD", alreadyTracked: ["BTC-USD"])
        #expect(v.error == "This app doesn't trade crypto.")
    }

    @Test func noCryptoSymbolSurvivesInTheShippedUniverseOrPresets() {
        #expect(!StockSageUniverse.worldwide.contains { $0.symbol.uppercased().hasSuffix("-USD") })
        #expect(!StockSageUniverse.catalog.contains { $0.symbol.uppercased().hasSuffix("-USD") })
    }
}
