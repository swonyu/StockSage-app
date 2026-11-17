import Testing
import Foundation
@testable import StockSage

// The whole-market socket republishes the LAST trade for every selected symbol on every 250 ms
// publication, so most symbols in a cycle carry a tick identical to the one already stored. Those
// ticks are rejected by `acceptsQuote` anyway; skipping them early avoids the merge work.
//
// The contract that matters here is the SAFE DIRECTION: `tickIsRedundant` must be a STRICT SUBSET
// of what `acceptsQuote` rejects. Skipping one tick that would have been accepted freezes a price
// on screen, which is far worse than doing redundant work, so every test below that asserts
// "not redundant" is guarding against over-eager skipping.
struct StockSageRedundantTickTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick(_ price: Double = 100, at when: Date? = nil, sequence: Int64? = 7) -> StockSageLiveStream.Tick {
        .init(symbol: "AAPL", price: price, timestamp: when ?? at, sequence: sequence)
    }
    private func quote(marketTime: Date?, sequence: Int64?,
                       source: StockSagePriceSource? = .massiveSIP) -> StockSageQuote {
        StockSageQuote(price: 100, previousPrice: 99, marketTime: marketTime,
                       massiveTradeSequence: sequence, priceSource: source)
    }

    @Test func theSameTradeRepublishedIsRedundant() {
        #expect(StockSageStore.tickIsRedundant(tick(), prior: quote(marketTime: at, sequence: 7)))
    }

    @Test func aNewerTradeAtTheSameTimestampIsNotRedundant() {
        // acceptsQuote breaks an equal-timestamp tie on a strictly greater sequence, so this tick
        // WOULD be applied. Skipping it would freeze the price.
        #expect(!StockSageStore.tickIsRedundant(tick(sequence: 8), prior: quote(marketTime: at, sequence: 7)))
    }

    @Test func aLaterTimestampIsNeverRedundantEvenWithAnEqualSequence() {
        #expect(!StockSageStore.tickIsRedundant(tick(at: at.addingTimeInterval(1), sequence: 7),
                                                prior: quote(marketTime: at, sequence: 7)))
    }

    @Test func anUnknownSequenceOnEitherSideIsNeverTreatedAsRedundant() {
        // An unknown sequence cannot prove the two ticks are the same trade, so it must not skip.
        #expect(!StockSageStore.tickIsRedundant(tick(sequence: nil), prior: quote(marketTime: at, sequence: 7)))
        #expect(!StockSageStore.tickIsRedundant(tick(sequence: 7), prior: quote(marketTime: at, sequence: nil)))
    }

    @Test func aRowWithNoPriorObservationIsNeverRedundant() {
        #expect(!StockSageStore.tickIsRedundant(tick(), prior: nil))
        #expect(!StockSageStore.tickIsRedundant(tick(), prior: quote(marketTime: nil, sequence: 7)))
    }

    @Test func aNonSIPPriorIsNeverRedundant() {
        // acceptsQuote nils a `.sample` current outright, and a non-SIP source is a different
        // ordering regime, so neither may be compared by SIP sequence.
        #expect(!StockSageStore.tickIsRedundant(tick(), prior: quote(marketTime: at, sequence: 7, source: .sample)))
        #expect(!StockSageStore.tickIsRedundant(tick(), prior: quote(marketTime: at, sequence: 7, source: .yahoo)))
    }

    // The property that makes the optimisation safe, checked against acceptsQuote itself.
    @Test func everyRedundantTickIsOneAcceptsQuoteWouldHaveRejected() {
        let times = [at, at.addingTimeInterval(-1), at.addingTimeInterval(1)]
        let sequences: [Int64?] = [nil, 0, 7, 8]
        let sources: [StockSagePriceSource?] = [.massiveSIP, .yahoo, .sample, nil]
        for time in times {
            for priorSeq in sequences {
                for tickSeq in sequences {
                    for source in sources {
                        let prior = quote(marketTime: time, sequence: priorSeq, source: source)
                        let incoming = tick(sequence: tickSeq)
                        guard StockSageStore.tickIsRedundant(incoming, prior: prior) else { continue }
                        #expect(!StockSageStore.acceptsQuote(incoming.timestamp, after: prior.marketTime,
                            massiveTradeSequence: incoming.sequence, afterMassiveTradeSequence: prior.massiveTradeSequence,
                            priceSource: .massiveSIP, afterPriceSource: prior.priceSource, now: at.addingTimeInterval(60)),
                            "tickIsRedundant skipped a tick acceptsQuote would have APPLIED")
                    }
                }
            }
        }
    }
}
