import Foundation

/// Lifecycle separated from the pure contracts/parser. Parent supplies its shared, policy-aware
/// transport; load MUST cancel at maximumBytes and enforce request.timeoutInterval while receiving.
/// There is no default transport, credential lookup, polling loop, or independent worker pool.
@MainActor
final class StockSageBenzingaEvidenceClient {
    typealias E = StockSageBenzingaEvidence
    struct Response: Sendable {
        let data: Data
        let status: Int
        var retryAfter: TimeInterval? = nil
    }
    typealias Load = @MainActor (URLRequest, _ maximumBytes: Int) async -> Result<Response, E.Failure>
    private struct Query: Hashable {
        let product: E.Product
        let symbol: String
        let referenceID: String?
    }
    private struct Cached {
        let observation: E.Observation
        let expires: Date
        var accessed: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<E.Observation, Never>
    }
    private let key: @MainActor () -> String
    private let permitted: @MainActor () -> Bool
    private let load: Load
    private let now: @MainActor () -> Date
    private var generation = UUID()
    private var access: UInt64 = 0
    private var cache: [Query: Cached] = [:]
    private var inFlight: [Query: Flight] = [:]
    private var cooldown: [E.Product: Date] = [:]
    var cachedQueryCount: Int { cache.count }

    init(key: @escaping @MainActor () -> String, permitted: @escaping @MainActor () -> Bool,
         now: @escaping @MainActor () -> Date = { Date() }, load: @escaping Load) {
        self.key = key; self.permitted = permitted; self.now = now; self.load = load
    }

    /// Call synchronously on provider credential OR policy/configuration changes, before publishing.
    /// Keep provider throttling across credential changes; changing keys must not cause a retry storm.
    func invalidate() {
        generation = UUID()
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll(); cache.removeAll()
    }

    func fetch(_ product: E.Product, symbol: String, referenceID: String? = nil,
               bypassAuthorizationCache: Bool = false) async -> E.Observation {
        func failed(_ reason: E.Failure) -> E.Observation {
            .unavailable(product, symbol: symbol, failure: reason)
        }
        guard permitted() else { return failed(.policyDenied) }
        guard !Task.isCancelled else { return failed(.cancelled) }
        guard let request = E.request(product, symbol: symbol, referenceID: referenceID, key: key()) else {
            return failed(product.isReference && referenceID == nil ? .missingReference : .requestUnavailable)
        }
        let query = Query(product: product, symbol: symbol.uppercased(), referenceID: referenceID)
        let capturedGeneration = generation
        let time = now()
        guard time.timeIntervalSince1970.isFinite else { return failed(.requestUnavailable) }
        if let until = cooldown[product], time < until { return failed(.cooldown) }
        if var hit = cache[query], time < hit.expires, time >= (hit.observation.checkedAt ?? time) {
            let denied: Bool
            if case .http(let status) = hit.observation.failure { denied = [401, 402, 403].contains(status) } else { denied = false }
            if !bypassAuthorizationCache || !denied {
                access &+= 1; hit.accessed = access; cache[query] = hit
                return hit.observation
            }
        }
        let task: Task<E.Observation, Never>
        let flightID: UUID
        if let existing = inFlight[query] { task = existing.task; flightID = existing.id }
        else {
            flightID = UUID()
            task = Task { @MainActor [self] in
                guard !Task.isCancelled else { return failed(.cancelled) }
                guard permitted() else { return failed(.policyDenied) }
                let response = await load(request, E.responseByteLimit)
                guard permitted() else { return failed(.policyDenied) }
                guard capturedGeneration == generation else { return failed(.configurationChanged) }
                guard !Task.isCancelled else { return failed(.cancelled) }
                let checked = now()
                guard checked.timeIntervalSince(time).isFinite, checked >= time,
                      checked.timeIntervalSince(time) <= 12 else { return failed(.timedOut) }
                let observation: E.Observation
                switch response {
                case .failure(let reason): observation = .unavailable(product, symbol: symbol, checkedAt: checked, failure: reason)
                case .success(let response):
                    if response.status == 429 {
                        let delay = response.retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60
                        cooldown[product] = checked.addingTimeInterval(min(3_600, max(1, delay)))
                    }
                    if response.data.count > E.responseByteLimit {
                        observation = .unavailable(product, symbol: symbol, checkedAt: checked, failure: .responseTooLarge)
                    } else if response.status != 200 {
                        observation = .unavailable(product, symbol: symbol, checkedAt: checked, failure: .http(response.status))
                    } else {
                        observation = E.parse(response.data, product: product, symbol: symbol,
                                              referenceID: referenceID, checkedAt: checked)
                    }
                }
                // Cancellation and policy/configuration failures are never reusable authorization.
                if observation.failure != .cancelled && observation.failure != .policyDenied && observation.failure != .configurationChanged {
                    access &+= 1
                    cache[query] = Cached(observation: observation,
                        expires: checked.addingTimeInterval(observation.state == .unavailable ? 30 : product.cacheSeconds), accessed: access)
                    if cache.count > 500, let oldest = cache.min(by: { $0.value.accessed < $1.value.accessed })?.key { cache.removeValue(forKey: oldest) }
                }
                return observation
            }
            inFlight[query] = Flight(id: flightID, task: task)
        }
        let observation = await task.value
        guard permitted() else { return failed(.policyDenied) }
        guard capturedGeneration == generation else { return failed(.configurationChanged) }
        if inFlight[query]?.id == flightID { inFlight.removeValue(forKey: query) }
        guard !Task.isCancelled else { return failed(.cancelled) }
        return observation
    }

