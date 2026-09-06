import Testing
@testable import StockSage

// MARK: - PriceFlash.direction(from:to:) — W3 (owner: "live prices … seamless and look cool")
//
// Pure helper behind the `.priceFlash(_:)` view modifier: which way (if any) a price moved.
// No view, no `@State`, no clock — just the two prices. The straddle that matters here is
// EQUAL price (a poll re-confirming the same number, or two ticks with no real move) — that
// must report nil (no flash), never fabricate an "up" or "down" out of a non-move.
struct MarketsPriceFlashDirectionTests {
    typealias Flash = PriceFlash

    @Test func straddleAtEqualPriceFlashesNothing() {
        #expect(Flash.direction(from: 100, to: 100) == nil)
        // Straddle either side of equal — one cent below and above the boundary really do flash.
        #expect(Flash.direction(from: 99.99, to: 100) == .up)
        #expect(Flash.direction(from: 100.01, to: 100) == .down)
    }

    @Test func risingPriceFlashesUp() {
        #expect(Flash.direction(from: 150, to: 155.25) == .up)
    }

    @Test func fallingPriceFlashesDown() {
        #expect(Flash.direction(from: 305, to: 300) == .down)
    }

    @Test func eitherSideMissingFlashesNothing() {
        #expect(Flash.direction(from: nil, to: 100) == nil)
        #expect(Flash.direction(from: 100, to: nil) == nil)
        #expect(Flash.direction(from: nil, to: nil) == nil)
    }
}
