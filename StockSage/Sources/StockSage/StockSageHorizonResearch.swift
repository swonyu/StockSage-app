import Foundation
import Combine

/// Manual research only. Deliberately has no paper book, order, journal or broker writer.
@MainActor
final class StockSageHorizonResearch: ObservableObject {
    static let shared = StockSageHorizonResearch(history: .shared)
    nonisolated static let scanLimit = 500
    nonisolated static let topBuyLimit = 5
    nonisolated static let topBuyRankingNote = "After all checks, the model compares every eligible Buy / Strong Buy for this horizon. Cases and risks stay whole; cited evidence may be shortened to fit. Large pools use multiple comparison rounds. See Coverage for limits. This is unvalidated model judgment, not a prediction of returns."
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
                + "\nA catalyst must have a dated source and plausible timing inside this horizon; an undated or already-passed item is context, not a catalyst."
                + "\nUse the app-calculated earnings holding-window check as authoritative for timing. Do not calculate or state relative earnings dates, durations, month parts, or event probabilities in reason/risk. An outside-window date cannot be an in-window catalyst; unknown dates cannot establish either timing or absence of risk. Projected dates are not announcements. Historical earnings results are separate from the next report."
        }
    }
    nonisolated struct Listing: Codable, Identifiable, Sendable, Equatable {
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
        var evidenceReceipt: StockSageAIAssessment.EvidenceCoverage? = nil
        var diagnosticID: UUID? = nil
        var diagnosticsComplete: Bool? = nil
        var qualification: StockSageResearchQualification.Receipt? = nil
        /// Typed Form 4 detail for this symbol, extracted from the SAME capture that produced
        /// `qualification`. Absent on every result written before this existed. Every purchase
        /// AND sale is retained here; the deterministic Top-5 ranking is the only reader.
        var insiderTransactions: [StockSageMassiveEvents.InsiderTransaction] = []
    }
    struct Scan {
        var listings: [Listing] = []
        var results: [String: Result] = [:]
        var status = "Press Run to research up to \(StockSageHorizonResearch.scanLimit) NASDAQ common stocks once."
        var at: Date?
        var selection: StockSageResearchUniverse.Receipt?
        var ranking: StockSageResearchRanking.Receipt?
        var rankingFailure: String?
        var retainedFromRunID: UUID?
        var isComparing = false
        var needsSaving = false
        var qualificationPolicyVersion: Int? = nil

        func isEligible(_ symbol: String) -> Bool {
            guard let result = results[symbol], result.verdict?.action == .buy || result.verdict?.action == .strongBuy else { return false }
            guard let qualificationPolicyVersion else { return true }
            guard qualificationPolicyVersion == 1, let receipt = result.qualification else { return false }
            return receipt.originalAction == result.verdict?.action.rawValue && receipt.isQualified && StockSageResearchQualification.valid(receipt,
                symbol: symbol, horizon: receipt.horizon, at: result.at,
                citedKeys: result.evidenceReceipt?.citedKeys ?? [])
        }

        /// Only a completed comparison may publish top picks. Raw checks retain scan order.
        var topBuys: [Listing] {
            guard let ranking, rankingFailure == nil, results.count == listings.count else { return [] }
            return ranking.symbols.compactMap { symbol in
                guard isEligible(symbol) else { return nil }
                return listings.first { $0.ticker == symbol }
            }
        }

        /// The deterministic, explainable Top-5 (see `StockSageTopFiveRanking`): always fills
        /// five ranked slots from every FULLY CHECKED listing, regardless of action, even when
        /// fewer than five pass strict Buy/Strong Buy qualification. nil only when the scan
        /// itself is incomplete (checks still running) — there is nothing verified to rank yet.
        /// This never calls a model and is independent of the LLM-driven `ranking`/`topBuys`
        /// comparison above.
        func rankedTopFive(horizon: Horizon, now: Date) -> StockSageTopFiveRanking.Result? {
            guard results.count == listings.count, !listings.isEmpty else { return nil }
            let candidates = listings.compactMap { listing -> StockSageTopFiveRanking.Candidate? in
                guard let result = results[listing.ticker], let verdict = result.verdict,
                      let qualification = result.qualification else { return nil }
                // Reuse the SAME structural validator `isEligible` already applies, rather than
                // trusting any non-nil receipt: symbol, requested horizon, evidence citations and
                // capture time must all be internally consistent. A receipt that fails this can
                // never read as Qualified below, but the candidate still appears with its real
                // action and an explicit reason — this never hides a legitimate Hold/Avoid row.
                let citedKeys = result.evidenceReceipt?.citedKeys ?? []
                let valid = StockSageResearchQualification.valid(qualification, symbol: listing.ticker,
                    horizon: horizon.rawValue, at: result.at, citedKeys: citedKeys)
                return .init(symbol: listing.ticker, action: verdict.action.rawValue,
                    catalystIdentity: qualification.candidateCatalysts.first?.identity,
                    qualification: qualification, insiderTransactions: result.insiderTransactions,
                    isReceiptValid: valid)
            }
            guard !candidates.isEmpty else { return nil }
            return StockSageTopFiveRanking.rank(candidates, horizon: horizon, now: now)
        }
    }
    @Published private(set) var scans: [Horizon: Scan] = [:]
    @Published private(set) var running: Horizon?
    @Published private(set) var runningHorizons: [Horizon] = []
    @Published private(set) var activeSymbols: Set<String> = []
    var activeSymbol: String? { activeSymbols.sorted().first }
    var activeDescription: String {
        let symbols = activeSymbols.sorted()
        return symbols.prefix(3).joined(separator: ", ") + (symbols.count > 3 ? " +\(symbols.count - 3) more" : "")
    }
    private var task: Task<Void, Never>?
    private let history: StockSageResearchHistory?
    private var completedRuns: [Horizon: StockSageResearchHistory.Run] = [:]

    init(history: StockSageResearchHistory? = nil) {
        self.history = history
        for horizon in Horizon.allCases {
            if let restored = history?.completedScan(horizon: horizon) {
                scans[horizon] = restored.scan
                completedRuns[horizon] = restored.run
                if let history, !history.runs.contains(where: { $0.id == restored.run.id }) {
                    persistCompletedRun(horizon)
                }
            }
        }
    }
    enum ScanFailure: Error { case modelUnavailable(String), checkpointUnavailable }
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

    /// Injected ownership for the one shared outcome trigger. Production reads the live policy,
    /// credential and clock; a test host supplies its own so no real request can ever be made.
    @MainActor struct SavedOutcomeGates {
        var isRunningTests: @MainActor () -> Bool = { StockSageStore.isRunningTests }
        var externalAllowed: @MainActor () -> Bool = { ToolPolicy.isExternalAllowed }
        var apiKey: @MainActor () -> String = { StockSageMassive.apiKey }
        var credentialRevision: @MainActor () -> String? = { StockSageMassive.credentialRevision() }
        var clock: @MainActor () -> Date = { Date() }
        /// nil uses the real settled-window Massive review fetch.
        var fetch: (@MainActor (StockSageResearchHistory.Prediction, StockSageResearchHistory.Run, String,
                     @escaping @MainActor () -> Bool) async -> StockSageResearchHistory.Observation?)?
    }

    /// ONE caller for both the Saved Research action and a foreground activation. The credential
    /// and policy are captured once, then re-checked after every await, so a response that arrives
    /// after the owner revoked access or rotated the key is discarded rather than persisted.
    /// `history.isChecking` is the single-flight guard; there is no timer or background poller.
    @MainActor
    static func checkSavedOutcomes(history: StockSageResearchHistory, store: StockSageStore,
                                   gates: SavedOutcomeGates = .init()) async {
        guard !gates.isRunningTests(), !Task.isCancelled, gates.externalAllowed(), !store.isSampleData else { return }
        let key = gates.apiKey()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let revision = gates.credentialRevision()
        let allowed: @MainActor () -> Bool = {
            !Task.isCancelled && !gates.isRunningTests() && gates.externalAllowed() && !store.isSampleData
                && gates.apiKey() == key && gates.credentialRevision() == revision
        }
        await history.checkActive(clock: gates.clock, allowed: allowed) { prediction, run in
            if let fetch = gates.fetch { return await fetch(prediction, run, key, allowed) }
            return await fetchReviewObservation(prediction: prediction, run: run, key: key,
                allowed: allowed, clock: gates.clock)
        }
    }

    /// The last date this review may request. A daily-policy run stops at the latest New York
    /// session that has WHOLLY ended, so Massive's adjusted daily aggregate is settled, capped at
    /// the scheduled horizon. A legacy run keeps requesting through its captured target close.
    nonisolated static func reviewEnd(for run: StockSageResearchHistory.Run, now: Date) -> Date? {
        guard run.outcomePolicy == .dailyBarFirstHit else { return StockSageResearchHistory.targetClose(for: run) }
        return StockSageResearchHistory.settledReviewDate(for: run, now: now)
    }

    /// Fetch ONE adjusted daily series covering the review window. A daily-policy run starts at the
    /// saved reference date, so the corporate-action ratio and the monitoring path share one basis;
    /// a legacy run keeps its benchmark-through-target window. This path does not fall back to
    /// another provider or request a model opinion.
    static func fetchReviewObservation(prediction: StockSageResearchHistory.Prediction,
        run: StockSageResearchHistory.Run, key: String,
        allowed: @escaping @MainActor () -> Bool, clock: @MainActor () -> Date = { Date() },
        transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> StockSageResearchHistory.Observation? {
        guard !Task.isCancelled, allowed() else { return nil }
        let requestedAt = clock()
        let firstHit = run.outcomePolicy == .dailyBarFirstHit
        guard run.predictions.contains(prediction),
              StockSageResearchHistory.availability(for: run, now: requestedAt).state == .due,
              let end = reviewEnd(for: run, now: requestedAt),
              let benchmark = StockSageResearchHistory.benchmarkDay(after: run.completedAt) else { return nil }
        let start = firstHit ? (prediction.referenceDate ?? benchmark) : benchmark
        guard start <= end else { return nil }
        // The requested end date must itself be settled before its aggregate can be trusted.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard let settledAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        guard let request = dailyHistoryRequest(symbol: prediction.symbol,
            from: formatter.string(from: start), to: formatter.string(from: end), key: key) else { return nil }
        do {
            let data: Data
            let response: URLResponse
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000) }
            guard !Task.isCancelled, allowed(), (response as? HTTPURLResponse)?.statusCode == 200,
                  let history = parseResearchHistory(data, symbol: prediction.symbol) else { return nil }
            let fetchedAt = clock()
            guard fetchedAt.timeIntervalSince1970.isFinite, fetchedAt >= requestedAt,
                  fetchedAt >= (firstHit ? settledAt : end) else { return nil }
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

    /// Use the latest session whose full daily-aggregate window has ended in New York.
    nonisolated static func completedHistory(_ h: StockSagePriceHistory, at now: Date) -> StockSagePriceHistory? {
        guard now.timeIntervalSince1970.isFinite, h.priceSource == .massiveDaily,
              h.count == h.dates.count, h.count == h.opens.count, h.count == h.highs.count,
              h.count == h.lows.count, h.count == h.volumes.count else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard let latest = StockSageMarketHours.latestCompletedDailySession(at: now),
              let boundary = calendar.date(byAdding: .day, value: 1, to: latest) else { return nil }
        for i in h.dates.indices {
            guard h.dates[i].timeIntervalSince1970.isFinite, h.dates[i].timeIntervalSince1970 > 0,
                  i == 0 || h.dates[i] > h.dates[i - 1],
                  [h.opens[i], h.highs[i], h.lows[i], h.closes[i]].allSatisfy({ $0.isFinite && $0 > 0 }),
                  h.volumes[i].isFinite, h.volumes[i] >= 0,
                  h.highs[i] >= max(h.opens[i], h.closes[i]), h.lows[i] <= min(h.opens[i], h.closes[i]) else { return nil }
        }
        let n = h.dates.prefix { $0 < boundary && $0 <= now }.count
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

    typealias Analysis = @MainActor @Sendable (Horizon) async -> Result

    /// Structured lookahead: one local capture or two cloud captures, never an unbounded queue.
    private static func prepareAnalyses(_ first: Listing, second: Listing?,
        makeAnalysis: @escaping @MainActor (Listing) async -> Analysis) async -> [Analysis] {
        guard let second else { return [await makeAnalysis(first)] }
        async let firstAnalysis = makeAnalysis(first)
        let secondAnalysis = await makeAnalysis(second)
        let firstResult = await firstAnalysis
        return [firstResult, secondAnalysis]
    }

    func start(_ horizons: [Horizon], allowed: @escaping @MainActor () -> Bool,
        interruptionReason: @escaping @MainActor () -> String? = { nil },
        universe: @escaping @MainActor () async throws -> StockSageResearchUniverse.Selection,
        rank: (@MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>)? = nil,
        parallelism: @escaping @MainActor () -> Int = { 1 },
        analyze: @escaping @MainActor (Listing, Horizon) async -> Result) -> Bool {
        start(horizons, allowed: allowed, interruptionReason: interruptionReason, universe: universe,
            rank: rank, parallelism: parallelism, makeAnalysis: { item in
                { horizon in await analyze(item, horizon) }
            })
    }

    func start(_ horizons: [Horizon], allowed: @escaping @MainActor () -> Bool,
        interruptionReason: @escaping @MainActor () -> String? = { nil },
        universe: @escaping @MainActor () async throws -> StockSageResearchUniverse.Selection,
        rank: (@MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>)? = nil,
        parallelism: @escaping @MainActor () -> Int = { 1 },
        concurrentGathering: Bool = false,
        qualificationPolicyVersion: Int? = nil,
        makeAnalysis: @escaping @MainActor (Listing) async -> Analysis) -> Bool {
        guard task == nil, allowed(), !horizons.isEmpty, Set(horizons).count == horizons.count,
              qualificationPolicyVersion == nil || qualificationPolicyVersion == 1 else { return false }
        let previous = scans
        let startedAt = Date()
        running = horizons[0]; runningHorizons = horizons
        for horizon in horizons {
            scans[horizon] = Scan(status: "Selecting up to \(Self.scanLimit) NASDAQ common stocks by dated trading activity…", at: startedAt, qualificationPolicyVersion: qualificationPolicyVersion)
        }
        task = Task {
            var didStart = false
            var completed: Set<Horizon> = []
            @MainActor func finish(_ horizon: Horizon, count: Int) async throws {
                guard !completed.contains(horizon), let captured = scans[horizon] else { return }
                guard valid() else { throw CancellationError() }
                activeSymbols.removeAll()
                let outcome: Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>
                if let rank {
                    scans[horizon]?.isComparing = true
                    scans[horizon]?.status = "All \(count) checks finished · comparing research for the top five…"
                    outcome = await rank(captured, horizon)
                    guard valid() else { throw CancellationError() }
                } else { outcome = .failure(.unavailable) }
                finishComparison(outcome, horizon: horizon, earliestRankingAt: startedAt,
                    id: completedRuns[horizon]?.id ?? UUID())
                completed.insert(horizon)
                runningHorizons.removeAll { $0 == horizon }; running = runningHorizons.first
            }
            defer { activeSymbols.removeAll(); running = nil; runningHorizons = []; task = nil }
            let valid: @MainActor @Sendable () -> Bool = { !Task.isCancelled && allowed() }
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
                let updateProgress: @MainActor @Sendable () -> Void = {
                    guard valid() else { return }
                    for horizon in horizons {
                        self.scans[horizon]?.status = "Checking \(self.activeDescription) · \(self.scans[horizon]?.results.count ?? 0)/\(names.count) finished"
                    }
                }
                // Cloud preparation overlaps at most two stocks. Captures reserve model slots,
                // so the producer cannot gather past the loaded capacity while models are busy.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var occupied = 0, next = 0
                    let gatherLimit = concurrentGathering ? 2 : 1
                    while next < names.count {
                        while occupied + min(gatherLimit, min(min(8, max(1, parallelism())), names.count - next))
                            > min(8, max(1, parallelism())) {
                            try await group.next()
                            occupied -= 1
                        }
                        guard valid() else { throw CancellationError() }
                        let count = min(gatherLimit, min(min(8, max(1, parallelism())), names.count - next))
                        let items = Array(names[next..<(next + count)])
                        for item in items { activeSymbols.insert(item.ticker) }
                        updateProgress()
                        let analyses = await Self.prepareAnalyses(items[0], second: items.count == 2 ? items[1] : nil,
                            makeAnalysis: makeAnalysis)
                        guard valid() else { throw CancellationError() }
                        for (item, analyze) in zip(items, analyses) {
                            group.addTask { @MainActor @Sendable in
                                defer { self.activeSymbols.remove(item.ticker); updateProgress() }
                                for horizon in horizons {
                                    guard valid() else { throw CancellationError() }
                                    let result = await analyze(horizon)
                                    guard valid() else { throw CancellationError() }
                                    self.scans[horizon]?.results[item.ticker] = result
                                    updateProgress()
                                }
                            }
                        }
                        occupied += count; next += count
                    }
                    try await group.waitForAll()
                }
                // Both completed horizons are durable before the first model comparison starts.
                for horizon in horizons {
                    scans[horizon]?.rankingFailure = "Top five comparison has not completed. Retry using these saved checks."
                    guard let scan = scans[horizon] else { continue }
                    let pending = StockSageResearchHistory.snapshot(startedAt: startedAt, completedAt: Date(), horizon: horizon, scan: scan)
                    completedRuns[horizon] = pending
                }
                for horizon in horizons {
                    if let history, let pending = completedRuns[horizon], let scan = scans[horizon],
                       !history.saveCompletedChecks(pending, scan: scan) { throw ScanFailure.checkpointUnavailable }
                }
                for horizon in horizons { try await finish(horizon, count: names.count) }
            } catch {
                for horizon in horizons where !completed.contains(horizon) {
                    scans[horizon]?.isComparing = false
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
                    } else if case ScanFailure.checkpointUnavailable = error {
                        scans[horizon]?.needsSaving = true
                        scans[horizon]?.status = "All checks finished, but could not be saved for recovery. Comparison has not started. Keep the app open and use Retry save after resolving storage access."
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
    private func finishComparison(_ outcome: Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>,
        horizon: Horizon, earliestRankingAt: Date, id: UUID = UUID(), originalRunID: UUID? = nil) {
        guard var scan = scans[horizon], let startedAt = scan.at else { return }
        scan.ranking = nil; scan.isComparing = false
        switch outcome {
        case .success(let receipt):
            let eligible = Set(scan.listings.filter { scan.isEligible($0.ticker) }.map(\.ticker))
            if StockSageResearchRanking.valid(receipt), receipt.version == (scan.qualificationPolicyVersion == nil ? 1 : 2),
               Set(receipt.candidateSymbols) == eligible,
               receipt.horizon == horizon.rawValue, receipt.at >= earliestRankingAt, receipt.at <= Date() {
                scan.ranking = receipt; scan.rankingFailure = nil
            } else { scan.rankingFailure = StockSageResearchRanking.Failure.invalidOutput.message }
        case .failure(let failure): scan.rankingFailure = failure.message
        }
        scan.status = "Scan finished · \(scan.results.count) listings checked once. No orders created."
        if let failure = scan.rankingFailure { scan.status += " Top five unavailable: \(failure)" }
        let run = StockSageResearchHistory.snapshot(id: id, startedAt: startedAt, completedAt: Date(),
            horizon: horizon, scan: scan, originalRunID: originalRunID)
        completedRuns[horizon] = run
        scans[horizon] = scan
        persistCompletedRun(horizon)
    }

    /// Same receipt and completion date on storage retry; no model or provider work.
    private func persistCompletedRun(_ horizon: Horizon) {
        guard let history, let run = completedRuns[horizon], var scan = scans[horizon] else { return }
        let retained = history.saveCompletedChecks(run, scan: scan)
        let checkpointError = retained ? nil : history.lastError
        let recorded = history.runs.contains(where: { $0.id == run.id }) || history.record(run)
        let recordError = recorded ? nil : history.lastError
        scan.needsSaving = !retained || !recorded
        scan.status += recorded ? " Saved for \(run.horizon.rawValue)-trading-day review."
            : " Research could not be saved for review. \(recordError ?? "Check storage access.")"
        if !retained { scan.status += " \(checkpointError ?? "Full checks could not be saved for recovery.") Keep the app open." }
        if scan.needsSaving { scan.status += " Use Retry save after resolving storage access." }
        scans[horizon] = scan
    }

    func retrySave(_ horizon: Horizon) {
        guard task == nil, scans[horizon]?.needsSaving == true else { return }
        scans[horizon]?.status = "Completed research retained."
        persistCompletedRun(horizon)
    }

    func canRetryTopFive(_ horizon: Horizon) -> Bool {
        guard task == nil, let scan = scans[horizon], let source = completedRuns[horizon],
              scan.at == source.startedAt, scan.ranking == nil, !scan.listings.isEmpty,
              Set(scan.listings.map(\.ticker)) == Set(scan.results.keys) else { return false }
        return scan.qualificationPolicyVersion == 1 || scan.listings.contains { scan.isEligible($0.ticker) }
    }

    /// Reuses only immutable completed checks: no universe, provider or per-stock AI work.
    @discardableResult func retryTopFive(_ horizon: Horizon, allowed: @escaping @MainActor () -> Bool,
        rank: @escaping @MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>) -> Bool {
        guard canRetryTopFive(horizon), allowed(), let captured = scans[horizon], let source = completedRuns[horizon] else { return false }
        if let history, !history.saveCompletedChecks(source, scan: captured) {
            scans[horizon]?.status = "Completed checks could not be saved for recovery. Comparison has not started. Keep the app open and check Saved research for the save error."
            return false
        }
        // A crash may leave a pending checkpoint without its small history record.
        if let history, !history.runs.contains(where: { $0.id == source.id }), !history.record(source) { return false }
        let began = Date()
        running = horizon; runningHorizons = [horizon]
        scans[horizon]?.isComparing = true
        scans[horizon]?.status = "Retrying Top 5 · comparing \(captured.results.count) saved checks. Original evidence retained…"
        task = Task {
            defer { scans[horizon]?.isComparing = false; running = nil; runningHorizons = []; task = nil }
            let outcome = await rank(captured, horizon)
            guard !Task.isCancelled, allowed() else {
                scans[horizon]?.status = "Comparison stopped · all original checks retained. Retry Top 5 when ready."
                return
            }
            finishComparison(outcome, horizon: horizon, earliestRankingAt: began, originalRunID: source.originalRunID ?? source.id)
        }
        return true
    }

    func retryTopFive(_ horizon: Horizon, store: StockSageStore) {
        guard canRetryTopFive(horizon) else { return }
        guard let config = StockSageAIAssessments.configuration, ToolPolicy.isExternalAllowed, !store.isSampleData else {
            scans[horizon]?.status = "Enable web access and the local model in Settings to retry Top 5. Original checks retained."
            return
        }
        let revision = StockSageLocalModelServer.settingsRevision()
        let allowed: @MainActor () -> Bool = {
            !StockSageLocalModelServer.isShuttingDown && ToolPolicy.isExternalAllowed && !store.isSampleData
                && StockSageAIAssessments.configuration == config && StockSageLocalModelServer.settingsRevision() == revision
        }
        retryTopFive(horizon, allowed: allowed) { scan, horizon in
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            guard probe.reachable, probe.hasModel else { return .failure(.modelFailure) }
            return await StockSageResearchRanking.rank(scan: scan, horizon: horizon, config: config,
                isOllama: probe.isOllama, allowed: allowed, progress: { self.scans[horizon]?.status = $0 })
        }
    }

    func incompleteListings(_ horizon: Horizon) -> [Listing] {
        guard task == nil, let scan = scans[horizon], let source = completedRuns[horizon],
              scan.at == source.startedAt, Set(scan.listings.map(\.ticker)) == Set(scan.results.keys) else { return [] }
        return scan.listings.filter { scan.results[$0.ticker]?.verdict == nil }
    }

    /// New dated observations for failed checks only; all accepted checks remain byte-for-byte.
    @discardableResult func retryIncomplete(_ horizon: Horizon, allowed: @escaping @MainActor () -> Bool,
        parallelism: @escaping @MainActor () -> Int = { 1 },
        concurrentGathering: Bool = false,
        makeAnalysis: @escaping @MainActor (Listing) async -> Analysis,
        rank: @escaping @MainActor (Scan, Horizon) async -> Swift.Result<StockSageResearchRanking.Receipt, StockSageResearchRanking.Failure>) -> Bool {
        let missing = incompleteListings(horizon)
        guard !missing.isEmpty, allowed(), let original = scans[horizon], let source = completedRuns[horizon] else { return false }
        if let history {
            guard history.saveCompletedChecks(source, scan: original),
                  history.runs.contains(where: { $0.id == source.id }) || history.record(source) else {
                scans[horizon]?.status = "The original checks could not be saved. Retry has not started; keep the app open."
                return false
            }
        }
        let startedAt = Date()
        running = horizon; runningHorizons = [horizon]
        scans[horizon]?.status = "Retrying incomplete checks · 0/\(missing.count) finished · \(original.results.count - missing.count) previous opinions retained…"
        task = Task {
            defer { activeSymbols.removeAll(); scans[horizon]?.isComparing = false; running = nil; runningHorizons = []; task = nil }
            let valid: @MainActor @Sendable () -> Bool = { !Task.isCancelled && allowed() }
            var revised = original
            revised.at = startedAt; revised.retainedFromRunID = source.id
            revised.ranking = nil; revised.rankingFailure = "Updated checks await Top 5 comparison."
            var finished = 0
            @MainActor func accept(_ result: (String, Result)) throws {
                guard valid() else { throw CancellationError() }
                revised.results[result.0] = result.1
                activeSymbols.remove(result.0); finished += 1
                scans[horizon]?.status = "Retrying incomplete checks · \(finished)/\(missing.count) finished · \(original.results.count - missing.count) previous opinions retained…"
            }
            do {
                try await withThrowingTaskGroup(of: (String, Result).self) { group in
                    var occupied = 0, next = 0
                    let gatherLimit = concurrentGathering ? 2 : 1
                    while next < missing.count {
                        while occupied + min(gatherLimit, min(min(8, max(1, parallelism())), missing.count - next))
                            > min(8, max(1, parallelism())) {
                            if let result = try await group.next() { try accept(result) }
                            occupied -= 1
                        }
                        guard valid() else { throw CancellationError() }
                        let count = min(gatherLimit, min(min(8, max(1, parallelism())), missing.count - next))
                        let items = Array(missing[next..<(next + count)])
                        for item in items { activeSymbols.insert(item.ticker) }
                        let analyses = await Self.prepareAnalyses(items[0], second: items.count == 2 ? items[1] : nil,
                            makeAnalysis: makeAnalysis)
                        guard valid() else { throw CancellationError() }
                        for (item, analyze) in zip(items, analyses) {
                            group.addTask { @MainActor @Sendable in
                                guard valid() else { throw CancellationError() }
                                return (item.ticker, await analyze(horizon))
                            }
                        }
                        occupied += count; next += count
                    }
                    while let result = try await group.next() { try accept(result) }
                }
                guard valid() else { throw CancellationError() }
                scans[horizon] = revised
                let pending = StockSageResearchHistory.snapshot(startedAt: startedAt, completedAt: Date(), horizon: horizon, scan: revised)
                completedRuns[horizon] = pending
                if let history, !history.saveCompletedChecks(pending, scan: revised) {
                    scans[horizon]?.needsSaving = true
                    scans[horizon]?.status = "Updated checks could not be saved for recovery. Comparison has not started; keep the app open and use Retry save after resolving storage access."
                    return
                }
                scans[horizon]?.isComparing = true
                scans[horizon]?.status = "Updated checks complete · comparing the full eligible pool for Top 5…"
                let outcome = await rank(revised, horizon)
                guard valid() else { throw CancellationError() }
                finishComparison(outcome, horizon: horizon, earliestRankingAt: startedAt, id: pending.id)
            } catch {
                // Before the amended checkpoint, the original scan stays published and durable.
                scans[horizon]?.status = "Retry stopped. Completed research is retained; no new ranked picks were published."
            }
        }
        return true
    }

    func retryIncomplete(_ horizon: Horizon, store: StockSageStore) {
        guard !incompleteListings(horizon).isEmpty, let config = StockSageAIAssessments.configuration,
              StockSageMassive.isConfigured, ToolPolicy.isExternalAllowed, !store.isSampleData else { return }
        let key = StockSageMassive.apiKey
        let credentials = StockSageMassive.credentialRevision()
        let revision = StockSageLocalModelServer.settingsRevision()
        let allowed: @MainActor () -> Bool = {
            !StockSageLocalModelServer.isShuttingDown && ToolPolicy.isExternalAllowed && !store.isSampleData
                && StockSageMassive.apiKey == key && StockSageMassive.credentialRevision() == credentials
                && StockSageAIAssessments.configuration == config && StockSageLocalModelServer.settingsRevision() == revision
        }
        var capacity = 1
        var isOllama = false
        var prepared = false
        var modelReady = true
        retryIncomplete(horizon, allowed: { allowed() && modelReady }, parallelism: { capacity },
            concurrentGathering: config.isRunPodGemma, makeAnalysis: { item in
            if !prepared {
                let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
                prepared = true; capacity = probe.researchParallelism; isOllama = probe.isOllama
                modelReady = probe.reachable && probe.hasModel
            }
            guard modelReady else { return { _ in .init(note: "Local model unavailable; original check retained.") } }
            let gathered = await Self.gather(item, store: store, key: key, allowed: allowed,
                selectionFact: self.scans[horizon]?.selection?.detail(for: item.ticker))
            return Self.preparedAnalysis(gathered, config: config, isOllama: isOllama, allowed: allowed,
                outputTokens: 384, qualify: self.scans[horizon]?.qualificationPolicyVersion == 1)
        }, rank: { scan, horizon in
            await StockSageResearchRanking.rank(scan: scan, horizon: horizon, config: config, isOllama: isOllama,
                allowed: allowed, progress: { self.scans[horizon]?.status = $0 })
        })
    }

    func stop() {
        guard running != nil else { return }
        task?.cancel(); activeSymbols.removeAll()
        for horizon in runningHorizons { scans[horizon]?.status = "Stopping scan · keeping completed results…" }
    }
    func isRunning(_ horizon: Horizon) -> Bool { runningHorizons.contains(horizon) }
    func start(_ horizon: Horizon, store: StockSageStore) { start([horizon], store: store) }

    func start(_ horizons: [Horizon], store: StockSageStore) {
        guard task == nil, !horizons.isEmpty else { return }
        guard let config = StockSageAIAssessments.configuration, StockSageMassive.isConfigured,
              ToolPolicy.isExternalAllowed, !store.isSampleData else {
            for horizon in horizons { scans[horizon, default: Scan()].status = "Enable web access, Massive and the local model in Settings. No scan started." }
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
        var parallelism = 1
        var refreshCapacityAfterLoad = false
        _ = start(horizons, allowed: allowed, interruptionReason: interruptionReason, universe: {
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            guard probe.reachable, probe.hasModel else { throw ScanFailure.modelUnavailable(probe.detail) }
            isOllama = probe.isOllama
            parallelism = probe.researchParallelism
            refreshCapacityAfterLoad = parallelism == 1
            let result = try await StockSageResearchUniverse.fetch(key: key, allowed: allowed)
            selection = result.receipt
            return result
        }, rank: { scan, horizon in
            await StockSageResearchRanking.rank(scan: scan, horizon: horizon, config: config,
                isOllama: isOllama, allowed: allowed, progress: { status in
                    self.scans[horizon]?.status = status
                })
        }, parallelism: { parallelism }, concurrentGathering: config.isRunPodGemma, qualificationPolicyVersion: 1, makeAnalysis: { item in
            let gathered = await Self.gather(item, store: store, key: key, allowed: allowed,
                selectionFact: selection?.detail(for: item.ticker))
            let analyze = Self.preparedAnalysis(gathered, config: config, isOllama: isOllama, allowed: allowed, qualify: true)
            return { horizon in
                let result = await analyze(horizon)
                // A downloaded model can JIT-load on the first request with a higher saved capacity.
                if refreshCapacityAfterLoad, result.model == config.model, !Task.isCancelled, allowed() {
                    refreshCapacityAfterLoad = false
                    let loaded = await StockSageLocalModelServer.probe(config, stillValid: allowed)
                    parallelism = loaded.researchParallelism
                }
                return result
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
        var evidencePacket: StockSageAIAssessment.EvidencePacket? = nil
        var nextEarnings: StockSageMassiveEarnings.Observation? = nil
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

    static func preparedAnalysis(_ gathered: Gathered,
        config: StockSageLocalModelServer.Config, isOllama: Bool,
        allowed: @escaping @MainActor () -> Bool,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil,
        outputTokens: Int = researchOutputTokens, qualify: Bool = false) -> Analysis {
        { horizon in
            switch gathered {
            case .failed(let result): return result
            case .captured(let capture):
                return await assess(capture, horizon: horizon, config: config, isOllama: isOllama,
                    allowed: allowed, modelTransport: modelTransport, evidenceIsCurrent: evidenceIsCurrent, outputTokens: outputTokens, qualify: qualify)
            }
        }
    }

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
        insiderObservation: ((String, Date) async -> StockSageMassiveEvents.Observation)? = nil,
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
        guard let (data, response) = try? await historyFetch(), active() else {
            return failed("Massive daily-history request failed or was interrupted; no opinion.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return failed("Massive daily-history request returned HTTP \((response as? HTTPURLResponse)?.statusCode.description ?? "unknown"); no opinion.")
        }
        guard let raw = parseResearchHistory(data, symbol: item.ticker) else {
            return failed("Massive daily-history response did not satisfy the symbol, adjustment and bar-validity contract; no opinion.")
        }
        guard let history = completedHistory(raw, at: Date()) else {
            return failed("Massive returned \(raw.count) daily bars. Need at least 30 valid, completed daily bars including the latest ended aggregate session from a verified calendar. History is insufficient or stale; no opinion.")
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
        var company = companyObservations ?? store.companyEventChecks[item.ticker] ?? [:]
        // A research listing need not be on the Markets board. Each capture gets its own
        // current Form 4 check; explicit company observations remain an offline replay seam.
        if insiderObservation != nil || companyObservations == nil {
            company[.insider] = await (insiderObservation ?? {
                await StockSageMassiveEvents.fetch(.insider, symbol: $0, now: $1, allowed: evidenceAllowed)
            })(item.ticker, Date())
            guard evidenceAllowed() else { return failed("Analysis interrupted.") }
        }
        let capturedAt = Date()
        var coverage = [EvidenceCoverage(source: "Daily history", state: .answered, checkedAt: began)]
        var extra: [StockSageAIAssessment.EvidenceFact] = []
        func appendExtra(_ key: String, _ text: String, required: Bool = true,
                         availability: StockSageAIAssessment.FactAvailability = .available) {
            extra.append(.init(key: key, text: text, required: required, availability: availability))
        }
        var earningsAnswered = false
        switch earnings.outcome {
        case .answered(let row):
            let validCheck = earningsCheckedAt.map { (0...300).contains(capturedAt.timeIntervalSince($0)) } == true
            let todayUTC = floor(earningsAt.timeIntervalSince1970 / 86_400) * 86_400
            earningsAnswered = validCheck && (row.map { $0.date.timeIntervalSince1970.isFinite && (todayUTC...(todayUTC + 401 * 86_400 - 1)).contains($0.date.timeIntervalSince1970) } ?? true)
            coverage.append(.init(source: "Next earnings", state: earningsAnswered ? .answered : .unavailable, checkedAt: earningsCheckedAt))
            if let row, earningsAnswered {
                appendExtra("nextEarnings", "Next earnings: \(row.date.ISO8601Format()), \(row.confirmed ? "confirmed" : "projected, not announced"). Source: \(StockSageMassiveEarnings.source); checked \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Date-only precision, no release time or earnings outcome inferred.")
            } else {
                appendExtra("nextEarnings", earningsAnswered ? "Next earnings: provider answered with no scheduled date in the queried 400-day window, checked \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Not proof of no upcoming earnings risk." : "Next earnings: invalid provider date; unavailable.", availability: earningsAnswered ? .missing : .unknown)
            }
        case .unavailable:
            coverage.append(.init(source: "Next earnings", state: .unavailable, checkedAt: earningsCheckedAt))
            appendExtra("nextEarnings", "Next earnings: unavailable from \(StockSageMassiveEarnings.source), attempted \(earningsCheckedAt?.ISO8601Format() ?? "not checked"). Missing is not no earnings risk.", availability: .unknown)
        case .notRequested:
            coverage.append(.init(source: "Next earnings", state: .unchecked, checkedAt: nil))
            let origin: String
            if case .priorAuthenticationRejection(let at) = earnings.notRequestedReason {
                origin = "prior authentication rejection at \(at.ISO8601Format())"
            } else { origin = "access, cancellation or request availability" }
            appendExtra("nextEarnings", "Next earnings: not requested (\(origin)); decision recorded \(earnings.recordedAt.ISO8601Format()). Missing is not no earnings risk.", availability: .unknown)
        }
        let filingsFresh = (0...300).contains(capturedAt.timeIntervalSince(filings.checkedAt))
        let filingsAnswered = filingsFresh && filings.outcome == .answered
        coverage.append(.init(source: "SEC submissions metadata", state: !filingsFresh ? .stale : filingsAnswered ? .answered : .unavailable, checkedAt: filings.checkedAt))
        let filingsStatus: String
        switch filings.outcome {
        case .answered: filingsStatus = filingsFresh ? "answered; bounded selection of up to five recent 8-K, 10-Q, 10-K, 6-K and 20-F records" : "stale or invalid check clock"
        case .unavailable(let reason): filingsStatus = "unavailable; " + reason.message
        }
        appendExtra("sec.status", "SEC submissions metadata: \(filingsStatus). Checked \(filings.checkedAt.ISO8601Format()). These are filing identities and dates, not retrieved filing documents or interpreted contents.", availability: filingsAnswered ? .available : .unknown)
        if filingsAnswered {
            for filing in filings.filings.prefix(5) where filing.filingDate.timeIntervalSince1970.isFinite && filing.filingDate.timeIntervalSince1970 > 0
                && (filing.acceptedAt.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 && $0 <= capturedAt } ?? (filing.filingDate <= capturedAt)) {
                appendExtra("sec.record." + filing.accessionNumber, "SEC metadata: form \(filing.form); accession \(filing.accessionNumber); filed \(filing.filingDate.ISO8601Format()); accepted \(filing.acceptedAt?.ISO8601Format() ?? "time not supplied"). Metadata does not establish the filing's meaning or price impact.", required: false)
            }
        }
        let context = StockSageAIAssessment.Context(idea: idea, earnings: nil,
            company: company, at: capturedAt,
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
        for (index, text) in historicalFacts(history).enumerated() {
            appendExtra("history.liquidityAndGaps.\(index)", text, required: false)
        }
        if let selectionFact { appendExtra("universe.selection", selectionFact) }
        // Keep independent forward earnings and SEC statuses mandatory, even when records are trimmed.
        let packet = context.evidencePacket(maximumUTF8Bytes: 12_000)
        var evidence = packet.facts.filter { $0.key != "earnings" }
        let providerIndex = evidence.firstIndex {
            $0.key == "benzinga.status" || $0.key.hasPrefix("feed.insider.transaction.")
        } ?? evidence.count
        evidence.insert(contentsOf: extra, at: providerIndex)
        return .captured(.init(history: history, context: context, facts: evidence.map(\.text),
            coverage: coverage, at: began, blockedByThrottle: blocked,
            evidencePacket: .init(facts: evidence, prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount),
            nextEarnings: earnings))
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
        insiderObservation: ((String, Date) async -> StockSageMassiveEvents.Observation)? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil) async -> Result {
        let gathered = await gather(item, store: store, key: key, allowed: allowed,
            companyObservations: companyObservations, historyTransport: historyTransport, benzingaSnapshot: benzingaSnapshot, newsObservation: newsObservation,
            nextEarnings: nextEarnings, filingsObservation: filingsObservation, insiderObservation: insiderObservation,
            evidenceIsCurrent: evidenceIsCurrent)
        return await preparedAnalysis(gathered, config: config, isOllama: isOllama,
            allowed: allowed, modelTransport: modelTransport, evidenceIsCurrent: evidenceIsCurrent)(horizon)
    }

    static func assess(_ capture: Capture, horizon: Horizon,
        config: StockSageLocalModelServer.Config, isOllama: Bool,
        allowed: @escaping @MainActor () -> Bool,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil,
        outputTokens: Int = researchOutputTokens,
        diagnostics: StockSageResearchDiagnostics? = nil, qualify: Bool = false) async -> Result {
        let writer = diagnostics ?? (modelTransport == nil && !StockSageStore.isRunningTests ? .shared : nil)
        let receipt = StockSageResearchDiagnostics.Context(symbol: capture.context.idea.symbol,
            horizon: horizon == .week ? 7 : 14, purpose: .assessment)
        let began = await writer?.begin(receipt) ?? false
        let observer: (@Sendable (StockSageLocalModelServer.ModelAttemptEvent) async -> Void)?
        if let writer {
            observer = { event in _ = await writer.record(event, context: receipt) }
        } else { observer = nil }
        var result = await assessCaptured(capture, horizon: horizon, config: config, isOllama: isOllama,
            allowed: allowed, modelTransport: modelTransport, evidenceIsCurrent: evidenceIsCurrent,
            outputTokens: outputTokens, attemptObserver: observer, qualify: qualify)
        if let writer {
            // This records validation at this instant, not publication, an order or a prediction outcome.
            let state: StockSageResearchDiagnostics.Outcome.State = Task.isCancelled ? .cancelled
                : result.verdict != nil ? .accepted : result.evidenceReceipt == nil ? .notRequested : .rejected
            let finished = await writer.finish(receipt, outcome: .init(state: state, note: result.note))
            result.diagnosticID = receipt.id
            result.diagnosticsComplete = began && finished
            let current = capture.context.benzinga.map {
                evidenceIsCurrent?($0) ?? StockSageBenzingaClient.shared.isCurrent($0)
            } ?? true
            if !allowed() || Task.isCancelled || !capture.isFresh(at: Date()) || !current {
                result.verdict = nil; result.levels = nil; result.qualification = nil
                if let evidence = result.evidenceReceipt {
                    result.evidenceReceipt = .init(symbol: evidence.symbol, requiredKeys: evidence.requiredKeys,
                        missingOrUnknownRequiredKeys: evidence.missingOrUnknownRequiredKeys,
                        offeredKeys: evidence.offeredKeys, omittedKeys: evidence.omittedKeys,
                        prePromptOmittedRecordCount: evidence.prePromptOmittedRecordCount, citedKeys: [])
                }
                result.note = "Analysis interrupted or captured evidence expired before publication."
            }
        }
        return result
    }

    /// Fresh, symbol-matched, typed Form 4 detail only. Never a guess: an unfresh check or a
    /// record for another symbol yields nothing, and a legacy cached event with no typed
    /// `.insider` payload is simply skipped rather than reconstructed from its prose.
    nonisolated static func insiderTransactions(from context: StockSageAIAssessment.Context,
                                                at now: Date) -> [StockSageMassiveEvents.InsiderTransaction] {
        guard let observation = context.company[.insider], observation.symbol == context.idea.symbol.uppercased(),
              observation.feed == .insider, observation.outcome == .answered,
              observation.fresh(at: now) else { return [] }
        let events = observation.insiderEvents ?? observation.event.map { [$0] } ?? []
        return events.filter { $0.symbol == context.idea.symbol.uppercased() && $0.feed == .insider }
            .compactMap(\.insider)
    }

    private static func assessCaptured(_ capture: Capture, horizon: Horizon,
        config: StockSageLocalModelServer.Config, isOllama: Bool,
        allowed: @escaping @MainActor () -> Bool,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))?,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)?, outputTokens: Int,
        attemptObserver: (@Sendable (StockSageLocalModelServer.ModelAttemptEvent) async -> Void)?, qualify: Bool) async -> Result {
        let history = capture.history, context = capture.context, referenceClose = capture.referenceClose
        var evidenceReceipt: StockSageAIAssessment.EvidenceCoverage?
        func evidenceAllowed() -> Bool {
            allowed() && !Task.isCancelled && capture.isFresh(at: Date())
                && (context.benzinga.map { evidenceIsCurrent?($0) ?? StockSageBenzingaClient.shared.isCurrent($0) } ?? true)
        }
        func result(_ note: String, facts: [String] = []) -> Result {
            .init(facts: facts, note: note, at: capture.at, referenceClose: referenceClose, coverage: capture.coverage, evidenceReceipt: evidenceReceipt)
        }
        guard [researchOutputTokens, 384].contains(outputTokens) else { return result("Unsupported research output budget; no opinion.") }
        guard evidenceAllowed() else { return result("Evidence exceeded the age limit or access changed; no opinion.") }
        if capture.blockedByThrottle { return result("Supplemental evidence requests were blocked by throttling or access denial, with no usable fallback; no model request or opinion. Retry after provider access recovers.", facts: capture.facts) }
        var horizonFacts = ["Requested holding horizon: \(horizon.rawValue). Research only, no orders or position management. Reference entry is the last completed split-adjusted daily close, NOT a live quote. An unfinished daily aggregate is excluded until the scheduled extended-hours session ends."]
        let earningsWindow = StockSageMassiveEarnings.Window(observation: capture.nextEarnings,
            asOf: context.asOf, horizon: horizon)
        for period in [7, 14] {
            if let value = StockSageIndicators.returnOverPeriod(history.closes, period: period), value.isFinite {
                horizonFacts.append("Observed return over the last \(period) completed daily bars: \(value)%. Bar window ends \(history.dates.last!.ISO8601Format()). Historical change, not an expected return.")
            }
        }
        horizonFacts.append("Evidence coverage at capture (not a quality score): " + capture.coverage.map(\.detail).joined(separator: "; "))
        // Legacy injected captures conservatively keep every fact; live captures carry explicit keys.
        let packet = capture.evidencePacket ?? .init(facts: capture.facts.enumerated().map {
            .init(key: "captured.\($0.offset)", text: $0.element, required: true, availability: .unknown)
        }, prePromptOmittedRecordCount: 0)
        let qualification = qualify ? StockSageResearchQualification.prepare(capture, horizon: horizon) : nil
        let optional = packet.facts.filter { !$0.required }
        var mandatory = packet.facts.filter(\.required) + horizonFacts.enumerated().map {
            StockSageAIAssessment.EvidenceFact(key: "horizon.\($0.offset)", text: $0.element,
                                             required: true, availability: .available)
        } + [.init(key: "nextEarnings.window", text: earningsWindow.fact, required: true,
                   availability: earningsWindow.relation == .unknown ? .unknown : .available)]
        if let qualification {
            mandatory.append(.init(key: "research.qualification.v1", text: qualification.fact, required: true, availability: .available))
        }
        let system = horizon.instructions + (qualify ? "\nBe selective. Buy / Strong Buy needs a cited recent catalyst, positive price/volume confirmation, a defensible historical-range stop/target and no critical unresolved data gap. The app's strict screen is authoritative for its measured criteria. Public insider purchases and sales remain evidence; preserve their source meaning. Hold is appropriate when the buying case is insufficient. Do not invent a catalyst or change the measured screen to justify Buy." : "")
        guard let fitted = StockSageAIAssessment.fittedResearchPrompt(optional: optional.map(\.text),
            mandatory: mandatory.map(\.text), system: { _ in system },
            optionalKeys: optional.map(\.key), outputTokens: config.reservedOutputTokens(for: outputTokens)) else {
            return result("Evidence could not fit the model context budget without dropping a mandatory horizon or source-status fact; no opinion.", facts: mandatory.map(\.text))
        }
        let offered = Array(optional.prefix(fitted.optionalKept)) + mandatory
        evidenceReceipt = context.coverage(offered: offered, omittedKeys: fitted.omittedKeys,
            prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount)
        let facts = fitted.facts
        let trimmedNote = fitted.isComplete ? "" : " \(fitted.omitted) of \(optional.count) optional evidence records were omitted to fit the context budget."
        let response = await StockSageAIAssessment.complete(config, isOllama: isOllama,
            system: fitted.system, user: fitted.user, facts: facts, maxTokens: outputTokens,
            attemptObserver: attemptObserver, stillValid: evidenceAllowed, transport: modelTransport)
        guard evidenceAllowed() else { return result("Analysis interrupted or captured evidence expired.", facts: facts) }
        if case .success(let completion) = response, let rejection = StockSageLocalModelServer.financialOutputRejection(completion) {
            return result("No verified opinion. " + rejection + trimmedNote + " " + completion.diagnostic.summary, facts: facts)
        }
        guard case .success(let completion) = response else {
            return result("No verified opinion. " + StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0) + trimmedNote, facts: facts)
        }
        let verdict: StockSageAIAssessment.Verdict
        switch StockSageAIAssessment.validate(completion.text, facts: facts, earningsWindow: earningsWindow) {
        case .success(let accepted): verdict = accepted
        case .failure(let failure):
            return result("No verified opinion. " + failure.explanation(model: completion.model) + trimmedNote, facts: facts)
        }
        evidenceReceipt = context.coverage(offered: offered, omittedKeys: fitted.omittedKeys,
            prePromptOmittedRecordCount: packet.prePromptOmittedRecordCount, verdict: verdict)
        let qualified = qualification?.receipt(verdict: verdict, citedKeys: evidenceReceipt?.citedKeys ?? [], offeredKeys: offered.map(\.key))
        return .init(verdict: verdict, levels: qualified?.levels ?? levels(history: history, action: verdict.action, at: Date()),
            facts: facts, note: "Unvalidated model research · \(horizon.rawValue). No order created." + trimmedNote,
            at: capture.at, model: config.model, referenceClose: referenceClose, coverage: capture.coverage, evidenceReceipt: evidenceReceipt, qualification: qualified,
            insiderTransactions: insiderTransactions(from: context, at: capture.at))
    }
}
