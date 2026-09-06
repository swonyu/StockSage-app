import Testing
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import StockSage

@Suite("Massive NBBO boundaries")
struct StockSageNBBOTests {
    typealias L = StockSageLiveStream
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func quote(bid: Double = 100.01, ask: Double = 100.03, size: Double = 100,
               offset: TimeInterval = 0, sequence: Int64? = 10, symbol: String = "AAPL") -> StockSageNBBO {
        .init(symbol: symbol, bid: bid, ask: ask, bidSize: size, askSize: size,
              bidExchange: 4, askExchange: 7, timestamp: now.addingTimeInterval(offset), sequence: sequence)
    }

    @Test("compact quote copy is dated, observational and keeps invalid sides explicit")
    func compactCopy() throws {
        let q = quote()
        let text = StockSageNBBO.compactText(q)
        #expect(text.contains("Bid") && text.contains("Ask") && text.contains("100"))
        #expect(text.contains("NBBO · Massive SIP"))
        #expect(text.contains(q.timestamp.formatted(date: .abbreviated, time: .standard)))
        #expect(text.contains("Observed spread 2.00 bps"))
        #expect(text.contains("last observed, not a fill quote"))
        #expect(!text.contains("Live") && !text.contains("guaranteed"))
        #expect(text.contains("Bid unknown #4 · ask unknown #7"))
        let venues: [Int64: StockSageMassiveTicks.Exchange] = [
            4: .init(id: 4, mic: "TEST", acronym: "TEST-BID"),
            7: .init(id: 7, mic: "TEST-ASK", acronym: nil)]
        let attributed = StockSageNBBO.compactText(q, exchanges: venues)
        #expect(attributed.contains("Bid TEST-BID · ask TEST-ASK"))
        // A historical spread remains a valid observation, never a fresh cost input.
        #expect(q.quotedSpreadBps != nil && q.spreadBps(at: now.addingTimeInterval(6)) == nil)
        #expect(StockSageNBBO.compactText(nil).contains("bid/ask unavailable; costs estimated"))
        #expect(StockSageNBBO.compactText(quote(bid: 0)).contains("Bid unavailable"))
        #expect(StockSageNBBO.compactText(quote(ask: .nan)).contains("Ask unavailable"))
        for q in [quote(bid: 101), quote(bid: 100, ask: 100), quote(size: 0)] {
            #expect(StockSageNBBO.compactText(q).contains("Spread unavailable"))
            #expect(q.quotedSpreadBps == nil)
        }
    }

    #if os(macOS)
    @MainActor @Test("render the actual compact component at phone width without app state or network")
    func renderCompactQuoteAtPhoneWidth() throws {
        let text = StockSageNBBO.compactText(quote())
        let view = StockSageNBBOCompactView(text: text).padding(12)
            .frame(width: 320).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/stocksage-nbbo-compact-320.png"), options: .atomic)
        #expect(image.size.width == 320 && image.size.height > 20)
    }
    #endif

