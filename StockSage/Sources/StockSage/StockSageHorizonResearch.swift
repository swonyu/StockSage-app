import Foundation
import Combine

/// Manual research only. Deliberately has no paper book, order, journal or broker writer.
@MainActor
final class StockSageHorizonResearch: ObservableObject {
    static let shared = StockSageHorizonResearch(history: .shared)
    nonisolated static let scanLimit = 500
    nonisolated static let topBuyLimit = 5
    nonisolated static let topBuyRankingNote = "After all checks, Qwen compares every eligible Buy / Strong Buy for this horizon. Cases and risks stay whole; cited evidence may be shortened to fit. Large pools use multiple comparison rounds. See Coverage for limits. This is unvalidated model judgment, not a prediction of returns."
    /// Shared by the fit() budget and the dispatched output limit; see PaperAutomation.
    nonisolated static let researchOutputTokens = 192
    nonisolated enum Horizon: String, CaseIterable, Identifiable, Sendable {
        case week = "1–7 trading days", fortnight = "7–14 trading days"
        var id: String { rawValue }
        static let focusInstructions = """
        StockSage focuses on \(Horizon.week.rawValue) and \(Horizon.fortnight.rawValue), as multi-session holding horizons. Do not propose intraday or same-session day-trading strategies, or long-term plans beyond 14 trading days. Longer historical windows are background evidence, not a holding horizon. If asked for an out-of-scope strategy, explain this focus and offer one of the supported horizons instead. Rankings are unvalidated research, not predictions of future returns.
        """
        var instructions: String {
            Self.focusInstructions + "\n" + StockSageAIAssessment.instructions.replacingOccurrences(of: "Assess the supplied stock for the next trading week.",
                with: "Assess the supplied stock for a \(rawValue) holding horizon, research only. These are trading days, not calendar days. Consider overnight gaps and missing future catalysts. The daily technical rules are background, not independently validated for this horizon.")
        }
    }
    nonisolated struct Listing: Decodable, Identifiable, Sendable, Equatable {
        let ticker: String
        let name: String
        let market: String
        let locale: String
        let active: Bool
        let type: String?
        let currency_name: String?
        let primary_exchange: String?
        var id: String { ticker }
    }
    nonisolated struct Page: Decodable, Sendable {
        let status: String
        let results: [Listing]
        let next_url: String?
        let count: Int?
    }
    nonisolated struct Levels: Sendable, Equatable {
        let entry: Double
        let stop: Double
        let target: Double
        let at: Date
        let basis: String
    }
    nonisolated struct Result: Sendable {
        var verdict: StockSageAIAssessment.Verdict?
        var levels: Levels?
        var facts: [String] = []
        var note: String
        var at: Date = Date()
        var model: String = ""
        var referenceClose: (value: Double, at: Date)? = nil
        var coverage: [EvidenceCoverage] = []
    }
    struct Scan {
        var listings: [Listing] = []
        var results: [String: Result] = [:]
        var status = "Press Run to research up to \(StockSageHorizonResearch.scanLimit) NASDAQ common stocks once."
        var at: Date?
        var selection: StockSageResearchUniverse.Receipt?
        var ranking: StockSageResearchRanking.Receipt?
        var rankingFailure: String?

        /// Only a completed comparison may publish top picks. Raw checks retain scan order.
        var topBuys: [Listing] {
            guard let ranking, rankingFailure == nil, results.count == listings.count else { return [] }
            return ranking.symbols.compactMap { symbol in
                guard results[symbol]?.verdict?.action == .buy || results[symbol]?.verdict?.action == .strongBuy else { return nil }
                return listings.first { $0.ticker == symbol }
            }
        }
    }
    @Published private(set) var scans: [Horizon: Scan] = [:]
    @Published private(set) var running: Horizon?
    @Published private(set) var runningHorizons: [Horizon] = []
    @Published private(set) var activeSymbol: String?
    private var task: Task<Void, Never>?
    private let history: StockSageResearchHistory?

    init(history: StockSageResearchHistory? = nil) {
        self.history = history
    }
    enum ScanFailure: Error { case modelUnavailable(String) }
    private static let session = URLSession(configuration: .ephemeral, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)

