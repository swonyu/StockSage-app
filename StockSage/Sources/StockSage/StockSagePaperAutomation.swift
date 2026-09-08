import Foundation
import Combine
import Darwin

/// Qwen research and a separate, cash-funded SIMULATION. No broker or real-journal writes.
@MainActor
final class StockSagePaperAutomation: ObservableObject {
    static let shared = StockSagePaperAutomation()
    static let enabledKey = "stocksage.qwenPaper.enabled"
    nonisolated static let initialCash = 10_000.0
    nonisolated static let positionCap = 2_000.0
    nonisolated static let costRate = 0.001 // Assumed 10 bps on each side, not measured broker costs.
    nonisolated static let interval: TimeInterval = 900

    nonisolated struct Decision: Codable, Identifiable, Sendable {
        let id: UUID
        let at: Date
        let symbol: String
        let action: String
        let reason: String
        let risk: String
        let facts: [String]
        let evidence: [String]
        let model: String
    }

    nonisolated struct Pending: Codable, Identifiable, Sendable {
        let id: UUID
        let symbol: String
        let buy: Bool
        let at: Date
    }

    nonisolated struct Book: Codable, Sendable {
        var version = 1
        var trades: [TradeRecord] = []
        var pending: [Pending] = []
        var decisions: [Decision] = []
        var lastResearch: Date?
        var cursor = 0

        var open: [TradeRecord] { trades.filter(\.isOpen) }
        var cash: Double {
            Self.money(Self.initialBalance(trades))
        }
        private static func initialBalance(_ trades: [TradeRecord]) -> Double {
            trades.reduce(StockSagePaperAutomation.initialCash) { balance, trade in
                balance - money(trade.entry * trade.shares) + (trade.exitPrice.map { money($0 * trade.shares) } ?? 0)
            }
        }
        static func money(_ value: Double) -> Double { (value * 100).rounded() / 100 }

        var valid: Bool {
            version == 1 && cursor >= 0 && trades.count <= 50_000 && decisions.count <= 50_000
                && open.count <= 5 && pending.count <= 5 && cash.isFinite && cash >= 0
                && Set(trades.map(\.id)).count == trades.count
                && Set(open.map(\.symbol)).count == open.count
                && Set(pending.map(\.id)).count == pending.count
                && Set(pending.map(\.symbol)).count == pending.count
                && (lastResearch?.timeIntervalSince1970.isFinite ?? true)
                && trades.allSatisfy { t in
                    t.side == .long && StockSagePaperAutomation.validSymbol(t.symbol)
                        && t.entry.isFinite && t.entry > 0 && t.stop.isFinite && t.stop > 0 && t.stop < t.entry
                        && t.target.map { $0.isFinite && $0 > t.entry } == true
                        && t.shares.isFinite && t.shares >= 1 && t.shares.rounded(.down) == t.shares
                        && t.shares <= 1_000_000 && t.closureError == nil
                }
                && pending.allSatisfy { StockSagePaperAutomation.validSymbol($0.symbol) && $0.at.timeIntervalSince1970.isFinite }
                && decisions.allSatisfy { $0.at.timeIntervalSince1970.isFinite }
        }

        mutating func note(symbol: String = "", action: String, reason: String, at: Date,
                           risk: String = "", facts: [String] = [], evidence: [String] = [], model: String = "") {
            decisions.append(.init(id: UUID(), at: at, symbol: symbol, action: action,
                reason: reason, risk: risk, facts: facts, evidence: evidence, model: model))
        }

        /// A validated model opinion can request a paper action, never supply price or size.
        mutating func propose(symbol: String, action: TradeAdvice.Action, at: Date) {
            guard StockSagePaperAutomation.validSymbol(symbol), !pending.contains(where: { $0.symbol == symbol }) else { return }
            let held = open.contains { $0.symbol == symbol }
            let buy = action == .buy || action == .strongBuy
            let sell = action == .sell || action == .reduce
            if buy && !held && open.count + pending.filter(\.buy).count < 5 && cash > 0 {
                pending.append(.init(id: UUID(), symbol: symbol, buy: true, at: at))
            } else if sell && held {
                pending.append(.init(id: UUID(), symbol: symbol, buy: false, at: at))
            } else if buy || sell {
                note(symbol: symbol, action: "Skipped", reason: "Position, cash or pending-order limit; no paper order created.", at: at)
            }
        }

        /// Fill only from a FRESH market observation strictly AFTER the saved decision.
        /// Stops/targets are sampled triggers, filled at a subsequent observed price, never at an invented level.
        @MainActor mutating func settle(quotes: [String: StockSageQuoteService.LiveQuote], at now: Date) {
            for order in pending {
                guard (0..<120).contains(now.timeIntervalSince(order.at)) else {
                    pending.removeAll { $0.id == order.id }
                    note(symbol: order.symbol, action: "Expired", reason: "No eligible post-decision fill within two minutes, or clock moved backwards.", at: now)
                    continue
                }
                guard StockSagePaperAutomation.paperSessionOpen(now),
                      let q = quotes[order.symbol], StockSagePaperAutomation.fresh(q, at: now),
                      q.symbol == order.symbol, let quoteTime = q.marketTime, quoteTime > order.at else { continue }
                pending.removeAll { $0.id == order.id }
                let fill = q.price * (order.buy ? 1 + StockSagePaperAutomation.costRate : 1 - StockSagePaperAutomation.costRate)
                if order.buy {
                    let shares = min(1_000_000, floor(min(cash, StockSagePaperAutomation.positionCap) / fill))
                    guard shares >= 1, open.count < 5, !open.contains(where: { $0.symbol == order.symbol }),
                          Self.money(fill * shares) <= cash else {
                        note(symbol: order.symbol, action: "Skipped", reason: "Insufficient paper cash or position capacity at the observed fill.", at: now)
                        continue
                    }
                    trades.append(TradeRecord(id: order.id, symbol: order.symbol, side: .long, entry: fill,
                        stop: fill * 0.98, target: fill * 1.04, shares: shares, openedAt: now,
                        note: "Qwen paper simulation; assumed costs, not a broker fill."))
                } else if let i = trades.firstIndex(where: { $0.isOpen && $0.symbol == order.symbol }) {
                    trades[i].exitPrice = fill; trades[i].closedAt = now
                } else { continue }
                note(symbol: order.symbol, action: order.buy ? "Paper Buy" : "Paper Sell",
                     reason: "Simulated at a later Massive observation with an assumed 10 bps adverse fill.", at: now,
                     facts: ["Observed price: \(q.price)", "Market timestamp: \(quoteTime.ISO8601Format())", "Simulated fill: \(fill)"])
            }
            guard StockSagePaperAutomation.paperSessionOpen(now) else { return }
            for trade in open where !pending.contains(where: { $0.symbol == trade.symbol }) {
                guard let q = quotes[trade.symbol], q.symbol == trade.symbol,
                      StockSagePaperAutomation.fresh(q, at: now), q.marketTime! > trade.openedAt else { continue }
                if q.price <= trade.stop || q.price >= (trade.target ?? .infinity) {
                    pending.append(.init(id: UUID(), symbol: trade.symbol, buy: false, at: now))
                    note(symbol: trade.symbol, action: "Exit requested", reason: "Observed the simulation's stop or target; awaiting a later quote.", at: now)
                }
            }
        }

        func equity(quotes: [String: StockSageQuoteService.LiveQuote], at now: Date) -> Double? {
            var total = cash
            for trade in open {
                guard let q = quotes[trade.symbol], q.symbol == trade.symbol,
                      StockSagePaperAutomation.fresh(q, at: now) else { return nil }
                total += Self.money(trade.shares * q.price * (1 - StockSagePaperAutomation.costRate))
            }
            return total.isFinite ? Self.money(total) : nil
        }
    }

