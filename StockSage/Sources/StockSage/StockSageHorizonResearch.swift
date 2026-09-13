import Foundation
import Combine

/// Manual research only. Deliberately has no paper book, order, journal or broker writer.
@MainActor
final class StockSageHorizonResearch: ObservableObject {
    static let shared = StockSageHorizonResearch()
    nonisolated static let scanLimit = 500
    /// Shared by the fit() budget and the dispatched output limit; see PaperAutomation.
    nonisolated static let researchOutputTokens = 192
    nonisolated enum Horizon: String, CaseIterable, Identifiable, Sendable {
        case week = "1–7 trading days", fortnight = "7–14 trading days"
        var id: String { rawValue }
        var instructions: String {
            StockSageAIAssessment.instructions.replacingOccurrences(of: "Assess the supplied stock for the next trading week.",
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
        enum ValidationOutcome: String, Sendable { case validated, rejected, unknown }
        var verdict: StockSageAIAssessment.Verdict?
        var levels: Levels?
        var facts: [String] = []
        var note: String
        var at: Date = Date()
        var model: String = ""
        var validationOutcome: ValidationOutcome = .unknown
        var validationFailure: String? = nil
        var referenceClose: (value: Double, at: Date)? = nil
        var newsCheckedAt: Date? = nil
        var newestNewsAt: Date? = nil
        var newsCheckSummary: String? = nil
    }
    struct Scan {
        var listings: [Listing] = []
        var results: [String: Result] = [:]
        var status = "Press Run to research up to \(StockSageHorizonResearch.scanLimit) US listings once."
        var at: Date?
        var selection: StockSageResearchUniverse.Receipt?
        var requestedAt: Date? = nil
        var lastAttemptAt: Date? = nil
        var attemptFinishedAt: Date? = nil
        var retainsEarlierResults = false
        var changes: [String: String] = [:]
        var completedAt: Date? = nil
        var previousCompletedAt: Date? = nil
    }
    @Published private(set) var scans: [Horizon: Scan] = [:]
    @Published private(set) var running: Horizon?
    @Published private(set) var activeSymbol: String?
    private var task: Task<Void, Never>?
    enum ScanFailure: Error { case modelUnavailable(String) }
    private static let session = URLSession(configuration: .ephemeral, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
    typealias ReceiptObserver = @MainActor @Sendable (StockSageLocalModelServer.ModelAttemptEvent) -> Void
    typealias ReceiptAnalyzer = @MainActor (Listing, UUID, @escaping ReceiptObserver) async -> Result

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
        guard n >= 30, (0...4 * 86400).contains(now.timeIntervalSince(h.dates[n - 1])) else { return nil }
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
               analyze: @escaping @MainActor (Listing) async -> Result,
               receiptStore: StockSageResearchReceiptStore? = nil,
               receiptAnalyzer: ReceiptAnalyzer? = nil) -> Bool {
        guard task == nil, allowed() else { return false }
        let previousScan = scans[horizon]
        let receiptID = receiptStore?.begin(horizon: horizon)
        running = horizon
        let requestedAt = Date()
        scans[horizon] = Scan(status: "Selecting up to \(Self.scanLimit) US listings by dated trading activity…", at: requestedAt,
            requestedAt: requestedAt, lastAttemptAt: requestedAt, completedAt: nil, previousCompletedAt: previousScan?.completedAt)
        task = Task {
            var didStart = false
            var attemptID: UUID?
            defer { activeSymbol = nil; running = nil; task = nil }
            @MainActor func valid() -> Bool { !Task.isCancelled && allowed() }
            do {
                let selection = try await universe()
                guard valid() else { throw CancellationError() }
                let directory = selection.listings
                guard Set(directory.map(\.ticker)).count == directory.count, directory.count <= 50_000 else { throw URLError(.cannotParseResponse) }
                didStart = true
                // Selection is activity-ranked BEFORE this safety cap; never sort it alphabetically.
                let names = Array(directory.prefix(Self.scanLimit))
                let receiptAttempts: [UUID] = {
                    guard let receiptStore, let receiptID else { return [] }
                    return receiptStore.registerSelection(selection.receipt, listings: names, for: receiptID)
                }()
                scans[horizon]?.listings = names
                scans[horizon]?.selection = selection.receipt
                // ponytail: one manual worker limits additional local-model load while the independent
                // four-worker day scanner runs. No automatic repeat; parallelize only if model capacity allows.
                for (index, item) in names.enumerated() {
                    guard valid() else { throw CancellationError() }
                    attemptID = receiptAttempts.indices.contains(index) ? receiptAttempts[index] : nil
                    if let receiptStore, let receiptID, let id = attemptID { receiptStore.beginAttempt(id, scanID: receiptID) }
                    activeSymbol = item.ticker
                    scans[horizon]?.status = "Checking \(item.ticker) · \(scans[horizon]?.results.count ?? 0)/\(names.count) finished"
                    let result: Result
                    if let receiptAnalyzer, let id = attemptID {
                        result = await receiptAnalyzer(item, id) { capture in
                            if let receiptStore, let receiptID { receiptStore.capture(capture, for: id, scanID: receiptID) }
                        }
                    } else {
                        result = await analyze(item)
                    }
                    guard valid() else { throw CancellationError() }
                    scans[horizon]?.results[item.ticker] = result
                    scans[horizon]?.changes[item.ticker] = StockSageResearchFreshness.change(from: previousScan?.results[item.ticker], to: result)
                    if let receiptStore, let receiptID, let id = attemptID {
                        let terminal = result.verdict == nil ? (result.note.localizedCaseInsensitiveContains("interrupted") ? "interrupted" : "rejected") : "accepted"
                        receiptStore.finishAttempt(result, attemptID: id, scanID: receiptID, status: terminal)
                    }
                    attemptID = nil
                    activeSymbol = nil
                }
                scans[horizon]?.completedAt = Date()
                scans[horizon]?.status = "Scan finished · \(names.count) listings checked once. No orders created."
            } catch {
                if let receiptStore, let receiptID, let id = attemptID {
                    let result = Result(note: error is CancellationError ? "Interrupted before terminal analysis." : "Attempt failed before terminal analysis.")
                    receiptStore.finishAttempt(result, attemptID: id, scanID: receiptID,
                        status: error is CancellationError ? "interrupted" : "failed")
                }
                // A failed preflight is not a replacement run; restore captured data and its dates.
                if !didStart, let previousScan {
                    scans[horizon] = previousScan
                    scans[horizon]?.lastAttemptAt = requestedAt
                    scans[horizon]?.retainsEarlierResults = true
                }
                if !valid() {
                    let reason = Task.isCancelled ? "Stop requested" : (interruptionReason() ?? "Model settings or access changed")
                    let count = scans[horizon]?.results.count ?? 0
                    let retained = count == 0 ? "No stocks were checked; no results to retain." : "\(count) completed results retained; remaining listings were not checked."
                    scans[horizon]?.status = "Scan stopped · \(reason). \(retained) Run again when ready."
                } else if case ScanFailure.modelUnavailable(let detail) = error {
                    scans[horizon]?.status = "\(detail) No scan started. Open Catalysts → Explanation model, finish setup, then Run again."
                } else {
                    scans[horizon]?.status = "Scan incomplete: US directory or dated market activity could not be verified. Check Massive settings and retry."
                }
                if !didStart, previousScan != nil {
                    scans[horizon]?.status += " Earlier scan data retained; no new listings checked."
                }
            }
            if let receiptStore, let receiptID {
                receiptStore.finish(scanID: receiptID, status: scans[horizon]?.status ?? "finished")
                if receiptStore.persistenceFailed(scanID: receiptID) { scans[horizon]?.status += " Receipt persistence failed; durable coverage is unavailable." }
            }
            scans[horizon]?.attemptFinishedAt = Date()
        }
        return true
    }
    func stop() {
        guard let running else { return }
        task?.cancel(); activeSymbol = nil
        scans[running]?.status = "Stopping scan · keeping completed results…"
    }

    func start(_ horizon: Horizon, store: StockSageStore) {
        guard task == nil else { return }
        guard let config = StockSageAIAssessments.configuration, StockSageMassive.isConfigured,
              ToolPolicy.isExternalAllowed, !store.isSampleData else {
            let attemptAt = Date()
            let retained = !(scans[horizon]?.results.isEmpty ?? true)
            scans[horizon, default: Scan()].lastAttemptAt = attemptAt
            scans[horizon]?.attemptFinishedAt = attemptAt
            scans[horizon]?.retainsEarlierResults = retained
            scans[horizon]?.status = "Enable web access, Massive and the local Qwen model in Settings. No scan started."
                + (retained ? " Earlier scan data retained; no new listings checked." : "")
            return
        }
        let key = StockSageMassive.apiKey
        let credentialRevision = StockSageMassive.credentialRevision()
        let revision = StockSageLocalModelServer.settingsRevision()
        let interruptionReason: @MainActor () -> String? = {
            if StockSageLocalModelServer.isShuttingDown { return "StockSage is closing" }
            if !ToolPolicy.isExternalAllowed { return "Web access was disabled" }
            if store.isSampleData { return "The app switched to sample data" }
            if StockSageMassive.apiKey != key || StockSageMassive.credentialRevision() != credentialRevision {
                return "Massive credentials changed"
            }
            if StockSageAIAssessments.configuration != config || StockSageLocalModelServer.settingsRevision() != revision {
                return "Model settings changed"
            }
            return nil
        }
        let allowed: @MainActor () -> Bool = { interruptionReason() == nil }
        var isOllama = false
        _ = start(horizon, allowed: allowed, interruptionReason: interruptionReason, universe: {
            let probe = await StockSageLocalModelServer.prepare(config, stillValid: allowed)
            guard probe.reachable, probe.hasModel else { throw ScanFailure.modelUnavailable(probe.detail) }
            isOllama = probe.isOllama
            return try await StockSageResearchUniverse.fetch(key: key, allowed: allowed)
        }, analyze: { item in
            await Self.analyze(item, horizon: horizon, store: store, config: config,
                isOllama: isOllama, key: key, allowed: allowed)
        }, receiptStore: StockSageResearchReceiptStore.default,
        receiptAnalyzer: { item, _, observer in
            await Self.analyze(item, horizon: horizon, store: store, config: config,
                isOllama: isOllama, key: key, allowed: allowed, attemptObserver: observer)
        })
    }

    /// The injected closures exist for deterministic offline tests only, exactly as
    /// `fetchUniverse` and `completeDetailed` already allow. Production passes none of them and
    /// reaches the real endpoints. Without them this function — which owns the evidence budget,
    /// the freshness gates and the verdict acceptance — had no test at all.
    ///
    /// All FOUR are required for an offline test, not just the two transports: the Benzinga
    /// client and the news service are singletons that consult the real web gate and the real
    /// credentials, so a test that injected only the transports would still issue real PAID
    /// requests. Measured 2026-09-10: it did — seven Benzinga pages came back "answered".
    static func analyze(_ item: Listing, horizon: Horizon, store: StockSageStore,
        config: StockSageLocalModelServer.Config, isOllama: Bool, key: String,
        allowed: @escaping @MainActor () -> Bool,
        historyTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        modelTransport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
        benzingaSnapshot: ((String, Date) async -> StockSageBenzinga.Snapshot)? = nil,
        newsObservation: ((String, Date, StockSageBenzinga.Page?) async -> StockSageNewsService.Observation)? = nil,
        evidenceIsCurrent: ((StockSageBenzinga.Snapshot) -> Bool)? = nil,
        attemptObserver: ReceiptObserver? = nil) async -> Result {
        guard item.currency_name?.lowercased() == "usd" else {
            return .init(note: "USD price currency not confirmed; listing retained, no opinion.")
        }
        guard validTicker(item.ticker), allowed(), !Task.isCancelled,
              let dates = StockSageMassive.historyDates(for: "1y"),
              let url = URL(string: StockSageMassive.host + "/v2/aggs/ticker/\(item.ticker)/range/1/day/\(dates.from)/\(dates.to)?adjusted=true&sort=asc&limit=5000") else {
            return .init(note: "Unsupported symbol or request cancelled; no opinion.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let historyFetch: () async throws -> (Data, URLResponse) = {
            if let historyTransport { return try await historyTransport(request) }
            return try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000)
        }
        guard let (data, historyResponse) = try? await historyFetch(),
              allowed(), !Task.isCancelled, (historyResponse as? HTTPURLResponse)?.statusCode == 200,
              let raw = parseResearchHistory(data, symbol: item.ticker),
              let history = completedHistory(raw, at: Date()) else {
            return .init(note: "Need at least 30 valid, completed daily bars and a bar within four days. History missing, stale or malformed; no opinion.")
        }
        let referenceClose = (value: history.closes.last!, at: history.dates.last!) // completedHistory checked both arrays.
        let ideas = await StockSageStore.buildIdeas(defs: [.init(symbol: item.ticker, market: "US · \(item.primary_exchange ?? "exchange unconfirmed")")], histories: [item.ticker: history])
        guard allowed(), !Task.isCancelled, let idea = ideas.first else { return .init(note: "Analysis interrupted or unsupported history.") }
        let newsAt = Date()
        let benzinga: StockSageBenzinga.Snapshot
        if let benzingaSnapshot {
            benzinga = await benzingaSnapshot(item.ticker, newsAt)
        } else {
            benzinga = await StockSageBenzingaClient.shared.snapshot(for: item.ticker, now: newsAt, fresh: true, companyName: item.name)
        }
        let evidenceAllowed: @MainActor () -> Bool = {
            allowed() && !Task.isCancelled
                && (evidenceIsCurrent?(benzinga) ?? StockSageBenzingaClient.shared.isCurrent(benzinga))
        }
        // The check between the two fetches is deliberate: a revoked permission must stop the
        // second one. Keeping them as separate seams preserves that ordering exactly.
        guard evidenceAllowed() else { return .init(note: "Analysis interrupted.") }
        let newsPage = benzinga.pages.first { $0.query.product == .news }
        let news: StockSageNewsService.Observation
        if let newsObservation {
            news = await newsObservation(item.ticker, newsAt, newsPage)
        } else {
            news = await StockSageNewsService.observation(for: item.ticker, limit: 3, now: newsAt,
                                                          benzingaPage: newsPage, companyName: item.name)
        }
        guard evidenceAllowed() else { return .init(note: "Analysis interrupted.") }
        let assessmentAt = Date()
        let catalyst = store.catalystChain[item.ticker]
        let instrument = StockSageResearchInstrument(symbol: item.ticker, name: item.name, providerType: item.type)
        let context = StockSageAIAssessment.Context(idea: idea, earnings: catalyst,
            company: store.companyEventChecks[item.ticker] ?? [:], at: assessmentAt, newsObservation: news, quotedInUSD: true, benzinga: benzinga, instrument: instrument)
        var horizonFacts = ["Requested holding horizon: \(horizon.rawValue). Research only, no orders or position management. Reference entry is the last completed split-adjusted daily close, NOT a live quote. Current daily candle excluded."]
        horizonFacts.append(instrument.fact)
        let temporalEvents = StockSageResearchHorizonCalendar.capturedEvents(
            benzinga: benzinga, catalyst: catalyst, at: assessmentAt,
            excludingProducts: instrument.excludedProducts)
        horizonFacts.append(StockSageResearchHorizonCalendar.mandatoryFact(
            at: assessmentAt, horizon: horizon, events: temporalEvents))
        for period in [7, 14] {
            if let value = StockSageIndicators.returnOverPeriod(history.closes, period: period), value.isFinite {
                horizonFacts.append("Observed return over the last \(period) completed daily bars: \(value)%. Bar window ends \(history.dates.last!.ISO8601Format()). Historical change, not an expected return.")
            }
        }
        // Pack to the model's real allowance rather than a hardcoded 12,000 bytes; the horizon
        // facts are mandatory (they define the requested holding period and the reference entry)
        // and are never dropped. Omissions are disclosed in the returned note.
        let optionalFacts = context.facts(maximumUTF8Bytes: 12_000).filter { $0 != instrument.fact }
        guard let fitted = StockSageAIAssessment.fittedResearchPrompt(
                optional: optionalFacts, mandatory: horizonFacts,
                system: { _ in horizon.instructions },
                outputTokens: Self.researchOutputTokens) else {
            return .init(facts: horizonFacts,
                         note: "Evidence could not be reduced to the model context budget without dropping a mandatory horizon fact; no opinion.", referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
        }
        let facts = fitted.facts
        let trimmedNote = fitted.isComplete
            ? ""
            : " \(fitted.omitted) of \(optionalFacts.count) optional evidence records were omitted to fit the context budget."
        guard context.canAssess(at: Date()) else { return .init(facts: facts, note: "Evidence exceeded the age or size limit; no opinion." + trimmedNote, referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary) }
        let response = await StockSageAIAssessment.complete(config, isOllama: isOllama,
            system: fitted.system, user: fitted.user, facts: facts,
            maxTokens: Self.researchOutputTokens,
            stillValid: { evidenceAllowed() && context.canAssess(at: Date()) }, transport: modelTransport,
            attemptObserver: attemptObserver)
        guard evidenceAllowed() else { return .init(note: "Analysis interrupted.") }
        // A verdict truncated at the output limit is refused, exactly as in paper research.
        if case .success(let completion) = response, StockSageLocalModelServer.rejectsTruncatedOutput(completion) {
            return .init(facts: facts,
                         note: "No verified opinion. The model stopped at the output limit before finishing; a truncated verdict is not accepted." + trimmedNote, referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
        }
        guard context.canAssess(at: Date()), case .success(let completion) = response else {
            return .init(facts: facts, note: "No verified opinion. " + StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0) + trimmedNote, referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
        }
        switch StockSageAIAssessment.validate(completion.text, facts: facts) {
        case .success(let verdict):
            guard instrument.allows(verdict) else {
                return .init(facts: facts, note: "No verified opinion. The ETF answer used excluded corporate earnings or analyst-target language." + trimmedNote,
                             model: config.model, validationOutcome: .rejected, validationFailure: "instrumentApplicability",
                             referenceClose: referenceClose, newsCheckedAt: news.latestCheckAt,
                             newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
            }
            return .init(verdict: verdict, levels: levels(history: history, action: verdict.action, at: Date()),
                facts: facts, note: "Unvalidated Qwen research · \(horizon.rawValue). No order created." + trimmedNote,
                model: config.model, validationOutcome: .validated, referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
        case .failure(let failure):
            return .init(facts: facts,
                note: "No verified opinion. " + StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0) + trimmedNote,
                model: config.model, validationOutcome: .rejected, validationFailure: failure.rawValue,
                referenceClose: referenceClose,
                         newsCheckedAt: news.latestCheckAt, newestNewsAt: news.items.map(\.date).max(), newsCheckSummary: news.summary)
        }
    }
}
