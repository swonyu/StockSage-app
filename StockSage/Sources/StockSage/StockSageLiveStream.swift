import Foundation
import Combine

/// Real-time price streaming over EODHD's WebSocket (owner directive 2026-07-28: "real live
/// tracking, not a button to refresh").
///
/// WHAT THIS DOES: holds one WebSocket per chunk of `maxSubscriptionsPerConnection` symbols on
/// EODHD's US feed and pushes every tick straight into the store, so prices move on their own
/// while the app is open. Verified authorized on the owner's key (handshake returns
/// `{"status_code":200,"message":"Authorized"}`).
///
/// HONEST LIMITS — these are platform/vendor facts, not missing effort:
///   • US symbols ONLY. EODHD carries no Saudi exchange (measured — see StockSageEODHD), so
///     Tadawul names keep using the polling refresh. There is no stream to subscribe them to.
///   • FOREGROUND only on iOS. iOS suspends an app shortly after it leaves the screen and tears
///     down its sockets; no background mode legitimately keeps a finance WebSocket alive. True
///     24/7 tracking requires a server holding the socket and sending push notifications —
///     infrastructure this app deliberately does not have. macOS can hold it open indefinitely.
///   • Streams TRADES. Between trades the price does not change, so a thin name updates rarely;
///     that is the market being quiet, not the stream being broken.
@MainActor
final class StockSageLiveStream: ObservableObject {
    static let shared = StockSageLiveStream()

    /// True while ANY chunk's socket is open AND authorized — the UI's "LIVE" indicator binds to
    /// this and must never claim live when every connection has dropped.
    @Published private(set) var isStreaming = false
    /// When the last tick of any symbol on any connection arrived. nil until the first one.
    @Published private(set) var lastTickAt: Date?
    /// Symbols currently subscribed across every open connection (uppercased, US only) — ONLY
    /// those on a connection that is actually AUTHORIZED and streaming right now (blocker fix
    /// 2026-09-06). Before this it was a STORED value assigned from the merely-REQUESTED union
    /// the instant `start()` ran — before `connections.forEach { $0.open() }` even executed, let
    /// alone before any handshake returned — so a symbol whose socket never authorized (missing
    /// API key, non-200 handshake, every chunk dropped) still read as "covered": `isStreaming`
    /// correctly went false, but `subscribed` kept claiming every requested symbol, so
    /// `StockSageStore.streamGapCandidates` returned `[]` and those names were polled by NOTHING
    /// except the far-slower `.full` sweep. Computed (not stored) so it can never go stale
    /// relative to each connection's own `isStreaming`. Pulled through the pure
    /// `subscribedSymbols(from:)` below so the "only authorized chunks count" rule is
    /// unit-testable without opening a real socket.
    var subscribed: Set<String> {
        Self.subscribedSymbols(from: connections.map { (symbols: $0.symbols, isStreaming: $0.isStreaming) })
    }

    /// Pure: union of `symbols` for every entry whose `isStreaming` is true. Tuple-typed (not
    /// `StockSageLiveStreamConnection`, which is `private` to this file and MainActor-bound) so
    /// it can be pinned directly with plain fixtures.
    nonisolated static func subscribedSymbols(from connections: [(symbols: Set<String>, isStreaming: Bool)]) -> Set<String> {
        connections.filter(\.isStreaming).reduce(into: Set<String>()) { $0.formUnion($1.symbols) }
    }

    /// EODHD's per-connection ceiling. Source (fetched 2026-09-06):
    /// https://eodhd.com/financial-apis/new-real-time-data-api-websockets — "Symbol Limits &
    /// Usage Notes ... Concurrent subscriptions: up to 50 symbols per connection by default
    /// (upgradeable in user dashboard for extra fee)." The same page separately caps the
    /// account at "up to 64 concurrent connections per API token" (shared across every market),
    /// which is why we chunk into additional connections rather than opening one per symbol.
    static let maxSubscriptionsPerConnection = 50

    private var connections: [StockSageLiveStreamConnection] = []
    private var wantsConnection = false

