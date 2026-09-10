import Foundation

/// One production owner for bounded Massive/Benzinga evidence and generic-news fallback.
/// No persisted cache, credential projection, pagination, retries, or quote/trading changes.
@MainActor final class StockSageBenzingaClient {
    private typealias B = StockSageBenzinga
    static let shared = StockSageBenzingaClient(
        key: { StockSageMassive.apiKey },
        revision: { StockSageMassive.credentialRevision() },
        allowed: { ToolPolicy.isExternalAllowed },
        policyRevision: { AppSettings.policyRevision() })

    private struct Capture: Equatable, Sendable {
        let key: String
        let revision: String?
        let allowed: Bool
        let policyRevision: String?
        let epoch: String
    }
    private enum RequestKey: Hashable {
        case page(B.Query)
        // Nearby moving windows share only after exact interval/cutoff checks below.
        case newsWindow(String, String)
        case fallback(URL)
    }
    private struct CacheEntry {
        let page: B.Page
        var access: UInt64
    }
    private enum Output {
        case page(B.Page)
        case raw(Data, URLResponse)
    }
    private final class Job {
        let id = UUID()
        let key: RequestKey
        let query: B.Query?
        let request: URLRequest
        let capture: Capture
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var waiters: [UUID: CheckedContinuation<Result<Output, B.Failure>, Never>] = [:]
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var finished = false

        init(key: RequestKey, query: B.Query?, request: URLRequest, capture: Capture) {
            self.key = key; self.query = query; self.request = request; self.capture = capture
        }
    }

    private let readKey: @MainActor () -> String
    private let readRevision: @MainActor () -> String?
    private let readAllowed: @MainActor () -> Bool
    private let readPolicyRevision: @MainActor () -> String?
    private let now: @MainActor () -> Date
    private let transport: @MainActor @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sleepUntil: @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void
    private var capture: Capture?
    private var cache: [RequestKey: CacheEntry] = [:]
    private var access: UInt64 = 0
    private var flights: [RequestKey: Job] = [:]
    private var queue: [Job] = []
    // A cancelled native operation keeps its slot until its task actually returns.
    private var running: [UUID: Job] = [:]
    private var cooldownUntil: Date?

    /// Getters are deliberately not evaluated in init. Tests inject synthetic state/transport.
    init(key: @escaping @MainActor () -> String,
         revision: @escaping @MainActor () -> String?,
         allowed: @escaping @MainActor () -> Bool,
         policyRevision: @escaping @MainActor () -> String? = { nil },
         now: @escaping @MainActor () -> Date = { Date() },
         session: URLSession? = nil,
         transport: (@MainActor @Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
         sleepUntil: @escaping @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        readKey = key; readRevision = revision; readAllowed = allowed; self.now = now
        readPolicyRevision = policyRevision
        self.sleepUntil = sleepUntil
        if let transport {
            self.transport = transport
        } else {
            let session = session ?? Self.nativeSession()
            self.transport = { request in
                try await StockSageHTTP.data(for: request, session: session, maximumBytes: 2_000_000)
            }
        }
    }

    private static func nativeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
    }

    /// Receipt validity, not transport eligibility. Offline/no-key status-only receipts are valid.
    func isCurrent(_ generation: String?) -> Bool {
        generation != nil && synchronize().epoch == generation
    }

    func isCurrent(_ snapshot: StockSageBenzinga.Snapshot) -> Bool {
        isCurrent(snapshot.credentialGeneration)
    }

    /// Forget cached HTTP 401/402/403 only; no request, epoch change, or cooldown reset.
    func clearAuthorizationFailures() {
        cache = cache.filter {
            switch $0.value.page.status {
            case .unavailable(.unauthorized), .unavailable(.entitlement): return false
            default: return true
            }
        }
    }