    /// Sequential here; the parent transport owns the app-wide three-request budget. Do not
    /// invoke per quote tick. One captured snapshot is shared by all consumers of this research.
    func snapshot(symbol: String) async -> E.Snapshot {
        let capturedGeneration = generation
        var observations: [E.Observation] = []
        for product in E.Product.allCases where !product.isReference {
            observations.append(await fetch(product, symbol: symbol))
            if !permitted() || Task.isCancelled || capturedGeneration != generation { break }
        }
        if permitted(), !Task.isCancelled, capturedGeneration == generation {
            let records = observations.flatMap(\.records)
            let analystIDs = Array(Set(records.compactMap(\.analystID))).sorted()
            observations.append(await references(.analysts, ids: analystIDs, symbol: symbol))
            if permitted(), !Task.isCancelled, capturedGeneration == generation {
                let firmIDs = Array(Set((records + observations.flatMap(\.records)).compactMap(\.firmID))).sorted()
                observations.append(await references(.firms, ids: firmIDs, symbol: symbol))
            }
        }
        let reason: E.Failure? = !permitted() ? .policyDenied : (capturedGeneration != generation ? .configurationChanged : (Task.isCancelled ? .cancelled : nil))
        if let reason {
            observations = E.Product.allCases.map { .unavailable($0, symbol: symbol, failure: reason) }
        }
        return .init(symbol: symbol, capturedAt: now(), observations: observations)
    }

    private func references(_ product: E.Product, ids: [String], symbol: String) async -> E.Observation {
        guard !ids.isEmpty else { return .unavailable(product, symbol: symbol, failure: .missingReference) }
        let capturedGeneration = generation
        var parts: [E.Observation] = []
        for id in ids.prefix(3) {
            parts.append(await fetch(product, symbol: symbol, referenceID: id))
            if !permitted() || Task.isCancelled || capturedGeneration != generation { break }
        }
        let records = Array(parts.flatMap(\.records).prefix(E.retainedLimit))
        let failed = parts.contains { $0.state == .unavailable }
        let partial = ids.count > 3 || failed || parts.contains { $0.state == .partial } || parts.count < min(3, ids.count)
        let state: E.State = records.isEmpty ? (failed ? .unavailable : .empty) : (partial ? .partial : .available)
        return .init(product: product, symbol: symbol.uppercased(), checkedAt: parts.compactMap(\.checkedAt).max(),
            state: state, records: records, failure: parts.compactMap(\.failure).first,
            rejectedCount: parts.reduce(0) { $0 + $1.rejectedCount },
            omittedCount: max(0, ids.count - 3) + parts.reduce(0) { $0 + $1.omittedCount }, hasMore: parts.contains( where: \.hasMore))
    }
}
