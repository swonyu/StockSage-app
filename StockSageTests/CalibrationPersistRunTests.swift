import Testing
import Foundation
@testable import StockSage

// Owner-requested headless "Run the Strategy Backtest once" (2026-07-10): reproduces
// StockSageStore.refreshStrategyBacktest's EXACT recipe INCLUDING its calibration
// fit + persisted-snapshot write (StockSageStore.swift ~1303-1350), so the live app's
// init-restore picks up a real 5y-fitted win-prob map at next launch instead of the
// thin-cache identity floor. Sentinel-gated (`/tmp/salehman_persist_calibration`) so it
// is INERT in CI and normal runs — it hits the network AND writes the app's real
// `stocksage.calibration.v1` key (hosted tests share the app's defaults domain), which
// only an explicit owner request sanctions. Same file-sentinel pattern as
// StrategyBaselineMeasurementTests (env vars don't cross the xcodebuild boundary).
@Suite(.serialized)
struct CalibrationPersistRunTests {
    @Test("run the 5y strategy backtest and persist its calibration fit (sentinel-gated, network, writes app defaults)")
    func runAndPersistCalibration() async {
        guard FileManager.default.fileExists(atPath: "/tmp/salehman_persist_calibration") else {
            return   // inert in normal CI runs
        }

        // Same sequence as refreshStrategyBacktest (StockSageStore.swift ~1303-1335), verbatim.
        let symbols = StockSageStrategyBacktest.sampleSymbols
        async let benchmarkTask = StockSageQuoteService.fetchHistory("^GSPC", range: "5y")
        let histories = await StockSageQuoteService.fetchHistories(for: symbols, range: "5y")
        let benchmark = await benchmarkTask

        var ts: [BacktestTrade] = []
        var ds: [Date] = []
        var loaded = 0
        for sym in symbols {
            guard let h = histories[sym.uppercased()] else { continue }
            loaded += 1
            let d = StockSageBacktester.runDetailed(h, costs: StockSageNetEdge.defaultCosts(forSymbol: sym),
                                                    benchmark: benchmark)
            ts.append(contentsOf: d.trades)
            ds.append(contentsOf: d.trades.map { h.dates[$0.entryIndex] })
        }

        // The manual button's calibration leg (StockSageStore.swift ~1341-1350), verbatim:
        // same fit function, same chronological dates, same Snapshot source/format/key.
        let fit = StockSageConvictionCalibration.fit(fromBacktest: ts, dates: ds)
        var evidence = """
        === CALIBRATION PERSIST RUN (owner-requested, 2026-07-10) ===
        loaded \(loaded)/\(symbols.count) symbols, pooled trades=\(ts.count), benchmark bars=\(benchmark?.closes.count ?? 0)
        """
        if let cal = fit {
            let snap = StockSageConvictionCalibration.Snapshot(calibration: cal, source: "strategy-backtest-5y",
                                                               fittedAt: Date(), oosBrier: nil)
            snap.save()
            let back = StockSageConvictionCalibration.Snapshot.load()
            evidence += """

            fit: method=\(cal.method.rawValue) sampleSize=\(cal.sampleSize) bins=\(cal.bins.count)
            persisted+readBack: source=\(back?.source ?? "MISSING") method=\(back?.methodLabel ?? "-") \
            sampleCount=\(back?.sampleCount ?? -1) fittedAt=\(back?.fittedAt.description ?? "-")
            === END ===
            """
            #expect(back?.source == "strategy-backtest-5y", "persisted snapshot must read back")
            #expect(back?.sampleCount == cal.sampleSize, "read-back must match the fit just written")
        } else {
            evidence += "\nfit: nil — pooled sample too thin to fit honestly; NOTHING persisted (honest no-op)\n=== END ==="
            // Not a failure: nil is the shipped thin-sample contract. But with 5y × ~24 symbols the
            // fit is expected; loaded==0 means network outage — surface that as the real failure.
            #expect(loaded > 0, "no symbols loaded — network throttle/outage; run invalid")
        }
        print(evidence)
        try? evidence.write(toFile: "/tmp/salehman_calibration_persist_result.txt", atomically: true, encoding: .utf8)
    }
}
