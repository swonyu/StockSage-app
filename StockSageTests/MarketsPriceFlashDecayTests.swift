import Testing
import Foundation
import SwiftUI
@testable import StockSage

// A price flash that never ends is not a flash. The stream publishes four times a second, so a
// moving symbol changes price more often than the 600 ms decay — and restarting the decay timer on
// every change meant the row stayed permanently tinted for as long as the symbol kept trading.
// Same failure as the per-tick haptic: a signal that fires continuously stops being a signal.
//
// The fix is one running decay per burst. The colour still tracks the LATEST move, so it never
// shows a stale direction; only the timer refuses to restart.
struct MarketsPriceFlashDecayTests {
    typealias F = PriceFlash
    private let first = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    @Test func theFirstMoveInABurstStartsADecayTimer() {
        let state = F.applying(.up, to: .init(), newTimer: first)
        #expect(state == F.FlashState(direction: .up, timer: first))
    }

    @Test func aSecondMoveKeepsTheRunningTimerSoTheFlashStillDecays() {
        var state = F.applying(.up, to: .init(), newTimer: first)
        state = F.applying(.down, to: state, newTimer: second)
        #expect(state.timer == first, "Restarting the timer is what made the tint permanent")
    }

    @Test func theColourStillFollowsTheMostRecentMove() {
        var state = F.applying(.up, to: .init(), newTimer: first)
        state = F.applying(.down, to: state, newTimer: second)
        #expect(state.direction == .down, "A stale direction would misreport which way the price moved")
    }

    @Test func expiryClearsBothSoTheNextBurstCanFlashAgain() {
        let expired = F.expired()
        #expect(expired.direction == nil && expired.timer == nil)
        let next = F.applying(.up, to: expired, newTimer: second)
        #expect(next.timer == second)
    }

    // The straddle the existing direction test pins: an unchanged price is not a move, so it must
    // not start a timer or tint a row.
    @Test func arepeatedPriceIsNotAMoveAndCannotStartAFlash() {
        #expect(F.direction(from: 100, to: 100) == nil)
        #expect(F.direction(from: nil, to: 100) == nil)
    }
}