    // Vendor contract: massive.com/docs/rest/stocks/tickers/all-tickers, checked 2026-09-09.
    // Full reference pagination, not the trade snapshot (which omits unpriced symbols).
    nonisolated static func referenceRequest(key: String, next: String? = nil) -> URLRequest? {
        guard !key.isEmpty, (next?.utf8.count ?? 0) <= 8192,
              let c = URLComponents(string: next ?? StockSageMassive.host + "/v3/reference/tickers?market=stocks&active=true&sort=ticker&order=asc&limit=1000"),
              c.scheme == "https", c.host == "api.massive.com", c.port == nil || c.port == 443,
              c.user == nil, c.password == nil, c.fragment == nil, c.path == "/v3/reference/tickers",
              c.queryItems?.contains(where: { $0.name.lowercased() == "apikey" }) != true else { return nil }
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return r
    }
    nonisolated static func parsePage(_ data: Data) throws -> Page {
        guard data.count <= 4_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.status == "OK", page.results.count <= 1000, page.count.map({ $0 == page.results.count }) ?? true,
              page.results.allSatisfy({ (1...64).contains($0.ticker.utf8.count)
                  && !$0.ticker.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && $0.name.utf8.count <= 1000 }),
              page.next_url.map({ !$0.isEmpty }) ?? true else { throw URLError(.cannotParseResponse) }
        return page
    }
    nonisolated static func validTicker(_ symbol: String) -> Bool {
        symbol.range(of: #"^[A-Z][A-Z0-9.-]{0,31}$"#, options: .regularExpression) != nil
            && !symbol.contains("..")
    }

    /// Both research and its later review need the same explicit split-adjusted daily contract.
    nonisolated static func dailyHistoryRequest(symbol: String, from: String, to: String, key: String) -> URLRequest? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard validTicker(symbol), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              from.utf8.count == 10, to.utf8.count == 10,
              let start = formatter.date(from: from), formatter.string(from: start) == from,
              let end = formatter.date(from: to), formatter.string(from: end) == to, start <= end,
              let url = URL(string: StockSageMassive.host + "/v2/aggs/ticker/\(symbol)/range/1/day/\(from)/\(to)?adjusted=true&sort=asc&limit=5000") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func parseResearchHistory(_ data: Data, symbol: String) -> StockSagePriceHistory? {
        struct Metadata: Decodable {
            struct Volume: Decodable { let v: Double }
            let ticker: String
            let adjusted: Bool
            let resultsCount: Int
            let results: [Volume]
            let next_url: String?
        }
        guard data.count <= 2_000_000, let meta = try? JSONDecoder().decode(Metadata.self, from: data),
              meta.ticker == symbol, meta.adjusted, meta.next_url == nil,
              meta.results.count <= 5000, meta.resultsCount == meta.results.count,
              meta.results.allSatisfy({ $0.v.isFinite && $0.v >= 0 }),
              let history = StockSageMassive.parseHistory(data, symbol: symbol),
              history.count == meta.results.count else { return nil }
        return history
    }

    /// Fetch the next trading date's daily open and the target close on one adjusted price basis.
    /// This path does not fall back to another provider or request a model opinion.
    static func fetchReviewObservation(prediction: StockSageResearchHistory.Prediction,
        run: StockSageResearchHistory.Run, key: String,
        allowed: @escaping @MainActor () -> Bool, clock: @MainActor () -> Date = { Date() },
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> StockSageResearchHistory.Observation? {
        guard !Task.isCancelled, allowed() else { return nil }
        let requestedAt = clock()
        guard run.predictions.contains(prediction),
              StockSageResearchHistory.availability(for: run, now: requestedAt).state == .due,
              let target = StockSageResearchHistory.targetClose(for: run),
              let benchmark = StockSageResearchHistory.benchmarkDay(after: run.completedAt) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        guard let request = dailyHistoryRequest(symbol: prediction.symbol,
            from: formatter.string(from: benchmark), to: formatter.string(from: target), key: key) else { return nil }
        do {
            let data: Data
            let response: URLResponse
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000) }
            guard !Task.isCancelled, allowed(), (response as? HTTPURLResponse)?.statusCode == 200,
                  let history = parseResearchHistory(data, symbol: prediction.symbol) else { return nil }
            let fetchedAt = clock()
            guard fetchedAt.timeIntervalSince1970.isFinite, fetchedAt >= requestedAt, fetchedAt >= target else { return nil }
            return .init(history: history, splitAdjusted: true,
                provider: "Massive split-adjusted daily aggregates", fetchedAt: fetchedAt)
        } catch { return nil }
    }