    private func synchronize() -> Capture {
        let key = readKey(), revision = readRevision(), allowed = readAllowed()
        let policyRevision = readPolicyRevision()
        if let capture, capture.key == key, capture.revision == revision, capture.allowed == allowed,
           capture.policyRevision == policyRevision {
            return capture
        }
        let next = Capture(key: key, revision: revision, allowed: allowed, policyRevision: policyRevision, epoch: UUID().uuidString)
        capture = next
        cache.removeAll()
        // Cooldown survives policy/key toggles: neither is permission to evade Retry-After.
        for job in Array(flights.values) {
            finish(job, .failure(allowed ? .obsoleteCredential : .policyDenied))
            job.operation?.cancel()
        }
        return next
    }

    private func receiptFailure(_ original: Capture) -> B.Failure? {
        let current = synchronize()
        guard current.epoch != original.epoch else { return nil }
        return current.allowed ? .obsoleteCredential : .policyDenied
    }

    private func admissionFailure(_ original: Capture) -> B.Failure? {
        if let failure = receiptFailure(original) { return failure }
        if !original.allowed { return .policyDenied }
        if original.key.isEmpty { return .missingCredential }
        if let until = cooldownUntil, now() < until { return .throttled }
        return nil
    }

    private func unavailable(_ query: B.Query, _ original: Capture, _ failure: B.Failure) -> B.Page {
        B.Page(query: query, checkedAt: now(), credentialGeneration: original.epoch,
               status: .unavailable(failure), records: [], excludedCount: 0, hasMore: false)
    }

    func page(for query: StockSageBenzinga.Query,
              recheckAuthorization: Bool = false) async -> StockSageBenzinga.Page {
        let original = synchronize()
        if Task.isCancelled { return unavailable(query, original, .cancelled) }
        if !original.allowed { return unavailable(query, original, .policyDenied) }
        if original.key.isEmpty { return unavailable(query, original, .missingCredential) }
        guard let request = B.request(for: query, key: original.key) else {
            return unavailable(query, original, .invalidQuery)
        }
        let key = requestKey(query)
        if var cached = cache[key] {
            let age = now().timeIntervalSince(cached.page.checkedAt)
            let denial = cached.page.status == .unavailable(.unauthorized)
                || cached.page.status == .unavailable(.entitlement)
            if age >= 0, age < query.product.cacheTTL,
               compatible(cached.page.query, query), !(recheckAuthorization && denial) {
                access &+= 1; cached.access = access; cache[key] = cached
                return revalidate(cached.page, for: query)
            }
            cache.removeValue(forKey: key)
        }
        if let failure = admissionFailure(original) { return unavailable(query, original, failure) }
        // An earlier caller's wider/different window cannot supply this caller's result.
        let flightKey: RequestKey
        if let existing = flights[key], let prior = existing.query, !compatible(prior, query) {
            flightKey = .page(query)
        } else { flightKey = key }
        let result = await wait(key: flightKey, query: query, request: request, capture: original)
        if Task.isCancelled { return unavailable(query, original, .cancelled) }
        if let failure = receiptFailure(original) { return unavailable(query, original, failure) }
        switch result {
        case .success(.page(let page)): return revalidate(page, for: query)
        case .failure(let failure): return unavailable(query, original, failure)
        case .success(.raw): return unavailable(query, original, .malformed)
        }
    }

    /// Same queue, deadline, cooldown and epoch as dedicated evidence; no second admission layer.
    /// Non-200 HTTP responses are returned so the news adapter preserves its ordered attempt status.
    func newsFallback(for request: URLRequest, credentialGeneration: String?) async throws -> (Data, URLResponse) {
        let original = synchronize()
        if Task.isCancelled { throw B.Failure.cancelled }
        guard credentialGeneration == original.epoch else { throw B.Failure.obsoleteCredential }
        if let failure = admissionFailure(original) { throw failure }
        guard let request = fallbackRequest(request, key: original.key), let url = request.url else {
            throw B.Failure.invalidQuery
        }
        let result = await wait(key: .fallback(url), query: nil, request: request, capture: original)
        if Task.isCancelled { throw B.Failure.cancelled }
        if let failure = receiptFailure(original) { throw failure }
        switch result {
        case .success(.raw(let data, let response)): return (data, response)
        case .failure(let failure): throw failure
        case .success(.page): throw B.Failure.malformed
        }
    }