    /// EODHD's US trade stream. Host is the legacy domain deliberately: ws.eodhd.com presents a
    /// certificate that fails hostname validation (measured 2026-07-28), so using it would mean
    /// either a TLS error or disabling verification — neither acceptable for a price feed.
    fileprivate static let host = "wss://ws.eodhistoricaldata.com/ws/us"

    // MARK: - Pure, testable pieces

    struct Tick: Sendable, Equatable {
        let symbol: String
        let price: Double
        let timestamp: Date?
    }

    /// Parse one EODHD stream frame. Handles the trade payload, the auth acknowledgement, and
    /// anything malformed — returning nil rather than a fabricated price in every non-trade case.
    nonisolated static func parseTick(_ text: String) -> Tick? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Status frames ({"status_code":200,...}) carry no price — not a tick.
        guard obj["status_code"] == nil else { return nil }
        guard let symbol = (obj["s"] as? String)?.uppercased(), !symbol.isEmpty else { return nil }
        // Price arrives as a number or a numeric string depending on the field.
        let price: Double?
        if let d = obj["p"] as? Double { price = d }
        else if let i = obj["p"] as? Int { price = Double(i) }
        else if let s = obj["p"] as? String { price = Double(s) }
        else { price = nil }
        guard let p = price, p > 0, p.isFinite else { return nil }
        // `t` is milliseconds since epoch on this feed.
        var when: Date?
        if let ms = obj["t"] as? Double { when = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = obj["t"] as? Int { when = Date(timeIntervalSince1970: Double(ms) / 1000) }
        return Tick(symbol: symbol, price: p, timestamp: when)
    }

    /// Which of `symbols` this stream can actually carry. Reuses the EODHD coverage whitelist so
    /// the two can never disagree about what US means.
    nonisolated static func streamable(_ symbols: [String]) -> [String] {
        symbols.filter { StockSageEODHD.covers($0) }.map { $0.uppercased() }.sorted()
    }

    /// Split `symbols` into contiguous chunks of at most `limit` (last chunk may be smaller).
    /// Pure so the batching math — ceil(n/limit) chunks, none over cap, union equals input — can
    /// be pinned without opening a socket. `limit <= 0` means "no cap" (one chunk).
    nonisolated static func chunked(_ symbols: [String], limit: Int) -> [[String]] {
        guard limit > 0, !symbols.isEmpty else { return symbols.isEmpty ? [] : [symbols] }
        var result: [[String]] = []
        var i = 0
        while i < symbols.count {
            let end = min(i + limit, symbols.count)
            result.append(Array(symbols[i..<end]))
            i = end
        }
        return result
    }

    /// Reconnect backoff in seconds: 1, 2, 4, 8, 16, capped at 30. Capped so a long outage still
    /// retries at a sane cadence instead of drifting to hours.
    nonisolated static func backoffSeconds(attempt: Int) -> Double {
        min(30, pow(2, Double(max(0, attempt))))
    }

    /// Status-frame classifier. EODHD's control frames carry `status_code`; nil means this is not
    /// a status frame. Kept separate from `parseTick` (which correctly rejects them) so the
    /// connection layer can honour `isStreaming`'s "open AND AUTHORIZED" contract. (Review Q5,
    /// 2026-07-28.)
    nonisolated static func authStatus(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let c = obj["status_code"] as? Int { return c }
        if let s = obj["status_code"] as? String { return Int(s) }
        return nil
    }

    /// How long a connection may go without ANY frame before it stops claiming LIVE and
    /// re-probes. A quiet market sends no trades and a NAT/Wi-Fi handover leaves a half-open
    /// socket — in both cases `receive` simply never returns, so `.failure` (the only thing that
    /// cleared `isStreaming`) never fires and the pulsing dot lies indefinitely. (Review Q5,
    /// 2026-07-28.)
    fileprivate static let silenceTimeout = 45

    // MARK: - Connection lifecycle