    static func fetchUniverse(key: String, allowed: @MainActor () -> Bool,
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> [Listing] {
        var next: String?
        var visited: Set<URL> = []
        var listings: [String: Listing] = [:]
        repeat {
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            guard let request = referenceRequest(key: key, next: next), let url = request.url,
                  visited.insert(url).inserted, visited.count <= 50 else { throw URLError(.cannotParseResponse) }
            let (data, response): (Data, URLResponse)
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 4_000_000) }
            try Task.checkCancellation()
            guard allowed() else { throw CancellationError() }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let page = try parsePage(data)
            for item in page.results where item.active && item.market == "stocks" && item.locale == "us" {
                if let existing = listings[item.ticker], existing != item { throw URLError(.cannotParseResponse) }
                listings[item.ticker] = item
            }
            next = page.next_url
        } while next != nil
        guard !listings.isEmpty else { throw URLError(.zeroByteResource) }
        return listings.values.sorted { $0.ticker < $1.ticker }
    }

    /// Prior New York dates only: today's daily candle is never assumed complete.
    nonisolated static func completedHistory(_ h: StockSagePriceHistory, at now: Date) -> StockSagePriceHistory? {
        guard now.timeIntervalSince1970.isFinite, h.priceSource == .massiveDaily,
              h.count == h.dates.count, h.count == h.opens.count, h.count == h.highs.count,
              h.count == h.lows.count, h.count == h.volumes.count else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let boundary = calendar.startOfDay(for: now)
        for i in h.dates.indices {
            guard h.dates[i].timeIntervalSince1970.isFinite, h.dates[i].timeIntervalSince1970 > 0,
                  i == 0 || h.dates[i] > h.dates[i - 1],
                  [h.opens[i], h.highs[i], h.lows[i], h.closes[i]].allSatisfy({ $0.isFinite && $0 > 0 }),
                  h.volumes[i].isFinite, h.volumes[i] >= 0,
                  h.highs[i] >= max(h.opens[i], h.closes[i]), h.lows[i] <= min(h.opens[i], h.closes[i]) else { return nil }
        }
        let n = h.dates.prefix { $0 < boundary }.count
        guard n >= 30, StockSageMarketHours.isLatestCompletedDailyBar(h.dates[n - 1], at: now) else { return nil }
        return .init(symbol: h.symbol, dates: Array(h.dates.prefix(n)), opens: Array(h.opens.prefix(n)),
            highs: Array(h.highs.prefix(n)), lows: Array(h.lows.prefix(n)), closes: Array(h.closes.prefix(n)),
            volumes: Array(h.volumes.prefix(n)), priceSource: h.priceSource)
    }
    nonisolated static func levels(history: StockSagePriceHistory, action: TradeAdvice.Action, at now: Date) -> Levels? {
        guard action == .buy || action == .strongBuy, let h = completedHistory(history, at: now),
              let entry = h.closes.last, let at = h.dates.last,
              let atr = StockSageIndicators.atr(highs: h.highs, lows: h.lows, closes: h.closes), atr.isFinite, atr > 0 else { return nil }
        let vol = StockSageIndicators.annualizedVolatility(h.closes)
        let pair = StockSageAdvisor.stopTarget(action: action, price: entry, atr: atr, realizedVol: vol)
        guard let stop = pair.stop, let target = pair.target, stop.isFinite, target.isFinite,
              stop > 0, stop < entry, entry < target else { return nil }
        return .init(entry: entry, stop: stop, target: target, at: at,
            basis: "\(StockSageAdvisor.stopMultiple(forVol: vol))× daily ATR stop; target = twice the entry-to-stop distance. Existing rules, not horizon-optimized or a forecast. Re-price before considering a trade; overnight gaps can pass the stop.")
    }

    func start(_ horizon: Horizon, allowed: @escaping @MainActor () -> Bool,
        interruptionReason: @escaping @MainActor () -> String? = { nil },
        universe: @escaping @MainActor () async throws -> StockSageResearchUniverse.Selection,
        rank: (@MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>)? = nil,
        analyze: @escaping @MainActor (Listing) async -> Result) -> Bool {
        start([horizon], allowed: allowed, interruptionReason: interruptionReason, universe: universe, rank: rank,
              analyze: { item, _ in await analyze(item) })
    }

    func start(_ horizons: [Horizon], allowed: @escaping @MainActor () -> Bool,
        interruptionReason: @escaping @MainActor () -> String? = { nil },
        universe: @escaping @MainActor () async throws -> StockSageResearchUniverse.Selection,
        rank: (@MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>)? = nil,
        analyze: @escaping @MainActor (Listing, Horizon) async -> Result) -> Bool {
        guard task == nil, allowed(), !horizons.isEmpty, Set(horizons).count == horizons.count else { return false }
        let previous = scans
        let startedAt = Date()
        running = horizons[0]; runningHorizons = horizons
        for horizon in horizons {
            scans[horizon] = Scan(status: "Selecting up to \(Self.scanLimit) NASDAQ common stocks by dated trading activity…", at: startedAt)
        }
        task = Task {
            var didStart = false
            var completed: Set<Horizon> = []
            @MainActor func finish(_ horizon: Horizon, count: Int) async throws {
                guard !completed.contains(horizon), let captured = scans[horizon] else { return }
                guard valid() else { throw CancellationError() }
                activeSymbol = nil
                if let rank {
                    scans[horizon]?.status = "All \(count) checks finished · comparing research for the top five…"
                    let outcome = await rank(captured, horizon)
                    guard valid() else { throw CancellationError() }
                    switch outcome {
                    case .success(let receipt):
                        let eligible = Set(captured.listings.filter {
                            captured.results[$0.ticker]?.verdict?.action == .buy || captured.results[$0.ticker]?.verdict?.action == .strongBuy
                        }.map(\.ticker))
                        if StockSageResearchRanking.valid(receipt), Set(receipt.candidateSymbols) == eligible,
                           receipt.horizon == horizon.rawValue, receipt.at >= startedAt, receipt.at <= Date() {
                            scans[horizon]?.ranking = receipt
                        } else {
                            scans[horizon]?.rankingFailure = StockSageResearchRanking.Failure.invalidOutput.message
                        }
                    case .failure(let failure): scans[horizon]?.rankingFailure = failure.message
                    }
                } else if captured.results.values.contains(where: { $0.verdict?.action == .buy || $0.verdict?.action == .strongBuy }) {
                    scans[horizon]?.rankingFailure = "Comparative ranking was unavailable. All checks remain available."
                }
                completed.insert(horizon)
                runningHorizons.removeAll { $0 == horizon }; running = runningHorizons.first
                scans[horizon]?.status = "Scan finished · \(count) listings checked once. No orders created."
                if let failure = scans[horizon]?.rankingFailure { scans[horizon]?.status += " Top five unavailable: \(failure)" }
                if let history, let scan = scans[horizon] {
                    let run = StockSageResearchHistory.snapshot(startedAt: startedAt, completedAt: Date(), horizon: horizon, scan: scan)
                    scans[horizon]?.status += history.record(run)
                        ? " Saved for \(run.horizon.rawValue)-trading-day review."
                        : " Research could not be saved. Open Saved research for details."
                }
            }
            defer { activeSymbol = nil; running = nil; runningHorizons = []; task = nil }
            @MainActor func valid() -> Bool { !Task.isCancelled && allowed() }
            do {
                let selection = try await universe()
                guard valid() else { throw CancellationError() }
                let directory = selection.listings
                guard Set(directory.map(\.ticker)).count == directory.count, directory.count <= 50_000 else { throw URLError(.cannotParseResponse) }
                didStart = true
                let names = Array(directory.prefix(Self.scanLimit))
                for horizon in horizons {
                    scans[horizon]?.listings = names
                    scans[horizon]?.selection = selection.receipt
                }
                // Exactly one symbol worker; both-horizon research gathers once, then asks serially.
                for item in names {
                    guard valid() else { throw CancellationError() }
                    activeSymbol = item.ticker
                    for horizon in horizons {
                        scans[horizon]?.status = "Checking \(item.ticker) · \(scans[horizon]?.results.count ?? 0)/\(names.count) finished"
                    }
                    for horizon in horizons {
                        activeSymbol = item.ticker
                        let result = await analyze(item, horizon)
                        guard valid() else { throw CancellationError() }
                        scans[horizon]?.results[item.ticker] = result
                    }
                    activeSymbol = nil
                }
                for horizon in horizons { try await finish(horizon, count: names.count) }
            } catch {
                for horizon in horizons where !completed.contains(horizon) {
                    if !didStart, let old = previous[horizon] { scans[horizon] = old }
                    if !valid() {
                        let reason = Task.isCancelled ? "Stop requested" : (interruptionReason() ?? "Model settings or access changed")
                        let count = scans[horizon]?.results.count ?? 0
                        let allChecked = didStart && count > 0 && count == scans[horizon]?.listings.count
                        let retained = !didStart && previous[horizon] != nil ? "No new checks; the previous research is retained."
                            : count == 0 ? "No stocks were checked; no results to retain."
                            : allChecked ? "All \(count) checks retained; top five comparison was not completed."
                            : "\(count) completed results retained; remaining listings were not checked."
                        if allChecked { scans[horizon]?.rankingFailure = "Comparison stopped before completion. All checks remain available." }
                        scans[horizon]?.status = "Scan stopped · \(reason). \(retained) Run again when ready."
                    } else if case ScanFailure.modelUnavailable(let detail) = error {
                        scans[horizon]?.status = "\(detail) No scan started. Open Catalysts → Explanation model, finish setup, then Run again."
                    } else if let failure = error as? StockSageResearchUniverse.Failure {
                        scans[horizon]?.status = "Scan incomplete: " + (failure.errorDescription ?? "Calendar unavailable.")
                    } else {
                        scans[horizon]?.status = "Scan incomplete: the directory or dated activity response was unavailable or inconsistent. No verified selection could be made; retry after checking data access."
                    }
                    if !didStart, previous[horizon] != nil {
                        scans[horizon]?.status += " Earlier scan data retained; no new listings checked."
                    }
                }
            }
        }
        return true
    }
    func stop() {
        guard running != nil else { return }
        task?.cancel(); activeSymbol = nil
        for horizon in runningHorizons { scans[horizon]?.status = "Stopping scan · keeping completed results…" }
    }
    func isRunning(_ horizon: Horizon) -> Bool { runningHorizons.contains(horizon) }
    func start(_ horizon: Horizon, store: StockSageStore) { start([horizon], store: store) }

    func start(_ horizons: [Horizon], store: StockSageStore) {
        guard task == nil, !horizons.isEmpty else { return }
        guard let config = StockSageAIAssessments.configuration, StockSageMassive.isConfigured,
              ToolPolicy.isExternalAllowed, !store.isSampleData else {
            for horizon in horizons { scans[horizon, default: Scan()].status = "Enable web access, Massive and the local Qwen model in Settings. No scan started." }
            return
        }
        let key = StockSageMassive.apiKey
        let credentialRevision = StockSageMassive.credentialRevision()
        let revision = StockSageLocalModelServer.settingsRevision()
        let interruptionReason: @MainActor () -> String? = {
            if StockSageLocalModelServer.isShuttingDown { return "StockSage is closing" }
            if !ToolPolicy.isExternalAllowed { return "Web access was disabled" }
            if store.isSampleData { return "The app switched to sample data" }
            if StockSageMassive.apiKey != key || StockSageMassive.credentialRevision() != credentialRevision { return "Massive credentials changed" }
            if StockSageAIAssessments.configuration != config || StockSageLocalModelServer.settingsRevision() != revision { return "Model settings changed" }
            return nil
        }
        let allowed: @MainActor () -> Bool = { interruptionReason() == nil }
        var isOllama = false
        var selection: StockSageResearchUniverse.Receipt?
        var gathered: Gathered?
        _ = start(horizons, allowed: allowed, interruptionReason: interruptionReason, universe: {
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            guard probe.reachable, probe.hasModel else { throw ScanFailure.modelUnavailable(probe.detail) }
            isOllama = probe.isOllama
            let result = try await StockSageResearchUniverse.fetch(key: key, allowed: allowed)
            selection = result.receipt
            return result
        }, rank: { scan, horizon in
            await StockSageResearchRanking.rank(scan: scan, horizon: horizon, config: config,
                isOllama: isOllama, allowed: allowed, progress: { status in
                    self.scans[horizon]?.status = status
                })
        }, analyze: { item, horizon in
            if horizon == horizons.first {
                gathered = await Self.gather(item, store: store, key: key, allowed: allowed,
                    selectionFact: selection?.detail(for: item.ticker))
            }
            switch gathered {
            case .failed(let result): return result
            case .captured(let capture):
                return await Self.assess(capture, horizon: horizon, config: config,
                    isOllama: isOllama, allowed: allowed)
            case nil: return .init(note: "Evidence was not gathered; no opinion.")
            }
        })
    }

    nonisolated struct EvidenceCoverage: Sendable, Equatable {
        enum State: String, Sendable { case answered, partial, unavailable, unchecked, stale }
        let source: String
        let state: State
        let checkedAt: Date?
        var detail: String { source + ": " + state.rawValue + (checkedAt.map { " · " + $0.ISO8601Format() } ?? "") }
    }
    struct Capture {
        let history: StockSagePriceHistory
        let context: StockSageAIAssessment.Context
        let facts: [String]
        let coverage: [EvidenceCoverage]
        let at: Date
        let blockedByThrottle: Bool
        var referenceClose: (value: Double, at: Date) { (history.closes.last!, history.dates.last!) }
        func isFresh(at now: Date) -> Bool {
            (0...300).contains(now.timeIntervalSince(at))
                && context.asOf.timeIntervalSince1970.isFinite && context.asOf <= now
                && (context.benzinga.map { $0.capturedAt.timeIntervalSince1970.isFinite && $0.capturedAt <= context.asOf } ?? true)
                && context.canAssess(at: now)
                && StockSageHorizonResearch.completedHistory(history, at: now) != nil
        }
    }
    enum Gathered { case captured(Capture), failed(Result) }

    /// Research uses strict daily-response metadata; generic disk cache cannot establish adjustment.
    /// All provider closures must be injected in offline tests, including forward earnings and SEC.
    static func gather(_ item: Listing, store: StockSageStore, key: String,
        allowed: @escaping @MainActor () -> Bool,
        companyObservations: [StockSageMassiveEvents.Feed: StockSageMassiveEvents.Observation]? = nil,
        historyTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        benzingaSnapshot: ((String, Date) async -> StockSageBenzinga.Snapshot)? = nil,
        newsObservation: ((String, Date, StockSageBenzinga.Page?) async -> StockSageNewsService.Observation)? = nil,
        nextEarnings: ((String, Date) async -> StockSageMassiveEarnings.Observation)? = nil,
        filingsObservation: ((String, Date) async -> StockSageDisclosureService.FilingsObservation)? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil,
        selectionFact: String? = nil) async -> Gathered {
        func failed(_ note: String) -> Gathered { .failed(.init(note: note)) }
        func active() -> Bool { allowed() && !Task.isCancelled }
        guard item.currency_name?.lowercased() == "usd" else {
            return failed("USD price currency not confirmed; listing retained, no opinion.")
        }
        guard active(), let dates = StockSageMassive.historyDates(for: "1y"),
              let request = dailyHistoryRequest(symbol: item.ticker, from: dates.from, to: dates.to, key: key) else {
            return failed("Unsupported symbol or request cancelled; no opinion.")
        }
        let historyFetch: () async throws -> (Data, URLResponse) = {
            if let historyTransport { return try await historyTransport(request) }
            return try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000)
        }
        guard let (data, response) = try? await historyFetch(), active(),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = parseResearchHistory(data, symbol: item.ticker),
              let history = completedHistory(raw, at: Date()) else {
            return failed("Need at least 30 valid, completed daily bars including the latest prior trading session from a verified calendar. History missing, stale or malformed; no opinion.")
        }
        let referenceClose = (value: history.closes.last!, at: history.dates.last!)
        guard StockSageMassive.covers(item.ticker), item.ticker.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return .failed(.init(note: "This symbol is unsupported by the supplemental evidence contracts; listing and daily close retained, no opinion.", referenceClose: referenceClose))
        }
        let ideas = await StockSageStore.buildIdeas(defs: [.init(symbol: item.ticker, market: "US · \(item.primary_exchange ?? "exchange unconfirmed")")], histories: [item.ticker: history])
        guard active(), let idea = ideas.first else { return failed("Analysis interrupted or unsupported history.") }
        let began = Date()
        let benzinga = await (benzingaSnapshot ?? { await StockSageBenzingaClient.shared.snapshot(for: $0, now: $1) })(item.ticker, began)
        func evidenceAllowed() -> Bool {
            active() && (evidenceIsCurrent?(benzinga) ?? StockSageBenzingaClient.shared.isCurrent(benzinga))
        }
        guard evidenceAllowed() else { return failed("Analysis interrupted.") }
        let newsPage = benzinga.pages.first { $0.query.product == .news }
        let news = await (newsObservation ?? { await StockSageNewsService.observation(for: $0, limit: 3, now: $1, benzingaPage: $2) })(item.ticker, began, newsPage)
        guard evidenceAllowed() else { return failed("Analysis interrupted.") }

        // This research-local query retains its own provider semantics and credential gate;
        // board records can come from fallback providers or an older credential revision.
        let earningsAt = Date()
        let earnings = await (nextEarnings ?? { await StockSageMassiveEarnings.observe($0, now: $1) })(item.ticker, earningsAt)
        let earningsCheckedAt = earnings.checkedAt
        guard evidenceAllowed() else { return failed("Analysis interrupted.") }
        let filingsAt = Date()
        let filings = await (filingsObservation ?? {
            await StockSageDisclosureService.recentFilingsObservation(for: $0,
                forms: ["8-K", "10-Q", "10-K", "6-K", "20-F"], limit: 5, now: $1)
        })(item.ticker, filingsAt)
        guard evidenceAllowed() else { return failed("Analysis interrupted.") }
        let capturedAt = Date()
        var coverage = [EvidenceCoverage(source: "Daily history", state: .answered, checkedAt: began)]
        var extra: [String] = []
        var earningsAnswered = false
        switch earnings.outcome {
        case .answered(let row):
            let validCheck = earningsCheckedAt.map { (0...300).contains(capturedAt.timeIntervalSince($0)) } == true
            let todayUTC = floor(earningsAt.timeIntervalSince1970 / 86_400) * 86_400
            earningsAnswered = validCheck && (row.map { $0.date.timeIntervalSince1970.isFinite && (todayUTC...(todayUTC + 401 * 86_400 - 1)).contains($0.date.timeIntervalSince1970) } ?? true)
            coverage.append(.init(source: "Next earnings", state: earningsAnswered ? .answered : .unavailable, checkedAt: earningsCheckedAt))
            if let row, earningsAnswered {
                extra.append("Next earnings: \(row.date.ISO8601Format()), \(row.confirmed ? "confirmed" : "projected, not announced"). Source: \(StockSageMassiveEarnings.source); checked \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Date-only precision, no release time or earnings outcome inferred.")
            } else {
                extra.append(earningsAnswered ? "Next earnings: provider answered with no scheduled date in the queried 400-day window, checked \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Not proof of no upcoming earnings risk." : "Next earnings: invalid provider date; unavailable.")
            }
        case .unavailable:
            coverage.append(.init(source: "Next earnings", state: .unavailable, checkedAt: earningsCheckedAt))
            extra.append("Next earnings: unavailable from \(StockSageMassiveEarnings.source), attempted \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Missing is not no earnings risk.")
        case .notRequested:
            coverage.append(.init(source: "Next earnings", state: .unchecked, checkedAt: nil))
            let origin: String
            if case .priorAuthenticationRejection(let at) = earnings.notRequestedReason {
                origin = "prior authentication rejection at \(at.ISO8601Format())"
            } else { origin = "access, cancellation or request availability" }
            extra.append("Next earnings: not requested (\(origin)); decision recorded \(earnings.recordedAt.ISO8601Format()). Missing is not no earnings risk.")
        }
        let filingsFresh = (0...300).contains(capturedAt.timeIntervalSince(filings.checkedAt))
        let filingsAnswered = filingsFresh && filings.outcome == .answered
        coverage.append(.init(source: "SEC submissions metadata", state: !filingsFresh ? .stale : filingsAnswered ? .answered : .unavailable, checkedAt: filings.checkedAt))
        let filingsStatus: String
        switch filings.outcome {
        case .answered: filingsStatus = filingsFresh ? "answered; bounded selection of up to five recent 8-K, 10-Q, 10-K, 6-K and 20-F records" : "stale or invalid check clock"
        case .unavailable(let reason): filingsStatus = "unavailable; " + reason.message
        }
        extra.append("SEC submissions metadata: \(filingsStatus). Checked \(filings.checkedAt.ISO8601Format()). These are filing identities and dates, not retrieved filing documents or interpreted contents.")
        if filingsAnswered {
            for filing in filings.filings.prefix(5) where filing.filingDate.timeIntervalSince1970.isFinite && filing.filingDate.timeIntervalSince1970 > 0
                && (filing.acceptedAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 && $0 <= capturedAt } ?? (filing.filingDate <= capturedAt)) {
                extra.append("SEC metadata: form \(filing.form); accession \(filing.accessionNumber); filed \(filing.filingDate.ISO8601Format()); accepted \(filing.acceptedAt?.ISO8601Format() ?? "time not supplied"). Metadata does not establish the filing's meaning or price impact.")
            }
        }
        let context = StockSageAIAssessment.Context(idea: idea, earnings: nil,
            company: companyObservations ?? store.companyEventChecks[item.ticker] ?? [:], at: capturedAt,
            newsObservation: news, quotedInUSD: true, benzinga: benzinga)
        for product in StockSageBenzinga.Product.allCases where product != .news {
            let pages = benzinga.pages.filter { $0.query.product == product }
            let state: EvidenceCoverage.State
            if pages.isEmpty || pages.allSatisfy({ $0.status == .notChecked }) { state = .unchecked }
            else if pages.contains(where: { $0.credentialGeneration != benzinga.credentialGeneration || !(0...product.cacheTTL).contains(capturedAt.timeIntervalSince($0.checkedAt)) }) { state = .stale }
            else if pages.contains(where: { !StockSageBenzinga.valid($0.query) || $0.checkedAt > benzinga.capturedAt || (product != .analysts && product != .firms && $0.query.subject.uppercased() != item.ticker) }) { state = .unavailable }
            else if pages.allSatisfy({ $0.status == .answered }) { state = .answered }
            else if pages.contains(where: { $0.status == .answered || $0.status == .partial }) { state = .partial }
            else { state = .unavailable }
            coverage.append(.init(source: "Benzinga " + product.label, state: state, checkedAt: pages.map(\.checkedAt).min()))
        }
        // News fallback attempts are one evidence family, never two votes of coverage.
        let newsAnswered = news.withholdingReason == nil && news.attempts.contains { $0.status == .answered || $0.status == .partial }
        let answeredNews = news.attempts.filter { $0.status == .answered || $0.status == .partial }
        let newsState: EvidenceCoverage.State = news.attempts.isEmpty ? .unchecked
            : !newsAnswered ? .unavailable
            : news.attempts.allSatisfy({ $0.status == .answered }) ? .answered : .partial
        coverage.append(.init(source: "Recent news", state: newsState,
            checkedAt: answeredNews.last?.checkedAt ?? news.attempts.last?.checkedAt))
        var companyAnswered = false
        for feed in [StockSageMassiveEvents.Feed.filing8K, .dividends, .insider] {
            let record = context.company[feed].flatMap { $0.symbol == item.ticker && $0.feed == feed ? $0 : nil }
            let state: EvidenceCoverage.State = record.map {
                !$0.fresh(at: capturedAt) ? .stale : $0.outcome == .answered ? .answered : .unavailable
            } ?? .unchecked
            if state == .answered { companyAnswered = true }
            coverage.append(.init(source: feed.source, state: state, checkedAt: record?.checkedAt))
        }
        let attempted = benzinga.pages.filter { $0.status != .notChecked }
        let blocked = !attempted.isEmpty && attempted.contains { $0.status == .unavailable(.throttled) }
            && attempted.allSatisfy {
                switch $0.status {
                case .unavailable(.throttled), .unavailable(.entitlement), .unavailable(.unauthorized), .unavailable(.priorAuthenticationRejection): true
                default: false
                }
            }
            && !newsAnswered && !earningsAnswered && !filingsAnswered && !companyAnswered
        extra += historicalFacts(history)
        if let selectionFact { extra.append(selectionFact) }
        // Replace the generic board-only earnings line with this capture's independent check.
        var facts = context.facts(maximumUTF8Bytes: 12_000).filter { !$0.hasPrefix("Earnings:") }
        // Preserve concise research facts before optional long provider excerpts are trimmed.
        let providerIndex = facts.firstIndex { $0.hasPrefix("Massive/Benzinga sample;") } ?? facts.count
        facts.insert(contentsOf: extra, at: providerIndex)
        return .captured(.init(history: history, context: context, facts: facts,
            coverage: coverage, at: began, blockedByThrottle: blocked))
    }

    nonisolated static func historicalFacts(_ history: StockSagePriceHistory) -> [String] {
        let n = min(20, history.count)
        guard n > 1, history.dates.count == history.count, history.volumes.count == history.count,
              history.opens.count == history.count else { return [] }
        let start = history.count - n
        let dollars = (start..<history.count).map { history.closes[$0] * history.volumes[$0] }
        let average = dollars.reduce(0) { $0 + $1 / Double(n) }
        var facts: [String] = []
        let dates = "\(history.dates[start].ISO8601Format()) through \(history.dates.last!.ISO8601Format())"
        if dollars.allSatisfy({ $0.isFinite && $0 >= 0 }), average.isFinite {
            facts.append("Historical average daily dollar volume: \(average) USD over \(n) bars, \(dates), estimated as close × volume. Not a spread, order-size capacity or fill guarantee.")
        }
        let gaps = ((start + 1)..<history.count).map { (history.opens[$0] / history.closes[$0 - 1] - 1) * 100 }
        if gaps.allSatisfy(\.isFinite), let largest = gaps.map({ abs($0) }).max() {
            let mean = gaps.reduce(0) { $0 + abs($1) / Double(gaps.count) }
            if mean.isFinite {
                facts.append("Historical open-to-prior-close gaps: mean absolute \(mean)%, largest absolute \(largest)%, \(gaps.count) adjacent-bar observations, \(dates). Daily aggregates may include extended hours; not a future gap probability or stop-fill estimate.")
            }
        }
        return facts
    }

    static func analyze(_ item: Listing, horizon: Horizon, store: StockSageStore,
        config: StockSageLocalModelServer.Config, isOllama: Bool, key: String,
        allowed: @escaping @MainActor () -> Bool,
        companyObservations: [StockSageMassiveEvents.Feed: StockSageMassiveEvents.Observation]? = nil,
        historyTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        benzingaSnapshot: ((String, Date) async -> StockSageBenzinga.Snapshot)? = nil,
        newsObservation: ((String, Date, StockSageBenzinga.Page?) async -> StockSageNewsService.Observation)? = nil,
        nextEarnings: ((String, Date) async -> StockSageMassiveEarnings.Observation)? = nil,
        filingsObservation: ((String, Date) async -> StockSageDisclosureService.FilingsObservation)? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil) async -> Result {
        let gathered = await gather(item, store: store, key: key, allowed: allowed,
            companyObservations: companyObservations, historyTransport: historyTransport, benzingaSnapshot: benzingaSnapshot, newsObservation: newsObservation,
            nextEarnings: nextEarnings, filingsObservation: filingsObservation, evidenceIsCurrent: evidenceIsCurrent)
        switch gathered {
        case .failed(let result): return result
        case .captured(let capture):
            return await assess(capture, horizon: horizon, config: config, isOllama: isOllama,
                allowed: allowed, modelTransport: modelTransport, evidenceIsCurrent: evidenceIsCurrent)
        }
    }

    static func assess(_ capture: Capture, horizon: Horizon,
        config: StockSageLocalModelServer.Config, isOllama: Bool,
        allowed: @escaping @MainActor () -> Bool,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil) async -> Result {
        let history = capture.history, context = capture.context, referenceClose = capture.referenceClose
        func evidenceAllowed() -> Bool {
            allowed() && !Task.isCancelled && capture.isFresh(at: Date())
                && (context.benzinga.map { evidenceIsCurrent?($0) ?? StockSageBenzingaClient.shared.isCurrent($0) } ?? true)
        }
        func result(_ note: String, facts: [String] = []) -> Result {
            .init(facts: facts, note: note, at: capture.at, referenceClose: referenceClose, coverage: capture.coverage)
        }
        guard evidenceAllowed() else { return result("Evidence exceeded the age limit or access changed; no opinion.") }
        if capture.blockedByThrottle { return result("Supplemental evidence requests were blocked by throttling or access denial, with no usable fallback; no model request or opinion. Retry after provider access recovers.", facts: capture.facts) }
        var horizonFacts = ["Requested holding horizon: \(horizon.rawValue). Research only, no orders or position management. Reference entry is the last completed split-adjusted daily close, NOT a live quote. Current daily candle excluded."]
        for period in [7, 14] {
            if let value = StockSageIndicators.returnOverPeriod(history.closes, period: period), value.isFinite {
                horizonFacts.append("Observed return over the last \(period) completed daily bars: \(value)%. Bar window ends \(history.dates.last!.ISO8601Format()). Historical change, not an expected return.")
            }
        }
        horizonFacts.append("Evidence coverage at capture (not a quality score): " + capture.coverage.map(\.detail).joined(separator: "; "))
        if let benzinga = context.benzinga, let statuses = StockSageBenzinga.projection(benzinga, maximumUTF8Bytes: 12_000, maximumRecords: 0) {
            horizonFacts.append("Provider check states; record details may be omitted: " + statuses.statusLines.joined(separator: "; "))
        }
        let optionalFacts = capture.facts
        guard let fitted = StockSageAIAssessment.fittedResearchPrompt(optional: optionalFacts, mandatory: horizonFacts,
            system: { _ in horizon.instructions }, outputTokens: Self.researchOutputTokens) else {
            return result("Evidence could not fit the model context budget without dropping a mandatory horizon or source-status fact; no opinion.", facts: horizonFacts)
        }
        let facts = fitted.facts
        let trimmedNote = fitted.isComplete ? "" : " \(fitted.omitted) of \(optionalFacts.count) optional evidence records were omitted to fit the context budget."
        let response = await StockSageAIAssessment.complete(config, isOllama: isOllama,
            system: fitted.system, user: fitted.user, facts: facts, maxTokens: Self.researchOutputTokens,
            stillValid: evidenceAllowed, transport: modelTransport)
        guard evidenceAllowed() else { return result("Analysis interrupted or captured evidence expired.") }
        if case .success(let completion) = response, let rejection = StockSageLocalModelServer.financialOutputRejection(completion) {
            return result("No verified opinion. " + rejection + trimmedNote + " " + completion.diagnostic.summary, facts: facts)
        }
        guard case .success(let completion) = response,
              case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: facts) else {
            return result("No verified opinion. " + StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0) + trimmedNote, facts: facts)
        }
        return .init(verdict: verdict, levels: levels(history: history, action: verdict.action, at: Date()),
            facts: facts, note: "Unvalidated Qwen research · \(horizon.rawValue). No order created." + trimmedNote,
            at: capture.at, model: config.model, referenceClose: referenceClose, coverage: capture.coverage)
    }
}
