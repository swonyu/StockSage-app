import Foundation
import Combine

/// Manual research only. Deliberately has no paper book, order, journal or broker writer.
@MainActor
final class StockSageHorizonResearch: ObservableObject {
    static let shared = StockSageHorizonResearch()
    static let scanLimit = 500
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
        var verdict: StockSageAIAssessment.Verdict?
        var levels: Levels?
        var facts: [String] = []
        var note: String
        var at: Date = Date()
        var model: String = ""
    }
    struct Scan {
        var listings: [Listing] = []
        var results: [String: Result] = [:]
        var status = "Press Run to research up to \(StockSageHorizonResearch.scanLimit) US listings once."
        var at: Date?
    }
    @Published private(set) var scans: [Horizon: Scan] = [:]
    @Published private(set) var running: Horizon?
    @Published private(set) var activeSymbol: String?
    private var task: Task<Void, Never>?
    private enum ScanFailure: Error { case modelUnavailable }
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
               universe: @escaping @MainActor () async throws -> [Listing],
               analyze: @escaping @MainActor (Listing) async -> Result) -> Bool {
        guard task == nil, allowed() else { return false }
        running = horizon
        scans[horizon] = Scan(status: "Loading US directory · research capped at \(Self.scanLimit)…", at: Date())
        task = Task {
            defer { activeSymbol = nil; running = nil; task = nil }
            @MainActor func valid() -> Bool { !Task.isCancelled && allowed() }
            do {
                let directory = try await universe()
                guard valid() else { throw CancellationError() }
                guard Set(directory.map(\.ticker)).count == directory.count, directory.count <= 50_000 else { throw URLError(.cannotParseResponse) }
                // Preserve directory order; this cap is not an investment ranking or an index.
                let names = Array(directory.prefix(Self.scanLimit))
                scans[horizon]?.listings = names
                // ponytail: one manual worker limits additional local-model load while the independent
                // four-worker day scanner runs. No automatic repeat; parallelize only if model capacity allows.
                for item in names {
                    guard valid() else { throw CancellationError() }
                    activeSymbol = item.ticker
                    scans[horizon]?.status = "Checking \(item.ticker) · \(scans[horizon]?.results.count ?? 0)/\(names.count) finished"
                    let result = await analyze(item)
                    guard valid() else { throw CancellationError() }
                    scans[horizon]?.results[item.ticker] = result
                    activeSymbol = nil
                }
                scans[horizon]?.status = "Scan finished · \(names.count) listings checked once. No orders created."
            } catch {
                if !valid() {
                    scans[horizon]?.status = "Scan stopped · completed results retained; remaining listings were not checked."
                } else if error is ScanFailure {
                    scans[horizon]?.status = "Local Qwen could not be reached or the selected model is missing. Check Model settings and retry; no scan started."
                } else {
                    scans[horizon]?.status = "Scan incomplete: listing directory could not be verified. Check Massive settings and retry."
                }
            }
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
            scans[horizon, default: Scan()].status = "Enable web access, Massive and the local Qwen model in Settings. No scan started."
            return
        }
        let key = StockSageMassive.apiKey
        let revision = StockSageLocalModelServer.settingsRevision()
        let allowed: @MainActor () -> Bool = {
            ToolPolicy.isExternalAllowed && !store.isSampleData && StockSageMassive.apiKey == key
                && StockSageAIAssessments.configuration == config && StockSageLocalModelServer.settingsRevision() == revision
        }
        var isOllama = false
        _ = start(horizon, allowed: allowed, universe: {
            let probe = await StockSageLocalModelServer.probe(config, stillValid: allowed)
            guard probe.reachable, probe.hasModel else { throw ScanFailure.modelUnavailable }
            isOllama = probe.isOllama
            return try await Self.fetchUniverse(key: key, allowed: allowed)
        }, analyze: { item in
            await Self.analyze(item, horizon: horizon, store: store, config: config,
                isOllama: isOllama, key: key, allowed: allowed)
        })
    }

    private static func analyze(_ item: Listing, horizon: Horizon, store: StockSageStore,
        config: StockSageLocalModelServer.Config, isOllama: Bool, key: String,
        allowed: @MainActor () -> Bool) async -> Result {
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
        guard let (data, historyResponse) = try? await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000),
              allowed(), !Task.isCancelled, (historyResponse as? HTTPURLResponse)?.statusCode == 200,
              let raw = parseResearchHistory(data, symbol: item.ticker),
              let history = completedHistory(raw, at: Date()) else {
            return .init(note: "Need at least 30 valid, completed daily bars and a bar within four days. History missing, stale or malformed; no opinion.")
        }
        let ideas = await StockSageStore.buildIdeas(defs: [.init(symbol: item.ticker, market: "US · \(item.primary_exchange ?? "exchange unconfirmed")")], histories: [item.ticker: history])
        guard allowed(), !Task.isCancelled, let idea = ideas.first else { return .init(note: "Analysis interrupted or unsupported history.") }
        let news = await StockSageNewsService.observation(for: item.ticker, limit: 3)
        guard allowed(), !Task.isCancelled else { return .init(note: "Analysis interrupted.") }
        let context = StockSageAIAssessment.Context(idea: idea, earnings: store.catalystChain[item.ticker],
            company: store.companyEventChecks[item.ticker] ?? [:], at: Date(), newsObservation: news, quotedInUSD: true)
        var facts = context.facts + ["Requested holding horizon: \(horizon.rawValue). Research only, no orders or position management. Reference entry is the last completed split-adjusted daily close, NOT a live quote. Current daily candle excluded."]
        for period in [7, 14] {
            if let value = StockSageIndicators.returnOverPeriod(history.closes, period: period), value.isFinite {
                facts.append("Observed return over the last \(period) completed daily bars: \(value)%. Bar window ends \(history.dates.last!.ISO8601Format()). Historical change, not an expected return.")
            }
        }
        guard context.canAssess(at: Date()), facts.joined().utf8.count <= 12_000 else { return .init(facts: facts, note: "Evidence exceeded the age or size limit; no opinion.") }
        let response = await StockSageLocalModelServer.completeDetailed(config, isOllama: isOllama,
            system: horizon.instructions, user: StockSageAIAssessment.prompt(facts: facts), maxTokens: 192, stillValid: allowed)
        guard allowed(), !Task.isCancelled else { return .init(note: "Analysis interrupted.") }
        guard context.canAssess(at: Date()), case .success(let completion) = response,
              case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: facts) else {
            return .init(facts: facts, note: "No verified opinion. " + StockSageAIAssessments.failureSummary(response, facts: facts, leadCount: 0))
        }
        return .init(verdict: verdict, levels: levels(history: history, action: verdict.action, at: Date()),
            facts: facts, note: "Unvalidated Qwen research · \(horizon.rawValue). No order created.", model: config.model)
    }
}
