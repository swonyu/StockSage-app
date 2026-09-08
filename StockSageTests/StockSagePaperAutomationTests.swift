import Foundation
import Testing
@testable import StockSage

@Suite("Qwen paper automation") @MainActor
struct StockSagePaperAutomationTests {
    typealias A = StockSagePaperAutomation
    private let now = Date(timeIntervalSince1970: 1_788_886_800) // 2026-09-08, US regular session.
    private func quote(_ symbol: String = "AAPL", price: Double = 100, at: Date,
                       source: StockSagePriceSource = .massiveSIP) -> StockSageQuoteService.LiveQuote {
        .init(symbol: symbol, price: price, previousClose: 100, marketTime: at, priceSource: source)
    }

    @Test func paperCashCostsAndLaterFillAreReproducible() throws {
        #expect(A.regularHours(now))
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.propose(symbol: "AAPL", action: .strongBuy, at: now)
        #expect(book.pending.count == 1 && book.cash == 10_000)
        book.settle(quotes: ["AAPL": quote(at: now)], at: now.addingTimeInterval(1))
        #expect(book.open.isEmpty, "A quote from before or at decision time cannot fill the order")
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(book.valid && book.open.count == 1 && book.open[0].shares == 19 && book.cash == 8098.1)
        let persisted = try JSONDecoder().decode(A.Book.self, from: JSONEncoder().encode(book))
        book = persisted
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        #expect(book.trades.count == 1, "Restart/repeated observations cannot duplicate a fill")
        book.propose(symbol: "AAPL", action: .sell, at: now.addingTimeInterval(3))
        book.settle(quotes: ["AAPL": quote(price: 105, at: now.addingTimeInterval(4))], at: now.addingTimeInterval(5))
        #expect(book.valid && book.open.isEmpty && book.cash == 10_091.11)
        #expect(book.equity(quotes: [:], at: now.addingTimeInterval(5)) == book.cash)
    }

    @Test func badQuotesAndExpiredDecisionsCannotTrade() {
        for q in [quote(at: now.addingTimeInterval(-300)), quote(at: now.addingTimeInterval(30)),
                  quote(at: now.addingTimeInterval(1), source: .yahoo),
                  quote("MSFT", at: now.addingTimeInterval(1)), quote(price: .nan, at: now.addingTimeInterval(1))] {
            var book = A.Book()
            book.propose(symbol: "AAPL", action: .buy, at: now)
            book.settle(quotes: ["AAPL": q], at: now.addingTimeInterval(2))
            #expect(book.open.isEmpty && book.cash == 10_000)
            book.settle(quotes: [:], at: now.addingTimeInterval(120))
            #expect(book.pending.isEmpty && book.decisions.last?.action == "Expired")
        }
    }

    @Test func cashAndPositionCapsCannotBeOverriddenByOpinion() {
        var book = A.Book()
        let names = ["AAPL", "MSFT", "ORCL", "NVDA", "GOOG", "META"]
        for symbol in names { book.propose(symbol: symbol, action: .strongBuy, at: now) }
        #expect(book.pending.count == 5)
        let quotes = Dictionary(uniqueKeysWithValues: names.map { ($0, quote($0, at: now.addingTimeInterval(1))) })
        book.settle(quotes: quotes, at: now.addingTimeInterval(2))
        #expect(book.valid && book.open.count == 5 && book.cash >= 0)
        #expect(book.open.allSatisfy { A.Book.money($0.entry * $0.shares) <= 2_000 })
        book.propose(symbol: "META", action: .buy, at: now.addingTimeInterval(3))
        #expect(book.pending.isEmpty)
        #expect(book.equity(quotes: [:], at: now) == nil, "Missing marks cannot become zero-valued holdings")
        #expect(!A.validSymbol("2222.SR") && !A.validSymbol("BTC-USD") && !A.validSymbol("^GSPC"))
    }

    @Test func stopUsesSubsequentObservedPriceNotAnInventedStopFill() {
        var book = A.Book()
        book.propose(symbol: "AAPL", action: .buy, at: now)
        book.settle(quotes: ["AAPL": quote(at: now.addingTimeInterval(1))], at: now.addingTimeInterval(2))
        book.settle(quotes: ["AAPL": quote(price: 96, at: now.addingTimeInterval(3))], at: now.addingTimeInterval(4))
        #expect(book.open.count == 1 && book.pending.count == 1)
        book.settle(quotes: ["AAPL": quote(price: 94, at: now.addingTimeInterval(5))], at: now.addingTimeInterval(6))
        #expect(book.open.isEmpty && abs((book.trades[0].exitPrice ?? 0) - 93.906) < 0.000001)
        #expect(book.trades[0].exitPrice != book.trades[0].stop)
    }

    @Test func accountLeasePersistenceAndCorruptionProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "qwen-paper-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let url = root.appendingPathComponent("account.json")
        let first = A(url: url, defaults: defaults)
        let second = A(url: url, defaults: defaults)
        #expect(first.acquire() && !second.acquire())
        var book = A.Book()
        book.note(action: "Fixture research", reason: "Synthetic evidence", at: now)
        #expect(first.save(book))
        let before = try Data(contentsOf: url)
        var invalid = book; invalid.version = 999
        #expect(!first.save(invalid))
        #expect(try Data(contentsOf: url) == before)
        first.stop()
        #expect(second.acquire() && second.book.cash == 10_000)
        second.stop()
        try Data("broken".utf8).write(to: url)
        let corrupt = A(url: url, defaults: defaults)
        #expect(!corrupt.acquire() && corrupt.error != nil)
        #expect(try Data(contentsOf: url) == Data("broken".utf8))
    }
}
