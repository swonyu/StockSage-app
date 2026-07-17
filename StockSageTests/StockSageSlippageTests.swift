import Testing
import Foundation
@testable import StockSage

// MARK: - Realized-cost capture (measure + display only) — TradeRecord's 4 new optional
// fields (plannedEntry/entryFill/plannedExit/exitFill), StockSageJournal.measuredSlippage,
// and the close() persistence of the exit pair. Fixtures are hand-derived (see the spec's
// TEST PLAN); nothing here feeds NetEdge/the cost table/the trade gate.

struct StockSageSlippageTests {

    private func trade(symbol: String = "AAPL", side: TradeRecord.Side = .long,
                       plannedEntry: Double? = nil, entryFill: Double? = nil,
                       plannedExit: Double? = nil, exitFill: Double? = nil,
                       closed: Bool = true) -> TradeRecord {
        TradeRecord(symbol: symbol, side: side, entry: 100, stop: 95, target: nil, shares: 1,
                    openedAt: Date(timeIntervalSince1970: 0),
                    exitPrice: closed ? 105 : nil, closedAt: closed ? Date(timeIntervalSince1970: 100) : nil,
                    plannedEntry: plannedEntry, entryFill: entryFill,
                    plannedExit: plannedExit, exitFill: exitFill)
    }

    // MARK: Decode backward-compat + round-trip

    @Test func decodeBackwardCompatPreWaveJSON() throws {
        let id = UUID()
        let opened = Date(timeIntervalSince1970: 0)
        let closed = Date(timeIntervalSince1970: 100)
        // Encode the raw Date wire values with the SAME default JSONEncoder the store uses, so
        // the literal below is genuinely decodable without guessing the date format — the KEY SET
        // is what's under test (mirrors the shipped pre-wave schema, StockSageJournal.swift:12-34:
        // id/symbol/side/entry/stop/target/shares/openedAt/exitPrice/closedAt only).
        let openedRaw = String(data: try JSONEncoder().encode(opened), encoding: .utf8)!
        let closedRaw = String(data: try JSONEncoder().encode(closed), encoding: .utf8)!
        let json = """
        {
            "id": "\(id.uuidString)",
            "symbol": "AAPL",
            "side": "Long",
            "entry": 100,
            "stop": 95,
            "target": null,
            "shares": 10,
            "openedAt": \(openedRaw),
            "exitPrice": 102,
            "closedAt": \(closedRaw)
        }
        """
        let decoded = try JSONDecoder().decode(TradeRecord.self, from: Data(json.utf8))
        #expect(decoded.plannedEntry == nil)
        #expect(decoded.entryFill == nil)
        #expect(decoded.plannedExit == nil)
        #expect(decoded.exitFill == nil)
        // Hand-derived: long entry 100, stop 95, exit 102 => R = (102-100)/(100-95) = 2/5 = +0.40.
        #expect(abs((decoded.realizedR ?? .nan) - 0.40) < 1e-9)
    }

