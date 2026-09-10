import Foundation
import Combine

/// One whole-market Massive stocks socket; parsing and latest-value retention live off MainActor.
/// Foreground-only on iOS. Connection health is separate from per-symbol observation freshness.
@MainActor
final class StockSageLiveStream: ObservableObject {
    static let shared = StockSageLiveStream()
    @Published private(set) var isStreaming = false
    @Published private(set) var quotes: [String: StockSageNBBO] = [:]
    @Published private(set) var exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]
    @Published private(set) var diagnostics = StockSageFeedIngress.Metrics()
    @Published private(set) var connectionLabel = "Feed stopped"
    @Published private(set) var gapCount = 0
    private(set) var lastGap: String?
    private var delivered: [String: Tick] = [:]
    var subscribed: Set<String> {
        guard isStreaming else { return [] }
        let now = Date()
        return Set(StockSageStore.liveTicksForStore(delivered).values.filter { Self.isLiveObservation($0.timestamp, at: now) }.map(\.symbol))
    }
    fileprivate static let massiveHost = "wss://socket.massive.com/stocks"
    private var connection: StockSageLiveStreamConnection?
    private var publication: Task<Void, Never>?
    private var conditionTask: Task<Void, Never>?
    private var regularConditions: Set<Int64> = []
    private var conditionsAsOf: Date?
    private var exchangesAsOf: Date?
    private var referenceAttemptAt: Date?
    private var referenceGeneration = UUID()
    private static let referenceLifetime: TimeInterval = 86_400
    private var publicationCursor = 0

    nonisolated struct Tick: Sendable, Equatable {
        let symbol: String
        let price: Double
        let timestamp: Date
        var sequence: Int64? = nil
        var participantTime: Date? = nil
    }

    nonisolated enum Event: Sendable, Equatable {
        case status(String)
        case trade(Tick)
        case quote(StockSageNBBO)
    }

    /// Decode EVERY event, including mixed status/trade frames. A malformed element must not
    /// hide its valid siblings. https://massive.com/docs/websocket/quickstart
    nonisolated static func events(in text: String) -> [Event] {
        decode(Data(text.utf8)).events
    }

    nonisolated static func decode(_ data: Data) -> (events: [Event], rejected: Int) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return ([], 1) }
        let rows = (raw as? [Any]) ?? [raw]
        var oversizedMetadata = 0
        let events: [Event] = rows.compactMap { element in
            guard let row = element as? [String: Any] else { return nil }
            if row["ev"] as? String == "status", let status = row["status"] as? String {
                return .status(status)
            }
            guard let rawSymbol = row["sym"] as? String, let symbol = stockSymbol(rawSymbol),
                  let milliseconds = number(row["t"]), milliseconds > 0 else { return nil }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            switch row["ev"] as? String {
            case "T":
                guard let price = number(row["p"]), price > 0 else { return nil }
                let participant = number(row["pt"]).flatMap { $0 > 0 && $0 <= milliseconds ? Date(timeIntervalSince1970: $0 / 1_000) : nil }
                return .trade(Tick(symbol: symbol, price: price, timestamp: timestamp,
                                   sequence: integer(row["q"]), participantTime: participant))
            case "Q":
                guard let bid = number(row["bp"]), bid >= 0, let ask = number(row["ap"]), ask >= 0,
                      let bidSize = number(row["bs"]), bidSize >= 0,
                      let askSize = number(row["as"]), askSize >= 0 else { return nil }
                var quote = StockSageNBBO(symbol: symbol, bid: bid, ask: ask, bidSize: bidSize, askSize: askSize,
                                    bidExchange: integer(row["bx"]), askExchange: integer(row["ax"]),
                                    timestamp: timestamp, sequence: integer(row["q"]))
                quote.condition = integer(row["c"])
                if let raw = row["i"] {
                    if let array = raw as? [Any], array.count <= 64 {
                        let values = array.compactMap(integer)
                        quote.indicators = values.count == array.count ? values : nil
                    } else {
                        // Bound retained per-symbol metadata as well as frame/symbol counts.
                        // Preserve withdrawn sides; unknown metadata never qualifies costs.
                        quote.indicators = nil
                        if (raw as? [Any])?.count ?? 0 > 64 { oversizedMetadata += 1 }
                    }
                }
                return .quote(quote)
            default: return nil
            }
        }
        return (events, rows.count - events.count + oversizedMetadata)
    }

    /// Stocks socket namespace only. Preserve SIP preferred-share spelling (APTVpA).
    /// This is not permission to send these symbols through unrelated REST routes.
    nonisolated static func stockSymbol(_ raw: String) -> String? {
        let bytes = Array(raw.utf8)
        guard (1...32).contains(bytes.count), let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first),
              bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 }),
              !raw.hasSuffix("."), !raw.contains("..") else { return nil }
        // Bare lowercase user input remains compatible; mixed-case provider suffixes are exact.
        return raw == raw.lowercased() ? raw.uppercased() : raw
    }

    nonisolated static func displayQuote(for symbol: String, in quotes: [String: StockSageNBBO]) -> StockSageNBBO? {
        guard let key = stockSymbol(symbol), let quote = quotes[key], quote.matches(symbol) else { return nil }
        return quote
    }

    nonisolated static let maximumLiveAge: TimeInterval = 10
    nonisolated static func isLiveObservation(_ timestamp: Date?, at now: Date) -> Bool {
        guard let timestamp else { return false }
        return (0...maximumLiveAge).contains(now.timeIntervalSince(timestamp))
    }

    /// The runtime and deterministic tests use the same protocol state, without a live socket.
    nonisolated struct StreamState: Sendable {
        var symbolLimit = 32_768
        private(set) var capacityExceeded = false
        private(set) var isAuthorized = false
        private(set) var latestTrades: [String: Tick] = [:]
        private(set) var latestQuotes: [String: StockSageNBBO] = [:]

        mutating func consume(_ event: Event, requested _: Set<String> = [], now: Date) -> Tick? {
            switch event {
            case .status("auth_success"):
                isAuthorized = true
            case .status("auth_failed"), .status("error"), .status("connected"):
                self = StreamState(symbolLimit: symbolLimit)
            case .status:
                break // Informational/subscription messages do not revoke authentication.
            case .quote(let quote):
                guard isAuthorized, Self.valid(quote.symbol),
                      quote.supersedes(latestQuotes[quote.symbol], now: now) else { return nil }
                guard latestQuotes[quote.symbol] != nil || latestQuotes.count < symbolLimit else {
                    capacityExceeded = true; return nil
                }
                latestQuotes[quote.symbol] = quote
            case .trade(let tick):
                guard isAuthorized, Self.valid(tick.symbol), tick.price.isFinite, tick.price > 0,
                      StockSageStore.acceptsLiveTick(tick.timestamp, after: latestTrades[tick.symbol]?.timestamp,
                          massiveTradeSequence: tick.sequence,
                          afterMassiveTradeSequence: latestTrades[tick.symbol]?.sequence, now: now)
                else { return nil }
                guard latestTrades[tick.symbol] != nil || latestTrades.count < symbolLimit else {
                    capacityExceeded = true; return nil
                }
                latestTrades[tick.symbol] = tick
                return tick
            }
            return nil
        }

        private static func valid(_ symbol: String) -> Bool { StockSageLiveStream.stockSymbol(symbol) != nil }

        func coveredSymbols(at now: Date) -> Set<String> {
            guard isAuthorized else { return [] }
            return Set(latestTrades.filter { StockSageLiveStream.isLiveObservation($0.value.timestamp, at: now) }.keys)
        }

        func hasRecentTrades(at now: Date) -> Bool {
            isAuthorized && latestTrades.values.contains { StockSageLiveStream.isLiveObservation($0.timestamp, at: now) }
        }
    }

    nonisolated static func massiveSubscription(symbols _: Set<String> = []) -> String? {
        #"{"action":"subscribe","params":"T.*,Q.*"}"#
    }

    private nonisolated static func number(_ any: Any?) -> Double? {
        StockSageMassive.finite(any)
    }

    private nonisolated static func integer(_ any: Any?) -> Int64? {
        guard let value = StockSageMassive.int64(any), value >= 0 else { return nil }
        return value
    }

    nonisolated static func streamable(_ symbols: [String]) -> [String] {
        Set(symbols.filter { StockSageMassive.covers($0) }.map { $0.uppercased() }).sorted()
    }

    /// Reconnect backoff: 1, 2, 4, 8, 16, capped at 30 seconds.
    nonisolated static func backoffSeconds(attempt: Int) -> Double {
        min(30, pow(2, Double(max(0, attempt))))
    }

    func start(symbols _: [String]) {
        guard ToolPolicy.isExternalAllowed, StockSageMassive.isConfigured else { stop(); return }
        // Viewing a different board never changes the wildcard subscription or reconnects.
        guard connection == nil else { return }
        let current = StockSageLiveStreamConnection()
        connection = current
        current.open()
        publication = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.connection === current else { return }
                guard ToolPolicy.isExternalAllowed else { self.stop(); return }
                self.refreshReferences(stillValid: { [weak self, weak current] in
                    current != nil && self?.connection === current && ToolPolicy.isExternalAllowed
                })
                if let ingress = current.ingress {
                    let store = StockSageStore.shared
                    let selected = Set(store.trackedSymbolsUnion + store.ideas.map(\.symbol))
                    let all = selected.sorted()
                    let selection = StockSageStore.rotatedSweepSlice(all: all, cursor: self.publicationCursor,
                                                                   limit: ingress.limits.publicationSymbols)
                    self.publicationCursor = selection.nextCursor
                    let retained = all.count > ingress.limits.publicationSymbols
                        ? self.quotes.filter { selected.contains($0.key) } : [:]
                    let snapshot = await ingress.snapshot(symbols: selection.picked, retainingQuotes: retained)
                    guard !Task.isCancelled, self.connection === current, current.ingress === ingress else { continue }
                    guard ToolPolicy.isExternalAllowed else { self.stop(); return }
                    guard selected == Set(store.trackedSymbolsUnion + store.ideas.map(\.symbol)) else {
                        self.publicationCursor = 0 // A selection changed while the worker was capturing.
                        continue
                    }
                    if self.publish(snapshot, from: ingress, now: Date(), retainingQuotes: retained) {
                        await ingress.acknowledge(snapshot.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
                    } else { current.retry() }
                } else {
                    self.connectionLabel = "Feed reconnecting"
                    self.clearPrices()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Shared runtime/test seam: tests replace only the reference transports and session check.
    @discardableResult
    func refreshReferences(now: Date = Date(), stillValid: @escaping @MainActor () -> Bool,
        conditions: @escaping @MainActor () async throws -> Set<Int64> = {
            try await StockSageMassiveTicks.regularQuoteConditions()
        },
        exchangeList: @escaping @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange] = {
            try await StockSageMassiveTicks.exchanges()
        }
    ) -> Task<Void, Never>? {
        guard now.timeIntervalSince1970.isFinite, stillValid(), conditionTask == nil else { return nil }
        let conditionsFresh = conditionsAsOf.map { (0..<Self.referenceLifetime).contains(now.timeIntervalSince($0)) } == true
        let exchangesFresh = exchangesAsOf.map { (0..<Self.referenceLifetime).contains(now.timeIntervalSince($0)) } == true
        guard !conditionsFresh || !exchangesFresh else { return nil }
        // One retry per minute after failure/empty data; the 250ms publisher never fans out requests.
        if let at = referenceAttemptAt, (0..<60).contains(now.timeIntervalSince(at)) { return nil }
        referenceAttemptAt = now
        let refreshConditions = !conditionsFresh, refreshExchanges = !exchangesFresh
        let run = UUID()
        referenceGeneration = run
        let task = Task { [weak self] in
            defer {
                if self?.referenceGeneration == run { self?.conditionTask = nil }
            }
            guard !Task.isCancelled, stillValid(), let self, self.referenceGeneration == run else { return }
            if refreshConditions {
                do {
                    let regular = try await conditions()
                    guard !Task.isCancelled, stillValid(), self.referenceGeneration == run else { return }
                    if !regular.isEmpty {
                        self.regularConditions = regular
                        self.conditionsAsOf = now // Request-start time conservatively bounds reference age.
                    }
                } catch { /* Failed/empty conditions remain stale and retryable. */ }
            }
            guard !Task.isCancelled, stillValid(), self.referenceGeneration == run else { return }
            if refreshExchanges {
                do {
                    let exchanges = try await exchangeList()
                    guard !Task.isCancelled, stillValid(), self.referenceGeneration == run else { return }
                    if !exchanges.isEmpty {
                        self.exchanges = exchanges
                        self.exchangesAsOf = now
                    }
                } catch { /* Failed/empty exchanges remain stale and retryable. */ }
            }
        }
        conditionTask = task
        return task
    }

    /// The runtime and replay use the same @Published update. The clock ends after the store
    /// merge; compositor/render time remains separate. Tests replace only the store side effect.
    @discardableResult
    func publish(_ snapshot: StockSageFeedIngress.Snapshot, from ingress: StockSageFeedIngress, now: Date,
        retainingQuotes: [String: StockSageNBBO] = [:],
        apply: @MainActor ([String: Tick], [String: StockSageNBBO], Date) -> Void = { ticks, quotes, at in
            StockSageStore.shared.applyLiveTicks(ticks)
            StockSageStore.shared.applyLiveNBBO(quotes, now: at)
        }
    ) -> Bool {
        var report = snapshot.metrics
        func valid() -> Bool { ingress.acceptsPublication(snapshot, at: ProcessInfo.processInfo.systemUptime) }
        func reject() -> Bool {
            let reason = ingress.failureReason ?? (snapshot.publicationExpired(at: ProcessInfo.processInfo.systemUptime)
                ? "UI publication delayed over 10s; gap and reconnect" : "Feed session invalidated; gap and reconnect")
            ingress.invalidate(reason)
            report.failure = reason; diagnostics = report
            recordGap(reason)
            clearPrices { apply([:], [:], now) }
            return false
        }
        guard valid() else { return reject() }
        let recent = snapshot.authorized && Self.isLiveObservation(snapshot.newestSIP, at: now)
            && (report.sipToReceive.map { (0...Self.maximumLiveAge).contains($0) } ?? false)
        if isStreaming != recent { isStreaming = recent }
        connectionLabel = !snapshot.authorized ? "Feed authenticating" : recent ? "US trades + quotes" : "Feed connected · no recent observation"
        delivered = snapshot.authorized ? snapshot.trades : [:]
        let regular = conditionsAsOf.map { (0..<Self.referenceLifetime).contains(now.timeIntervalSince($0)) } == true ? regularConditions : []
        // ponytail: retained cache/requalification can reach the existing 32,768-symbol
        // ingress bound; primary snapshot records stay capped at 4,096. No receipt time is invented.
        var latest: [String: StockSageNBBO] = [:]
        if snapshot.authorized {
            latest = retainingQuotes.filter { snapshot.retainedQuoteSymbols.contains($0.key) && $0.value.isFresh(at: now) }
            latest.merge(snapshot.quotes) { _, current in current } // Withdrawals replace old liquidity.
            latest = latest.mapValues { $0.qualifyingCosts(regularConditions: regular) }
        }
        if quotes != latest { quotes = latest }
        apply(delivered, latest, now)
        let publishedAt = ProcessInfo.processInfo.systemUptime
        report.receiveToPublish = snapshot.receivedUptime.values.map { max(0, publishedAt - $0) }.max() ?? 0
        report.peakReceiveToPublish = max(report.peakReceiveToPublish, report.receiveToPublish)
        // Recheck after the synchronous merge too, without locking out the receive callback.
        guard valid() else { return reject() }
        diagnostics = report
        if report.receiveToPublish > Self.maximumLiveAge {
            ingress.invalidate("UI price publication exceeded 10s; gap and reconnect")
            return reject()
        }
        return true
    }

    private func recordGap(_ reason: String) {
        gapCount += 1; lastGap = reason
        connectionLabel = "Feed gap · reconnecting"
    }

    private func clearPrices(clearNBBO: @MainActor () -> Void = { StockSageStore.shared.applyLiveNBBO([:]) }) {
        if isStreaming { isStreaming = false }
        delivered = [:]
        if !quotes.isEmpty { quotes = [:] }
        clearNBBO()
    }

    var diagnosticText: String {
        let m = diagnostics
        let trade = m.tradeSIPToReceive.map { String(format: "%.3fs", $0) } ?? "unknown"
        let quote = m.quoteSIPToReceive.map { String(format: "%.3fs", $0) } ?? "unknown"
        let sip = m.sipToReceive.map { String(format: "%.3fs", $0) } ?? "unknown"
        return "\(connectionLabel). Whole-market T.*,Q.*; latest values, not a complete tape. "
            + "\(m.tradeSymbols) trade / \(m.quoteSymbols) quote symbols. "
            + "Queue \(m.queuedFrames) frames / \(m.queuedBytes) bytes (peak \(m.peakFrames) / \(m.peakBytes)). "
            + String(format: "Receive→process %.3fs; receive→publish %.3fs (peak %.3fs). ", m.receiveToProcess, m.receiveToPublish, m.peakReceiveToPublish)
            + "Latest frame SIP→receive \(sip); trades \(trade), quotes \(quote). Upstream age is not proof of consumer backlog. "
            + String(format: "%.0f events/s; %.0f bytes/s (session average). ", Double(m.processedEvents) / max(0.001, m.elapsed), Double(m.receivedBytes) / max(0.001, m.elapsed))
            + "\(m.coalesced) replacements; \(m.rejected) rejected elements/oversized metadata; \(m.futureClocks) future clocks; \(gapCount) gaps. "
            + (lastGap.map { "Last gap: \($0). " } ?? "")
            + "LIVE requires a nonfuture observation ≤10s old; quiet symbols and closed markets need not print. Publication timing excludes compositor/render delay."
    }

    func stop(clearNBBO: @MainActor () -> Void = { StockSageStore.shared.applyLiveNBBO([:]) }) {
        publication?.cancel(); publication = nil
        conditionTask?.cancel(); conditionTask = nil
        referenceGeneration = UUID(); referenceAttemptAt = nil
        connection?.close(); connection = nil
        regularConditions = []; conditionsAsOf = nil; exchanges = [:]; exchangesAsOf = nil
        clearPrices(clearNBBO: clearNBBO)
        connectionLabel = "Feed stopped"
    }
}

@MainActor
private final class StockSageLiveStreamConnection {
    private(set) var ingress: StockSageFeedIngress?
    private var socket: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var active = true
    private var reconnect: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var pingDeadline: Task<Void, Never>?

    func open() {
        guard active, ToolPolicy.isExternalAllowed else { close(); return }
        let key = StockSageMassive.apiKey
        guard !key.isEmpty, let url = URL(string: StockSageLiveStream.massiveHost) else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = StockSageFeedIngress.Limits().frameBytes
        let ingress = StockSageFeedIngress(authorized: { source in
            // One auth transition may hop to MainActor to recheck policy; data frames never do.
            Task { @MainActor in
                guard source.isActive else { return }
                guard ToolPolicy.isExternalAllowed else { source.invalidate("External access disabled"); return }
                guard let text = StockSageLiveStream.massiveSubscription() else { return }
                socket.send(.string(text)) { error in
                    if error != nil { source.invalidate("Feed subscription send failed; gap and reconnect") }
                }
            }
        }, failed: { socket.cancel(with: .goingAway, reason: nil) })
        self.socket = socket; self.ingress = ingress
        socket.resume()
        if let data = try? JSONSerialization.data(withJSONObject: ["action": "auth", "params": key]),
           let text = String(data: data, encoding: .utf8) {
            socket.send(.string(text)) { error in
                if error != nil { ingress.invalidate("Feed authentication send failed; gap and reconnect") }
            }
        }
        Self.receive(socket, ingress: ingress)
        armWatchdog(socket, ingress: ingress)
    }

    func close() {
        active = false
        reconnect?.cancel(); reconnect = nil
        watchdog?.cancel(); watchdog = nil
        pingDeadline?.cancel(); pingDeadline = nil
        ingress?.invalidate(); ingress = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    func retry() {
        guard active else { return }
        ingress?.invalidate(); ingress = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        watchdog?.cancel(); watchdog = nil
        pingDeadline?.cancel(); pingDeadline = nil
        let delay = StockSageLiveStream.backoffSeconds(attempt: reconnectAttempt)
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.active, ToolPolicy.isExternalAllowed else { return }
            self.open()
        }
    }

    private func armWatchdog(_ socket: URLSessionWebSocketTask, ingress: StockSageFeedIngress) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.socket === socket, ingress.isActive else { return }
            guard ToolPolicy.isExternalAllowed else { self.close(); return }
            let snapshot = await ingress.snapshot(symbols: [])
            guard !Task.isCancelled, self.socket === socket else { return }
            guard snapshot.authorized else { ingress.invalidate("Feed authentication timed out; gap and reconnect"); return }
            self.reconnectAttempt = 0
            self.pingDeadline = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                ingress.invalidate("Feed ping timed out; gap and reconnect")
            }
            socket.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.socket === socket, ingress.isActive else { return }
                    self.pingDeadline?.cancel(); self.pingDeadline = nil
                    if error != nil { ingress.invalidate("Feed ping failed; gap and reconnect") }
                    else { self.armWatchdog(socket, ingress: ingress) }
                }
            }
        }
    }

    /// Receive/enqueue and consumption-paced rearming stay outside MainActor. One native
    /// frame awaits parsing; no Task per trade/frame on the UI actor or expanded raw queue.
    nonisolated private static func receive(_ socket: URLSessionWebSocketTask, ingress: StockSageFeedIngress) {
        guard ingress.isActive else { return }
        socket.receive { result in
            guard ingress.isActive else { return }
            switch result {
            case .success(let message):
                let at = Date(), uptime = ProcessInfo.processInfo.systemUptime
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: ingress.invalidate("Unknown feed frame; gap and reconnect"); return
                }
                ingress.offer(data, at: at, uptime: uptime, consumed: { receive(socket, ingress: ingress) })
            case .failure:
                ingress.invalidate("Feed connection lost; gap and reconnect")
            }
        }
    }
}
