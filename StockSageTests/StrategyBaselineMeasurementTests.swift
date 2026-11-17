import Testing
import Foundation
@testable import StockSage

// Engine-baseline measurement (NOT a CI test — gated on a /tmp sentinel file so it is inert
// unless a sentinel exists). Reproduces StockSageStore.refreshStrategyBacktest's EXACT recipe
// headlessly (the GUI panel is the only in-app surface; no computer-use MCP is available in
// agent sessions) so the shipped engine's live net-of-cost Deflated Sharpe can be measured and
// re-confirmed on demand. Hits the network (Yahoo 5y) by design; that is why it is gated out of
// the normal suite. To run: `touch /tmp/salehman_measure_baseline` then run this test only; read
// the printed "=== ENGINE BASELINE ===" block. (File sentinel, not an env var, because env vars
// don't reliably cross the `xcodebuild test` boundary into the test process.)
@Suite(.serialized)
struct StrategyBaselineMeasurementTests {
    @Test("engine baseline net-of-cost DSR on live sampleSymbols (sentinel-gated, network)")
    func measureBaseline() async {
        guard FileManager.default.fileExists(atPath: "/tmp/salehman_measure_baseline") else {
            return   // inert in normal CI runs
        }

        // Same sequence as refreshStrategyBacktest (StockSageStore.swift ~742-774), verbatim.
        let symbols = StockSageStrategyBacktest.sampleSymbols
        async let benchmarkTask = StockSageQuoteService.fetchHistory("^GSPC", range: "5y")
        let histories = await StockSageQuoteService.fetchHistories(for: symbols, range: "5y")
        let benchmark = await benchmarkTask

        var rs: [BacktestResult] = []
        var ts: [BacktestTrade] = []
        var ds: [Date] = []
        var loaded: [String] = []
        var skipped: [String] = []
        for sym in symbols {
            guard let h = histories[sym.uppercased()] else { skipped.append(sym); continue }
            loaded.append("\(sym):\(h.closes.count)")
            let d = StockSageBacktester.runDetailed(h, costs: StockSageNetEdge.defaultCosts(forSymbol: sym),
                                                    benchmark: benchmark)
            rs.append(d.result)
            ts.append(contentsOf: d.trades)
            ds.append(contentsOf: d.trades.map { h.dates[$0.entryIndex] })
        }
        let bt = StockSageStrategyBacktest.aggregate(rs, trades: ts, tradeEntryDates: ds)

        let dsrLine: String
        if let dsr = bt.deflatedSharpe {
            dsrLine = "DEFLATED SHARPE: psr=\(dsr.psr) dsr=\(dsr.dsr) passes(dsr>0.95)=\(dsr.passes)"
        } else {
            dsrLine = "DEFLATED SHARPE: nil (too few pooled trades for the selection-bias correction)"
        }
        let block = """
        === ENGINE BASELINE MEASUREMENT (2026-07-07, live 5y) ===
        benchmark ^GSPC loaded: \(benchmark != nil) (\(benchmark?.closes.count ?? 0) bars)
        loaded \(loaded.count)/\(symbols.count): \(loaded.joined(separator: " "))
        skipped \(skipped.count): \(skipped.joined(separator: " "))
        symbolsTested=\(bt.symbolsTested) symbolsWithTrades=\(bt.symbolsWithTrades) symbolsProfitable=\(bt.symbolsProfitable)
        totalTrades=\(bt.totalTrades) wins=\(bt.wins) blendedWinRate=\(bt.blendedWinRate)
        avgR=\(bt.avgR) totalR=\(bt.totalR) worstDrawdownR=\(bt.worstDrawdownR) pooledDrawdownR=\(bt.pooledDrawdownR)
        tStat=\(bt.tStat) momentCorrectedTStat=\(bt.momentCorrectedTStat)
        clearsMultipleTestingBar(t>3)=\(bt.clearsMultipleTestingBar) isSignificant(trades>=100)=\(bt.isSignificant)
        passesHonestSignificance=\(bt.passesHonestSignificance)
        \(dsrLine)
        significanceVerdict: \(bt.significanceVerdict)
        === END BASELINE ===
        """
        print(block)
        // Swift Testing swallows print() from the xcodebuild console — persist to a file too.
        try? block.write(toFile: "/tmp/salehman_baseline_result.txt", atomically: true, encoding: .utf8)

        // Honesty-floor assertions — make this a real check, not just a print.
        #expect(bt.symbolsTested > 0, "no symbols loaded — network throttle/outage; measurement invalid")
        if let dsr = bt.deflatedSharpe {
            #expect(dsr.dsr >= 0 && dsr.dsr <= 1, "DSR must be a probability in [0,1]")
            #expect(dsr.psr >= 0 && dsr.psr <= 1, "PSR must be a probability in [0,1]")
        }
    }
}