    @Test func encodeDecodeRoundTripWithAllFourFields() throws {
        let t = TradeRecord(symbol: "MSFT", side: .long, entry: 100, stop: 95, target: 110, shares: 5,
                            openedAt: Date(timeIntervalSince1970: 0), exitPrice: 105,
                            closedAt: Date(timeIntervalSince1970: 100), note: "n", conviction: 0.6,
                            plannedEntry: 100.0, entryFill: 100.25, plannedExit: 105.0, exitFill: 104.9)
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TradeRecord.self, from: data)
        #expect(decoded == t)
    }

    // MARK: Slippage arithmetic

    @Test func slippageArithmeticLong() {
        // Entry leg (buy): planned 100.00, fill 100.25 => +25.0 bps (0.25/100*10000).
        #expect(abs((TradeRecord.legSlippageBps(planned: 100.00, fill: 100.25, isBuy: true) ?? .nan) - 25.0) < 1e-6)
        // Exit leg (sell): planned 110.00, fill 109.78 => +20.0 bps (0.22/110*10000).
        #expect(abs((TradeRecord.legSlippageBps(planned: 110.00, fill: 109.78, isBuy: false) ?? .nan) - 20.0) < 1e-6)
        // Price improvement (buy filled BELOW plan): planned 100.00, fill 99.90 => -10.0 bps.
        #expect(abs((TradeRecord.legSlippageBps(planned: 100.00, fill: 99.90, isBuy: true) ?? .nan) - (-10.0)) < 1e-6)
    }

    @Test func slippageArithmeticShort() {
        // Entry leg (sell): planned 50.00, fill 49.90 => +20.0 bps (0.10/50*10000).
        #expect(abs((TradeRecord.legSlippageBps(planned: 50.00, fill: 49.90, isBuy: false) ?? .nan) - 20.0) < 1e-6)
        // Exit leg (buy): planned 45.00, fill 45.09 => +20.0 bps (0.09/45*10000).
        #expect(abs((TradeRecord.legSlippageBps(planned: 45.00, fill: 45.09, isBuy: true) ?? .nan) - 20.0) < 1e-6)
    }

    @Test func entryAndExitSlippageRouteSideCorrectly() {
        // Long enters via BUY, exits via SELL.
        let long = trade(side: .long, plannedEntry: 100, entryFill: 100.25, plannedExit: 110, exitFill: 109.78)
        #expect(abs((long.entrySlippageBps ?? .nan) - 25.0) < 1e-6)
        #expect(abs((long.exitSlippageBps ?? .nan) - 20.0) < 1e-6)
        // Short enters via SELL, exits via BUY.
        let short = trade(side: .short, plannedEntry: 50, entryFill: 49.90, plannedExit: 45, exitFill: 45.09)
        #expect(abs((short.entrySlippageBps ?? .nan) - 20.0) < 1e-6)
        #expect(abs((short.exitSlippageBps ?? .nan) - 20.0) < 1e-6)
    }

    // MARK: Nil-fill never fabricates

    @Test func nilFillNeverFabricates() {
        #expect(trade(plannedEntry: 100, entryFill: nil).entrySlippageBps == nil)
        #expect(trade(plannedEntry: nil, entryFill: 100.1).entrySlippageBps == nil)
        #expect(TradeRecord.legSlippageBps(planned: 0, fill: 100, isBuy: true) == nil)
        #expect(TradeRecord.legSlippageBps(planned: 100, fill: 0, isBuy: true) == nil)
        #expect(TradeRecord.legSlippageBps(planned: -5, fill: 100, isBuy: true) == nil)
        // An OPEN trade with both exit fields somehow set => exitSlippageBps nil (closed-only).
        let openWithExitFields = trade(plannedExit: 105, exitFill: 104.9, closed: false)
        #expect(openWithExitFields.isOpen == true)
        #expect(openWithExitFields.exitSlippageBps == nil)
    }

    // MARK: measuredSlippage — n<5 gate, median, assumed comparison, closed-only aggregation

    @Test func minLegsGate() {
        let four = (0..<4).map { trade(plannedEntry: 100, entryFill: 100 + Double($0)) }
        let m4 = StockSageJournal.measuredSlippage(four)
        #expect(m4?.legs == 4)
        #expect(m4?.meetsFloor == false)
        let five = four + [trade(plannedEntry: 100, entryFill: 105)]
        let m5 = StockSageJournal.measuredSlippage(five)
        #expect(m5?.legs == 5)
        #expect(m5?.meetsFloor == true)
        #expect(StockSageJournal.measuredSlippage([]) == nil)
    }

    @Test func medianHandDerivedOddAndEven() {
        // Each fixture contributes exactly ONE entry leg (long/buy); no exit-leg fields, so exit
        // never contributes a second leg per trade.
        func legTrade(bps: Double) -> TradeRecord {
            let planned = 100.0
            let fill = planned * (1 + bps / 10_000)
            return trade(plannedEntry: planned, entryFill: fill)
        }
        let odd = [10.0, 20, 30, 40, 50].map(legTrade)
        let oddResult = StockSageJournal.measuredSlippage(odd)
        #expect(oddResult?.legs == 5)
        #expect(abs((oddResult?.medianBps ?? .nan) - 30.0) < 1e-6)   // {10,20,30,40,50} => middle = 30

        let even = [10.0, 20, 30, 40].map(legTrade)
        let evenResult = StockSageJournal.measuredSlippage(even)
        #expect(evenResult?.legs == 4)
        #expect(abs((evenResult?.medianBps ?? .nan) - 25.0) < 1e-6)  // {10,20,30,40} => (20+30)/2 = 25
    }

    @Test func assumedComparisonHandDerivedAAPLAndBTC() {
        // Assumed round-trip bps pinned against StockSageNetEdge.defaultCosts's ratified table
        // (spec-fidelity — read from the spec, not the code under test's output):
        //   US large-cap (AAPL): spread 8 + slippage 5 = 13 bps round-trip => 6.5 bps/leg.
        //   crypto (-USD, BTC-USD): spread 30 + slippage 20 + takerFee 20 = 70 bps round-trip => 35.0 bps/leg.
        let aapl = trade(symbol: "AAPL", plannedEntry: 100, entryFill: 100.10)
        let btc = trade(symbol: "BTC-USD", plannedEntry: 100, entryFill: 100.20)
        let m = StockSageJournal.measuredSlippage([aapl, btc])
        #expect(m?.legs == 2)
        #expect(abs((m?.assumedMedianBpsPerLeg ?? .nan) - 20.75) < 1e-9)   // (6.5 + 35.0) / 2
    }

    @Test func openTradeContributesZeroLegs() {
        let open = trade(plannedEntry: 100, entryFill: 100.5, closed: false)
        #expect(StockSageJournal.measuredSlippage([open]) == nil)
    }

    // MARK: Slippage in R (2026-07-17) — cost expressed in the journal's own R unit
    @Test func slippageInRHandDerived() {
        // riskPerShare = |entry−stop| = |100−95| = 5. Entry leg planned 100, fill 100.25 ⇒ +25 bps
        // ⇒ price cost 0.25 ⇒ 0.25/5 = +0.05R. Exit leg planned 110, fill 109.78 (sell) ⇒ +20 bps
        // ⇒ price cost 110·0.0020 = 0.22 ⇒ 0.22/5 = +0.044R.
        let long = trade(side: .long, plannedEntry: 100, entryFill: 100.25, plannedExit: 110, exitFill: 109.78)
        #expect(abs((long.entrySlippageR ?? .nan) - 0.05) < 1e-9)
        #expect(abs((long.exitSlippageR ?? .nan) - 0.044) < 1e-9)
        // A single-trade book meets no floor, but totalR/perTradeR are computed regardless of the floor.
        // Five identical trades ⇒ meetsFloor, perTradeR = 0.05+0.044 = 0.094R, totalR = 5×0.094 = 0.47R.
        let five = (0..<5).map { _ in trade(side: .long, plannedEntry: 100, entryFill: 100.25,
                                            plannedExit: 110, exitFill: 109.78) }
        guard let m = StockSageJournal.measuredSlippage(five) else { Issue.record("expected a fit"); return }
        #expect(m.meetsFloor)
        #expect(abs(m.perTradeR - 0.094) < 1e-9)
        #expect(abs(m.totalR - 0.47) < 1e-9)
        // Positive slippage ⇒ positive R cost (drag). A leg with no planned price ⇒ nil R, no fabrication.
        #expect(trade(plannedEntry: nil, entryFill: 100.25).entrySlippageR == nil)
        // Zero risk (entry == stop) ⇒ R undefined, not infinite.
        let flat = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 100, target: nil, shares: 1,
                               openedAt: Date(timeIntervalSince1970: 0), exitPrice: 105,
                               closedAt: Date(timeIntervalSince1970: 100), plannedEntry: 100, entryFill: 100.25)
        #expect(flat.entrySlippageR == nil)
    }

    // MARK: Store close() persistence + existing-call-site compatibility

    private func isolatedStore() -> (store: StockSageJournalStore, defaults: UserDefaults, suite: String) {
        let suite = "journal.slippage.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1"), defaults, suite)
    }

    @Test func closePersistsExitPairAcrossStores() {
        let (a, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let t = TradeRecord(symbol: "AAPL", side: .long, entry: 100, stop: 95, target: nil, shares: 1,
                            openedAt: Date(timeIntervalSince1970: 0))
        a.add(t)
        a.close(t.id, exitPrice: 105, plannedExit: 106, exitFill: 105.8, at: Date(timeIntervalSince1970: 100))
        let b = StockSageJournalStore(defaults: defaults, key: "stocksage.journal.v1")
        let reloaded = b.trades.first { $0.id == t.id }
        #expect(reloaded?.plannedExit == 106)
        #expect(reloaded?.exitFill == 105.8)
        #expect(reloaded?.closedAt != nil)
    }

    @Test func existingCallSitesStillCompileAndBehaveIdentically() {
        // TradeRecord(...) without the new params, and close(id, exitPrice:) without the new
        // params — both must still work and leave the new fields nil.
        let t = TradeRecord(symbol: "X", side: .long, entry: 100, stop: 95, target: nil, shares: 1,
                            openedAt: Date(timeIntervalSince1970: 0))
        #expect(t.plannedEntry == nil && t.entryFill == nil && t.plannedExit == nil && t.exitFill == nil)
        let (store, defaults, suite) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.add(t)
        store.close(t.id, exitPrice: 105)
        #expect(store.trades.first?.plannedExit == nil && store.trades.first?.exitFill == nil)
        #expect(store.trades.first?.exitPrice == 105)
    }
}
