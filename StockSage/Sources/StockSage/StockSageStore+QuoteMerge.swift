import Foundation

// Pure quote ordering, provenance and merge rules shared by all publication paths.
extension StockSageStore {
    /// Allow small device/SIP clock skew, never an unbounded future freshness stamp.
    nonisolated static func acceptsLiveTick(_ incoming: Date?, after current: Date?,
        massiveTradeSequence: Int64? = nil, afterMassiveTradeSequence: Int64? = nil,
        priceSource: StockSagePriceSource? = nil, afterPriceSource: StockSagePriceSource? = nil,
        now: Date = Date()) -> Bool {
        guard incoming != nil else { return false }
        return acceptsQuote(incoming, after: current, massiveTradeSequence: massiveTradeSequence,
                            afterMassiveTradeSequence: afterMassiveTradeSequence,
                            priceSource: priceSource, afterPriceSource: afterPriceSource, now: now)
    }

    /// Shared by streams, polls, targeted fetches and full-refresh commits. Unknown timestamps
    /// may seed an unknown row, but cannot erase a known price's ordering/freshness evidence.
    nonisolated static func acceptsQuote(_ incoming: Date?, after current: Date?,
        massiveTradeSequence: Int64? = nil, afterMassiveTradeSequence: Int64? = nil,
        priceSource: StockSagePriceSource? = nil, afterPriceSource: StockSagePriceSource? = nil,
        now: Date = Date()) -> Bool {
        // Demo clocks are not market observations: never ingest one, and never let the
        // startup seed's Date() block a genuine (e.g. Friday-close) quote on a weekend.
        guard priceSource != .sample, priceSource != .manualEntry, priceSource != .importedRecord else { return false }
        let current = afterPriceSource == .sample ? nil : current
        guard let incoming else { return current == nil }
        guard incoming.timeIntervalSince1970.isFinite,
              incoming.timeIntervalSince1970 > 0, incoming <= now.addingTimeInterval(60) else { return false }
        guard let current, current.timeIntervalSince1970.isFinite,
              current.timeIntervalSince1970 > 0, current <= now.addingTimeInterval(60) else { return true }
        if incoming != current { return incoming > current }
        // Only compare the SAME symbol's Massive T sequence. Unknown/provider/quote ties
        // remain rejected; later dates win regardless of sequence (including daily resets).
        guard let sequence = massiveTradeSequence, let old = afterMassiveTradeSequence else { return false }
        return sequence >= 0 && old >= 0 && sequence > old
    }

