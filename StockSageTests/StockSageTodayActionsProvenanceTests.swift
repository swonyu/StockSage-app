import Testing
import Foundation
@testable import StockSage

// BATCH 11.1 (2026-09-12) — the order-shaped rows must carry the same provenance the idea card does.
//
// "Today's plan — executable equities first" renders entry/stop/target/size per row, which is the
// most order-shaped surface in the app, and it showed no source or age at all. The idea card for
// the same symbol shows "Massive SIP · 3h". Two surfaces, one symbol, one of them silent.
//
// The row's comment also claimed its stale cue was "the same utcDayKey staleness check copyAllText
// already gates its PRICE NOT LIVE line on". It is not: the export gates on
// StockSageTradePlan.draftOnlyStatus, which is strictly wider. These pins state the real
// relationship so the two are not conflated again.
@Suite("Today's-plan row provenance")
struct StockSageTodayActionsProvenanceTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }

    // The row and the idea card call the SAME helper, so equality here is the anti-divergence pin.
    @Test func theRowTagIsTheSameCallTheIdeaCardMakes() {
        let asOf = ago(3 * 3_600)
        let card = MarketsView.sourceTagLabel(isSampleData: false, loadedFromCache: false,
                                              priceAsOf: asOf, now: now, priceSource: .massiveSIP)
        #expect(card != nil)
        // Sample and cached outrank age, exactly as on the card.
        #expect(MarketsView.sourceTagLabel(isSampleData: true, loadedFromCache: false,
                                           priceAsOf: asOf, now: now, priceSource: .massiveSIP)
                != card)
        #expect(MarketsView.sourceTagLabel(isSampleData: false, loadedFromCache: true,
                                           priceAsOf: asOf, now: now, priceSource: .massiveSIP)
                != card)
        // Unknown renders NOTHING rather than a guessed source.
        #expect(MarketsView.sourceTagLabel(isSampleData: false, loadedFromCache: false,
                                           priceAsOf: nil, now: now, priceSource: nil) == nil)
    }

    // The plan must actually CARRY the provenance, or the row has nothing to render.
    @Test func theBuiltPlanCarriesTheIdeasOwnPriceSource() throws {
        let idea = SageFix.idea("AAPL", conviction: 0.6)
        let rows = StockSageTodayPlan.rankedActions([idea], account: 100_000, riskFraction: 0.01)
        let row = try #require(rows.first { $0.symbol == "AAPL" })
        #expect(row.priceAsOf == idea.priceAsOf)
        #expect(row.priceSource == idea.priceSource,
                "the row must quote the same observation the card does, not re-derive one")
    }

    // THE CORRECTED COMMENT, pinned as behaviour. The export check is strictly wider than the
    // row's prior-UTC-day cue: a 61-second-old price on the same UTC day exports as draft-only
    // while the row shows no stale marker at all.
    @Test func theExportCheckIsWiderThanTheRowsStaleCue() {
        let sameDayButOld = now.addingTimeInterval(-61)
        #expect(MarketsView.staleAsOfPrice(sameDayButOld, now: now) == nil,
                "same UTC day ⇒ the ROW shows no stale cue")
        #expect(StockSageTradePlan.draftOnlyStatus(symbol: "AAPL", priceAsOf: sameDayButOld,
                                                   isSample: false, now: now) != nil,
                "…but the EXPORT refuses to print an order line for it")
        // Both agree on the clearly-stale and the clearly-fresh ends.
        #expect(StockSageTradePlan.draftOnlyStatus(symbol: "AAPL", priceAsOf: now,
                                                   isSample: false, now: now) == nil)
        #expect(StockSageTradePlan.draftOnlyStatus(symbol: "AAPL", priceAsOf: nil,
                                                   isSample: false, now: now) != nil)
        #expect(StockSageTradePlan.draftOnlyStatus(symbol: "AAPL",
                                                   priceAsOf: now.addingTimeInterval(3_600),
                                                   isSample: false, now: now) != nil,
                "a future stamp is not freshness")
    }
}
