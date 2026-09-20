import Foundation
import Combine
import CoreFoundation

/// Manual, daily fundamental screening. No model, trade, watcher, or persistent research action.
@MainActor final class StockSageStockScreener: ObservableObject {
    static let shared = StockSageStockScreener()
    nonisolated static let ratiosPath = "/stocks/financials/v1/ratios"
    nonisolated static let maximumRows = 10_000
    nonisolated static let pageSize = 50

    nonisolated struct Row: Sendable, Identifiable {
        let symbol: String
        var name: String
        let date: String?
        let marketCap: Double?
        let metrics: [StockSageFundamentals.Metric]
        let note: String
        var id: String { symbol }
        func value(_ key: String) -> Double? { metrics.first { $0.key == key }?.value }
    }
    nonisolated enum MatchStatus: String, Sendable { case matched = "Matches", excluded = "Excluded", unavailable = "Unavailable" }
    nonisolated struct Match: Sendable { let status: MatchStatus; let reasons: [String] }
    nonisolated struct Filters: Sendable {
        var minimumCap: Double = 50_000_000
        var maximumCap: Double = 300_000_000
        var maximumPE: Double? = nil
        var minimumROA: Double? = nil // Fraction; the UI accepts percentage points.
        var maximumDebtEquity: Double? = nil
        var isValid: Bool {
            minimumCap.isFinite && maximumCap.isFinite && minimumCap >= 0 && maximumCap >= minimumCap
                && (maximumPE.map { $0.isFinite && $0 > 0 } ?? true)
                && (minimumROA.map(\.isFinite) ?? true)
                && (maximumDebtEquity.map { $0.isFinite && $0 >= 0 } ?? true)
        }
        func classify(_ row: Row) -> Match {
            guard isValid else { return .init(status: .unavailable, reasons: ["Correct the filter values."]) }
            var missing: [String] = [], failed: [String] = []
            if !row.note.isEmpty { missing.append(row.note) }
            if let cap = row.marketCap {
                if cap < minimumCap || cap > maximumCap { failed.append("Outside market-cap range") }
            } else { missing.append("Market cap unavailable") }
            if let ceiling = maximumPE {
                if let value = row.value("price_to_earnings"), value > 0 {
                    if value > ceiling { failed.append("P/E above ceiling") }
                } else { missing.append("Positive P/E unavailable") }
            }
            if let floor = minimumROA {
                if let value = row.value("return_on_assets") {
                    if value < floor { failed.append("ROA below minimum") }
                } else { missing.append("ROA unavailable") }
            }
            if let ceiling = maximumDebtEquity {
                if let value = row.value("debt_to_equity"), value >= 0 {
                    if value > ceiling { failed.append("Debt/equity above ceiling") }
                } else { missing.append("Nonnegative debt/equity unavailable") }
            }
            return .init(status: !missing.isEmpty ? .unavailable : (failed.isEmpty ? .matched : .excluded),
                         reasons: missing + failed)
        }
    }
    nonisolated enum Sort: String, CaseIterable, Identifiable, Sendable {
        case symbol = "Symbol", marketCap = "Market cap", pe = "P/E", roa = "ROA", debtEquity = "Debt/equity"
        var id: String { rawValue }
        func value(_ row: Row) -> Double? {
            switch self {
            case .symbol: nil
            case .marketCap: row.marketCap
            case .pe: row.value("price_to_earnings")
            case .roa: row.value("return_on_assets")
            case .debtEquity: row.value("debt_to_equity")
            }
        }
    }
    nonisolated struct Universe: Sendable {
        let listings: [StockSageHorizonResearch.Listing]
        let membership: StockSageSP500Constituents.Snapshot?
    }
    nonisolated struct Snapshot: Sendable {
        let rows: [Row]
        let retrievedAt: Date
        let receivedRows: Int
        let partial: Bool
        let note: String
        let membership: StockSageSP500Constituents.Provenance?
    }
    typealias UniverseLoader = @MainActor (String, @escaping @Sendable () -> Bool, StockSageMassive.Transport?) async throws -> Universe
    nonisolated private enum Failure: Error { case invalid, duplicate, denied }
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var status = "Load daily ratios to begin. Nothing is fetched automatically."
    @Published private(set) var isLoading = false
    @Published private(set) var qualitySymbol: String?
    @Published private(set) var quality: StockSageFundamentals.Snapshot?
    var isBusy: Bool { isLoading || qualitySymbol != nil }
    private let access: StockSageMassive.Access
    private let transport: StockSageMassive.Transport?
    private let secTransport: StockSageDisclosureService.Transport?
    private let clock: @Sendable () -> Date
    private let universe: UniverseLoader?
    private var generation = UUID()
    private var loadTask: Task<Snapshot, Error>?
    private var qualityTask: Task<StockSageFundamentals.Snapshot, Never>?

