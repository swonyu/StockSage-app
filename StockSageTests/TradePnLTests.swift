import Testing
import Foundation
@testable import StockSage

// MARK: - Trade Record P&L Tests (2026-07-27)
//
// Comprehensive test suite for trade journal P&L calculations, R-multiples,
// and execution slippage measurements. Ensures math is correct, honest, and
// handles edge cases properly.

@Suite("Trade P&L Calculations")
struct TradePnLTests {
    
    // MARK: - Long Trade Tests
    
    @Test("Long trade profit calculation")
    func longTradeProfit() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: 100,
            openedAt: .now
        )
        
        // At entry: break-even
        #expect(trade.profit(at: 100.0) == 0.0)
        
        // At target: $1000 profit
        #expect(trade.profit(at: 110.0) == 1000.0)
        
        // At stop: -$500 loss
        #expect(trade.profit(at: 95.0) == -500.0)
        
        // Double position: -$1000 loss
        #expect(trade.profit(at: 90.0) == -1000.0)
    }
    
    @Test("Long trade R-multiple")
    func longTradeRMultiple() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,  // Risk per share: $5
            target: 110.0,
            shares: 100,
            openedAt: .now
        )
        
        // At entry: 0R
        #expect(trade.rMultiple(at: 100.0) == 0.0)
        
        // At target (+$10): 2R
        #expect(trade.rMultiple(at: 110.0) == 2.0)
        
        // At stop (-$5): -1R
        #expect(trade.rMultiple(at: 95.0) == -1.0)
        
        // At +$2.50: 0.5R
        #expect(trade.rMultiple(at: 102.5) == 0.5)
    }
    
    @Test("Long trade risk per share")
    func longTradeRisk() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 150.0,
            stop: 145.0,
            target: nil,
            shares: 50,
            openedAt: .now
        )
        
        #expect(trade.riskPerShare == 5.0)
    }
    
    // MARK: - Short Trade Tests
    
    @Test("Short trade profit calculation")
    func shortTradeProfit() {
        let trade = TradeRecord(
            symbol: "TSLA",
            side: .short,
            entry: 200.0,
            stop: 210.0,
            target: 180.0,
            shares: 50,
            openedAt: .now
        )
        
        // At entry: break-even
        #expect(trade.profit(at: 200.0) == 0.0)
        
        // At target: $1000 profit (sold at 200, bought at 180)
        #expect(trade.profit(at: 180.0) == 1000.0)
        
        // At stop: -$500 loss (sold at 200, bought at 210)
        #expect(trade.profit(at: 210.0) == -500.0)
        
        // Adverse move: -$1500 loss
        #expect(trade.profit(at: 230.0) == -1500.0)
    }
    
    @Test("Short trade R-multiple")
    func shortTradeRMultiple() {
        let trade = TradeRecord(
            symbol: "TSLA",
            side: .short,
            entry: 200.0,
            stop: 210.0,  // Risk per share: $10
            target: 180.0,
            shares: 100,
            openedAt: .now
        )
        
        // At entry: 0R
        #expect(trade.rMultiple(at: 200.0) == 0.0)
        
        // At target (-$20): 2R
        #expect(trade.rMultiple(at: 180.0) == 2.0)
        
        // At stop (+$10): -1R
        #expect(trade.rMultiple(at: 210.0) == -1.0)
        
        // At -$5: 0.5R
        #expect(trade.rMultiple(at: 195.0) == 0.5)
    }
    
    @Test("Short trade risk per share")
    func shortTradeRisk() {
        let trade = TradeRecord(
            symbol: "TSLA",
            side: .short,
            entry: 300.0,
            stop: 315.0,
            target: 270.0,
            shares: 20,
            openedAt: .now
        )
        
        #expect(trade.riskPerShare == 15.0)
    }
    
    // MARK: - Slippage Tests
    
    @Test("Long entry slippage in basis points")
    func longEntrySlippage() {
        // Planned entry: $100, filled at $100.50
        let slippage = TradeRecord.legSlippageBps(planned: 100.0, fill: 100.5, isBuy: true)
        #expect(slippage == 50.0)  // 50 bps = 0.5% worse
        
        // Price improvement: filled better than planned
        let improvement = TradeRecord.legSlippageBps(planned: 100.0, fill: 99.5, isBuy: true)
        #expect(improvement == -50.0)  // -50 bps = saved 0.5%
    }
    
    @Test("Short entry slippage in basis points")
    func shortEntrySlippage() {
        // Planned short: $200, filled at $199.50 (worse - sold lower)
        let slippage = TradeRecord.legSlippageBps(planned: 200.0, fill: 199.5, isBuy: false)
        #expect(slippage == 25.0)  // 25 bps worse
        
        // Price improvement: sold higher than planned
        let improvement = TradeRecord.legSlippageBps(planned: 200.0, fill: 200.5, isBuy: false)
        #expect(improvement == -25.0)  // -25 bps = gained 0.25%
    }
    
    @Test("Trade with entry slippage")
    func tradeWithEntrySlippage() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: 100,
            openedAt: .now,
            plannedEntry: 100.0,
            entryFill: 100.25  // 25 bps worse
        )
        
        #expect(trade.entrySlippageBps == 25.0)
        
        // Slippage in R: 0.25 / 5 = 0.05R
        #expect(trade.entrySlippageR == 0.05)
    }
    
    @Test("Trade with exit slippage")
    func tradeWithExitSlippage() throws {
        var trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: 100,
            openedAt: .now,
            exitPrice: 110.0,
            closedAt: .now
        )
        
        // Close with slippage
        trade.plannedExit = 110.0
        trade.exitFill = 109.5  // Sold 0.5 lower (negative for long exit)
        
        // Hand-derived: 0.5 slip on the 110.0 planned exit = 0.5/110 × 10_000 = 500/11 ≈ 45.4545 bps.
        // (Review triage: the original asserted a truncated 45.45 with ==, which the engine's
        // exact value rightly fails.)
        let bps = try #require(trade.exitSlippageBps)
        #expect(abs(bps - 500.0 / 11.0) < 0.001, "Exit slippage should be ≈45.45 bps")

        // Exit slippage in R: 0.5 / 5 = 0.1R cost (the original asserted 0.09 against its own
        // derivation comment; 0.1 is exact at these fixture values).
        let slippageR = try #require(trade.exitSlippageR)
        #expect(abs(slippageR - 0.1) < 1e-9, "Exit slippage should be 0.1R")
    }
    
    @Test("Slippage with missing data returns nil")
    func slippageWithMissingData() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: nil,
            shares: 100,
            openedAt: .now
        )
        
        // No planned/fill data = nil slippage
        #expect(trade.entrySlippageBps == nil)
        #expect(trade.exitSlippageBps == nil)
        #expect(trade.entrySlippageR == nil)
        #expect(trade.exitSlippageR == nil)
    }
    
    // MARK: - Edge Cases
    
    @Test("Zero-risk trade (invalid setup)")
    func zeroRiskTrade() {
        let trade = TradeRecord(
            symbol: "TEST",
            side: .long,
            entry: 100.0,
            stop: 100.0,  // Same as entry = zero risk
            target: 110.0,
            shares: 100,
            openedAt: .now
        )
        
        #expect(trade.riskPerShare == 0.0)
        
        // R-multiple calculation should not divide by zero.
        // Contract fix (review triage): the engine's DOCUMENTED behavior for zero risk is
        // nil — "R is undefined, not infinite" (StockSageJournal.rMultiple doc + existing
        // suite pins it). The original assertion expected Inf/NaN, a contract that never
        // existed; the test bends to the engine, never the reverse.
        let r = trade.rMultiple(at: 110.0)
        #expect(r == nil)
    }
    
    @Test("Negative shares (invalid)")
    func negativeShares() {
        let trade = TradeRecord(
            symbol: "TEST",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: -50,  // Invalid
            openedAt: .now
        )
        
        // Profit calculation should still work mathematically
        #expect(trade.profit(at: 110.0) == -500.0)  // Inverted sign
    }
    
    @Test("Extreme price movements")
    func extremePriceMovements() {
        let trade = TradeRecord(
            symbol: "MEME",
            side: .long,
            entry: 10.0,
            stop: 9.0,
            target: 15.0,
            shares: 1000,
            openedAt: .now
        )
        
        // 10x gain
        #expect(trade.profit(at: 100.0) == 90_000.0)
        #expect(trade.rMultiple(at: 100.0) == 90.0)  // 90R
        
        // Total wipeout
        #expect(trade.profit(at: 0.0) == -10_000.0)
        #expect(trade.rMultiple(at: 0.0) == -10.0)  // -10R
    }
    
    @Test("Fractional shares")
    func fractionalShares() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 150.0,
            stop: 145.0,
            target: 160.0,
            shares: 10.5,  // Fractional share
            openedAt: .now
        )
        
        // $5 profit per share × 10.5 shares
        #expect(trade.profit(at: 155.0) == 52.5)
        #expect(trade.rMultiple(at: 155.0) == 1.0)
    }
    
    @Test("SAR currency conversion scenario")
    func sarCurrencyTrade() {
        // Saudi stock: entry in SAR, needs USD conversion for portfolio
        let trade = TradeRecord(
            symbol: "2222.SR",
            side: .long,
            entry: 100.0,  // SAR
            stop: 95.0,
            target: 110.0,
            shares: 200,
            openedAt: .now
        )
        
        // P&L in SAR
        let pnlSAR = trade.profit(at: 105.0)
        #expect(pnlSAR == 1000.0)  // 200 shares × 5 SAR
        
        // Convert to USD at 3.75 SAR/USD
        let pnlUSD = pnlSAR / 3.75
        #expect(abs(pnlUSD - 266.67) < 0.01)
    }
}

