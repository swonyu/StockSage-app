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
    nonisolated static let discoveryLimit = 101 // Total checks per cycle, including holdings (owner choice).
    nonisolated static let researchConcurrency = 4
    nonisolated static let researchMaximumAge: TimeInterval = 60
    /// One constant for both the fit() budget and the dispatched output limit: two literals
    /// could drift apart and pack a prompt to a budget larger than the one actually enforced.
    nonisolated static let researchOutputTokens = 192
    nonisolated static let researchInstructions = StockSageAIAssessment.instructions
        .replacingOccurrences(of: "Assess the supplied stock for the next trading week.",
            with: "Assess an entry or exit NOW for the REMAINDER OF TODAY'S New York session only. No overnight or multi-day thesis. Use the completed intraday bars or explicitly labelled qualified trades; daily technical rules are background, not intraday signals.")
        + "\nFor this paper scan, keep reason and risk to at most 20 words EACH. Retain the four-key JSON and all required evidence references."
        + "\nKeep reason and risk qualitative, without repeating numbers, dates or clock times; exact figures remain in the cited facts."

    nonisolated struct Decision: Codable, Identifiable, Sendable, Equatable {
        let id: UUID
        let at: Date
        let symbol: String
        let action: String
        let reason: String
        let risk: String
        let facts: [String]
        let evidence: [String]
        let model: String
        var plan: EntryPlan? = nil
    }

    nonisolated struct EntryPlan: Codable, Sendable, Equatable {
        let entry: Double
        let stop: Double
        let target: Double
        let at: Date
        init(entry: Double, at: Date) {
            self.entry = entry; self.at = at
            stop = entry * 0.98; target = entry * 1.04
        }
        var valid: Bool {
            entry.isFinite && stop.isFinite && target.isFinite && stop > 0 && stop < entry && target > entry
                && at.timeIntervalSince1970.isFinite && at.timeIntervalSince1970 > 0
        }
    }

    nonisolated struct Pending: Codable, Identifiable, Sendable {
        let id: UUID
        let symbol: String
        let buy: Bool
        var at: Date
        /// Optional for version-1 compatibility. Stops persist for this holding only;
        /// `at` remains the current 120-second attempt, not the original trigger time.
        var protectiveTradeID: UUID? = nil
    }

    nonisolated struct Book: Codable, Sendable {
        var version = 1
        var trades: [TradeRecord] = []
        var pending: [Pending] = []
        var decisions: [Decision] = []
        var lastResearch: Date?
        var cursor = 0
        var audit: Audit? = nil

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

        /// Receivables remain in total cash/equity, but cannot fund another same-day entry.
        func unsettledSales(at now: Date) -> [TradeRecord] {
            trades.filter { trade in
                guard let closed = trade.closedAt, trade.exitPrice != nil else { return false }
                guard let settlement = StockSagePaperAutomation.settlementDate(forSaleAt: closed) else { return true }
                return now < settlement
            }
        }
        func unsettledProceeds(at now: Date) -> Double {
            Self.money(unsettledSales(at: now).reduce(0) { $0 + Self.money($1.exitPrice! * $1.shares) })
        }
        func settledCash(at now: Date) -> Double { Self.money(cash - unsettledProceeds(at: now)) }
        // Preserve a negative legacy balance for disclosure; clamp only new spending capacity.
        func buyingCash(at now: Date) -> Double { max(0, settledCash(at: now)) }

        var valid: Bool {
            structurallyValid && decisions.count <= 50_000
        }
        var structurallyValid: Bool {
            ((version == 1 && audit == nil) || (version == 2 && audit != nil))
                && cursor >= 0 && trades.count <= 50_000
                && open.count <= 5 && pending.count <= 5 && cash.isFinite && cash >= 0
                && Set(decisions.map(\.id)).count == decisions.count
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
                && pending.allSatisfy { order in
                    StockSagePaperAutomation.validSymbol(order.symbol) && order.at.timeIntervalSince1970.isFinite
                        && (order.protectiveTradeID.map { id in
                            !order.buy && open.contains { $0.id == id && $0.symbol == order.symbol }
                        } ?? true)
                }
                && decisions.allSatisfy { $0.at.timeIntervalSince1970.isFinite && ($0.plan?.valid ?? true) }
        }

        mutating func note(symbol: String = "", action: String, reason: String, at: Date,
                           risk: String = "", facts: [String] = [], evidence: [String] = [], model: String = "", plan: EntryPlan? = nil) {
            decisions.append(.init(id: UUID(), at: at, symbol: symbol, action: action,
                reason: reason, risk: risk, facts: facts, evidence: evidence, model: model, plan: plan))
        }

        mutating func activateSameDay(at now: Date) {
            guard audit?.control.sameDayActivated != true,
                  !decisions.contains(where: { $0.action == "Same-day policy activated" }) else { return }
            let cancelled = pending.filter(\.buy).count
            pending.removeAll(where: \.buy)
            lastResearch = nil
            note(action: "Same-day policy activated",
                 reason: "Cancelled \(cancelled) pre-policy pending entries. Holdings, exit requests and history retained. Fresh same-day research is due; close-out starts at 19:55 New York.", at: now)
        }

        mutating func activateSettlement(at now: Date) {
            guard audit?.control.settlementActivated != true,
                  !decisions.contains(where: { $0.action == "T+1 cash policy activated" }) else { return }
            note(action: "T+1 cash policy activated",
                 reason: "New entries require settled paper cash. Net sale proceeds release on the scheduled next New York settlement date; unsupported dates remain unavailable. Historical fills and research cadence retained; this is not a broker balance.", at: now)
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
            if buy && !held && buyingCash(at: at) <= 0 {
                note(symbol: symbol, action: "Skipped", reason: "No settled paper cash available; sale proceeds cannot fund same-day entries.", at: at)
            } else if buy && !held && open.count + pending.filter(\.buy).count < 5 {
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
                    if let holding = order.protectiveTradeID,
                       open.contains(where: { $0.id == holding && $0.symbol == order.symbol }) {
                        // Retain the intent while closed without generating futile retry records.
                        // Never backdate a retry or let an expired attempt fill on this observation.
                        if now >= order.at, StockSagePaperAutomation.paperSessionOpen(now),
                           let i = pending.firstIndex(where: { $0.id == order.id }) {
                            pending[i].at = now
                            note(symbol: order.symbol, action: "Stop exit retry",
                                 reason: "Protective intent retained; new two-minute attempt awaits a later qualified observation.", at: now)
                        }
                        continue
                    }
                    pending.removeAll { $0.id == order.id }
                    note(symbol: order.symbol, action: "Expired", reason: "No eligible post-decision fill within two minutes, or clock moved backwards.", at: now)
                    continue
                }
                guard StockSagePaperAutomation.paperSessionOpen(now),
                      let q = quotes[order.symbol], StockSagePaperAutomation.qualified(q, at: now),
                      q.symbol == order.symbol, let quoteTime = q.marketTime, quoteTime > order.at else { continue }
                pending.removeAll { $0.id == order.id }
                let fill = q.price * (order.buy ? 1 + StockSagePaperAutomation.costRate : 1 - StockSagePaperAutomation.costRate)
                if order.buy {
                    let available = buyingCash(at: now)
                    let shares = min(1_000_000, floor(min(available, StockSagePaperAutomation.positionCap) / fill))
                    guard shares >= 1, open.count < 5, !open.contains(where: { $0.symbol == order.symbol }),
                          Self.money(fill * shares) <= available else {
                        note(symbol: order.symbol, action: "Skipped", reason: "Insufficient settled paper cash or position capacity at the observed fill.", at: now)
                        continue
                    }
                    let levels = EntryPlan(entry: fill, at: quoteTime)
                    trades.append(TradeRecord(id: order.id, symbol: order.symbol, side: .long, entry: fill,
                        stop: levels.stop, target: levels.target, shares: shares, openedAt: now,
                        note: "Qwen paper simulation; assumed costs, not a broker fill."))
                } else if let i = trades.firstIndex(where: { $0.isOpen && $0.symbol == order.symbol }) {
                    trades[i].exitPrice = fill; trades[i].closedAt = now
                } else { continue }
                note(symbol: order.symbol, action: order.buy ? "Paper Buy" : "Paper Sell",
                     reason: "Simulated at a later Massive observation with an assumed 10 bps adverse fill.", at: now,
                     facts: ["Observed price: \(q.price)", "Market timestamp: \(quoteTime.ISO8601Format())", "Simulated fill: \(fill)"])
            }
            guard StockSagePaperAutomation.paperSessionOpen(now) else { return }
            for trade in open {
                guard let q = quotes[trade.symbol], q.symbol == trade.symbol,
                      StockSagePaperAutomation.qualified(q, at: now), q.marketTime! > trade.openedAt else { continue }
                if q.price <= trade.stop || q.price >= (trade.target ?? .infinity) {
                    let stop = q.price <= trade.stop
                    if let i = pending.firstIndex(where: { $0.symbol == trade.symbol }) {
                        guard stop, !pending[i].buy, pending[i].protectiveTradeID == nil else { continue }
                        pending[i].protectiveTradeID = trade.id
                        pending[i].at = now
                    } else {
                        pending.append(.init(id: UUID(), symbol: trade.symbol, buy: false, at: now,
                                             protectiveTradeID: stop ? trade.id : nil))
                    }
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
                      StockSagePaperAutomation.qualified(q, at: now) else { return nil }
                total += Self.money(trade.shares * q.price * (1 - StockSagePaperAutomation.costRate))
            }
            return total.isFinite ? Self.money(total) : nil
        }
    }

    @Published private(set) var book = Book()
    @Published private(set) var hasLoadedBook = false
    @Published private(set) var isRunning = false
    @Published private(set) var isResearching = false
    @Published private(set) var researchProgress: Progress?
    @Published private(set) var researchingSymbols: Set<String> = []
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
        do { book = try read(); hasLoadedBook = true }
        catch { self.error = "Paper account could not be read. Existing data has been preserved." }
    }

    nonisolated static func validSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,11}$"#, options: .regularExpression) != nil
            && StockSageCurrency.conversionCurrencyForSymbol(symbol) == "USD"
            && StockSageAllocation.assetClass(symbol) == "Equity"
    }
    /// Native simulation only: published holidays, early closes and DST share the UI clock.
    /// Scheduled eligibility is not fresh data, liquidity or broker permission.
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

    /// Scheduled US equity T+1; midnight release is a simulation convention, not broker confirmation.
    /// FINRA calendar, verified 2026-09-09: /rules-guidance/key-topics/margin-accounts/margin-extension-holiday-schedule
    /// ponytail: explicit 2026 + January 2027 calendar; extend from verified notices before expiry.
    nonisolated static func settlementDate(forSaleAt sale: Date) -> Date? {
        guard sale.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func dayKey(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        }
        guard (20260101...20270131).contains(dayKey(sale)) else { return nil }
        let holidays: Set<Int> = [20260101, 20260119, 20260216, 20260403, 20260525, 20260619,
            20260703, 20260907, 20261012, 20261111, 20261126, 20261225, 20270101, 20270118]
        var day = calendar.startOfDay(for: sale)
        for _ in 0..<8 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  (20260101...20270131).contains(dayKey(next)) else { return nil }
            day = next
            if !calendar.isDateInWeekend(day), !holidays.contains(dayKey(day)) { return day }
        }
        return nil
    }
    nonisolated static func entryWindowOpen(_ now: Date) -> Bool {
        guard let cutoff = entryCutoff(now) else { return false }
        return paperSessionOpen(now) && now < cutoff
    }
    nonisolated static func entryCutoff(_ now: Date) -> Date? {
        guard let day = StockSageMarketHours.nasdaqDay(at: now), day.trading else { return nil }
        return sessionTime(now, hour: day.extendedClose - 1, minute: 55)
    }
    nonisolated static func sessionClockFact(at now: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(identifier: "America/New_York")!
        let cutoff = entryCutoff(now).map { format.string(from: $0) } ?? "unavailable (closed or unsupported calendar)"
        return "Authoritative decision-clock snapshot: \(format.string(from: now)) America/New_York. New entry window: \(entryWindowOpen(now) ? "OPEN" : "CLOSED"). Entry cutoff: \(cutoff). Do not compare UTC timestamps to New York clock times. Window status does not override evidence, cash, holdings or freshness checks."
    }
    nonisolated static func dayExitDue(openedAt: Date, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return (entryCutoff(now).map { now >= $0 } ?? false)
            || !calendar.isDate(openedAt, inSameDayAs: now)
    }
    nonisolated static func fresh(_ quote: StockSageQuoteService.LiveQuote, at now: Date,
                                  maximumAge: TimeInterval = StockSageLiveStream.maximumLiveAge) -> Bool {
        guard quote.price.isFinite, quote.price > 0, quote.priceSource == .massiveSIP,
              let at = quote.marketTime else { return false }
        return (0...maximumAge).contains(now.timeIntervalSince(at))
    }
    nonisolated static func qualified(_ quote: StockSageQuoteService.LiveQuote, at now: Date,
                                      maximumAge: TimeInterval = StockSageLiveStream.maximumLiveAge) -> Bool {
        quote.paperTradeQualified && fresh(quote, at: now, maximumAge: maximumAge)
    }
    nonisolated static func hasIntradayEvidence(_ evidence: [String], factIndices: Range<Int>) -> Bool {
        let intraday = Set(factIndices.map { "F\($0 + 1)" })
        return !intraday.isDisjoint(with: evidence)
    }

    /// Shared by research, pending fills and position monitoring; stale snapshots are not final answers.
    static func fetchPaperQuotes(for symbols: [String], after: [String: Date] = [:], at fixedTime: Date? = nil,
        maximumAge: TimeInterval = StockSageLiveStream.maximumLiveAge,
        externalAllowed: @escaping @MainActor () -> Bool = { ToolPolicy.isExternalAllowed },
        received: @escaping @MainActor (StockSageQuoteService.LiveQuote) -> Void = { _ in },
        snapshots: @MainActor ([String]) async -> [String: StockSageQuoteService.LiveQuote] = { _ in [:] },
        tick: @escaping @MainActor (String, Date) async -> StockSageQuoteService.LiveQuote? = { await StockSageMassiveTicks.freshPaperQuote(symbol: $0, now: $1) }
    ) async -> [String: StockSageQuoteService.LiveQuote] {
        guard externalAllowed(), !Task.isCancelled, !symbols.isEmpty else { return [:] }
        let snapshots = await snapshots(symbols)
        guard externalAllowed(), !Task.isCancelled else { return [:] }
        var result: [String: StockSageQuoteService.LiveQuote] = [:]
        func eligible(_ q: StockSageQuoteService.LiveQuote, symbol: String) -> Bool {
            q.symbol == symbol && qualified(q, at: fixedTime ?? Date(), maximumAge: maximumAge)
                && (after[symbol].map { (q.marketTime ?? .distantPast) > $0 } ?? true)
        }
        await forEachResearchTarget(Array(Set(symbols)).sorted()) { symbol in
            guard externalAllowed(), !Task.isCancelled else { return }
            if let q = snapshots[symbol], eligible(q, symbol: symbol) {
                result[symbol] = q
                received(q)
            } else if let q = await tick(symbol, fixedTime ?? Date()),
                      externalAllowed(), !Task.isCancelled, eligible(q, symbol: symbol) {
                result[symbol] = q
                received(q)
            }
        }
        // A sibling request may finish after permission was revoked; discard the entire batch.
        return externalAllowed() && !Task.isCancelled ? result : [:]
    }

    /// Revalidate actionable opinions after inference. Facts keep their original timestamps;
    /// read the current ledger only AFTER awaiting the qualified observation.
    static func decisionBook(symbol: String, verdict: StockSageAIAssessment.Verdict,
        facts: [String], model: String, researchQuote: StockSageQuoteService.LiveQuote,
        holdingID: UUID?, citesIntraday: Bool, at fixedTime: Date? = nil,
        allowed: @MainActor () -> Bool, contextFresh: @MainActor (Date) -> Bool,
        currentBook: @MainActor () -> Book,
        commit: @MainActor (Book) -> Bool = { _ in true },
        fetch: @MainActor (String, Date) async -> StockSageQuoteService.LiveQuote? = { symbol, after in
            await fetchPaperQuotes(for: [symbol], after: [symbol: after], maximumAge: researchMaximumAge)[symbol]
        }
    ) async -> Book? {
        guard allowed(), !Task.isCancelled else { return nil }
        let actionable = [.buy, .strongBuy, .sell, .reduce].contains(verdict.action)
        let cited = ![.buy, .strongBuy].contains(verdict.action) || citesIntraday
        let initialTime = fixedTime ?? Date()
        let observationFailure = "No valid qualified observation later than the research observation; no paper order created."
        let contextFailure = "Research context expired after inference; no paper order created."
        let sessionFailure = "Paper session closed after inference; no paper order created."
        var revalidated: StockSageQuoteService.LiveQuote?
        var revalidationFailure: String?
        if actionable, cited {
            if !contextFresh(initialTime) { revalidationFailure = contextFailure }
            else if !paperSessionOpen(initialTime) { revalidationFailure = sessionFailure }
            else if let after = researchQuote.marketTime { revalidated = await fetch(symbol, after) }
            else { revalidationFailure = observationFailure }
        }
        guard allowed(), !Task.isCancelled else { return nil }
        let decisionAt = fixedTime ?? Date()
        var next = currentBook()
        var preview: EntryPlan?
        if verdict.action == .buy || verdict.action == .strongBuy,
           researchQuote.priceSource == .massiveSIP, let at = researchQuote.marketTime, at <= decisionAt {
            let levels = EntryPlan(entry: researchQuote.price * (1 + costRate), at: at)
            if levels.valid { preview = levels }
        }
        next.note(symbol: symbol, action: verdict.action.rawValue, reason: verdict.reason, at: decisionAt,
                  risk: verdict.risk, facts: facts, evidence: verdict.evidence, model: model, plan: preview)
        guard actionable else { return commit(next) ? next : nil } // Hold/Avoid is an opinion, not a skipped order.
        if !cited {
            revalidationFailure = "Buy opinion did not cite an actual intraday observation; daily background alone cannot open a same-day position."
        } else if revalidationFailure == nil {
            if let q = revalidated, q.symbol == symbol, qualified(q, at: decisionAt, maximumAge: researchMaximumAge),
               let at = q.marketTime, let capturedAt = researchQuote.marketTime, at >= capturedAt {
                if !contextFresh(decisionAt) { revalidationFailure = contextFailure }
                else if !paperSessionOpen(decisionAt) { revalidationFailure = sessionFailure }
                else if holdingID != next.open.first(where: { $0.symbol == symbol })?.id {
                    revalidationFailure = "Paper holding changed after inference; no paper order created."
                } else {
                    next.note(symbol: symbol, action: "Price revalidated",
                        reason: "Separate qualified Massive observation after inference; original cited research facts are unchanged. A fill still requires a later observation.",
                        at: decisionAt, facts: ["Market timestamp: \(at.ISO8601Format())", "Observed price: \(q.price)", "Source: Massive SIP"])
                    next.propose(symbol: symbol, action: verdict.action, at: decisionAt)
                }
            } else { revalidationFailure = observationFailure }
        }
        if let reason = revalidationFailure {
            next.note(symbol: symbol, action: "Skipped", reason: reason, at: decisionAt)
        }
        return commit(next) ? next : nil
    }

    /// Rolling task group overlaps I/O/inference, while each ledger mutation stays on MainActor.
    static func forEachResearchTarget(_ symbols: [String],
        allowed: @escaping @MainActor () -> Bool = { true },
        operation: @escaping @MainActor @Sendable (String) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = symbols.makeIterator()
            for _ in 0..<researchConcurrency {
                if !Task.isCancelled, allowed(), let symbol = remaining.next() { group.addTask { await operation(symbol) } }
            }
            for await _ in group {
                if Task.isCancelled || !allowed() { group.cancelAll(); break }
                if let symbol = remaining.next() { group.addTask { await operation(symbol) } }
            }
        }
    }

    nonisolated static func mayResearch(_ symbol: String, marketSymbols: Set<String>, heldSymbols: Set<String>) -> Bool {
        validSymbol(symbol) && (marketSymbols.contains(symbol) || heldSymbols.contains(symbol))
    }

    nonisolated static func researchDue(book: Book, at now: Date) -> Bool {
        // A legacy watchlist-only cycle is not the first full-market scan after upgrade.
        (book.audit?.control.marketScanned != true && !book.decisions.contains { $0.action.hasPrefix("Market scan") })
            || (book.lastResearch.map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    /// Full-market screening is cheap; model calls have bounded concurrency. Holdings have first
    /// priority inside the 101 total slots. Least-recently attempted names rotate ahead of repeats.
    nonisolated static func researchTargets(market: StockSageMassive.MarketSnapshot?, book: Book, at now: Date) -> [String] {
        let held = Set(book.open.map(\.symbol).filter(validSymbol))
        let pending = Set(book.pending.map(\.symbol))
        var attempted: [String: Date] = book.audit?.control.latestAttempt ?? [:]
        for decision in book.decisions where !decision.symbol.isEmpty {
            attempted[decision.symbol] = max(attempted[decision.symbol] ?? .distantPast, decision.at)
        }
        let affordable = min(book.buyingCash(at: now), positionCap)
        let candidates = (market?.rows ?? []).filter {
            let q = $0.quote
            return validSymbol(q.symbol) && StockSageMassive.covers(q.symbol) && fresh(q, at: now, maximumAge: researchMaximumAge)
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
        return held.sorted() + candidates.prefix(max(0, discoveryLimit - held.count)).map(\.quote.symbol)
    }

    private func read() throws -> Book {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let directory = url.deletingLastPathComponent().path
            let files = FileManager.default.fileExists(atPath: directory)
                ? try FileManager.default.contentsOfDirectory(atPath: directory) : []
            guard !files.contains(where: { $0.hasPrefix("audit-") && $0.hasSuffix(".json") }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Book()
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Book.self, from: Data(contentsOf: url))
        guard value.valid else { throw CocoaError(.fileReadCorruptFile) }
        try value.audit?.validate(beside: url, activeIDs: Set(value.decisions.map(\.id)))
        return value
    }

    #if os(macOS)
    func exportResearch(to destination: URL) async throws {
        let account = url
        try await Task.detached(priority: .utility) {
            try Self.saveResearchExport(account: account, to: destination, at: Date())
        }.value
    }
    #endif

    /// Preserve exact cycle accounting even when an unusually long cycle spans audit rotation.
    private func decisions(since date: Date) throws -> [Decision] {
        var result: [Decision] = []
        for archive in book.audit?.archives ?? [] where archive.latestAt >= date {
            result += try archive.read(beside: url).filter { $0.at >= date }
        }
        return result + book.decisions.filter { $0.at >= date }
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
            hasLoadedBook = true
            error = nil
            return true
        } catch {
            hasLoadedBook = false
            release(); self.error = "Paper account unavailable or corrupt. Existing data has been preserved."; return false
        }
    }
    private func release() {
        if lease >= 0 { flock(lease, LOCK_UN); Darwin.close(lease); lease = -1 }
    }
    @discardableResult func save(_ next: Book, beforeAccountCommit: (() throws -> Void)? = nil) -> Bool {
        guard lease >= 0 else { error = "Paper account has no writer lease."; return false }
        do {
            // A stale caller must not erase a committed archive manifest.
            guard next.audit == book.audit else { throw CocoaError(.fileWriteInvalidFileName) }
            let (next, writes, data) = try Self.prepareAudit(next)
            for (archive, bytes) in writes {
                try bytes.write(to: archive.url(beside: url), options: [.withoutOverwriting, .completeFileProtection])
                _ = try archive.read(beside: url)
            }
            try beforeAccountCommit?() // Test fault boundary: archive completion is not account commitment.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            book = next; hasLoadedBook = true; error = nil
            return true
        } catch {
            self.error = "Paper account save failed or ledger limit reached. Automation paused; previous data preserved."
            defaults.set(false, forKey: Self.enabledKey)
            loop?.cancel(); research?.cancel(); isRunning = false; status = "Paused after storage failure"
            researchProgress = nil
            researchingSymbols.removeAll()
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
        next.activateSettlement(at: Date())
        if next.decisions.count != book.decisions.count, !save(next) { release(); return }
        defaults.set(true, forKey: Self.enabledKey)
        generation = UUID()
        isResearching = false
        researchProgress = nil
        researchingSymbols.removeAll()
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
        researchProgress = nil
        researchingSymbols.removeAll()
        if lease >= 0 {
            var next = book
            next.pending.removeAll { $0.protectiveTradeID == nil }
            next.note(action: "Paused", reason: "Ordinary pending orders cancelled. Holdings and triggered protective exits retained; no attempts while paused.", at: Date())
            _ = save(next)
        }
        release()
    }

    /// A model edit retires research, never the independent position/exit monitor.
    func cancelResearchForSettingsChange() {
        research?.cancel()
        researchProgress = nil
        researchingSymbols.removeAll()
        if isResearching { status = "Research cancelled after model settings changed; exits remain monitored" }
    }

    func scheduleResearch(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard !isResearching else { return }
        let run = generation
        isResearching = true
        researchProgress = Progress(totalUnitCount: 0)
        researchingSymbols.removeAll()
        research = Task { [weak self] in
            defer {
                if let self, self.generation == run {
                    self.isResearching = false
                    self.researchProgress = nil
                    self.researchingSymbols.removeAll()
                }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func withResearchCheck(_ symbol: String, operation: @MainActor () async -> Void) async {
        guard isResearching, !Task.isCancelled else { return }
        let run = generation
        researchingSymbols.insert(symbol)
        defer {
            if generation == run { researchingSymbols.remove(symbol) }
        }
        await operation()
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
            status = book.open.isEmpty ? "Waiting for a supported US session: normal 04:00–20:00, early-close 04:00–17:00 New York; exchange holidays closed"
                : "Session closed with unresolved paper positions; no closing prices invented. Exits retry next session."
            return
        }
        let run = generation
        let polled = await pollPositions(allowed: { self.isRunning && self.generation == run
            && ToolPolicy.isExternalAllowed && !store.isSampleData })
        guard !Task.isCancelled, isRunning, generation == run else { return }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else {
            status = "Waiting: web access or usable market data unavailable"; return
        }
        guard polled else { return }
        if !isResearching, Self.entryWindowOpen(Date()), Self.researchDue(book: book, at: Date()) {
            scheduleResearch { [weak self] in await self?.researchCycle(store: store) }
        }
        if !isResearching {
            status = Self.entryWindowOpen(Date()) ? "Monitoring paper positions; waiting for the next research cycle"
                : "Same-day close-out: new entries stopped; \(book.open.count) positions awaiting eligible exits"
        }
    }

    /// Process held-position observations as they arrive; new buys retain aggregate ordering.
    /// A later sibling basis warning pauses remaining work, never rewrites an already saved exit.
    func pollPositions(allowed: @escaping @MainActor () -> Bool, at fixedTime: Date? = nil,
        tick: @escaping @MainActor (String, Date) async -> StockSageQuoteService.LiveQuote? = {
            await StockSageMassiveTicks.freshPaperQuote(symbol: $0, now: $1)
        }) async -> Bool {
        var healthy = true
        let active = { @MainActor in healthy && allowed() && !Task.isCancelled }
        guard active() else { return false }
        let held = Array(Set(book.open.map(\.symbol) + book.pending.map(\.symbol))).sorted()
        let identities = Dictionary(uniqueKeysWithValues: book.open.map { ($0.symbol, $0.id) })
        let after = Dictionary(uniqueKeysWithValues: book.pending.map { ($0.symbol, $0.at) })
        let latest = await Self.fetchPaperQuotes(for: held, after: after, at: fixedTime,
            externalAllowed: active, received: { q in
                guard active(), let original = identities[q.symbol],
                      self.book.open.contains(where: { $0.id == original && $0.symbol == q.symbol }),
                      !self.book.pending.contains(where: { $0.symbol == q.symbol && $0.buy }) else { return }
                healthy = self.applyPositionQuotes([q.symbol: q], at: fixedTime ?? Date())
            }, tick: tick)
        guard active() else { return false }
        quotes = latest
        return applyPositionQuotes(latest, at: fixedTime ?? Date())
    }

    private func applyPositionQuotes(_ latest: [String: StockSageQuoteService.LiveQuote], at now: Date) -> Bool {
        // The existing per-holding split/basis guard applies before any trigger or fill.
        if book.open.contains(where: { t in
            guard let q = latest[t.symbol], Self.fresh(q, at: now) else { return false }
            return q.price / t.entry < 0.67 || q.price / t.entry > 1.5
        }) {
            stop(); error = "Large price/basis change: review possible corporate actions before restarting the simulation."
            return false
        }
        quotes.merge(latest) { _, new in new }
        var next = book
        let before = next.decisions.count
        next.settle(quotes: latest, at: now)
        return next.decisions.count == before || save(next)
    }

    private func researchCycle(store: StockSageStore) async {
        guard isRunning, !Task.isCancelled else { return }
        let run = generation
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
            let freshCount = market.rows.filter { Self.validSymbol($0.quote.symbol) && Self.fresh($0.quote, at: selectedAt, maximumAge: Self.researchMaximumAge) }.count
            next.note(action: "Market scan", reason: "\(market.returnedCount) US listed tickers returned; \(market.rows.count) supported trade observations; \(freshCount) fresh. Selected \(targets.count) for Qwen: \(targets.joined(separator: ", ")). Up to \(Self.discoveryLimit) total checks: all holdings first, then new candidates, rotating by last attempt then daily dollar activity. Screening is not full model analysis; unsupported, missing and stale data are excluded.", at: selectedAt)
        } else {
            next.note(action: "Market scan unavailable", reason: "Full-market data could not be verified; no new discovery. Reviewing \(targets.count) existing paper holdings only.", at: selectedAt)
        }
        guard save(next) else { return }
        guard !targets.isEmpty else { status = market == nil ? "Waiting for full-market data; retries next research cycle" : "Market screened; no fresh affordable research candidates"; return }
        guard let config = StockSageAIAssessments.configuration else {
            recordFailure("Local Qwen is disabled or not configured.", at: Date()); return
        }
        let revision = StockSageLocalModelServer.settingsRevision()
        let active: @MainActor @Sendable () -> Bool = { [self] in
            isRunning && !Task.isCancelled && generation == run && ToolPolicy.isExternalAllowed
                && !store.isSampleData && StockSageAIAssessments.configuration == config
                && StockSageLocalModelServer.settingsRevision() == revision
        }
        let probe = await StockSageLocalModelServer.probe(config, stillValid: active)
        guard active() else { return }
        guard probe.reachable, probe.hasModel else { recordFailure("Local Qwen server is unavailable.", at: Date()); return }
        researchProgress?.totalUnitCount = Int64(targets.count)
        status = "Qwen research 0/\(targets.count) completed · up to \(Self.researchConcurrency) in parallel"
        var finished = 0
        // researchTargets queues holdings first; a slow holding must not idle free workers.
        guard active() else { return }
        await Self.forEachResearchTarget(targets, allowed: active) { [self] symbol in
            await withResearchCheck(symbol) {
                await researchSymbol(symbol, store: store, config: config, isOllama: probe.isOllama,
                                     marketSymbols: marketSymbols, run: run, revision: revision)
            }
            guard active() else { return }
            finished += 1
            if generation == run, isRunning {
                researchProgress?.completedUnitCount = Int64(finished)
                status = "Qwen research \(finished)/\(targets.count) completed · up to \(Self.researchConcurrency) in parallel"
            }
        }
        guard isRunning, !Task.isCancelled, generation == run else { return }
        next = book
        guard ToolPolicy.isExternalAllowed, !store.isSampleData,
              StockSageAIAssessments.configuration == config, StockSageLocalModelServer.settingsRevision() == revision else {
            next.note(action: "Research interrupted", reason: "Model configuration, web access or usable-data mode changed during the cycle.", at: Date())
            _ = save(next)
            status = "Research interrupted; will recheck configuration next cycle"
            return
        }
        let completedAt = Date()
        guard let cycleDecisions = try? decisions(since: now) else {
            stop(); error = "Paper audit archive could not be verified; previous records preserved."; return
        }
        let outcomes = cycleDecisions.filter { !$0.symbol.isEmpty }
        let verified = outcomes.filter { !$0.model.isEmpty }.count
        let unavailable = outcomes.filter { $0.action == "Unavailable" }.count
        let buys = outcomes.filter { $0.action == "Paper Buy" }.count
        let sells = outcomes.filter { $0.action == "Paper Sell" }.count
        next.note(action: "Research complete", reason: "Visited \(finished)/\(targets.count) selected symbols in \(Int(max(0, completedAt.timeIntervalSince(now))))s: \(verified) verified opinions, \(unavailable) incomplete checks. During this cycle: \(buys) paper buys, \(sells) paper sells. A verified opinion is not necessarily an order; skipped decisions remain in the history.", at: completedAt)
        guard save(next) else { return }
        status = "Research complete; monitoring paper positions"
    }

    private func researchSymbol(_ symbol: String, store: StockSageStore,
        config: StockSageLocalModelServer.Config, isOllama: Bool, marketSymbols: Set<String>, run: UUID, revision: String?) async {
        let active: @MainActor @Sendable () -> Bool = { [self] in
            isRunning && !Task.isCancelled && ToolPolicy.isExternalAllowed && !store.isSampleData
                && generation == run && StockSageAIAssessments.configuration == config
                && StockSageLocalModelServer.settingsRevision() == revision
        }
        guard active(), Self.entryWindowOpen(Date()) else { return }
        guard Self.mayResearch(symbol, marketSymbols: marketSymbols, heldSymbols: Set(book.open.map(\.symbol))) else { return }
        async let historyFetch = StockSageQuoteService.fetchHistory(symbol, range: "1y")
        let newsAt = Date()
        async let benzingaFetch = StockSageBenzingaClient.shared.snapshot(for: symbol, now: newsAt)
        let intradayAt = Date()
        async let intradayFetch = StockSageMassiveTicks.intradayFacts(symbol: symbol,
            from: max(intradayAt.addingTimeInterval(-3600), Self.sessionTime(intradayAt, hour: 4, minute: 0)), now: intradayAt)
        let (history, benzinga, intraday) = await (historyFetch, benzingaFetch, intradayFetch)
        let evidenceActive: @MainActor @Sendable () -> Bool = {
            active() && StockSageBenzingaClient.shared.isCurrent(benzinga)
        }
        guard evidenceActive() else { return }
        let news = await StockSageNewsService.observation(for: symbol, limit: 3, now: newsAt,
            benzingaPage: benzinga.pages.first { $0.query.product == .news })
        guard evidenceActive() else { return }
        guard let intraday else {
            recordFailure("Recent intraday bars and qualified trade evidence unavailable; no same-day model decision. Scheduled exits remain active.", symbol: symbol, at: Date()); return
        }
        guard let history, let historyAt = history.dates.last,
              (0...4 * 86_400).contains(Date().timeIntervalSince(historyAt)) else {
            recordFailure("Recent dated price history unavailable; no paper decision.", symbol: symbol, at: Date(), facts: intraday.facts); return
        }
        let partialFacts = intraday.facts + ["Retrieved daily background ends \(historyAt.ISO8601Format()). Not an intraday price or executable quote."]
        // Discovery must not require an existing board row or mutate the owner's watchlist.
        let definitions = [store.symbols.first { $0.symbol == symbol }
            ?? StockSageSymbol(symbol: symbol, market: "US · Massive")]
        let ideas = await StockSageStore.buildIdeas(defs: definitions, histories: [symbol: history])
        guard evidenceActive() else { return }
        guard let base = ideas.first else {
            recordFailure("Price history or symbol definition unavailable; no paper decision.", symbol: symbol, at: Date(), facts: partialFacts); return
        }
        // History/news can take time. Capture the decision quote after those awaits.
        let observed = await Self.fetchPaperQuotes(for: [symbol], maximumAge: Self.researchMaximumAge)
        guard evidenceActive() else { return }
        guard let quote = observed[symbol], Self.fresh(quote, at: Date(), maximumAge: Self.researchMaximumAge) else {
            recordFailure("No qualifying Massive trade within one minute in the bounded tick tape; no paper decision.", symbol: symbol, at: Date(), facts: partialFacts); return
        }
        let idea = base.withLivePrice(quote.price, asOf: quote.marketTime, priceSource: quote.priceSource)
        let context = StockSageAIAssessment.Context(idea: idea, earnings: store.catalystChain[symbol],
            company: store.companyEventChecks[symbol] ?? [:], at: Date(), newsObservation: news, benzinga: benzinga)
        let held = book.open.first { $0.symbol == symbol }
        let position = held.map { "Currently held in the paper account: \($0.shares) shares, simulated entry \($0.entry) USD. Sell/Reduce closes this holding; Hold keeps it." }
            ?? "Not currently held in the paper account. Buy/Strong Buy can open a simulated position; Hold/Avoid leaves cash unchanged. Sell/Reduce cannot open a short."
        let executionFacts = intraday.facts + ["Daily background bars end \(historyAt.ISO8601Format()); daily indicators are not intraday predictions. Same-day policy: new entries stop five minutes before the scheduled extended-session end; no intended overnight holdings.",
            position, "Settled paper cash available for entries: \(book.buyingCash(at: Date())) USD. Total paper cash including unsettled sale proceeds: \(book.cash) USD; maximum per new position: \(Self.positionCap) USD. Simulated T+1 cash policy, not broker buying power. Do not invent a trade just to spend cash.", Self.sessionClockFact(at: Date())]
        // Evidence is packed to what the model's window ACTUALLY holds, not to a hardcoded
        // 12,000 bytes. Measured 2026-09-10: with these instructions and a 192-unit output, the
        // real allowance under the 4k target is ~1.9 kB, so the old constant meant the seam
        // rejected the entire research turn instead of returning a shorter, honest one.
        // Execution facts (position, settled cash, session clock) are MANDATORY and never dropped.
        let allFacts = context.facts(maximumUTF8Bytes: 12_000)
        func assemble(_ optionalCount: Int) -> (facts: [String], system: String, user: String) {
            let kept = Array(allFacts.prefix(optionalCount))
            let facts = kept + executionFacts
            // Skip the intraday caveat/summary: new entries must cite an actual dated observation.
            let indices = (kept.count + 1)..<(kept.count + intraday.facts.count)
            let instruction = "\nFor Buy or Strong Buy, cite at least one actual intraday observation: "
                + indices.map { "F\($0 + 1)" }.joined(separator: ", ")
                + ". Daily background alone is not a same-day entry case."
            return (facts, Self.researchInstructions + instruction, StockSageAIAssessment.prompt(facts: facts))
        }
        guard let fitted = StockSageLocalModelServer.fit(optionalCount: allFacts.count,
                  outputTokens: Self.researchOutputTokens,
                  contextTokens: StockSageLocalModelServer.researchContextTokens,
                  assemble: { let a = assemble($0); return (a.system, a.user) }) else {
            recordFailure("Research evidence could not be reduced to the model's context budget without dropping a mandatory execution fact. No paper order. Scheduled exits remain active.",
                          symbol: symbol, at: Date(), facts: partialFacts); return
        }
        let assembled = assemble(fitted.optionalKept)
        let facts = assembled.facts
        let intradayIndices = (fitted.optionalKept + 1)..<(fitted.optionalKept + intraday.facts.count)
        guard context.canAssess(at: Date()),
              intraday.fresh(at: Date()), Self.fresh(quote, at: Date(), maximumAge: Self.researchMaximumAge) else {
            recordFailure("Research context exceeded its freshness or size limit.", symbol: symbol, at: Date(), facts: partialFacts); return
        }
        if fitted.omitted > 0 {
            // Disclosed, never silent: the record shows the answer was formed on partial evidence.
            var trimmed = book
            trimmed.note(symbol: symbol, action: "Evidence trimmed",
                         reason: "\(fitted.omitted) of \(allFacts.count) optional evidence records were omitted to fit the model context budget; all execution facts were kept. Any opinion recorded next was formed without them.",
                         at: Date(), facts: facts)
            _ = save(trimmed)
        }
        let response = await StockSageLocalModelServer.completeDetailed(config, isOllama: isOllama,
            system: assembled.system, user: assembled.user,
            maxTokens: Self.researchOutputTokens,
            contextTokens: StockSageLocalModelServer.researchContextTokens,
            stillValid: evidenceActive)
        guard evidenceActive() else { return }
        guard case .success(let completion) = response else {
            let summary = StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0)
            recordFailure("Qwen request failed; \(summary). No paper order. Scheduled exits remain active.", symbol: symbol, at: Date(), facts: facts); return
        }
        // A verdict cut off at the output limit is refused outright. Measured 2026-09-10: a
        // truncated P/L answer stated a headline figure its own unfinished working contradicted.
        guard !StockSageLocalModelServer.rejectsTruncatedOutput(completion) else {
            recordFailure("Qwen answer stopped at the output limit before finishing; a truncated verdict is not accepted. No paper order. Scheduled exits remain active.",
                          symbol: symbol, at: Date(), facts: facts); return
        }
        guard case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: facts) else {
            let summary = StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0)
            recordFailure("Qwen response rejected; \(summary). No paper order. Scheduled exits remain active.", symbol: symbol, at: Date(), facts: facts); return
        }
        _ = await Self.decisionBook(symbol: symbol, verdict: verdict, facts: facts,
            model: config.model, researchQuote: quote, holdingID: held?.id,
            citesIntraday: Self.hasIntradayEvidence(verdict.evidence, factIndices: intradayIndices),
            allowed: {
                evidenceActive()
                    && Self.mayResearch(symbol, marketSymbols: marketSymbols, heldSymbols: Set(self.book.open.map(\.symbol)))
            }, contextFresh: { context.canAssess(at: $0) && intraday.fresh(at: $0) },
            currentBook: { self.book }, commit: { self.save($0) })
    }

    func recordFailure(_ reason: String, symbol: String = "", at: Date, facts: [String] = []) {
        var next = book
        next.note(symbol: symbol, action: "Unavailable", reason: reason, at: at, facts: facts)
        _ = save(next)
        status = reason
    }
}
