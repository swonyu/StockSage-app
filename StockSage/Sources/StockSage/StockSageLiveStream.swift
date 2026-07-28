import Foundation
import Combine

/// Real-time price streaming over EODHD's WebSocket (owner directive 2026-07-28: "real live
/// tracking, not a button to refresh").
///
/// WHAT THIS DOES: holds a WebSocket to EODHD's US feed and pushes every tick straight into the
/// store, so prices move on their own while the app is open. Verified authorized on the owner's
/// key (handshake returns `{"status_code":200,"message":"Authorized"}`).
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

    /// True while the socket is open AND authorized — the UI's "LIVE" indicator binds to this
    /// and must never claim live on a dropped connection.
    @Published private(set) var isStreaming = false
    /// When the last tick of any symbol arrived. nil until the first one.
    @Published private(set) var lastTickAt: Date?
    /// Symbols currently subscribed (uppercased, US only).
    private(set) var subscribed: Set<String> = []

    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var wantsConnection = false

    /// EODHD's US trade stream. Host is the legacy domain deliberately: ws.eodhd.com presents a
    /// certificate that fails hostname validation (measured 2026-07-28), so using it would mean
    /// either a TLS error or disabling verification — neither acceptable for a price feed.
    private static let host = "wss://ws.eodhistoricaldata.com/ws/us"

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

    /// Reconnect backoff in seconds: 1, 2, 4, 8, 16, capped at 30. Capped so a long outage still
    /// retries at a sane cadence instead of drifting to hours.
    nonisolated static func backoffSeconds(attempt: Int) -> Double {
        min(30, pow(2, Double(max(0, attempt))))
    }

    // MARK: - Connection lifecycle

    func start(symbols: [String]) {
        let wanted = Set(Self.streamable(symbols))
        guard !wanted.isEmpty else { stop(); return }
        wantsConnection = true
        if task != nil, wanted == subscribed { return }     // already streaming exactly this set
        subscribed = wanted
        openSocket()
    }

    func stop() {
        wantsConnection = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isStreaming = false
        subscribed = []
    }

    private func openSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        let key = StockSageEODHD.apiKey
        guard !key.isEmpty, let url = URL(string: "\(Self.host)?api_token=\(key)") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        sendSubscription()
        receiveLoop()
    }

    private func sendSubscription() {
        guard let t = task, !subscribed.isEmpty else { return }
        let payload = ["action": "subscribe", "symbols": subscribed.sorted().joined(separator: ",")]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    self.isStreaming = true
                    self.reconnectAttempt = 0
                    if case .string(let text) = message, let tick = Self.parseTick(text) {
                        self.lastTickAt = Date()
                        StockSageStore.shared.applyLiveTick(symbol: tick.symbol, price: tick.price,
                                                            at: tick.timestamp)
                    }
                    self.receiveLoop()
                case .failure:
                    self.isStreaming = false
                    guard self.wantsConnection else { return }
                    let delay = Self.backoffSeconds(attempt: self.reconnectAttempt)
                    self.reconnectAttempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                    if self.wantsConnection { self.openSocket() }
                }
            }
        }
    }
}