    @Test("documented Q fields retain share sizes and exact sequence integers")
    func fixture() throws {
        let events = L.events(in: #"[{"ev":"Q","sym":"MSFT","bp":114.125,"bs":100,"bx":4,"ap":114.128,"as":160,"ax":7,"t":1536036818784,"q":9007199254740993}]"#)
        guard case .quote(let q) = try #require(events.first) else { Issue.record("Missing quote"); return }
        #expect(q.bid == 114.125 && q.ask == 114.128)
        #expect(q.bidSize == 100 && q.askSize == 160)
        #expect(q.bidExchange == 4 && q.askExchange == 7)
        #expect(q.sequence == 9_007_199_254_740_993)
        #expect(q.timestamp == Date(timeIntervalSince1970: 1_536_036_818.784))
    }

    @Test("spread is full round-trip crossing width, with freshness and validity gates")
    func spreadBoundaries() throws {
        let q = quote()
        #expect(abs(try #require(q.spreadBps(at: now)) - (0.02 / 100.02 * 10_000)) < 1e-9)
        #expect(q.spreadBps(at: now.addingTimeInterval(5)) != nil)
        #expect(q.spreadBps(at: now.addingTimeInterval(5.001)) == nil)
        #expect(q.spreadBps(at: now.addingTimeInterval(-0.001)) == nil)
        #expect(quote(bid: 100, ask: 100).spreadBps(at: now) == nil)
        for invalid in [quote(bid: 0), quote(ask: 0), quote(size: 0), quote(bid: 101),
                        quote(bid: .nan), quote(ask: .infinity), quote(size: -1)] {
            #expect(invalid.spreadBps(at: now) == nil)
        }
    }

    @Test("quote sequence only breaks equal-time ties for the same symbol and channel")
    func sequenceBoundaries() {
        let old = quote(sequence: 9_007_199_254_740_992)
        #expect(quote(sequence: 9_007_199_254_740_993).supersedes(old, now: now))
        #expect(!old.supersedes(old, now: now))
        #expect(!quote(sequence: nil).supersedes(old, now: now))
        #expect(!quote(sequence: 11).supersedes(quote(sequence: nil), now: now))
        #expect(!quote(offset: -1, sequence: Int64.max).supersedes(old, now: now))
        #expect(!quote(sequence: Int64.max, symbol: "MSFT").supersedes(old, now: now))
        #expect(quote(offset: 60, sequence: 1).supersedes(old, now: now))
        #expect(!quote(offset: 60.001).supersedes(old, now: now))
        #expect(quote(offset: 86_400, sequence: 1).supersedes(old, now: now.addingTimeInterval(86_400)))
    }

    @Test("authenticated quotes never suppress last-trade gap polling; withdrawal replaces old book")
    func independentClocks() {
        var state = L.StreamState()
        let q = quote()
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
        _ = state.consume(.status("auth_success"), requested: ["AAPL"], now: now)
        _ = state.consume(.quote(quote(symbol: "MSFT")), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes["AAPL"] == q)
        #expect(state.coveredSymbols(at: now).isEmpty)
        #expect(!state.hasRecentTrades(at: now))
        let withdrawal = quote(ask: 0, sequence: 11)
        _ = state.consume(.quote(withdrawal), requested: ["AAPL"], now: now)
        _ = state.consume(.quote(q), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes["AAPL"] == withdrawal)
        #expect(state.latestQuotes["AAPL"]?.spreadBps(at: now) == nil)
        _ = state.consume(.status("success"), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.count == 1)
        _ = state.consume(.status("auth_failed"), requested: ["AAPL"], now: now)
        #expect(state.latestQuotes.isEmpty)
    }

    @Test("mixed batches retain quotes and trades but reject malformed and boolean quote values")
    func mixedAndMalformedFrames() {
        let events = L.events(in: #"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":100,"ap":101,"bs":100,"as":100,"t":1700000000000,"q":1},{"ev":"T","sym":"AAPL","p":100.5,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":100,"ap":101,"bs":true,"as":100,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":100,"ap":"nan","bs":100,"as":100,"t":1700000000000}]"#)
        #expect(events.count == 3)
        var state = L.StreamState()
        let trades = events.compactMap { state.consume($0, requested: ["AAPL"], now: now) }
        #expect(trades.count == 1)
        #expect(state.latestQuotes.count == 1)
        #expect(state.coveredSymbols(at: now) == ["AAPL"])
    }

    @Test("quote conditions resolve from a complete reference; unknown/flagged metadata fails closed")
    func conditionQualification() throws {
        // Deliberately invented provider IDs: eligibility comes from the SIP mapping, not 0/1.
        let reference = Data(#"{"status":"OK","results":[{"id":801,"asset_class":"stocks","data_types":["quote"],"type":"quote_condition","sip_mapping":{"UTP":"R"}},{"id":802,"asset_class":"stocks","data_types":["quote"],"type":"quote_condition","sip_mapping":{"UTP":"N"}},{"id":803,"asset_class":"stocks","data_types":["quote"],"type":"quote_condition","legacy":true,"sip_mapping":{"UTP":"R"}}]}"#.utf8)
        let regular = try StockSageMassiveTicks.parseRegularQuoteConditions(reference)
        #expect(regular == [801])
        for metadata in [#""c":801"#, #""c":801,"i":[]"#, #""c":802"#, #""c":801,"i":[604]"#,
                         #""c":801,"i":[true]"#, #""c":801,"i":null"#, #""c":true"#, #""q":2"#] {
            let json = #"{"ev":"Q","sym":"AAPL","bp":100,"ap":101,"bs":100,"as":100,"t":1700000000000,"# + metadata + "}"
            guard case .quote(let q) = try #require(L.events(in: json).first) else { Issue.record("No quote"); continue }
            let qualified = q.qualifyingCosts(regularConditions: regular)
            #expect(qualified.costConditionVerified == (metadata == #""c":801"# || metadata == #""c":801,"i":[]"#))
            #expect(!q.qualifyingCosts(regularConditions: []).costConditionVerified)
        }
        for invalid in [#"{"status":"OK","results":[],"next_url":"https://example.test"}"#,
                        #"{"status":"OK","results":[{"id":1},{"id":1}]}"#,
                        #"{"status":"OK","results":[{"id":true}]}"#,
                        #"{"status":"ERROR","results":[]}"#] {
            #expect(throws: (any Error).self) { try StockSageMassiveTicks.parseRegularQuoteConditions(Data(invalid.utf8)) }
        }
    }

    func costQuote(ask: Double = 101, at: Date? = nil) -> StockSageNBBO {
        var q = StockSageNBBO(symbol: "AAPL", bid: 100, ask: ask, bidSize: 100, askSize: 100,
                              bidExchange: 4, askExchange: 7, timestamp: at ?? now, sequence: 1)
        q.condition = 801
        return q.qualifyingCosts(regularConditions: [801])
    }

    @Test("current cost selector retains floor and every other leg, and never alters historical defaults")
    func costFloorAndExpiry() throws {
        typealias E = StockSageNetEdge
        let baseline = E.defaultCosts(forSymbol: "AAPL")
        #expect(E.costs(forSymbol: "AAPL", nbbo: costQuote(ask: 100.02), now: now) == baseline)
        let wide = costQuote()
        let selected = E.costs(forSymbol: "AAPL", nbbo: wide, now: now)
        #expect(abs(selected.spreadBps - (1 / 100.5 * 10_000)) < 1e-9)
        #expect(selected.slippageBps == baseline.slippageBps && selected.takerFeeBps == baseline.takerFeeBps)
        #expect(selected.perOrderMinimum == baseline.perOrderMinimum)
        #expect(E.defaultCosts(forSymbol: "AAPL") == baseline)
        #expect(E.costs(forSymbol: "AAPL", nbbo: wide, now: now.addingTimeInterval(5)).spreadBps == selected.spreadBps)
        #expect(E.costs(forSymbol: "AAPL", nbbo: wide, now: now.addingTimeInterval(5.001)) == baseline)
        #expect(E.costs(forSymbol: "AAPL", nbbo: wide, now: now.addingTimeInterval(-0.001)) == baseline)
        for q in [quote(), costQuote(ask: 0), costQuote(ask: 99), costQuote(ask: 100)] {
            #expect(E.costs(forSymbol: "AAPL", nbbo: q, now: now) == baseline)
        }
        for symbol in ["MSFT", "2222.SR", "BTC-USD", "EURUSD=X"] {
            #expect(E.costs(forSymbol: symbol, nbbo: wide, now: now) == E.defaultCosts(forSymbol: symbol))
        }
        #expect(E.costsDisplayLabel(forSymbol: "AAPL", advDollar: nil, nbbo: wide, now: now).contains("Massive SIP spread"))
        #expect(E.costsDisplayLabel(forSymbol: "AAPL", advDollar: nil, nbbo: wide, now: now.addingTimeInterval(6))
                == E.costsDisplayLabel(forSymbol: "AAPL", advDollar: nil))
    }

    @Test("store propagation preserves analysis, handles withdrawal/expiry and retains the book through scan/price updates")
    func storeCostInputs() {
        let original = SageFix.idea("AAPL", conviction: 0.8, action: .buy, rr: 2, price: 100, riskDistance: 10)
        let book = costQuote()
        let updated = StockSageStore.ideasWithNBBO([original], quotes: ["AAPL": book], now: now)[0]
        #expect(updated.nbbo == book)
        #expect(updated.advice == original.advice && updated.priceAsOf == original.priceAsOf)
        #expect(updated.generatedAt == original.generatedAt && updated.price == original.price)
        #expect(updated.withLivePrice(102, asOf: now).nbbo == book)
        #expect(StockSageStore.ideasWithLatestPrices([original], symbols: [], previous: [updated], now: now)[0].nbbo == book)
        #expect(StockSageStore.ideasWithNBBO([updated], quotes: [:], now: now)[0] == original)
        #expect(StockSageStore.ideasWithNBBO([updated], quotes: ["AAPL": book], now: now.addingTimeInterval(6))[0] == original)
        #expect(StockSageStore.ideasWithNBBO([updated], quotes: ["AAPL": costQuote(ask: 0)], now: now)[0] == original)
        #expect(StockSageStore.ideasWithNBBO([updated], quotes: ["AAPL": quote()], now: now)[0] == original)
        #expect(original.withNBBO(quote(symbol: "MSFT")).nbbo == nil)
    }

    @Test("EV, snapshot, allocator and copied plan respond to the same wide spread")
    func costConsumerParity() throws {
        let base = SageFix.idea("AAPL", conviction: 0.85, action: .strongBuy, rr: 2, price: 100, riskDistance: 1)
        let idea = base.withNBBO(costQuote(ask: 104, at: Date()))
        let net = try #require(StockSageNetEdge.netRR(for: idea))
        let snap = StockSageDecisionSnapshotBuilder.build(idea: idea, account: 10_000, riskFraction: 0.01)
        #expect(net < 0 && snap.netRR == net)
        #expect(snap.netEVR == StockSageExpectedValue.netEVR(for: idea))
        #expect(snap.netEVR! < StockSageExpectedValue.netEVR(for: base)!)
        #expect(!StockSageCapitalAllocator.allocate(ideas: [base], account: 10_000).positions.isEmpty)
        #expect(StockSageCapitalAllocator.allocate(ideas: [idea], account: 10_000).positions.isEmpty)
        #expect(snap.gate?.decision == .blocked)
        let copy = StockSageTodayPlan.build(idea: idea, ev: nil, account: 10_000, riskFraction: 0.01)
        #expect(copy.contains("BLOCKED") && copy.contains("No order plan exported"))
        let safe = SageFix.idea("AAPL", conviction: 0.85, action: .strongBuy, rr: 2, price: 100, riskDistance: 10)
            .withNBBO(costQuote(at: Date()))
        #expect(StockSageTodayPlan.build(idea: safe, ev: nil, account: 10_000, riskFraction: 0.01).contains("Massive SIP spread"))
    }
}
