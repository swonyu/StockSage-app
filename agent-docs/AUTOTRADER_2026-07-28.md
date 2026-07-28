# StockSageX — autonomous trading, honestly scoped

**Ask:** make StockSage buy and sell by itself, short holds (< 5 days), for testing.

**Answer:** yes for the NASDAQ half, properly, through a real broker API with real order objects and real fills. No for the Tadawul half — the API does not exist at any retail broker. Here is the exact split and the code.

---

## What's buildable and what isn't

| | Automated order placement | Why |
|---|---|---|
| **NASDAQ (~300 names)** | ✅ **Yes — Alpaca paper API** | Free, no approval, open to anyone globally with an email. Real order objects, real-time quotes, real fills, real position and P&L tracking. Base URL `https://paper-api.alpaca.markets`. This is genuine end-to-end automation. |
| **Tadawul (~600 `.SR`)** | ❌ No | Neither Sahm nor عوائد publishes a retail order API. Tadawul's automated-order channel runs through exchange members, and the CMA has issued no retail guidance. Nothing to connect to. These stay on the internal `StockSagePaperTrader` book, which already works. |
| **Live money at Sahm / عوائد** | ❌ No | Same reason. The only route would be driving the app's private endpoints with your brokerage credentials — I won't build that, and it would break under their next app update anyway. |

**Where it runs:** macOS only. iOS suspends backgrounded apps and kills sockets — your own hard constraint — so the phone cannot host an autonomous loop. On the Mac, the US session is 16:30–23:00 Riyadh, which is a window you're plausibly awake and the machine is on. That is the honest execution envelope.

---

## The honesty problem you must fix before trusting a single result

Alpaca's own docs state paper trading **does not model market impact, price slippage, order queue position, or regulatory fees**. Those are exactly the costs that dominate a sub-5-day strategy. A raw Alpaca paper P&L will look *better* than reality, and the shorter your hold, the bigger the lie.