    init(access: StockSageMassive.Access = .init(), transport: StockSageMassive.Transport? = nil,
         secTransport: StockSageDisclosureService.Transport? = nil,
         clock: @escaping @Sendable () -> Date = Date.init, universe: UniverseLoader? = nil) {
        self.access = access; self.transport = transport; self.clock = clock; self.universe = universe
        // Injecting one provider must not accidentally allow another provider to escape offline fixtures.
        if let secTransport { self.secTransport = secTransport }
        else if transport != nil { self.secTransport = { _ in throw URLError(.notConnectedToInternet) } }
        else { self.secTransport = nil }
    }

    func load() async {
        guard !isBusy else { return }
        guard !StockSageStore.isRunningTests || transport != nil else {
            status = "Provider access is unavailable in a test host without an injected fixture."; return
        }
        let operation = UUID(); generation = operation
        let captured = access.capture()
        isLoading = true; status = "Loading listing coverage and latest daily ratios…"
        let capturedAccess = StockSageMassive.Access(key: { captured.key }, credentialRevision: { nil },
            policyRevision: { nil }, allowed: captured.isCurrent)
        let task = Task { try await Self.collect(access: capturedAccess, transport: transport, clock: clock, universe: universe) }
        loadTask = task
        defer { isLoading = false; loadTask = nil }
        do {
            let value = try await task.value
            guard generation == operation else { return }
            guard captured.isCurrent(), !Task.isCancelled else {
                status = "Screener unavailable: access changed or the load was cancelled; no new results were published."; return
            }
            snapshot = value; quality = nil
            status = value.note
        } catch {
            guard generation == operation else { return }
            status = "Screener unavailable: check market-data access and retry. A changed credential, blocked policy, cancellation or invalid response cannot publish new results. Any earlier dated snapshot remains visible."
        }
    }

    func companyQuality(for row: Row) async {
        guard !isBusy, snapshot?.rows.contains(where: { $0.symbol == row.symbol }) == true else { return }
        guard !StockSageStore.isRunningTests || transport != nil else { return }
        let operation = UUID(); generation = operation
        let captured = access.capture()
        guard !captured.key.isEmpty, captured.isCurrent() else { status = "Company quality unavailable: check data access."; return }
        qualitySymbol = row.symbol; quality = nil
        status = "Loading company quality for \(row.symbol)…"
        let at = clock()
        let capturedAccess = StockSageMassive.Access(key: { captured.key }, credentialRevision: { nil },
            policyRevision: { nil }, allowed: captured.isCurrent)
        let task = Task { await StockSageFundamentals.collect(symbol: row.symbol, asOf: at,
            access: capturedAccess, transport: transport, secTransport: secTransport, clock: clock) }
        qualityTask = task
        defer { qualitySymbol = nil; qualityTask = nil }
        let value = await task.value
        guard generation == operation, captured.isCurrent(), !Task.isCancelled else {
            if generation == operation { status = "Company quality cancelled or access changed; no new detail was published." }
            return
        }
        quality = value
        status = "Company quality captured for \(row.symbol). Read its source status and missing-data notes."
    }

    func cancel() {
        generation = UUID(); loadTask?.cancel(); qualityTask?.cancel()
        status = "Cancelled. Any earlier dated snapshot remains visible."
    }

    nonisolated static func sorted(_ rows: [Row], by sort: Sort, ascending: Bool) -> [Row] {
        rows.sorted { left, right in
            if sort == .symbol { return ascending ? left.symbol < right.symbol : left.symbol > right.symbol }
            switch (sort.value(left), sort.value(right)) {
            case let (a?, b?) where a != b: return ascending ? a < b : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.symbol < right.symbol
            }
        }
    }

