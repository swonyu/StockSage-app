import Foundation
import Combine

/// Real-time price streaming over Massive's Stocks WebSocket. It subscribes only US equities
/// that Massive covers; all other symbols keep the explicit, keyless Yahoo polling path.
/// The socket is foreground-only on iOS; a server plus push notifications would be required for
/// real background monitoring. A quiet trade stream means the market is quiet, not that the
/// connection is broken.
@MainActor
final class StockSageLiveStream: ObservableObject {
    static let shared = StockSageLiveStream()

    /// True only while an authenticated connection is delivering recent trades.
    @Published private(set) var isStreaming = false
    /// Coalesced separately from trade prices. A quote must never advance trade freshness.
    @Published private(set) var quotes: [String: StockSageNBBO] = [:]
    /// Shared reference for compact cards; never fetch once per symbol/card.
    @Published private(set) var exchanges: [Int64: StockSageMassiveTicks.Exchange] = [:]

    /// Auth success is not subscription proof. Unseen or quiet symbols stay in the gap poll.
    var subscribed: Set<String> {
        connections.reduce(into: Set<String>()) { $0.formUnion($1.state.coveredSymbols(at: Date())) }
    }

    /// Massive Stocks WebSocket. The API key is sent only in the post-connect auth message.
    fileprivate static let massiveHost = "wss://socket.massive.com/stocks"
    nonisolated fileprivate static let silenceTimeout: TimeInterval = 45

    private var connections: [StockSageLiveStreamConnection] = []
    private var freshnessTimer: Task<Void, Never>?
    private var quoteFlush: Task<Void, Never>?
    private var conditionTask: Task<Void, Never>?
    private var regularConditions: Set<Int64> = []
    private var conditionsAsOf: Date?

    nonisolated struct Tick: Sendable, Equatable {
        let symbol: String
        let price: Double
        let timestamp: Date
        var sequence: Int64? = nil
    }

    nonisolated enum Event: Sendable, Equatable {
        case status(String)
        case trade(Tick)
        case quote(StockSageNBBO)
    }

    /// Decode EVERY event, including mixed status/trade frames. A malformed element must not
    /// hide its valid siblings. https://massive.com/docs/websocket/quickstart
    nonisolated static func events(in text: String) -> [Event] {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = (raw as? [Any]) ?? [raw]
        return rows.compactMap { element in
            guard let row = element as? [String: Any] else { return nil }
            if row["ev"] as? String == "status", let status = row["status"] as? String {
                return .status(status)
            }
            guard let symbol = (row["sym"] as? String)?.uppercased(), StockSageMassive.covers(symbol),
                  let milliseconds = number(row["t"]), milliseconds > 0 else { return nil }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            switch row["ev"] as? String {
            case "T":
                guard let price = number(row["p"]), price > 0 else { return nil }
                return .trade(Tick(symbol: symbol, price: price, timestamp: timestamp, sequence: integer(row["q"])))
            case "Q":
                guard let bid = number(row["bp"]), bid >= 0, let ask = number(row["ap"]), ask >= 0,
                      let bidSize = number(row["bs"]), bidSize >= 0,
                      let askSize = number(row["as"]), askSize >= 0 else { return nil }
                var quote = StockSageNBBO(symbol: symbol, bid: bid, ask: ask, bidSize: bidSize, askSize: askSize,
                                    bidExchange: integer(row["bx"]), askExchange: integer(row["ax"]),
                                    timestamp: timestamp, sequence: integer(row["q"]))
                quote.condition = integer(row["c"])
                if let raw = row["i"] {
                    let values = (raw as? [Any])?.compactMap(integer)
                    quote.indicators = values?.count == (raw as? [Any])?.count ? values : nil
                }
                return .quote(quote)
            default: return nil
            }
        }
    }