    private func wait(key: RequestKey, query: B.Query?, request: URLRequest,
                      capture: Capture) async -> Result<Output, B.Failure> {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .failure(.cancelled)); return }
                if let failure = admissionFailure(capture) {
                    continuation.resume(returning: .failure(failure)); return
                }
                let job: Job
                if let existing = flights[key] {
                    job = existing
                } else {
                    job = Job(key: key, query: query, request: request, capture: capture)
                    flights[key] = job; queue.append(job)
                    job.timer = Task { @MainActor in
                        do {
                            try await self.sleepUntil(job.deadline)
                            guard !Task.isCancelled, !job.finished else { return }
                            let failure = self.receiptFailure(job.capture) ?? .timedOut
                            self.finish(job, .failure(failure))
                            job.operation?.cancel()
                        } catch { /* Owned timer cancellation, not a provider result. */ }
                    }
                }
                job.waiters[waiter] = continuation
                drain()
            }
        } onCancel: {
            Task { @MainActor in
                guard let job = self.flights[key], job.capture.epoch == capture.epoch,
                      let continuation = job.waiters.removeValue(forKey: waiter) else { return }
                continuation.resume(returning: .failure(.cancelled))
                if job.waiters.isEmpty {
                    self.finish(job, .failure(.cancelled))
                    job.operation?.cancel()
                }
            }
        }
    }

    private func drain() {
        while running.count < 3, !queue.isEmpty {
            let job = queue.removeFirst()
            guard !job.finished else { continue }
            if let failure = admissionFailure(job.capture) {
                finish(job, .failure(failure)); continue
            }
            if ContinuousClock.now >= job.deadline {
                finish(job, .failure(.timedOut)); continue
            }
            running[job.id] = job
            job.operation = Task { @MainActor in
                defer {
                    self.running.removeValue(forKey: job.id)
                    job.operation = nil
                    self.drain()
                }
                guard !job.finished else { return }
                do {
                    try Task.checkCancellation()
                    if let failure = self.admissionFailure(job.capture) { throw failure }
                    let (data, response) = try await self.transport(job.request)
                    try Task.checkCancellation()
                    if let failure = self.receiptFailure(job.capture) { throw failure }
                    guard !job.finished else { return }
                    guard ContinuousClock.now < job.deadline else { throw B.Failure.timedOut }
                    guard data.count <= 2_000_000 else { throw B.Failure.oversized }
                    guard let http = response as? HTTPURLResponse, response.url == job.request.url else {
                        throw B.Failure.transport
                    }
                    if http.statusCode == 429 {
                        let until = self.now().addingTimeInterval(Self.retryDelay(
                            http.value(forHTTPHeaderField: "Retry-After"), now: self.now()))
                        self.cooldownUntil = max(self.cooldownUntil ?? until, until)
                    }
                    if let query = job.query {
                        if http.statusCode == 429 { throw B.Failure.throttled }
                        let page: B.Page
                        if http.statusCode == 200 {
                            page = B.parse(data, query: query, checkedAt: self.now(),
                                           credentialGeneration: job.capture.epoch)
                        } else {
                            let failure: B.Failure = http.statusCode == 401 ? .unauthorized
                                : (http.statusCode == 402 || http.statusCode == 403) ? .entitlement : .http(http.statusCode)
                            page = self.unavailable(query, job.capture, failure)
                        }
                        self.remember(page, key: job.key)
                        self.finish(job, .success(.page(page)))
                    } else {
                        self.finish(job, .success(.raw(data, response)))
                    }
                } catch {
                    guard !job.finished else { return }
                    let failure = self.receiptFailure(job.capture)
                        ?? (Task.isCancelled ? .cancelled : nil)
                        ?? (error as? B.Failure)
                        ?? ((error as? URLError)?.code == .dataLengthExceedsMaximum ? .oversized : nil)
                        ?? ((error as? URLError)?.code == .timedOut ? .timedOut : .transport)
                    self.finish(job, .failure(failure))
                }
            }
        }
    }

    private func finish(_ job: Job, _ result: Result<Output, B.Failure>) {
        guard !job.finished else { return }
        job.finished = true
        if flights[job.key] === job { flights.removeValue(forKey: job.key) }
        queue.removeAll { $0 === job }
        job.timer?.cancel(); job.timer = nil
        let waiters = job.waiters.values
        job.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func remember(_ page: B.Page, key: RequestKey) {
        access &+= 1
        cache[key] = CacheEntry(page: page, access: access)
        // At most 501 entries here: a linear oldest-access lookup avoids another index.
        if cache.count > 500, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    private func requestKey(_ query: B.Query) -> RequestKey {
        guard let window = window(query) else { return .page(query) }
        let delta = Decimal(now().timeIntervalSince1970) - window.upper
        guard delta >= 0, delta < 30, window.upper - window.lower <= 604_800 else { return .page(query) }
        return .newsWindow(query.subject.uppercased(), NSDecimalNumber(decimal: window.upper - window.lower).stringValue)
    }

    private func window(_ query: B.Query) -> (lower: Decimal, upper: Decimal)? {
        guard query.product == .news,
              let lower = StockSageNewsService.publicationDate(query.from)?.instant,
              let upper = StockSageNewsService.publicationDate(query.through)?.instant,
              lower <= upper else { return nil }
        return (lower, upper)
    }

    private func compatible(_ first: B.Query, _ next: B.Query) -> Bool {
        if first == next { return true }
        guard first.subject.uppercased() == next.subject.uppercased(),
              let a = window(first), let b = window(next),
              a.upper - a.lower == b.upper - b.lower else { return false }
        let delta = b.upper - a.upper
        return delta >= 0 && delta < 30
    }

    private func revalidate(_ page: B.Page, for query: B.Query) -> B.Page {
        guard let window = window(query), page.status == .answered || page.status == .partial else { return page }
        let records = page.records.filter {
            guard let instant = StockSageNewsService.publicationDate($0.published)?.instant else { return false }
            return instant >= window.lower && instant <= window.upper
        }
        let removed = page.records.count - records.count
        guard removed > 0 else { return page }
        return B.Page(query: page.query, checkedAt: page.checkedAt, credentialGeneration: page.credentialGeneration,
                      status: .partial, records: records, excludedCount: page.excludedCount + removed, hasMore: page.hasMore)
    }

    private func fallbackRequest(_ input: URLRequest, key: String) -> URLRequest? {
        guard input.httpMethod == nil || input.httpMethod == "GET",
              input.httpBody == nil, input.httpBodyStream == nil,
              let url = input.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "api.massive.com", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/v2/reference/news", url.absoluteString.utf8.count <= 4_096,
              !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        let items = parts.queryItems ?? []
        let names = Set(items.map(\.name))
        guard names.count == items.count,
              names.isSubset(of: ["ticker", "limit", "order", "sort", "published_utc.gte", "published_utc.lte"]),
              let ticker = items.first(where: { $0.name == "ticker" })?.value,
              StockSageMassive.covers(ticker), ticker == ticker.uppercased(),
              let limitText = items.first(where: { $0.name == "limit" })?.value,
              let limit = Int(limitText), (1...5).contains(limit) else { return nil }
        for item in items {
            guard let value = item.value else { return nil }
            if item.name == "order", value != "asc" && value != "desc" { return nil }
            if item.name == "sort", value != "published_utc" { return nil }
            if item.name.hasPrefix("published_utc."), StockSageNewsService.publicationDate(value) == nil { return nil }
        }
        let lower = items.first { $0.name == "published_utc.gte" }?.value.flatMap { StockSageNewsService.publicationDate($0)?.instant }
        let upper = items.first { $0.name == "published_utc.lte" }?.value.flatMap { StockSageNewsService.publicationDate($0)?.instant }
        if let lower, let upper, lower > upper { return nil }
        parts.queryItems = items.sorted { $0.name < $1.name }
        guard let safeURL = parts.url else { return nil }
        var request = URLRequest(url: safeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func retryDelay(_ value: String?, now: Date) -> TimeInterval {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return 30 }
        if let seconds = Double(text) { return seconds.isFinite && seconds >= 0 ? min(seconds, 300) : 30 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return 30 }
        return min(300, max(0, date.timeIntervalSince(now)))
    }

    func snapshot(symbol: String) async -> StockSageBenzinga.Snapshot {
        await snapshot(for: symbol, now: now())
    }

    /// Caller time bounds source selection only. Local checked/captured times use the injected clock.
    func snapshot(for symbol: String, now bounds: Date = Date()) async -> StockSageBenzinga.Snapshot {
        let original = synchronize()
        let symbol = symbol.uppercased()
        let formatter = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let baseQueries = B.Product.allCases.filter { $0 != .analysts && $0 != .firms }.map { product in
            B.Query(product: product, subject: symbol,
                    from: product == .news && bounds.timeIntervalSince1970.isFinite ? bounds.addingTimeInterval(-7 * 86_400).formatted(formatter) : nil,
                    through: product == .news && bounds.timeIntervalSince1970.isFinite ? bounds.formatted(formatter) : nil)
        }
        func withheld(_ queries: [B.Query], _ failure: B.Failure) -> B.Snapshot {
            let pages = queries.map { unavailable($0, original, failure) }
            return B.Snapshot(symbol: symbol, capturedAt: now(), credentialGeneration: original.epoch, pages: pages)
        }
        if Task.isCancelled { return withheld(baseQueries, .cancelled) }
        if !bounds.timeIntervalSince1970.isFinite { return withheld(baseQueries, .invalidQuery) }
        let basePages = await pages(baseQueries, capture: original)
        if Task.isCancelled { return withheld(baseQueries, .cancelled) }
        if let failure = receiptFailure(original) { return withheld(baseQueries, failure) }
        let base = B.Snapshot(symbol: symbol, capturedAt: now(), credentialGeneration: original.epoch, pages: basePages)
        // Snapshot is the production retention boundary. Never join metadata from discarded rows.
        let records = base.pages.flatMap(\.records)
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return Array(ids.filter { seen.insert($0).inserted }.prefix(3))
        }
        let metadataQueries = unique(records.flatMap(\.analystIDs)).map {
            B.Query(product: .analysts, subject: $0, from: nil, through: nil)
        } + unique(records.flatMap(\.firmIDs)).map {
            B.Query(product: .firms, subject: $0, from: nil, through: nil)
        }
        let metadata = await pages(metadataQueries, capture: original)
        if Task.isCancelled { return withheld(baseQueries + metadataQueries, .cancelled) }
        if let failure = receiptFailure(original) { return withheld(baseQueries + metadataQueries, failure) }
        // Already-trimmed base pages + its omissions once; initializer adds only new metadata omissions.
        return B.Snapshot(symbol: symbol, capturedAt: now(), credentialGeneration: original.epoch,
                          pages: base.pages + metadata, omittedRecordCount: base.omittedRecordCount)
    }

    private func pages(_ queries: [B.Query], capture: Capture) async -> [B.Page] {
        await withTaskGroup(of: (Int, B.Page).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, await self.capturedPage(query, capture: capture)) }
            }
            var result: [(Int, B.Page)] = []
            for await item in group {
                if Task.isCancelled || self.receiptFailure(capture) != nil { group.cancelAll() }
                result.append(item)
            }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func capturedPage(_ query: B.Query, capture: Capture) async -> B.Page {
        if Task.isCancelled { return unavailable(query, capture, .cancelled) }
        if let failure = receiptFailure(capture) { return unavailable(query, capture, failure) }
        let page = await page(for: query)
        if Task.isCancelled { return unavailable(query, capture, .cancelled) }
        if let failure = receiptFailure(capture) { return unavailable(query, capture, failure) }
        return page
    }
}