    /// Opens one connection per `maxSubscriptionsPerConnection`-sized chunk of `symbols` — a
    /// single connection when the whole set fits, several (each with its own watchdog/backoff)
    /// when it doesn't. Overall `isStreaming` is true when ANY chunk is live.
    func start(symbols: [String]) {
        let wanted = Self.streamable(symbols)
        guard !wanted.isEmpty else { stop(); return }
        wantsConnection = true
        let chunks = Self.chunked(wanted, limit: Self.maxSubscriptionsPerConnection).map(Set.init)
        guard Set(chunks) != Set(connections.map(\.symbols)) else { return }  // already exactly this
        connections.forEach { $0.close() }
        connections = chunks.map { StockSageLiveStreamConnection(symbols: $0, owner: self) }
        // `subscribed` is now DERIVED from each connection's own `isStreaming` (see its doc) —
        // no assignment needed here; it reads correctly (empty) until a chunk actually authorizes.
        connections.forEach { $0.open() }
    }

    func stop() {
        wantsConnection = false
        connections.forEach { $0.close() }
        connections = []
        isStreaming = false
        // `subscribed` is derived from `connections`, which is now empty — no assignment needed.
    }

    /// Called by a connection whenever its own `isStreaming` changes. Overall status is the union
    /// across every chunk — one dead connection must not blank out an otherwise-live stream.
    fileprivate func connectionStatusChanged() {
        isStreaming = connections.contains { $0.isStreaming }
    }

    fileprivate func tickReceived(symbol: String, price: Double, at when: Date?) {
        lastTickAt = Date()
        StockSageStore.shared.applyLiveTick(symbol: symbol, price: price, at: when)
    }
}

/// One EODHD WebSocket carrying at most `StockSageLiveStream.maxSubscriptionsPerConnection`
/// symbols. Everything here is the original single-connection logic (subscribe, 45s silence
/// watchdog, 1-2-4-8-16s-capped-30 backoff) unchanged — `StockSageLiveStream` just owns N of
/// these instead of one once the requested set exceeds the vendor cap.
@MainActor
private final class StockSageLiveStreamConnection {
    let symbols: Set<String>
    private(set) var isStreaming = false

    private weak var owner: StockSageLiveStream?
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var watchdog: Task<Void, Never>?

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
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isStreaming = false
    }

    private func openSocket() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty, let url = URL(string: "\(StockSageLiveStream.host)?api_token=\(key)") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        sendSubscription()
        receiveLoop()
    }

    private func sendSubscription() {
        guard let t = task, !symbols.isEmpty else { return }
        let payload = ["action": "subscribe", "symbols": symbols.sorted().joined(separator: ",")]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StockSageLiveStream.silenceTimeout))
            guard !Task.isCancelled, let self, self.wantsConnection, let t = self.task else { return }
            // A ping proves the socket is alive without claiming any price moved.
            t.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.task === t else { return }
                    if error != nil {
                        self.isStreaming = false
                        self.owner?.connectionStatusChanged()
                        self.openSocket()
                    } else {
                        self.armWatchdog()
                    }
                }
            }
        }
    }

    private func receiveLoop() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    if case .string(let text) = message {
                        if let status = StockSageLiveStream.authStatus(text) {
                            // ONLY an explicit 200 means authorized — the `isStreaming` contract.
                            self.isStreaming = (status == 200)
                            self.owner?.connectionStatusChanged()
                        } else if let tick = StockSageLiveStream.parseTick(text) {
                            self.isStreaming = true
                            self.owner?.connectionStatusChanged()
                            self.owner?.tickReceived(symbol: tick.symbol, price: tick.price, at: tick.timestamp)
                        }
                    }
                    self.armWatchdog()
                    self.receiveLoop()
                case .failure:
                    self.isStreaming = false
                    self.owner?.connectionStatusChanged()
                    guard self.wantsConnection else { return }
                    let delay = StockSageLiveStream.backoffSeconds(attempt: self.reconnectAttempt)
                    self.reconnectAttempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                    if self.wantsConnection { self.openSocket() }
                }
            }
        }
    }
}