    /// The runtime and deterministic tests use the same protocol state, without a live socket.
    nonisolated struct StreamState {
        private(set) var isAuthorized = false
        private var latestTrades: [String: Tick] = [:]
        private(set) var latestQuotes: [String: StockSageNBBO] = [:]

        mutating func consume(_ event: Event, requested: Set<String>, now: Date) -> Tick? {
            switch event {
            case .status("auth_success"):
                isAuthorized = true
            case .status("auth_failed"), .status("error"), .status("connected"):
                self = StreamState()
            case .status:
                break // Informational/subscription messages do not revoke authentication.
            case .quote(let quote):
                guard isAuthorized, requested.contains(quote.symbol),
                      quote.supersedes(latestQuotes[quote.symbol], now: now) else { return nil }
                latestQuotes[quote.symbol] = quote
            case .trade(let tick):
                guard isAuthorized, requested.contains(tick.symbol), tick.price.isFinite, tick.price > 0,
                      StockSageStore.acceptsLiveTick(tick.timestamp, after: latestTrades[tick.symbol]?.timestamp,
                          massiveTradeSequence: tick.sequence,
                          afterMassiveTradeSequence: latestTrades[tick.symbol]?.sequence, now: now)
                else { return nil }
                latestTrades[tick.symbol] = tick
                return tick
            }
            return nil
        }

        func coveredSymbols(at now: Date) -> Set<String> {
            guard isAuthorized else { return [] }
            return Set(latestTrades.filter { now.timeIntervalSince($0.value.timestamp) <= silenceTimeout }.keys)
        }

        func hasRecentTrades(at now: Date) -> Bool {
            isAuthorized && latestTrades.values.contains { now.timeIntervalSince($0.timestamp) <= silenceTimeout }
        }
    }

    nonisolated static func massiveSubscription(symbols: Set<String>) -> String? {
        guard !symbols.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "action": "subscribe",
                  "params": symbols.sorted().flatMap { ["T.\($0)", "Q.\($0)"] }.joined(separator: ","),
              ]) else { return nil }
        return String(data: data, encoding: .utf8)
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

    func start(symbols: [String]) {
        let wanted = Self.streamable(symbols)
        guard ToolPolicy.isExternalAllowed, StockSageMassive.isConfigured, !wanted.isEmpty else { stop(); return }
        let set = Set(wanted)
        guard connections.first?.symbols != set || connections.count != 1 || connections.first?.isActive != true else { return }
        connections.forEach { $0.close() }
        let connection = StockSageLiveStreamConnection(symbols: set, owner: self)
        connections = [connection]
        connectionStatusChanged()
        connection.open()
        conditionTask?.cancel()
        regularConditions = []
        conditionsAsOf = nil
        exchanges = [:]
        conditionTask = Task { [weak self] in
            // ponytail: one bounded reference request per start; on failure or after24h,
            // retain default costs until restart. Add retries only with verified rate limits.
            let regular = (try? await StockSageMassiveTicks.regularQuoteConditions()) ?? []
            guard !Task.isCancelled, let self, ToolPolicy.isExternalAllowed else { return }
            self.regularConditions = regular
            self.conditionsAsOf = Date()
            self.quotesChanged()
            let exchanges = (try? await StockSageMassiveTicks.exchanges()) ?? [:]
            guard !Task.isCancelled, ToolPolicy.isExternalAllowed else { return }
            if self.exchanges != exchanges { self.exchanges = exchanges }
        }
        freshnessTimer?.cancel()
        // ponytail: one-second UI/rank invalidation; money helpers check exact quote age.
        freshnessTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard ToolPolicy.isExternalAllowed else { self.stop(); return }
                self.connectionStatusChanged()
                StockSageStore.shared.applyLiveNBBO(self.quotes)
            }
        }
    }

    func stop() {
        conditionTask?.cancel()
        conditionTask = nil
        regularConditions = []
        conditionsAsOf = nil
        freshnessTimer?.cancel()
        freshnessTimer = nil
        quoteFlush?.cancel()
        quoteFlush = nil
        connections.forEach { $0.close() }
        connections = []
        isStreaming = false
        quotes = [:]
        exchanges = [:]
        StockSageStore.shared.applyLiveNBBO([:])
    }

    fileprivate func connectionStatusChanged() {
        let streaming = connections.contains { $0.state.hasRecentTrades(at: Date()) }
        // @Published emits even for equal assignments: don't redraw Markets for every trade.
        if isStreaming != streaming { isStreaming = streaming }
        if !connections.contains(where: { $0.state.isAuthorized }), !quotes.isEmpty {
            quotes = [:]
            StockSageStore.shared.applyLiveNBBO([:])
        }
    }

    fileprivate func quotesChanged() {
        guard quoteFlush == nil else { return }
        quoteFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.quoteFlush = nil
            guard ToolPolicy.isExternalAllowed else { self.stop(); return }
            let now = Date()
            let regular = self.conditionsAsOf.map { (0..<86_400).contains(now.timeIntervalSince($0)) } == true
                ? self.regularConditions : []
            let latest = self.connections.reduce(into: [String: StockSageNBBO]()) {
                if $1.state.isAuthorized { $0.merge($1.state.latestQuotes) { _, new in new } }
            }.mapValues { $0.qualifyingCosts(regularConditions: regular) }
            if self.quotes != latest { self.quotes = latest }
            StockSageStore.shared.applyLiveNBBO(latest, now: now)
        }
    }

    fileprivate func tickReceived(_ tick: Tick) {
        StockSageStore.shared.applyLiveTick(symbol: tick.symbol, price: tick.price, at: tick.timestamp,
                                            massiveTradeSequence: tick.sequence)
    }
}

