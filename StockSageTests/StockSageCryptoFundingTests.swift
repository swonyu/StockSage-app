import Testing
@testable import StockSage

// MARK: - Crypto perp funding drag (CRYPTO_RISK #4). Literals from /tmp/derive_cryptorisk.swift.

struct StockSageCryptoFundingTests {
    typealias F = StockSageCryptoFunding

    @Test func algebraPinsTheRateDayLeverageChain() {
        // derive: lev 1 · (3650bps/10 000/365) · 365d ÷ 0.05 risk = 7.3R exactly.
        let d = F.drag(spotNetExpectancyR: 10, riskFractionOfEquity: 0.05,
                       leverage: 1, holdDays: 365, annualFundingBps: (low: 3650, high: 3650))
        guard let d else { Issue.record("drag nil on valid inputs"); return }
        #expect(abs(d.fundingDragRMid - 7.3) < 1e-9 && abs(d.fundingDragRHigh - 7.3) < 1e-9)
        #expect(abs(d.netEdgeRAfterFunding - 2.7) < 1e-9 && d.stillPositiveMid)
    }

    @Test func dragIsMonotonicInLeverageHoldAndRate() {
        // derive: base (lev 1, hold 10, band 300–3000 → mid 1650, risk 0.05) = 0.09041095890410959.
        func mid(lev: Double = 1, hold: Double = 10, band: (low: Double, high: Double) = (300, 3000)) -> Double {
            F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0.05, leverage: lev,
                   holdDays: hold, annualFundingBps: band)!.fundingDragRMid
        }
        #expect(abs(mid() - 0.09041095890410959) < 1e-9)
        #expect(mid(lev: 2) > mid() && mid(hold: 20) > mid() && mid(band: (600, 6000)) > mid())
        #expect(F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0.05, leverage: 1, holdDays: 0)!.fundingDragRMid == 0)
    }

    @Test func fundingCanFlipAPositiveSpotEdgeNegative() {
        // spot +0.5R, drag mid 7.3R → after −6.8R: the sign-flip the spot backtest can't see.
        let d = F.drag(spotNetExpectancyR: 0.5, riskFractionOfEquity: 0.05,
                       leverage: 1, holdDays: 365, annualFundingBps: (low: 3650, high: 3650))
        guard let d else { Issue.record("drag nil"); return }
        #expect(!d.stillPositiveMid && d.netEdgeRAfterFunding < 0)
        #expect(d.note.lowercased().contains("funding"))
        #expect(d.fundingDragRHigh >= d.fundingDragRMid)
    }

    @Test func negativeBandRendersASignSafeCreditNeverADoubleSign() {
        // Hand-derived (independent of the format code): lev 1 · (−3650bps/10 000/365) · 365d ÷ 0.05
        // = −7.3R drag (a CREDIT); after = 0.5 − (−7.3) = 7.8R. Effect-on-edge rendering: −(−7.3)
        // via %+.2f → "+7.30"; a positive-band drag renders "-7.30" (one sign, never "−-").
        let credit = F.drag(spotNetExpectancyR: 0.5, riskFractionOfEquity: 0.05,
                            leverage: 1, holdDays: 365, annualFundingBps: (low: -3650, high: -3650))
        guard let credit else { Issue.record("drag nil on negative band"); return }
        #expect(abs(credit.fundingDragRMid - (-7.3)) < 1e-9 && abs(credit.netEdgeRAfterFunding - 7.8) < 1e-9)
        #expect(credit.stillPositiveMid)
        #expect(credit.note.contains("+7.30R mid (+7.30R at the high band)"))
        #expect(credit.note.contains("+7.80R left"))
        #expect(!credit.note.contains("−-") && !credit.note.contains("--") && !credit.note.contains("+-"))
        #expect(credit.note.contains("flip sign"))   // sign-flip disclosure survives the reformat
        let cost = F.drag(spotNetExpectancyR: 0.5, riskFractionOfEquity: 0.05,
                          leverage: 1, holdDays: 365, annualFundingBps: (low: 3650, high: 3650))
        guard let cost else { Issue.record("drag nil on positive band"); return }
        #expect(cost.note.contains("-7.30R mid (-7.30R at the high band)"))
    }

    @Test func honestyStringsAndGuards() {
        let d = F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0.05, leverage: 2, holdDays: 5)
        guard let d else { Issue.record("drag nil"); return }
        let n = d.note.lowercased(), c = d.caveat.lowercased()
        #expect(n.contains("flip sign") && n.contains("pays"))          // negative-funding disclosure
        #expect(n.contains("not a forecast") && c.contains("estimate")) // 'forecast' only negated
        #expect(!n.contains("guarantee") && !c.contains("guarantee"))
        // Degenerate inputs → nil, never a fake 0-cost read.
        #expect(F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0.05, leverage: 0, holdDays: 5) == nil)
        #expect(F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0, leverage: 1, holdDays: 5) == nil)
        #expect(F.drag(spotNetExpectancyR: 1, riskFractionOfEquity: 0.05, leverage: 1, holdDays: -1) == nil)
    }
}
