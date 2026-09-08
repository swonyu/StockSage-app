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
    nonisolated static let discoveryLimit = 100
    nonisolated static let researchConcurrency = 4
    nonisolated static let researchInstructions = StockSageAIAssessment.instructions
        .replacingOccurrences(of: "Assess the supplied stock for the next trading week.",
            with: "Assess an entry or exit NOW for the REMAINDER OF TODAY'S New York session only. No overnight or multi-day thesis. Use the completed intraday bars or explicitly labelled qualified trades; daily technical rules are background, not intraday signals.")
        + "\nFor this paper scan, keep reason and risk to at most 20 words EACH. Retain the four-key JSON and all required evidence references."
        + "\nKeep reason and risk qualitative, without repeating numbers, dates or clock times; exact figures remain in the cited facts."

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

        mutating func activateSameDay(at now: Date) {
            guard !decisions.contains(where: { $0.action == "Same-day policy activated" }) else { return }
            let cancelled = pending.filter(\.buy).count
            pending.removeAll(where: \.buy)
            lastResearch = nil
            note(action: "Same-day policy activated",
                 reason: "Cancelled \(cancelled) pre-policy pending entries. Holdings, exit requests and history retained. Fresh same-day research is due; close-out starts at 19:55 New York.", at: now)
        }

        /// A validated model opinion can request a paper action, never supply price or size.
        mutating func propose(symbol: String, action: TradeAdvice.Action, at: Date) {
            guard StockSagePaperAutomation.validSymbol(symbol), !pending.contains(where: { $0.symbol == symbol }) else { return }
            let held = open.contains { $0.symbol == symbol }
            let buy = action == .buy || action == .strongBuy
            let sell = action == .sell || action == .reduce
            if buy && (!StockSagePaperAutomation.entryWindowOpen(at)
                || open.contains { StockSagePaperAutomation.dayExitDue(openedAt: $0.openedAt, now: at) }) {
                note(symbol: symbol, action: "Skipped", reason: "Same-day entry window closed or an overdue holding still needs an exit.", at: at)
                return
            }
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
            enforceDayLimit(at: now)
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

        mutating func enforceDayLimit(at now: Date) {
            if !StockSagePaperAutomation.entryWindowOpen(now) {
                let cancelled = pending.filter(\.buy)
                pending.removeAll(where: \.buy)
                for order in cancelled {
                    note(symbol: order.symbol, action: "Cancelled", reason: "Same-day cutoff: unfilled entry cancelled.", at: now)
                }
            }
            guard StockSagePaperAutomation.paperSessionOpen(now) else { return }
            for trade in open where StockSagePaperAutomation.dayExitDue(openedAt: trade.openedAt, now: now)
                && !pending.contains(where: { $0.symbol == trade.symbol }) {
                pending.append(.init(id: UUID(), symbol: trade.symbol, buy: false, at: now))
                note(symbol: trade.symbol, action: "Day exit requested",
                     reason: "Same-day close-out or overdue holding: awaiting a genuinely later fresh observation.", at: now)
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
    nonisolated static func sessionTime(_ now: Date, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
    nonisolated static func entryWindowOpen(_ now: Date) -> Bool {
        paperSessionOpen(now) && now < sessionTime(now, hour: 19, minute: 55)
    }
    nonisolated static func sessionClockFact(at now: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(identifier: "America/New_York")!
        let cutoff = sessionTime(now, hour: 19, minute: 55)
        return "Authoritative decision-clock snapshot: \(format.string(from: now)) America/New_York. New entry window: \(entryWindowOpen(now) ? "OPEN" : "CLOSED"). Entry cutoff: \(format.string(from: cutoff)). Do not compare UTC timestamps to New York clock times. Window status does not override evidence, cash, holdings or freshness checks."
    }
    nonisolated static func dayExitDue(openedAt: Date, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return now >= sessionTime(now, hour: 19, minute: 55)
            || !calendar.isDate(openedAt, inSameDayAs: now)
    }
    nonisolated static func fresh(_ quote: StockSageQuoteService.LiveQuote, at now: Date) -> Bool {
        guard quote.price.isFinite, quote.price > 0, quote.priceSource == .massiveSIP,
              let at = quote.marketTime else { return false }
        return (0...120).contains(now.timeIntervalSince(at))
    }
    nonisolated static func hasIntradayEvidence(_ evidence: [String], factIndices: Range<Int>) -> Bool {
        let intraday = Set(factIndices.map { "F\($0 + 1)" })
        return !intraday.isDisjoint(with: evidence)
    }

    /// Shared by research, pending fills and position monitoring; stale snapshots are not final answers.
    static func fetchPaperQuotes(for symbols: [String], after: [String: Date] = [:], at fixedTime: Date? = nil,
        snapshots: @MainActor ([String]) async -> [String: StockSageQuoteService.LiveQuote] = { await StockSageMassive.fetchSnapshots(for: $0) },
        tick: @escaping @MainActor (String, Date) async -> StockSageQuoteService.LiveQuote? = { await StockSageMassiveTicks.freshPaperQuote(symbol: $0, now: $1) }
    ) async -> [String: StockSageQuoteService.LiveQuote] {
        let snapshots = await snapshots(symbols)
        var result: [String: StockSageQuoteService.LiveQuote] = [:]
        func eligible(_ q: StockSageQuoteService.LiveQuote, symbol: String) -> Bool {
            q.symbol == symbol && fresh(q, at: fixedTime ?? Date())
                && (after[symbol].map { (q.marketTime ?? .distantPast) > $0 } ?? true)
        }
        await forEachResearchTarget(Array(Set(symbols)).sorted()) { symbol in
            guard !Task.isCancelled else { return }
            if let q = snapshots[symbol], eligible(q, symbol: symbol) {
                result[symbol] = q
            } else if let q = await tick(symbol, fixedTime ?? Date()), eligible(q, symbol: symbol) {
                result[symbol] = q
            }
        }
        return result
    }

    /// Rolling task group overlaps I/O/inference, while each ledger mutation stays on MainActor.
    static func forEachResearchTarget(_ symbols: [String],
        operation: @escaping @MainActor @Sendable (String) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = symbols.makeIterator()
            for _ in 0..<researchConcurrency {
                if !Task.isCancelled, let symbol = remaining.next() { group.addTask { await operation(symbol) } }
            }
            for await _ in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let symbol = remaining.next() { group.addTask { await operation(symbol) } }
            }
        }
    }

    nonisolated static func mayResearch(_ symbol: String, marketSymbols: Set<String>, heldSymbols: Set<String>) -> Bool {
        validSymbol(symbol) && (marketSymbols.contains(symbol) || heldSymbols.contains(symbol))
    }

    nonisolated static func researchDue(book: Book, at now: Date) -> Bool {
        // A legacy watchlist-only cycle is not the first full-market scan after upgrade.
        !book.decisions.contains { $0.action.hasPrefix("Market scan") }
            || (book.lastResearch.map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    /// Full-market screening is cheap; model calls have bounded concurrency. Holdings never compete
    /// for discovery slots. Least-recently attempted names rotate ahead of repeated opinions.
    nonisolated static func researchTargets(market: StockSageMassive.MarketSnapshot?, book: Book, at now: Date) -> [String] {
        let held = Set(book.open.map(\.symbol).filter(validSymbol))
        let pending = Set(book.pending.map(\.symbol))
        var attempted: [String: Date] = [:]
        for decision in book.decisions where !decision.symbol.isEmpty {
            attempted[decision.symbol] = max(attempted[decision.symbol] ?? .distantPast, decision.at)
        }
        let affordable = min(book.cash, positionCap)
        let candidates = (market?.rows ?? []).filter {
            let q = $0.quote
            return validSymbol(q.symbol) && StockSageMassive.covers(q.symbol) && fresh(q, at: now)
                && !held.contains(q.symbol) && !pending.contains(q.symbol)
                && q.price * (1 + costRate) <= affordable
        }.sorted {
            let left = attempted[$0.quote.symbol] ?? .distantPast
            let right = attempted[$1.quote.symbol] ?? .distantPast
            if left != right { return left < right }
            let lhs = $0.dollarVolume.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1
            let rhs = $1.dollarVolume.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? -1
            return lhs != rhs ? lhs > rhs : $0.quote.symbol < $1.quote.symbol
        }
        return held.sorted() + candidates.prefix(discoveryLimit).map(\.quote.symbol)
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
        var next = book
        next.activateSameDay(at: Date())
        if next.decisions.count != book.decisions.count, !save(next) { release(); return }
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
        if next.decisions.count != book.decisions.count, !save(next) { return }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else { status = "Waiting: web access or usable market data unavailable"; return }
        guard Self.paperSessionOpen(now) else {
            status = book.open.isEmpty ? "Waiting for scheduled US sessions (04:00–20:00 New York time); holidays require fresh quotes"
                : "Session closed with unresolved paper positions; no closing prices invented. Exits retry next session."
            return
        }
        let held = Array(Set(book.open.map(\.symbol) + book.pending.map(\.symbol))).sorted()
        let after = Dictionary(uniqueKeysWithValues: book.pending.map { ($0.symbol, $0.at) })
        let latest = await Self.fetchPaperQuotes(for: held, after: after)
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
        if !isResearching, Self.entryWindowOpen(Date()), Self.researchDue(book: book, at: Date()) {
            research = Task { [weak self] in await self?.researchCycle(store: store) }
        }
        if !isResearching {
            status = Self.entryWindowOpen(Date()) ? "Monitoring paper positions; waiting for the next research cycle"
                : "Same-day close-out: new entries stopped; \(book.open.count) positions awaiting eligible exits"
        }
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
        next.note(action: "Research started", reason: "Scanning the full Massive US listed-market snapshot; no watchlist restriction. OTC excluded.", at: now)
        guard save(next) else { return }
        status = "Scanning the full US market with Massive"
        let market = await StockSageMassive.fetchMarketSnapshot()
        guard isRunning, !Task.isCancelled, generation == run, ToolPolicy.isExternalAllowed, !store.isSampleData else { return }
        let selectedAt = Date()
        let targets = Self.researchTargets(market: market, book: book, at: selectedAt)
        let marketSymbols = Set(market?.rows.map { $0.quote.symbol } ?? [])
        next = book
        if let market {
            let freshCount = market.rows.filter { Self.validSymbol($0.quote.symbol) && Self.fresh($0.quote, at: selectedAt) }.count
            next.note(action: "Market scan", reason: "\(market.returnedCount) US listed tickers returned; \(market.rows.count) supported trade observations; \(freshCount) fresh. Selected \(targets.count) for Qwen: \(targets.joined(separator: ", ")). All holdings first, then up to \(Self.discoveryLimit) new candidates, rotating by last attempt then daily dollar activity. Screening is not full model analysis; unsupported, missing and stale data are excluded.", at: selectedAt)
        } else {
            next.note(action: "Market scan unavailable", reason: "Full-market data could not be verified; no new discovery. Reviewing \(targets.count) existing paper holdings only.", at: selectedAt)
        }
        guard save(next) else { return }
        guard !targets.isEmpty else { status = market == nil ? "Full-market scan unavailable; will retry next cycle" : "Market screened; no fresh affordable research candidates"; return }
        guard let config = StockSageAIAssessments.configuration else {
            recordFailure("Local Qwen is disabled or not configured.", at: Date()); return
        }
        let probe = await StockSageLocalModelServer.probe(config)
        guard isRunning, !Task.isCancelled else { return }
        guard probe.reachable, probe.hasModel else { recordFailure("Local Qwen server is unavailable.", at: Date()); return }
        var finished = 0
        let heldSymbols = Set(book.open.map(\.symbol))
        for batch in [targets.filter { heldSymbols.contains($0) }, targets.filter { !heldSymbols.contains($0) }] {
            await Self.forEachResearchTarget(batch) { [self] symbol in
                await researchSymbol(symbol, store: store, config: config, isOllama: probe.isOllama,
                                     marketSymbols: marketSymbols, run: run)
                finished += 1
                if generation == run, isRunning {
                    status = "Qwen research \(finished)/\(targets.count) completed · up to \(Self.researchConcurrency) in parallel"
                }
            }
        }
        guard isRunning, !Task.isCancelled, generation == run else { return }
        next = book
        guard ToolPolicy.isExternalAllowed, !store.isSampleData,
              StockSageAIAssessments.configuration == config else {
            next.note(action: "Research interrupted", reason: "Model configuration, web access or usable-data mode changed during the cycle.", at: Date())
            _ = save(next)
            status = "Research interrupted; will recheck configuration next cycle"
            return
        }
        let completedAt = Date()
        let outcomes = next.decisions.filter { $0.at >= now && !$0.symbol.isEmpty }
        let verified = outcomes.filter { !$0.model.isEmpty }.count
        let unavailable = outcomes.filter { $0.action == "Unavailable" }.count
        let buys = outcomes.filter { $0.action == "Paper Buy" }.count
        let sells = outcomes.filter { $0.action == "Paper Sell" }.count
        next.note(action: "Research complete", reason: "Visited \(finished)/\(targets.count) selected symbols in \(Int(max(0, completedAt.timeIntervalSince(now))))s: \(verified) verified opinions, \(unavailable) unavailable checks. During this cycle: \(buys) paper buys, \(sells) paper sells. A verified opinion is not necessarily an order; skipped decisions remain in the history.", at: completedAt)
        guard save(next) else { return }
        status = "Research complete; monitoring paper positions"
    }

    private func researchSymbol(_ symbol: String, store: StockSageStore,
        config: StockSageLocalModelServer.Config, isOllama: Bool, marketSymbols: Set<String>, run: UUID) async {
        guard isRunning, !Task.isCancelled, ToolPolicy.isExternalAllowed, !store.isSampleData,
              Self.entryWindowOpen(Date()), generation == run, StockSageAIAssessments.configuration == config else { return }
        guard Self.mayResearch(symbol, marketSymbols: marketSymbols, heldSymbols: Set(book.open.map(\.symbol))) else { return }
        async let historyFetch = StockSageQuoteService.fetchHistory(symbol, range: "1y")
        async let newsFetch = StockSageNewsService.recentNews(for: symbol, limit: 3)
        let intradayAt = Date()
        async let intradayFetch = StockSageMassiveTicks.intradayFacts(symbol: symbol,
            from: max(intradayAt.addingTimeInterval(-3600), Self.sessionTime(intradayAt, hour: 4, minute: 0)), now: intradayAt)
        let (history, news, intraday) = await (historyFetch, newsFetch, intradayFetch)
        guard isRunning, !Task.isCancelled, generation == run else { return }
        guard let intraday else {
            recordFailure("Recent intraday bars and qualified trade evidence unavailable; no same-day model decision. Scheduled exits remain active.", symbol: symbol, at: Date()); return
        }
        guard let history, let historyAt = history.dates.last,
              (0...4 * 86_400).contains(Date().timeIntervalSince(historyAt)) else {
            recordFailure("Recent dated price history unavailable; no paper decision.", symbol: symbol, at: Date()); return
        }
        // Discovery must not require an existing board row or mutate the owner's watchlist.
        let definitions = [store.symbols.first { $0.symbol == symbol }
            ?? StockSageSymbol(symbol: symbol, market: "US · Massive")]
        let ideas = await StockSageStore.buildIdeas(defs: definitions, histories: [symbol: history])
        guard isRunning, !Task.isCancelled, generation == run else { return }
        guard let base = ideas.first else {
            recordFailure("Price history or symbol definition unavailable; no paper decision.", symbol: symbol, at: Date()); return
        }
        // History/news can take time. Capture the decision quote after those awaits.
        let observed = await Self.fetchPaperQuotes(for: [symbol])
        guard isRunning, !Task.isCancelled, generation == run else { return }
        guard let quote = observed[symbol], Self.fresh(quote, at: Date()) else {
            recordFailure("No qualifying Massive trade within two minutes after checking snapshot and tick tape; no paper decision.", symbol: symbol, at: Date()); return
        }
        let idea = base.withLivePrice(quote.price, asOf: quote.marketTime, priceSource: quote.priceSource)
        let context = StockSageAIAssessment.Context(idea: idea, earnings: store.catalystChain[symbol],
            company: store.companyEventChecks[symbol] ?? [:], news: news, at: Date())
        let held = book.open.first { $0.symbol == symbol }
        let position = held.map { "Currently held in the paper account: \($0.shares) shares, simulated entry \($0.entry) USD. Sell/Reduce closes this holding; Hold keeps it." }
            ?? "Not currently held in the paper account. Buy/Strong Buy can open a simulated position; Hold/Avoid leaves cash unchanged. Sell/Reduce cannot open a short."
        let facts = context.facts + intraday.facts + ["Daily background bars end \(historyAt.ISO8601Format()); daily indicators are not intraday predictions. Same-day policy: no new entries from 19:55 New York and no intended overnight holdings.",
            position, "Paper cash: \(book.cash) USD; maximum per new position: \(Self.positionCap) USD. Do not invent a trade just to spend cash.", Self.sessionClockFact(at: Date())]
        // Skip the intraday caveat/summary: new entries must cite an actual dated observation.
        let intradayIndices = (context.facts.count + 1)..<(context.facts.count + intraday.facts.count)
        let entryInstruction = "\nFor Buy or Strong Buy, cite at least one actual intraday observation: "
            + intradayIndices.map { "F\($0 + 1)" }.joined(separator: ", ") + ". Daily background alone is not a same-day entry case."
        guard context.canAssess(at: Date()), intraday.fresh(at: Date()), Self.fresh(quote, at: Date()) else {
            recordFailure("Research context exceeded its freshness or size limit.", symbol: symbol, at: Date()); return
        }
        let response = await StockSageLocalModelServer.complete(config, isOllama: isOllama,
            system: Self.researchInstructions + entryInstruction, user: StockSageAIAssessment.prompt(facts: facts), maxTokens: 192)
        guard isRunning, !Task.isCancelled, ToolPolicy.isExternalAllowed, !store.isSampleData,
              generation == run, StockSageAIAssessments.configuration == config else { return }
        guard case .success(let text) = response else {
            recordFailure("Qwen request failed; no paper order. Scheduled exits remain active.", symbol: symbol, at: Date()); return
        }
        guard let verdict = StockSageAIAssessment.parse(text, facts: facts) else {
            recordFailure("Qwen response failed schema, citation or numeric verification; no paper order. Scheduled exits remain active.", symbol: symbol, at: Date()); return
        }
        let decisionAt = Date()
        var next = book
        next.note(symbol: symbol, action: verdict.action.rawValue, reason: verdict.reason, at: decisionAt,
                  risk: verdict.risk, facts: facts, evidence: verdict.evidence, model: config.model)
        if (verdict.action == .buy || verdict.action == .strongBuy),
           !Self.hasIntradayEvidence(verdict.evidence, factIndices: intradayIndices) {
            next.note(symbol: symbol, action: "Skipped", reason: "Buy opinion did not cite an actual intraday observation; daily background alone cannot open a same-day position.", at: decisionAt)
        } else if Self.paperSessionOpen(decisionAt), intraday.fresh(at: decisionAt), Self.fresh(quote, at: decisionAt),
           held?.id == next.open.first(where: { $0.symbol == symbol })?.id,
           Self.mayResearch(symbol, marketSymbols: marketSymbols, heldSymbols: Set(next.open.map(\.symbol))) {
            next.propose(symbol: symbol, action: verdict.action, at: decisionAt)
        } else {
            next.note(symbol: symbol, action: "Skipped", reason: "Research finished after quote expiry, scheduled market close, a holding change or loss of research eligibility.", at: decisionAt)
        }
        guard save(next) else { return }
    }

    private func recordFailure(_ reason: String, symbol: String = "", at: Date) {
        var next = book
        next.note(symbol: symbol, action: "Unavailable", reason: reason, at: at)
        _ = save(next)
        status = reason
    }
}