    @Published private(set) var book = Book()
    @Published private(set) var isRunning = false
    @Published private(set) var isResearching = false
    @Published private(set) var status = "Paused"
    @Published private(set) var error: String?
    @Published private(set) var quotes: [String: StockSageQuoteService.LiveQuote] = [:]
    private let url: URL
    private let defaults: UserDefaults
    private var lease: Int32 = -1
    private var loop: Task<Void, Never>?
    private var research: Task<Void, Never>?
    private var generation = UUID()

    init(url: URL? = nil, defaults: UserDefaults = .standard) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSageQwenPaper/account.json")
        self.defaults = defaults
        do { book = try read() } catch { self.error = "Paper account could not be read. Existing data has been preserved." }
    }

    nonisolated static func validSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,11}$"#, options: .regularExpression) != nil
            && StockSageCurrency.conversionCurrencyForSymbol(symbol) == "USD"
            && StockSageAllocation.assetClass(symbol) == "Equity"
    }
    /// Native simulation only: the existing New York clock handles weekday and DST boundaries.
    /// This does not establish holiday eligibility, fresh data, liquidity or broker permission.
    nonisolated static func paperSessionOpen(_ now: Date) -> Bool {
        switch StockSageMarketHours.nasdaqState(at: now, calendar: Calendar(identifier: .gregorian)).phase {
        case .preMarket, .open, .afterHours: return true
        default: return false
        }
    }
    nonisolated static func fresh(_ quote: StockSageQuoteService.LiveQuote, at now: Date) -> Bool {
        guard quote.price.isFinite, quote.price > 0, quote.priceSource == .massiveSIP,
              let at = quote.marketTime else { return false }
        return (0...120).contains(now.timeIntervalSince(at))
    }

    private func read() throws -> Book {
        guard FileManager.default.fileExists(atPath: url.path) else { return Book() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Book.self, from: Data(contentsOf: url))
        guard value.valid else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    /// One process holds this account lease for its whole run. Atomic saves include decisions and fills together.
    @discardableResult func acquire() -> Bool {
        guard lease < 0 else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd); error = "This paper account is running in another StockSage process."; return false
            }
            lease = fd
            book = try read()
            error = nil
            return true
        } catch {
            release(); self.error = "Paper account unavailable or corrupt. Existing data has been preserved."; return false
        }
    }
    private func release() {
        if lease >= 0 { flock(lease, LOCK_UN); Darwin.close(lease); lease = -1 }
    }
    @discardableResult func save(_ next: Book) -> Bool {
        guard lease >= 0 else { error = "Paper account has no writer lease."; return false }
        do {
            guard next.valid else { throw CocoaError(.fileWriteInvalidFileName) }
            let data = try JSONEncoder().encode(next)
            guard data.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            book = next; error = nil
            return true
        } catch {
            self.error = "Paper account save failed or ledger limit reached. Automation paused; previous data preserved."
            defaults.set(false, forKey: Self.enabledKey)
            loop?.cancel(); research?.cancel(); isRunning = false; status = "Paused after storage failure"
            return false
        }
    }

    func resumeIfEnabled() {
        if defaults.bool(forKey: Self.enabledKey) { start() }
    }
    func start() {
        guard !isRunning, !StockSageStore.isRunningTests, !CommandLine.arguments.contains("--qa"), acquire() else { return }
        defaults.set(true, forKey: Self.enabledKey)
        generation = UUID()
        isResearching = false
        isRunning = true; status = "Waiting for fresh market observations"
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                await self.tick(store: .shared)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        generation = UUID()
        loop?.cancel(); research?.cancel(); loop = nil; research = nil
        isRunning = false; isResearching = false; status = "Paused; paper positions retained"
        if lease >= 0 {
            var next = book
            next.pending = []
            next.note(action: "Paused", reason: "Pending paper orders cancelled. Existing paper holdings retained.", at: Date())
            _ = save(next)
        }
        release()
    }

    private func tick(store: StockSageStore) async {
        guard isRunning, !Task.isCancelled else { return }
        let now = Date()
        if let last = book.lastResearch, last > now {
            stop(); error = "Clock moved backwards; paper automation paused for review."; return
        }
        var next = book
        // Expire pending orders even while the market/data connection is unavailable.
        next.settle(quotes: [:], at: now)
        if next.pending.count != book.pending.count, !save(next) { return }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else { status = "Waiting: web access or usable market data unavailable"; return }
        guard Self.paperSessionOpen(now) else { status = "Waiting for scheduled US sessions (04:00–20:00 New York time); holidays require fresh quotes"; return }
        let held = Array(Set(book.open.map(\.symbol) + book.pending.map(\.symbol))).sorted()
        let latest = await StockSageQuoteService.fetchQuotes(for: held)
        guard !Task.isCancelled, isRunning else { return }
        quotes = latest
        // Do not mis-account for a possible split as a giant profit/loss. No split-factor guessing.
        if book.open.contains(where: { t in
            guard let q = latest[t.symbol], Self.fresh(q, at: Date()) else { return false }
            return q.price / t.entry < 0.67 || q.price / t.entry > 1.5
        }) {
            stop(); error = "Large price/basis change: review possible corporate actions before restarting the simulation."; return
        }
        next = book
        let before = next.decisions.count
        next.settle(quotes: latest, at: Date())
        if next.decisions.count != before, !save(next) { return }
        if !isResearching, book.lastResearch.map({ Date().timeIntervalSince($0) >= Self.interval }) ?? true {
            research = Task { [weak self] in await self?.researchCycle(store: store) }
        }
        if !isResearching { status = "Monitoring paper positions; research every fifteen minutes" }
    }

    private func researchCycle(store: StockSageStore) async {
        guard !isResearching, isRunning, !Task.isCancelled else { return }
        let run = generation
        isResearching = true
        defer { if generation == run { isResearching = false } }
        var next = book
        let now = Date()
        if let last = next.lastResearch, now.timeIntervalSince(last) > Self.interval * 1.5 {
            next.note(action: "Observation gap", reason: "More than one research interval elapsed. No forecasts or paper fills were backfilled.", at: now)
        }
        next.lastResearch = now
        let watched = store.userSymbols.filter { Self.validSymbol($0) }
        let candidates = Array(Set(watched + book.open.map(\.symbol))).sorted()
        let targets = candidates.isEmpty ? [] : (0..<min(4, candidates.count)).map { candidates[(next.cursor + $0) % candidates.count] }
        next.cursor = candidates.isEmpty ? 0 : (next.cursor + targets.count) % candidates.count
        next.note(action: "Research started", reason: "Selected \(targets.joined(separator: ", ")). At most four watchlist/held symbols per cycle, rotating through the list.", at: now)
        guard save(next) else { return }
        guard !targets.isEmpty else { status = "Add US stocks to your watchlist to begin research"; return }
        guard let config = StockSageAIAssessments.configuration else {
            recordFailure("Local Qwen is disabled or not configured.", at: Date()); return
        }
        let probe = await StockSageLocalModelServer.probe(config)
        guard isRunning, !Task.isCancelled else { return }
        guard probe.reachable, probe.hasModel else { recordFailure("Local Qwen server is unavailable.", at: Date()); return }
        for symbol in targets {
            guard isRunning, !Task.isCancelled, StockSageAIAssessments.configuration == config else { return }
            guard store.userSymbols.contains(symbol) || book.open.contains(where: { $0.symbol == symbol }) else { continue }
            status = "Researching \(symbol) with Qwen"
            let observed = await StockSageQuoteService.fetchQuotes(for: [symbol])
            guard isRunning, !Task.isCancelled else { return }
            guard let quote = observed[symbol], Self.fresh(quote, at: Date()) else {
                recordFailure("Fresh Massive SIP observation unavailable; no paper decision.", symbol: symbol, at: Date()); continue
            }
            let history = await StockSageQuoteService.fetchHistory(symbol, range: "1y")
            let news = await StockSageNewsService.recentNews(for: symbol, limit: 3)
            guard isRunning, !Task.isCancelled else { return }
            guard let history, let historyAt = history.dates.last,
                  (0...4 * 86_400).contains(Date().timeIntervalSince(historyAt)) else {
                recordFailure("Recent dated price history unavailable; no paper decision.", symbol: symbol, at: Date()); continue
            }
            let definitions = store.symbols.filter { $0.symbol == symbol }
            let ideas = await StockSageStore.buildIdeas(defs: definitions, histories: [symbol: history])
            guard isRunning, !Task.isCancelled else { return }
            guard let base = ideas.first else {
                recordFailure("Price history or symbol definition unavailable; no paper decision.", symbol: symbol, at: Date()); continue
            }
            let idea = base.withLivePrice(quote.price, asOf: quote.marketTime, priceSource: quote.priceSource)
            let context = StockSageAIAssessment.Context(idea: idea, earnings: store.catalystChain[symbol],
                company: store.companyEventChecks[symbol] ?? [:], news: news, at: Date())
            let facts = context.facts + ["Technical inputs use daily bars ending \(historyAt.ISO8601Format()); not intraday predictions."]
            guard context.canAssess(at: Date()), Self.fresh(quote, at: Date()) else {
                recordFailure("Research context exceeded its freshness or size limit.", symbol: symbol, at: Date()); continue
            }
            let response = await StockSageLocalModelServer.complete(config, isOllama: probe.isOllama,
                system: StockSageAIAssessment.instructions, user: StockSageAIAssessment.prompt(facts: facts), maxTokens: 512)
            guard isRunning, !Task.isCancelled, StockSageAIAssessments.configuration == config else { return }
            guard case .success(let text) = response, let verdict = StockSageAIAssessment.parse(text, facts: facts) else {
                recordFailure("Qwen failed or returned an unverifiable response; no paper order.", symbol: symbol, at: Date()); continue
            }
            let decisionAt = Date()
            next = book
            next.note(symbol: symbol, action: verdict.action.rawValue, reason: verdict.reason, at: decisionAt,
                      risk: verdict.risk, facts: facts, evidence: verdict.evidence, model: config.model)
            if Self.paperSessionOpen(decisionAt), Self.fresh(quote, at: decisionAt),
               store.userSymbols.contains(symbol) || next.open.contains(where: { $0.symbol == symbol }) {
                next.propose(symbol: symbol, action: verdict.action, at: decisionAt)
            } else {
                next.note(symbol: symbol, action: "Skipped", reason: "Research finished after quote expiry, scheduled market close or removal from the watchlist.", at: decisionAt)
            }
            guard save(next) else { return }
        }
        next = book
        next.note(action: "Research complete", reason: "Finished the selected symbols; unavailable and skipped decisions are retained above.", at: Date())
        guard save(next) else { return }
        status = "Research complete; monitoring paper positions"
    }

    private func recordFailure(_ reason: String, symbol: String = "", at: Date) {
        var next = book
        next.note(symbol: symbol, action: "Unavailable", reason: reason, at: at)
        _ = save(next)
        status = reason
    }
}