    nonisolated static func request(key: String, next: String? = nil) -> URLRequest? {
        guard !key.isEmpty, (next?.utf8.count ?? 0) <= 8192,
              let url = URLComponents(string: next ?? StockSageMassive.host + ratiosPath + "?limit=1000"),
              url.scheme == "https", url.host == "api.massive.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil, url.percentEncodedPath == ratiosPath,
              url.queryItems?.contains(where: { $0.name.lowercased() == "apikey" }) != true,
              let target = url.url else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func parseRow(_ raw: [String: Any], asOf: Date) throws -> Row {
        guard let symbol = raw["ticker"] as? String, StockSageHorizonResearch.validTicker(symbol) else { throw Failure.invalid }
        let metrics = try StockSageFundamentals.parseRatio(raw, symbol: symbol, asOf: asOf)
        guard let day = raw["date"] as? String,
              let date = ISO8601DateFormatter().date(from: day + "T00:00:00Z") else { throw Failure.invalid }
        var cap: Double?
        if let input = raw["market_cap"], !(input is NSNull) {
            guard let number = input as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { throw Failure.invalid }
            if number.doubleValue > 0 { cap = number.doubleValue }
        }
        let stale = asOf.timeIntervalSince(date) > 7 * 86_400
        return .init(symbol: symbol, name: symbol, date: day, marketCap: cap, metrics: metrics,
                     note: stale ? "Daily ratios are older than the screener’s seven-calendar-day matching limit." : "")
    }

    static func join(universe: Universe, ratios: [String: Row], at now: Date) throws -> [Row] {
        guard universe.listings.count <= 50_000,
              Set(universe.listings.map(\.ticker)).count == universe.listings.count else { throw Failure.invalid }
        return universe.listings.compactMap { item -> Row? in
            var listing = item
            listing.sp500Membership = universe.membership?.membership(for: item.ticker)
            guard StockSageResearchUniverse.eligibleListing(listing, through: now) else { return nil }
            var row = ratios[listing.ticker] ?? Row(symbol: listing.ticker, name: listing.name, date: nil,
                marketCap: nil, metrics: [], note: "No usable daily ratio row in this capture; not treated as zero.")
            row.name = listing.name
            return row
        }.sorted { $0.symbol < $1.symbol }
    }

    /// Sequential directory, membership and ratio pages; Company quality cannot overlap this load.
    static func collect(access: StockSageMassive.Access, transport: StockSageMassive.Transport?,
                        clock: @escaping @Sendable () -> Date, universe loader: UniverseLoader? = nil) async throws -> Snapshot {
        let captured = access.capture(), started = clock()
        guard !captured.key.isEmpty, captured.isCurrent(), started.timeIntervalSince1970.isFinite else { throw Failure.denied }
        let universe: Universe
        if let loader { universe = try await loader(captured.key, captured.isCurrent, transport) }
        else {
            let guarded: StockSageMassive.Transport = { request in
                let response = try await StockSageMassive.response(for: request, maximumBytes: 4_000_000, transport: transport)
                return (response.0, response.1)
            }
            let directory = try await StockSageHorizonResearch.fetchUniverse(key: captured.key,
                allowed: captured.isCurrent, transport: guarded)
            let membership = try await StockSageSP500Constituents.fetch(allowed: captured.isCurrent, clock: clock, transport: transport)
            universe = .init(listings: directory, membership: membership)
        }
        guard captured.isCurrent() else { throw Failure.denied }
        var next: String?, visited: Set<URL> = [], ratios: [String: Row] = [:], seen: Set<String> = []
        var count = 0, partial = false, invalidRows = 0
        repeat {
            do {
                guard captured.isCurrent() else { throw Failure.denied }
                guard let request = request(key: captured.key, next: next), let url = request.url,
                      visited.insert(url).inserted, visited.count <= 20 else { throw Failure.invalid }
                let (data, response) = try await StockSageMassive.response(for: request, maximumBytes: 4_000_000, transport: transport)
                guard captured.isCurrent() else { throw Failure.denied }
                guard response.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["status"] as? String == "OK", let rows = object["results"] as? [[String: Any]],
                      rows.count <= 1000 else { throw Failure.invalid }
                let at = clock()
                guard at.timeIntervalSince1970.isFinite, at >= started else { throw Failure.invalid }
                for raw in rows {
                    guard count < maximumRows else { partial = true; break }
                    count += 1
                    guard let symbol = raw["ticker"] as? String, StockSageHorizonResearch.validTicker(symbol) else { invalidRows += 1; continue }
                    guard seen.insert(symbol).inserted else { throw Failure.duplicate }
                    if let row = try? parseRow(raw, asOf: at) { ratios[symbol] = row }
                    else { invalidRows += 1 }
                }
                if let value = object["next_url"], !(value is NSNull) {
                    guard let text = value as? String, !text.isEmpty else { throw Failure.invalid }
                    next = text
                } else { next = nil }
                if count >= maximumRows, next != nil { partial = true; break }
            } catch {
                guard captured.isCurrent(), !(error is CancellationError) else { throw Failure.denied }
                if case Failure.duplicate = error { throw error }
                guard count > 0 else { throw error }
                partial = true; break
            }
        } while next != nil
        let end = clock()
        guard captured.isCurrent(), end.timeIntervalSince1970.isFinite, end >= started else { throw Failure.denied }
        let rows = try join(universe: universe, ratios: ratios, at: end)
        guard !rows.isEmpty else { throw Failure.invalid }
        let note = (partial ? "Partial capture: ratio pagination is incomplete. " : "Daily ratio capture completed. ")
            + "\(count) provider rows received; \(invalidRows) invalid rows unavailable. \(rows.count) supported listings are shown, including missing coverage. No model assessment or trade signal was generated."
        return .init(rows: rows, retrievedAt: end, receivedRows: count, partial: partial, note: note,
                     membership: universe.membership?.provenance)
    }
}