    /// A scan computes advice against history while quotes continue arriving. Publish its NEW
    /// advice with the latest observed price, without changing its stop/target or analysis date.
    nonisolated static func ideasWithLatestPrices(
        _ fresh: [StockSageIdea], symbols: [StockSageSymbol], previous: [StockSageIdea], now: Date = Date()
    ) -> [StockSageIdea] {
        var latest: [String: (price: Double, at: Date, sequence: Int64?, source: StockSagePriceSource?, denomination: StockSagePriceDenomination?)] = [:]
        for symbol in symbols {
            guard let quote = symbol.quotes.last, quote.price > 0, quote.price.isFinite,
                  let at = quote.marketTime,
                  acceptsLiveTick(at, after: nil, priceSource: quote.priceSource, now: now) else { continue }
            latest[symbol.symbol.uppercased()] = (quote.price, at, quote.massiveTradeSequence, quote.priceSource, quote.denomination)
        }
        for idea in previous {
            let key = idea.symbol.uppercased()
            guard idea.price > 0, idea.price.isFinite, let at = idea.priceAsOf,
                  acceptsLiveTick(at, after: latest[key]?.at, massiveTradeSequence: idea.massiveTradeSequence,
                                  afterMassiveTradeSequence: latest[key]?.sequence,
                                  priceSource: idea.priceSource, afterPriceSource: latest[key]?.source, now: now) else { continue }
            latest[key] = (idea.price, at, idea.massiveTradeSequence, idea.priceSource, idea.denomination)
        }
        let books = Dictionary(previous.compactMap { idea in idea.nbbo.map { (idea.symbol, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return fresh.map { original in
            let book = books[original.symbol] ?? original.nbbo
            let idea = original.withNBBO(book?.isFresh(at: now) == true ? book : nil)
            guard let quote = latest[idea.symbol.uppercased()],
                  acceptsLiveTick(quote.at, after: idea.priceAsOf, massiveTradeSequence: quote.sequence,
                                  afterMassiveTradeSequence: idea.massiveTradeSequence,
                                  priceSource: quote.source, afterPriceSource: idea.priceSource, now: now) else { return idea }
            return idea.withLivePrice(quote.price, asOf: quote.at, massiveTradeSequence: quote.sequence,
                                      priceSource: quote.source, denomination: quote.denomination)
        }
    }

    /// Only the authenticated, coalesced stream calls this. Withdrawals/auth loss replace
    /// the entire input set; the one-second timer expires quiet books without per-card polling.
    nonisolated static func ideasWithNBBO(_ ideas: [StockSageIdea], quotes: [String: StockSageNBBO],
                                          now: Date = Date()) -> [StockSageIdea] {
        ideas.map { idea in
            let quote = StockSageLiveStream.displayQuote(for: idea.symbol, in: quotes)
            return idea.withNBBO(quote?.costConditionVerified == true && quote?.spreadBps(at: now) != nil ? quote : nil)
        }
    }

    /// Pure merge step behind `applyPolledQuotes` (W3, owner: "seamless … update automatically").
    /// Given the current board rows, idea rows, and the `symbolIndex` lookup, applies each
    /// PRICED quote (`price > 0`) to the matching board row AND the matching idea's price/asOf —
    /// the same mirror `applyLiveTicks`/`mergeLiveQuote` already do for a streamed tick, so a
    /// polled row and its card can never disagree — leaving every OTHER row, and both arrays'
    /// order/count/identity, byte-identical. `asOf: q.marketTime` is passed straight through
    /// (never `?? Date()`): an undated quote only seeds an undated row, never overwrites a
    /// dated observation. Existing row identity is preserved. Returns the updated
    /// arrays plus the newest market time actually observed (nil if none did) so the caller can
    /// stamp `quoteAsOf` honestly. `nonisolated static` and side-effect-free — testable without
    /// the `@MainActor` singleton, a live stream, or the network (MarketsPolledQuoteMergeTests).
    /// Price ordering and previous-close evidence have distinct clocks. A REST observation
    /// may repair the latter without replacing a newer streamed trade or refreshing its age.
    nonisolated static func mergedQuote(_ q: StockSageQuoteService.LiveQuote, after current: StockSageQuote?,
                                       symbol: String, acceptPrice: Bool, now: Date) -> StockSageQuote? {
        let incoming = StockSageQuote(price: q.price, previousPrice: q.previousClose, time: now,
            marketTime: q.marketTime, massiveTradeSequence: q.massiveTradeSequence, priceSource: q.priceSource,
            previousCloseSource: q.previousCloseSource, previousCloseQuoteTime: q.previousCloseQuoteTime,
            denomination: q.denomination)
        let destination = acceptPrice ? incoming : current
        guard let destination else { return nil }
        // A baseline borrowed from another observation must share its explicit
        // currency AND raw unit. Same-response baselines remain internally bound.
        let currentComparable = !acceptPrice || (current?.denomination != nil
            && current?.denomination?.currencyCode == destination.denomination?.currencyCode
            && current?.denomination?.rawUnitsPerMajor == destination.denomination?.rawUnitsPerMajor)
        let incomingComparable = acceptPrice || (incoming.denomination != nil
            && incoming.denomination?.currencyCode == destination.denomination?.currencyCode
            && incoming.denomination?.rawUnitsPerMajor == destination.denomination?.rawUnitsPerMajor)
        let previousValid = currentComparable
            && current?.hasSessionBaseline(symbol: symbol, at: destination.marketTime) == true
        let incomingValid = incomingComparable
            && incoming.hasSessionBaseline(symbol: symbol, at: q.marketTime)
            && incoming.hasSessionBaseline(symbol: symbol, at: destination.marketTime)
        let newer = (incoming.previousCloseQuoteTime ?? .distantPast) > (current?.previousCloseQuoteTime ?? .distantPast)
        let baseline = incomingValid && (!previousValid || newer) ? incoming : (previousValid ? current : nil)
        guard acceptPrice || baseline != nil else { return current }
        return StockSageQuote(id: destination.id, price: destination.price,
            previousPrice: baseline?.previousPrice ?? q.previousClose, time: destination.time,
            marketTime: destination.marketTime, massiveTradeSequence: destination.massiveTradeSequence,
            priceSource: destination.priceSource, previousCloseSource: baseline?.previousCloseSource,
            previousCloseQuoteTime: baseline?.previousCloseQuoteTime, denomination: destination.denomination)
    }

    nonisolated static func mergedPolledQuotes(
        symbols: [StockSageSymbol], ideas: [StockSageIdea], symbolIndex: [String: Int],
        quotes: [String: StockSageQuoteService.LiveQuote], now: Date = Date()
    ) -> (symbols: [StockSageSymbol], ideas: [StockSageIdea], newestMarketTime: Date?, acceptedKeys: Set<String>, baselineKeys: Set<String>) {
        var symbols = symbols
        var ideas = ideas
        var newestMarketTime: Date?
        var acceptedKeys: Set<String> = []
        var baselineKeys: Set<String> = []
        let ideaIndex = Dictionary(ideas.enumerated().map { ($0.element.symbol.uppercased(), $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        for (key, q) in quotes {
            guard q.price > 0, q.price.isFinite, q.previousClose.isFinite else { continue }
            let upper = key.uppercased()
            guard q.symbol.uppercased() == upper else { continue }
            let i = symbolIndex[upper].flatMap { index in
                symbols.indices.contains(index) && symbols[index].symbol.uppercased() == upper ? index : nil
            }
            let j = ideaIndex[upper]
            guard i != nil || j != nil else { continue }
            let row = i.flatMap { symbols[$0].quotes.last }
            let idea = j.map { ideas[$0] }
            let accepted = acceptsQuote(q.marketTime, after: row?.marketTime, massiveTradeSequence: q.massiveTradeSequence,
                               afterMassiveTradeSequence: row?.massiveTradeSequence,
                               priceSource: q.priceSource, afterPriceSource: row?.priceSource, now: now)
                && acceptsQuote(q.marketTime, after: idea?.priceAsOf, massiveTradeSequence: q.massiveTradeSequence,
                               afterMassiveTradeSequence: idea?.massiveTradeSequence,
                               priceSource: q.priceSource, afterPriceSource: idea?.priceSource, now: now)
            if let i, let updated = mergedQuote(q, after: row, symbol: upper, acceptPrice: accepted, now: now) {
                if !accepted, updated != row { baselineKeys.insert(upper) }
                if accepted { symbols[i].quotes = [StockSageQuote(price: updated.previousPrice,
                    previousPrice: updated.previousPrice, time: now.addingTimeInterval(-86_400)), updated] }
                else if !symbols[i].quotes.isEmpty { symbols[i].quotes[symbols[i].quotes.count - 1] = updated }
            }
            guard accepted else { continue }
            if let j {
                ideas[j] = ideas[j].withLivePrice(q.price, asOf: q.marketTime, massiveTradeSequence: q.massiveTradeSequence,
                                                priceSource: q.priceSource, denomination: q.denomination)
            }
            acceptedKeys.insert(upper)
            if let mt = q.marketTime, newestMarketTime == nil || mt > newestMarketTime! { newestMarketTime = mt }
        }
        return (symbols, ideas, newestMarketTime, acceptedKeys, baselineKeys)
    }

}
