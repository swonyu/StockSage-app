import Testing
import Foundation
@testable import StockSage

// MARK: - Stream-triggered price alerts + day-volume alerts
//
// Replays the stream path with injected ticks, clock, delivery and REST confirmation: no socket,
// no network, no shared board and no system notification.

struct StockSageLiveAlertTests {
    typealias Monitor = StockSageMonitor
    /// Thursday 2026-09-10: 11:00 ET (regular session) and 08:00 ET (pre-market).
    private let regular = ISO8601DateFormatter().date(from: "2026-09-10T15:00:00Z")!
    private let preMarket = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

    private func tick(_ symbol: String, _ price: Double, at time: Date, conditions: [Int64]? = nil) -> StockSageLiveStream.Tick {
        .init(symbol: symbol, price: price, timestamp: time, conditions: conditions)
    }

    // MARK: Model and storage

    @MainActor @Test func legacyJSONDecodesAsAPriceAlertAndPriceAlertsKeepTheirBytes() throws {
        let json = Data(#"[{"id":"00000000-0000-0000-0000-0000000000AB","symbol":"AAPL","target":150,"direction":"above"}]"#.utf8)
        let decoded = try JSONDecoder().decode([PriceAlert].self, from: json)
        let legacy = try #require(decoded.first)
        #expect(legacy.metric == nil && legacy.resolvedMetric == .price)
        #expect(legacy == PriceAlert(id: legacy.id, symbol: "AAPL", target: 150, direction: .above))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [[String: Any]])
        #expect(encoded.first?["metric"] == nil, "price alerts must keep the pre-metric stored form")

        let volume = PriceAlert(symbol: "AAPL", target: 5_000_000, direction: .above, metric: .dayVolume)
        let back = try JSONDecoder().decode(PriceAlert.self, from: JSONEncoder().encode(volume))
        #expect(back == volume && back.resolvedMetric == .dayVolume)
        #expect(back.rearmed().resolvedMetric == .dayVolume)
    }

    @MainActor @Test func dayVolumeAlertsCompareOnlyConfirmedVolume() {
        let alert = PriceAlert(symbol: "AAPL", target: 1_000_000, direction: .above, metric: .dayVolume)
        #expect(StockSagePriceAlertEngine.newlyTriggered([alert], prices: ["AAPL": 2_000_000]).isEmpty)
        #expect(StockSagePriceAlertEngine.newlyTriggered([alert], prices: [:], volumes: ["AAPL": 999_999]).isEmpty)
        #expect(StockSagePriceAlertEngine.newlyTriggered([alert], prices: [:], volumes: ["AAPL": 1_000_000]) == [alert])
        #expect(PriceAlert(symbol: "AAPL", target: 1, direction: .below, metric: .dayVolume).validationError != nil)
    }

    @MainActor @Test func storeAndBackupRoundTripKeepTheVolumeMetric() throws {
        let name = "live-alert.store.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(store.addPriceAlert(symbol: "AAPL", target: 5_000_000, direction: .above, metric: .dayVolume))
        #expect(!store.addPriceAlert(symbol: "AAPL", target: 5_000_000, direction: .above, metric: .dayVolume))
        #expect(store.addPriceAlert(symbol: "AAPL", target: 5_000_000, direction: .above), "same level, different metric")
        #expect(!store.addPriceAlert(symbol: "AAPL", target: 5, direction: .below, metric: .dayVolume))
        let reopened = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(reopened.priceAlerts.map(\.resolvedMetric) == [.dayVolume, .price])

        let alerts = try reopened.backupPriceAlerts()
        #expect(alerts == reopened.priceAlerts)
        let data = try StockSageBackup.export(trades: [], positions: [], userSymbols: [], priceAlerts: alerts)
        let payload = try JSONDecoder().decode(StockSageBackup.BackupPayload.self, from: data)
        #expect(payload.priceAlerts == alerts)
        #expect(StockSageBackup.priceAlertValidationError(in: alerts) == nil)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(json["priceAlerts"] as? [[String: Any]])
        #expect(rows.map { $0["metric"] as? String } == ["dayVolume", nil])
    }

    // MARK: REST day-volume confirmation

    @MainActor @Test func restSnapshotConfirmsOnlyRecentRegularSessionDayVolume() {
        func payload(_ traded: Date) -> Data {
            let ns = Int64(traded.timeIntervalSince1970) * 1_000_000_000
            return Data(#"{"tickers":[{"ticker":"AAPL","day":{"v":1234567},"lastTrade":{"t":\#(ns)}},{"ticker":"MSFT","day":{}}]}"#.utf8)
        }
        let fresh = payload(regular.addingTimeInterval(-60))
        #expect(Monitor.parseDayVolumes(fresh, requested: ["AAPL", "MSFT"], now: regular) == ["AAPL": 1_234_567])
        #expect(Monitor.parseDayVolumes(fresh, requested: ["MSFT"], now: regular).isEmpty)
        #expect(Monitor.parseDayVolumes(payload(regular.addingTimeInterval(-3600)), requested: ["AAPL"], now: regular).isEmpty)
        #expect(Monitor.parseDayVolumes(payload(preMarket.addingTimeInterval(-60)), requested: ["AAPL"], now: preMarket).isEmpty)
        #expect(Monitor.parseDayVolumes(Data("{}".utf8), requested: ["AAPL"], now: regular).isEmpty)
    }

    @MainActor @Test(arguments: [true, false])
    func restConfirmedDayVolumeFiresOnlyWhenMet(met: Bool) async throws {
        let name = "live-alert.volume.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var live = [PriceAlert(symbol: "AAPL", target: 1_000_000, direction: .above, metric: .dayVolume)]
        let volume: Double = met ? 2_000_000 : 500_000
        var sent: [Double] = []
        var quoteFetches = 0
        await Monitor(defaults: defaults).checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { _ in
            quoteFetches += 1
            return [:]
        }, enqueue: { _, observed in
            sent.append(observed)
            return true
        }, markTriggered: { ids in
            for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
        }, fetchDayVolumes: { symbols in
            #expect(symbols == ["AAPL"])
            return ["AAPL": volume]
        })
        #expect(quoteFetches == 0, "a volume alert never reads prices")
        #expect(sent == (met ? [volume] : []))
        #expect(live[0].isArmed == !met)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == (met ? 1 : 0))
    }

    @MainActor @Test func streamNominatesDayVolumeButOnlyRESTConfirmationFires() async throws {
        let name = "live-alert.stream-volume.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 1_000_000, direction: .above, metric: .dayVolume)]
        var confirmations: [[String]] = []
        var sent: [Double] = []
        func check() async {
            await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: {
                confirmations.append($0)
                return ["TEST": 2_000_000]
            }, enqueue: { _, observed in
                sent.append(observed)
                return true
            }, markTriggered: { ids in
                for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
            }, now: { regular })
        }
        await check()
        #expect(confirmations.isEmpty && sent.isEmpty, "no live trade, no nomination, no REST request")
        #expect(monitor.nominateStreamedTicks(["TEST": tick("TEST", 10, at: regular.addingTimeInterval(-1))],
                                              armed: live, now: regular) == ["TEST"])
        await check()
        #expect(confirmations == [["TEST"]])
        #expect(sent == [2_000_000] && !live[0].isArmed)
    }

    // MARK: Stream gates

    @MainActor @Test func streamChecksAreThrottledPerSymbol() throws {
        let name = "live-alert.throttle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = Monitor(defaults: defaults)
        let armed = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        func nominate(_ at: Date) -> [String] {
            monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: at.addingTimeInterval(-1)),
                                           "OTHER": tick("OTHER", 110, at: at.addingTimeInterval(-1))], armed: armed, now: at)
        }
        #expect(nominate(regular) == ["TEST"], "only symbols with an armed alert are nominated")
        #expect(nominate(regular.addingTimeInterval(Monitor.streamCheckInterval - 1)).isEmpty)
        #expect(nominate(regular.addingTimeInterval(Monitor.streamCheckInterval)) == ["TEST"])
        #expect(nominate(regular.addingTimeInterval(60)).count == 1)
        #expect(monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular)], armed: [], now: regular).isEmpty)
    }

    @MainActor @Test(arguments: ["preMarket", "formT", "regular"])
    func extendedHoursStreamedTradesDoNotFire(kind: String) async throws {
        let name = "live-alert.session.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let at = kind == "preMarket" ? preMarket : regular
        let trade = tick("TEST", 110, at: at.addingTimeInterval(-1), conditions: kind == "formT" ? [12] : nil)
        #expect(Monitor.isAlertableStreamTrade(trade, now: at) == (kind == "regular"))
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        var sent = 0
        _ = monitor.nominateStreamedTicks(["TEST": trade], armed: live, now: at)
        await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: { _ in [:] },
            enqueue: { _, _ in sent += 1; return true },
            markTriggered: { ids in for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() } },
            now: { at })
        #expect(sent == (kind == "regular" ? 1 : 0))
        #expect(live[0].isArmed == (kind != "regular"))
    }

    @MainActor @Test func staleStreamedTradesNeverFire() async throws {
        let name = "live-alert.stale.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        var sent = 0
        func check(_ at: Date) async {
            await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: { _ in [:] },
                enqueue: { _, _ in sent += 1; return true },
                markTriggered: { ids in for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() } },
                now: { at })
        }
        // Old at arrival: never recorded.
        #expect(monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular.addingTimeInterval(-30))],
                                              armed: live, now: regular).isEmpty)
        await check(regular)
        #expect(sent == 0)
        // Live at arrival, but aged past the live window before the check ran.
        #expect(monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular.addingTimeInterval(-1))],
                                              armed: live, now: regular) == ["TEST"])
        await check(regular.addingTimeInterval(StockSageLiveStream.maximumLiveAge + 5))
        #expect(sent == 0 && live[0].isArmed)
    }

    @MainActor @Test func hourlyCapHoldsForStreamTriggeredAlerts() async throws {
        let name = "live-alert.cap.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var budget = StockSageNotificationBudget(loadingFrom: defaults)
        for i in 0..<StockSageNotificationBudget.hourlyCap { budget.record(symbol: "SEED\(i)", price: 100) }
        budget.save(to: defaults)
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        var sent = 0
        _ = monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular.addingTimeInterval(-1))], armed: live, now: regular)
        await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: { _ in [:] },
            enqueue: { _, _ in sent += 1; return true },
            markTriggered: { ids in for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() } },
            now: { regular })
        #expect(sent == 0 && live[0].isArmed, "a capped alert stays armed for a later cycle")
    }

    // MARK: Single-flight

    @MainActor @Test func streamCheckDuringLoopFetchIsSkippedAndSendsExactlyOnePush() async throws {
        let name = "live-alert.overlap-loop.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        var sent = 0
        var entered = false, release = false
        defer { release = true } // Never leave the gated task spinning if a requirement throws.
        let loop = Task {
            await monitor.checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { _ in
                entered = true
                while !release { await Task.yield() }
                return ["TEST": .init(symbol: "TEST", price: 110, previousClose: 100, marketTime: Date())]
            }, enqueue: { _, _ in
                sent += 1
                return true
            }, markTriggered: { ids in
                for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
            })
        }
        var spins = 0
        while !entered, spins < 100_000 { spins += 1; await Task.yield() }
        try #require(entered)
        #expect(monitor.priceAlertCheckInFlight)
        _ = monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular.addingTimeInterval(-1))], armed: live, now: regular)
        func streamCheck() async {
            await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: { _ in [:] },
                enqueue: { _, _ in sent += 1; return true },
                markTriggered: { ids in for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() } },
                now: { regular })
        }
        await streamCheck()
        #expect(sent == 0, "the stream check must skip while the loop check is in flight")
        release = true
        await loop.value
        #expect(sent == 1 && !live[0].isArmed && !monitor.priceAlertCheckInFlight)
        await streamCheck()
        #expect(sent == 1, "the latched one-shot never re-pushes")
    }

    @MainActor @Test func loopCheckDuringStreamDeliveryIsSkippedAndSendsExactlyOnePush() async throws {
        let name = "live-alert.overlap-stream.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let monitor = Monitor(defaults: defaults)
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        var sent = 0
        var entered = false, release = false
        defer { release = true } // Never leave the gated task spinning if a requirement throws.
        _ = monitor.nominateStreamedTicks(["TEST": tick("TEST", 110, at: regular.addingTimeInterval(-1))], armed: live, now: regular)
        let stream = Task {
            await monitor.checkStreamedPriceAlerts(currentAlerts: { live }, confirmDayVolumes: { _ in [:] }, enqueue: { _, _ in
                sent += 1
                entered = true
                while !release { await Task.yield() } // Dispatched, not yet latched.
                return true
            }, markTriggered: { ids in
                for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
            }, now: { regular })
        }
        var spins = 0
        while !entered, spins < 100_000 { spins += 1; await Task.yield() }
        try #require(entered)
        func loopCheck() async {
            await monitor.checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { _ in
                ["TEST": .init(symbol: "TEST", price: 110, previousClose: 100, marketTime: Date())]
            }, enqueue: { _, _ in
                sent += 1
                return true
            }, markTriggered: { ids in
                for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
            })
        }
        await loopCheck()
        #expect(sent == 1, "the loop check must skip while a stream delivery is unlatched")
        release = true
        await stream.value
        #expect(sent == 1 && !live[0].isArmed)
        await loopCheck()
        #expect(sent == 1)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 1)
    }
}