You already own the fix. `StockSageNetEdge.defaultCosts(forSymbol:)` returns 13 bps round-trip for US large-cap (`:98`). Deduct it from every closed trade before you report anything. The autotrader below does this and reports **both** figures, labelled — gross (what Alpaca says) and net (what you'd actually have made). Never look at the gross one.

For scale: at a 5-day hold you turn over ~50× a year. 50 × 13 bps ≈ **6.5% of capital annually** on NASDAQ names. That's the number the test has to beat, and it's the *cheap* market — the `.SR` equivalent from your own table is 60 bps, ≈ 30%/yr.

---

## New file: `StockSage/Sources/StockSage/StockSageBroker.swift`

```swift
import Foundation

// MARK: - Broker (Alpaca paper)
//
// The ONLY automated-execution venue this app has. Deliberately paper-only: `liveBase` is not
// defined anywhere in this file and adding it is a conscious, separate decision — a typo in a
// base URL must never be the difference between a simulation and real money.
//
// SCOPE (measured, 2026-07-28): Alpaca covers US equities. Tadawul is NOT reachable — neither
// Sahm nor عوائد publishes a retail order API, and Tadawul's automated-order channel runs
// through exchange members. `.SR` names therefore never reach this file; they stay on the
// internal StockSagePaperTrader book. `tradable(_:)` is the fence.
//
// HONESTY FLOOR: Alpaca's paper engine does NOT model slippage, market impact, queue position
// or regulatory fees (their docs say so). Every P&L this file produces is therefore GROSS and
// is labelled as such; StockSageAutoTrader applies StockSageNetEdge.defaultCosts on top and
// reports the net figure beside it. A gross paper return displayed alone would be exactly the
// kind of number this app must never show.
enum StockSageBroker {

    /// Paper endpoint. There is no live counterpart in this file, on purpose.
    static let paperBase = "https://paper-api.alpaca.markets"

    static let keyIDDefault     = "stocksage.broker.keyID"
    static let keySecretDefault = "stocksage.broker.keySecret"

    nonisolated static var keyID: String { UserDefaults.standard.string(forKey: keyIDDefault) ?? "" }
    nonisolated static var keySecret: String { UserDefaults.standard.string(forKey: keySecretDefault) ?? "" }
    nonisolated static var configured: Bool { !keyID.isEmpty && !keySecret.isEmpty }

    /// Only bare US tickers route here. Mirrors StockSageEODHD.covers' fence: anything with a
    /// dot suffix (.SR and friends) is a non-US listing with no Alpaca coverage, and `^`/`=X`/
    /// `-USD` are index/FX/crypto markers this universe no longer carries.
    nonisolated static func tradable(_ symbol: String) -> Bool {
        let s = symbol.uppercased()
        guard !s.isEmpty, !s.contains("."), !s.hasPrefix("^"),
              !s.hasSuffix("=X"), !s.hasSuffix("-USD") else { return false }
        return s.allSatisfy { $0.isLetter }
    }

    // MARK: Wire types

    struct Position: Decodable, Sendable {
        let symbol: String
        let qty: String
        let avg_entry_price: String
        let unrealized_pl: String
        var shares: Double { Double(qty) ?? 0 }
        var entry: Double { Double(avg_entry_price) ?? 0 }
    }

    struct Order: Decodable, Sendable {
        let id: String
        let symbol: String
        let qty: String?
        let side: String
        let status: String
        let filled_avg_price: String?
        let filled_at: String?
        var filledPrice: Double? { filled_avg_price.flatMap(Double.init) }
    }

    struct Account: Decodable, Sendable {
        let equity: String
        let cash: String
        let trading_blocked: Bool
        var equityValue: Double { Double(equity) ?? 0 }
    }

    /// A bracket order: entry + stop-loss + take-profit submitted as ONE object, so the exit legs
    /// exist at the broker the instant the entry fills. This is the whole reason to use a real API
    /// rather than a poll loop — the stop does not depend on this app still being open.
    private struct BracketRequest: Encodable {
        struct Leg: Encodable { let stop_price: String?; let limit_price: String? }
        let symbol: String
        let qty: String
        let side: String
        let type: String
        let time_in_force: String
        let limit_price: String
        let order_class: String
        let stop_loss: Leg
        let take_profit: Leg
    }

    enum BrokerError: LocalizedError {
        case notConfigured
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No broker keys — add Alpaca PAPER keys in Settings."
            case .http(let c, let b): return "Broker rejected the request (HTTP \(c)): \(b)"
            }
        }
    }

    // MARK: Transport

    private nonisolated static func request(_ path: String, method: String = "GET",
                                            body: Data? = nil) throws -> URLRequest {
        guard configured else { throw BrokerError.notConfigured }
        var r = URLRequest(url: URL(string: paperBase + path)!)
        r.httpMethod = method
        r.setValue(keyID, forHTTPHeaderField: "APCA-API-KEY-ID")
        r.setValue(keySecret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 20
        return r
    }

    private nonisolated static func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw BrokerError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: API

    nonisolated static func account() async throws -> Account {
        try await send(request("/v2/account"), as: Account.self)
    }

    nonisolated static func positions() async throws -> [Position] {
        try await send(request("/v2/positions"), as: [Position].self)
    }

    nonisolated static func openOrders() async throws -> [Order] {
        try await send(request("/v2/orders?status=open&limit=200"), as: [Order].self)
    }

    nonisolated static func closedOrders(after: Date) async throws -> [Order] {
        let iso = ISO8601DateFormatter().string(from: after)
        let q = "/v2/orders?status=closed&limit=500&after=\(iso)"
        return try await send(request(q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q),
                              as: [Order].self)
    }

    /// Submit a long bracket. `limit`, `stop` and `target` are pre-snapped to the venue tick by the
    /// caller (StockSageTickSize) — an unsnapped price is rejected by the venue, not silently rounded.
    nonisolated static func submitBracket(symbol: String, shares: Int, limit: Double,
                                          stop: Double, target: Double) async throws -> Order {
        let req = BracketRequest(
            symbol: symbol.uppercased(),
            qty: String(shares),
            side: "buy",
            type: "limit",
            // DAY, never GTC: an unattended loop must not leave a resting order alive overnight
            // for a thesis that was computed against yesterday's board.
            time_in_force: "day",
            limit_price: String(format: "%.2f", limit),
            order_class: "bracket",
            stop_loss: .init(stop_price: String(format: "%.2f", stop), limit_price: nil),
            take_profit: .init(stop_price: nil, limit_price: String(format: "%.2f", target))
        )
        let body = try JSONEncoder().encode(req)
        return try await send(request("/v2/orders", method: "POST", body: body), as: Order.self)
    }

    /// Market-close a position — the time-stop path. Cancels the resting bracket legs first, since
    /// Alpaca rejects a close while an OCO leg still holds the shares.
    nonisolated static func closePosition(symbol: String) async throws {
        _ = try? await send(request("/v2/positions/\(symbol.uppercased())?cancel_orders=true",
                                    method: "DELETE"), as: Order.self)
    }
}
```

---

## New file: `StockSage/Sources/StockSage/StockSageAutoTrader.swift`

```swift
import Foundation

// MARK: - Autonomous paper trader (US names only)
//
// Runs the app's own rules end-to-end against a REAL broker API on PAPER money: picks buy-family
// ideas, sizes them off the stop (the same discipline the whole app is built on), submits a bracket
// so the exits live at the broker, and time-stops anything that hasn't resolved inside the planned
// hold. Every trade is a real order object with a real fill — this is the forward test the
// backtester and the internal paper book can only approximate.
//
// SCOPE: US bare tickers only (StockSageBroker.tradable). Tadawul has no retail order API at any
// broker, so `.SR` ideas are skipped here and remain on StockSagePaperTrader's internal book.
//
// HONESTY FLOOR — three non-negotiables:
//   1. Alpaca paper models NO slippage, market impact, queue position or fees (their docs).
//      `netR(of:)` below deducts StockSageNetEdge.defaultCosts, and the UI shows gross and net
//      SIDE BY SIDE, labelled. The gross number alone is not a result, it is a mirage.
//   2. Every gate the manual path applies still applies: Sharia screen, portfolio heat cap,
//      freshness. An auto path that skips a gate the human path enforces is a lie about what
//      the app does.
//   3. macOS only. iOS suspends backgrounded apps, so a phone cannot host this loop; pretending
//      otherwise would produce a book with silent holes in it.
@MainActor
final class StockSageAutoTrader {
    static let shared = StockSageAutoTrader()
    private init() {}

    // MARK: Settings

    static let enabledKey      = "stocksage.auto.enabled"
    static let maxPositionsKey = "stocksage.auto.maxPositions"
    static let riskPctKey      = "stocksage.auto.riskPercent"
    static let maxHoldDaysKey  = "stocksage.auto.maxHoldDays"
    static let maxPerDayKey    = "stocksage.auto.maxNewPerDay"

    static let defaultMaxPositions = 5
    static let defaultRiskPercent  = 0.5     // % of paper equity risked per trade
    static let defaultMaxHoldDays  = 5       // the "< 5 days" horizon
    static let defaultMaxNewPerDay = 3

    nonisolated static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    nonisolated static var maxPositions: Int {
        StockSageAlertBudgetPrefs.int(maxPositionsKey, or: defaultMaxPositions)
    }
    nonisolated static var riskFraction: Double {
        StockSageAlertBudgetPrefs.double(riskPctKey, or: defaultRiskPercent) / 100
    }
    nonisolated static var maxHoldDays: Int {
        StockSageAlertBudgetPrefs.int(maxHoldDaysKey, or: defaultMaxHoldDays)
    }
    nonisolated static var maxNewPerDay: Int {
        StockSageAlertBudgetPrefs.int(maxPerDayKey, or: defaultMaxNewPerDay)
    }

    /// symbol → the day it was opened, so the time stop survives a relaunch (same day-keyed
    /// persistence rationale as StockSageAlertBudget: in-memory state is erased by every process
    /// death, and an erased open-date means a position that never time-stops).
    private struct Book: Codable { var openedOn: [String: Date] = [:] }
    private static let bookKey = "stocksage.auto.book"
    private var book: Book = {
        guard let d = UserDefaults.standard.data(forKey: bookKey),
              let b = try? JSONDecoder().decode(Book.self, from: d) else { return Book() }
        return b
    }()
    private func saveBook() {
        if let d = try? JSONEncoder().encode(book) { UserDefaults.standard.set(d, forKey: Self.bookKey) }
    }

    private(set) var lastError: String = ""
    private(set) var lastRunAt: Date?
    private var openedToday: [String: Int] = [:]   // dayKey → count

    // MARK: The cycle

    /// One pass: time-stop what's overdue, then open what qualifies. Safe to call on the monitor's
    /// cadence — it is idempotent (it reads live broker positions each time rather than trusting
    /// local state) and it opens at most `maxNewPerDay` positions per UTC day.
    func runCycle() async {
        guard Self.enabled, StockSageBroker.configured else { return }
        // Kill switch: a blocked account or an unreachable broker must stop the loop, not guess.
        guard let account = try? await StockSageBroker.account(), !account.trading_blocked else {
            lastError = "Broker unreachable or trading blocked — auto-trader idle."
            return
        }
        guard !StockSageMarketHours.isClosed(market: .nasdaq) else { return }

        do {
            let positions = try await StockSageBroker.positions()
            try await timeStopOverdue(positions)
            try await openQualifying(equity: account.equityValue,
                                     held: Set(positions.map { $0.symbol.uppercased() }))
            lastError = ""
        } catch {
            lastError = error.localizedDescription
        }
        lastRunAt = Date()
    }

    /// Close anything past the planned hold. This is StockSageTimeStop's rule applied for real:
    /// a trade that hasn't worked in the time you gave it is tying up capital, and on a <5-day
    /// horizon the bracket's stop/target may simply never be touched.
    private func timeStopOverdue(_ positions: [StockSageBroker.Position]) async throws {
        let now = Date()
        for p in positions {
            let sym = p.symbol.uppercased()
            guard let opened = book.openedOn[sym] else {
                // Unknown open date (opened before this build, or the book was lost): adopt it now
                // rather than closing a position on a date we cannot justify.
                book.openedOn[sym] = now; saveBook(); continue
            }
            guard let ts = StockSageTimeStop.suggest(openedAt: opened, now: now,
                                                     daysToHold: Self.maxHoldDays), ts.shouldExit
            else { continue }
            try await StockSageBroker.closePosition(symbol: sym)
            book.openedOn[sym] = nil
            saveBook()
        }
    }

    private func openQualifying(equity: Double, held: Set<String>) async throws {
        let dayKey = StockSageScanChunking.utcDayKey(Date())
        var todays = openedToday[dayKey] ?? 0
        guard todays < Self.maxNewPerDay, held.count < Self.maxPositions else { return }

        // SAME source as every prescriptive surface: Sharia-screened, never the raw list.
        let ideas = StockSageShariaScreen.screened(StockSageStore.shared.ideas)
        for idea in ideas {
            guard todays < Self.maxNewPerDay, held.count + todays < Self.maxPositions else { break }
            let sym = idea.symbol.uppercased()
            guard StockSageBroker.tradable(sym), !held.contains(sym), book.openedOn[sym] == nil else { continue }
            let a = idea.advice
            guard a.action == .strongBuy || a.action == .buy,
                  let stop = a.stopPrice, let target = a.targetPrice,
                  idea.price > stop, stop > 0, target > idea.price else { continue }
            // Never trade off a price the board itself calls stale (same gate the push path uses).
            guard let row = StockSageStore.shared.symbols.first(where: { $0.symbol.uppercased() == sym }),
                  !row.isStale() else { continue }

            let size = StockSagePositionSizer.size(account: equity, riskFraction: Self.riskFraction,
                                                  entry: idea.price, stop: stop)
            let shares = Int(size.shares)
            guard shares >= 1 else { continue }

            // Snap every price to the venue tick — an unsnapped limit is REJECTED, not rounded.
            let limit  = StockSageTickSize.snap(idea.price, symbol: sym)
            let sStop  = StockSageTickSize.snap(stop, symbol: sym)
            let sTgt   = StockSageTickSize.snap(target, symbol: sym)
            guard limit > sStop, sTgt > limit else { continue }

            _ = try await StockSageBroker.submitBracket(symbol: sym, shares: shares,
                                                       limit: limit, stop: sStop, target: sTgt)
            book.openedOn[sym] = Date(); saveBook()
            todays += 1
            openedToday[dayKey] = todays
        }
    }

    // MARK: - Honest results

    /// Net R for a closed round trip, with the frictions Alpaca's paper engine omits added back.
    /// Alpaca's docs are explicit that paper models no slippage, market impact, queue position or
    /// fees — on a <5-day horizon those ARE the result, so a gross paper R is not a measurement.
    /// Convention matches StockSagePaperTrader exactly: costPerShare = roundTripBps/10_000 × entry.
    nonisolated static func netR(entry: Double, exit: Double, stop: Double, symbol: String) -> Double? {
        let risk = entry - stop
        guard entry > 0, risk > 0 else { return nil }
        let bps = StockSageNetEdge.defaultCosts(forSymbol: symbol).roundTripBps
        let costPerShare = Swift.max(0, bps) / 10_000 * entry
        return ((exit - costPerShare) - entry) / risk
    }

    /// Display string for the results card. States BOTH figures and names the gap, because the gap
    /// is the whole point: it is the cost the paper engine did not charge you.
    nonisolated static func resultLine(grossR: Double, netR: Double, trades: Int) -> String {
        "\(trades) closed · \(String(format: "%+.2f", netR))R net (measured cost model) · "
        + "\(String(format: "%+.2f", grossR))R gross — the gap is slippage/fees Alpaca's paper "
        + "engine does not charge. Only the net figure is a result."
    }
}
```

---

## Wiring

**1. Drive it from the monitor.** In `StockSageMonitor.runCycle`, after the alert work (`:196`):

```swift
                // Autonomous paper execution (macOS only — iOS suspends the loop, so a phone
                // would produce a book with silent holes in it). Self-guards on its own enable
                // flag, broker config, and market hours.
                #if os(macOS)
                await StockSageAutoTrader.shared.runCycle()
                #endif
```

**2. Settings — new section**, macOS-fenced:

```swift
                Section("Autonomous paper trading (US names only)") {
                    Toggle("Enabled", isOn: $autoEnabled)
                    SecureField("Alpaca PAPER key ID", text: $brokerKeyID)
                    SecureField("Alpaca PAPER secret", text: $brokerSecret)
                    Stepper("Max open positions: \(autoMaxPositions)", value: $autoMaxPositions, in: 1...20)
                    Stepper("Risk per trade: \(autoRiskPct, specifier: "%.2f")%", value: $autoRiskPct, in: 0.1...2, step: 0.1)
                    Stepper("Max hold: \(autoMaxHold) days", value: $autoMaxHold, in: 1...30)
                    Stepper("Max new per day: \(autoMaxPerDay)", value: $autoMaxPerDay, in: 1...10)
                    Text("PAPER ONLY. This places real orders against Alpaca's simulated account with real-time quotes — it cannot reach real money, and it cannot reach Tadawul (no Saudi broker publishes a retail order API). Alpaca's paper engine charges no slippage or fees, so results are shown net of this app's own measured cost model beside the raw figure. Only the net figure is a result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

**3. Get keys:** sign up at alpaca.markets for a Paper-Only account (email address, no approval, free), generate paper API keys, paste them in. They start you at $100,000 simulated and you can reset any time.

---

## Tests: `StockSageTests/StockSageAutoTraderTests.swift`

```swift
import Testing
import Foundation
@testable import StockSage

struct StockSageAutoTraderTests {
    typealias AT = StockSageAutoTrader
    typealias BK = StockSageBroker

    @Test func onlyBareUSTickersRouteToTheBroker() {
        #expect(BK.tradable("AAPL"))
        #expect(BK.tradable("NVDA"))
        // Tadawul has no retail order API — the fence must hold.
        #expect(BK.tradable("2222.SR") == false)
        #expect(BK.tradable("1120.SR") == false)
        #expect(BK.tradable("^GSPC") == false)
        #expect(BK.tradable("BTC-USD") == false)
        #expect(BK.tradable("") == false)
    }

    @Test func netRDeductsTheCostAlpacaPaperOmits() {
        // US large-cap default is 13bps round-trip (StockSageNetEdge.defaultCosts).
        // entry 100, stop 95 (risk 5), exit 105 → gross +1.00R.
        let net = try #require(AT.netR(entry: 100, exit: 105, stop: 95, symbol: "AAPL"))
        // costPerShare = 13/10_000 × 100 = 0.13 → (104.87 − 100)/5 = 0.974
        #expect(abs(net - 0.974) < 1e-9)
        #expect(net < 1.0)   // net is ALWAYS below gross — that is the point
    }

    @Test func netRIsNilWhenRiskIsUndefined() {
        #expect(AT.netR(entry: 100, exit: 105, stop: 100, symbol: "AAPL") == nil)  // zero risk
        #expect(AT.netR(entry: 0, exit: 105, stop: -1, symbol: "AAPL") == nil)
    }

    @Test func resultLineStatesBothFiguresAndNamesTheGap() {
        let s = AT.resultLine(grossR: 1.0, netR: 0.97, trades: 12)
        #expect(s.contains("12 closed"))
        #expect(s.contains("+0.97R net"))
        #expect(s.contains("+1.00R gross"))
        #expect(s.contains("Only the net figure is a result"))
    }

    @Test func theTimeStopFiresAtTheConfiguredHorizon() {
        let opened = Date(timeIntervalSince1970: 1_000_000)
        let day4 = opened.addingTimeInterval(4 * 86_400)
        let day5 = opened.addingTimeInterval(5 * 86_400)
        #expect(StockSageTimeStop.suggest(openedAt: opened, now: day4, daysToHold: 5)?.shouldExit == false)
        #expect(StockSageTimeStop.suggest(openedAt: opened, now: day5, daysToHold: 5)?.shouldExit == true)
    }
}
```

---

## What to expect, so the result doesn't surprise you

Run it for six to eight weeks. Then read **only** the net figure.

Your engine's measured Deflated Sharpe is ≈ 0 and the UI says so. At a 5-day hold you're turning over ~50× a year against 13 bps, so roughly 6.5% of capital a year goes to friction. The most likely honest outcome is a net result somewhere around flat-to-negative, and the gross figure looking deceptively fine. If that's what comes back, the test worked — it cost you nothing and it told you something real about a strategy you were otherwise going to fund with money.

And if the net figure is genuinely, durably positive across enough closed trades to mean anything, you'll have measured evidence instead of a hunch. That's a much better position to be in than either of us guessing tonight.

The Tadawul half stays manual regardless. That isn't me being cautious — there is nothing to connect to.

**Sources:** [Alpaca paper trading docs](https://docs.alpaca.markets/us/docs/paper-trading) · [Alpaca Trading API](https://docs.alpaca.markets/us/docs/trading-api) · [Algorithmic Trading on Tadawul: Permitted or Not?](https://www.mondaq.com/saudiarabia/financial-services/1150576/algorithmic-trading-on-tadawul-permitted-or-not)