@Suite("Trade State Tests")
struct TradeStateTests {
    
    @Test("Open trade identification")
    func openTrade() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: 100,
            openedAt: .now
        )
        
        #expect(trade.isOpen == true)
        #expect(trade.exitPrice == nil)
        #expect(trade.closedAt == nil)
    }
    
    @Test("Closed trade identification")
    func closedTrade() {
        let trade = TradeRecord(
            symbol: "AAPL",
            side: .long,
            entry: 100.0,
            stop: 95.0,
            target: 110.0,
            shares: 100,
            openedAt: .now,
            exitPrice: 108.0,
            closedAt: .now
        )
        
        #expect(trade.isOpen == false)
        #expect(trade.exitPrice != nil)
        #expect(trade.closedAt != nil)
    }
}

@Suite("Journal Statistics Tests")
struct JournalStatisticsTests {
    
    @Test("Win rate calculation")
    func winRateCalculation() {
        let trades = [
            TradeRecord(symbol: "A", side: .long, entry: 100, stop: 95, target: 110, shares: 10, 
                       openedAt: .now, exitPrice: 108, closedAt: .now),  // Win
            TradeRecord(symbol: "B", side: .long, entry: 50, stop: 48, target: 55, shares: 20, 
                       openedAt: .now, exitPrice: 53, closedAt: .now),   // Win
            TradeRecord(symbol: "C", side: .long, entry: 200, stop: 195, target: 210, shares: 5, 
                       openedAt: .now, exitPrice: 196, closedAt: .now),  // Loss
        ]
        
        let wins = trades.filter { 
            guard let exit = $0.exitPrice else { return false }
            return $0.profit(at: exit) > 0
        }.count
        
        let winRate = Double(wins) / Double(trades.count)
        #expect(abs(winRate - 0.6667) < 0.01)  // 66.67%
    }
    
    @Test("Average R-multiple")
    func averageRMultiple() {
        let trades = [
            TradeRecord(symbol: "A", side: .long, entry: 100, stop: 95, target: 110, shares: 10, 
                       openedAt: .now, exitPrice: 110, closedAt: .now),  // 2R
            TradeRecord(symbol: "B", side: .long, entry: 100, stop: 95, target: 110, shares: 10, 
                       openedAt: .now, exitPrice: 102.5, closedAt: .now), // 0.5R
            TradeRecord(symbol: "C", side: .long, entry: 100, stop: 95, target: 110, shares: 10, 
                       openedAt: .now, exitPrice: 95, closedAt: .now),   // -1R
        ]
        
        // Review triage: the original closure shadowed $0 (calling rMultiple on a Double)
        // and blew the type-checker budget; the engine already exposes realizedR for this.
        // Hand-derived: A (110-100)/5 = 2R, B 0.5R, C -1R -> avg 0.5R over 3 closes.
        let rs = trades.compactMap(\.realizedR)
        #expect(rs.count == 3)
        let avgR = rs.reduce(0.0, +) / Double(rs.count)
        #expect(abs(avgR - 0.5) < 0.01)
    }
}