@MainActor
private final class StockSageLiveStreamConnection {
    let symbols: Set<String>
    private(set) var state = StockSageLiveStream.StreamState()

    private weak var owner: StockSageLiveStream?
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    var isActive: Bool { wantsConnection }
    private var watchdog: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?

    init(symbols: Set<String>, owner: StockSageLiveStream) {
        self.symbols = symbols
        self.owner = owner
    }

    func open() {
        wantsConnection = true
        openSocket()
    }

    func close() {
        wantsConnection = false
        watchdog?.cancel()
        watchdog = nil
        reconnect?.cancel()
        reconnect = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .init()
        owner?.connectionStatusChanged()
    }

    private func openSocket() {
        guard wantsConnection, ToolPolicy.isExternalAllowed else { close(); return }
        watchdog?.cancel()
        watchdog = nil
        reconnect?.cancel()
        reconnect = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .init()
        owner?.connectionStatusChanged()
        let key = StockSageMassive.apiKey
        guard !key.isEmpty, let url = URL(string: StockSageLiveStream.massiveHost) else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        sendAuth(key)
        receiveLoop()
        armWatchdog()
    }

    private func sendAuth(_ key: String) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: ["action": "auth", "params": key]),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text, on: task)
    }

    private func sendSubscription() {
        guard let task, let text = StockSageLiveStream.massiveSubscription(symbols: symbols) else { return }
        send(text, on: task)
    }

    private func send(_ text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.connectionFailed(socket) }
        }
    }

    /// Invalidate the socket before scheduling a retry. Late callbacks from it cannot reset
    /// the replacement connection, and close() cancels a pending reconnect during scene exit.
    private func connectionFailed(_ socket: URLSessionWebSocketTask) {
        guard task === socket else { return }
        task = nil
        socket.cancel(with: .goingAway, reason: nil)
        watchdog?.cancel()
        watchdog = nil
        state = .init()
        owner?.connectionStatusChanged()
        guard wantsConnection else { return }
        let delay = StockSageLiveStream.backoffSeconds(attempt: reconnectAttempt)
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.openSocket()
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StockSageLiveStream.silenceTimeout))
            guard !Task.isCancelled, let self, self.wantsConnection, let task = self.task else { return }
            guard ToolPolicy.isExternalAllowed else { self.close(); return }
            self.owner?.connectionStatusChanged()
            guard self.state.isAuthorized else { self.connectionFailed(task); return }
            task.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.task === task else { return }
                    if error != nil {
                        self.connectionFailed(task)
                    } else {
                        self.armWatchdog()
                    }
                }
            }
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                guard ToolPolicy.isExternalAllowed else { self.close(); return }
                switch result {
                case .success(let message):
                    let text: String?
                    switch message {
                    case .string(let value): text = value
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    for event in StockSageLiveStream.events(in: text ?? "") {
                        let wasAuthorized = self.state.isAuthorized
                        if let tick = self.state.consume(event, requested: self.symbols, now: Date()) {
                            self.reconnectAttempt = 0
                            self.owner?.tickReceived(tick)
                        }
                        if case .quote = event { self.owner?.quotesChanged() }
                        if !wasAuthorized, self.state.isAuthorized { self.sendSubscription() }
                        if event == .status("auth_failed") || event == .status("error") {
                            self.connectionFailed(task)
                            return
                        }
                    }
                    self.owner?.connectionStatusChanged()
                    self.receiveLoop()
                case .failure:
                    self.connectionFailed(task)
                }
            }
        }
    }
}
