import Testing
import Foundation
import Combine
@testable import StockSage

// MARK: - User-set price alerts (async race replay + pure rules)

struct StockSagePriceAlertTests {
    @MainActor @Test(arguments: ["add", "remove", "rearm", "trigger", "import"])
    func unregisteredWriterCannotMutatePriceAlerts(action: String) throws {
        let name = "alerts.unregistered-mutation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let alert = PriceAlert(symbol: "AAPL", target: 100, direction: .above)
        defaults.set(try JSONEncoder().encode([alert]), forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: name) ?? [:]
        switch action {
        case "add": #expect(!store.addPriceAlert(symbol: "MSFT", target: 200, direction: .above))
        case "remove": store.removePriceAlert(alert.id)
        case "rearm": store.resetPriceAlert(alert.id)
        case "trigger": store.markPriceAlertsTriggered([alert.id])
        default:
            #expect(throws: StockSageFileLock.Failure.self) {
                try store.preparePriceAlertBackupImport([PriceAlert(symbol: "MSFT", target: 200, direction: .above)])
            }
        }
        #expect(store.priceAlerts == [alert])
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: name) ?? [:]))
    }

    @MainActor @Test func unregisteredWriterCannotMonitorOrDeliverAnArmedAlert() async throws {
        let name = "alerts.unregistered-delivery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let alert = PriceAlert(symbol: "AAPL", target: 100, direction: .above)
        defaults.set(try JSONEncoder().encode([alert]), forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let before = defaults.persistentDomain(forName: name) ?? [:]
        #expect(store.priceAlertsForMonitoring().isEmpty)
        #expect(store.priceAlertsPersistenceError != nil)
        var fetched = false, sent = false, marked = false
        // Supply a captured alert directly: the delivery owner must enforce its own lease,
        // even if a caller retained a previously armed definition.
        await StockSageMonitor(defaults: defaults).checkPriceAlerts(currentAlerts: { [alert] }, fetchQuotes: { _ in
            fetched = true
            return ["AAPL": .init(symbol: "AAPL", price: 110, previousClose: 100, marketTime: Date())]
        }, enqueue: { _, _ in sent = true; return true }, markTriggered: { _ in marked = true })
        #expect(!fetched && !sent && !marked)
        #expect(NSDictionary(dictionary: before).isEqual(to: defaults.persistentDomain(forName: name) ?? [:]))
    }

    @MainActor @Test func everyFailedSavePublishesFeedbackEvenWhenTheMessageIsUnchanged() throws {
        let name = "alerts.repeated-error.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        defaults.set("invalid", forKey: "stocksage_price_alerts")
        var failures = 0
        let subscription = store.$priceAlertsPersistenceError.sink { if $0 != nil { failures += 1 } }
        defer { subscription.cancel() }
        for _ in 0..<2 { #expect(!store.addPriceAlert(symbol: "AAPL", target: 100, direction: .above)) }
        #expect(failures == 2)
        #expect(store.priceAlertsForMonitoring().isEmpty)
        #expect(store.priceAlertsForMonitoring().isEmpty)
        #expect(failures == 3, "Unchanged background errors notify once; user edits still notify each time")
        #expect(defaults.string(forKey: "stocksage_price_alerts") == "invalid")
    }
    @MainActor @Test func recoveredStorageUpdatesVisibleAlertsBeforeAnyUserMutation() throws {
        let name = "alerts.read-recovery.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("invalid", forKey: "stocksage_price_alerts")
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        let records = [PriceAlert(symbol: "RECOVERED", target: 100, direction: .above)]
        defaults.set(try JSONEncoder().encode(records), forKey: "stocksage_price_alerts")
        #expect(store.priceAlertsForMonitoring() == records)
        #expect(store.priceAlerts == records && store.priceAlertsPersistenceError == nil)
    }
    @MainActor @Test func acceptedDeliverySurvivesCorruptStorageWithoutResending() async throws {
        let name = "alerts.accepted-corrupt.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(store.addPriceAlert(symbol: "FIRST", target: 100, direction: .above))
        #expect(store.addPriceAlert(symbol: "SECOND", target: 100, direction: .above))
        let records = store.priceAlerts
        let saved = try JSONEncoder().encode(records)
        let corrupt = Data("[{".utf8)
        var sent: [UUID] = []
        let monitor = StockSageMonitor(defaults: defaults)
        func cycle() async {
            await monitor.checkPriceAlerts(currentAlerts: { store.priceAlertsForMonitoring() }, fetchQuotes: { symbols in
                Dictionary(uniqueKeysWithValues: symbols.map {
                    ($0, .init(symbol: $0, price: 110, previousClose: 100, marketTime: Date()))
                })
            }, enqueue: { alert, _ in
                sent.append(alert.id)
                defaults.set(corrupt, forKey: "stocksage_price_alerts")
                await Task.yield()
                return true
            }, markTriggered: { store.markPriceAlertsTriggered($0) })
        }
        await cycle()
        await cycle()
        #expect(sent == [records[0].id])
        #expect(store.priceAlerts.first?.isArmed == false)
        #expect(store.priceAlertsPersistenceError != nil)
        #expect(defaults.data(forKey: "stocksage_price_alerts") == corrupt)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == 1)
        defaults.set(saved, forKey: "stocksage_price_alerts") // Synthetic recovery, not owner data.
        #expect(store.priceAlertsForMonitoring().first?.isArmed == false)
        #expect(store.priceAlertsPersistenceError == nil)
        let recovered = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(recovered.priceAlerts.first?.isArmed == false, "Recovery must persist the accepted delivery without another Add")
        #expect(store.addPriceAlert(symbol: "THIRD", target: 100, direction: .above))
        let restarted = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(restarted.priceAlerts.first?.isArmed == false)
        #expect(restarted.priceAlerts.count == 3)
    }

    @MainActor @Test(arguments: ["add", "remove", "rearm"])
    func corruptStorageRefusesUserEditsWithoutOptimisticChanges(edit: String) throws {
        let name = "alerts.edit-corrupt.\(UUID())"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] })
        #expect(store.addPriceAlert(symbol: "AAPL", target: 100, direction: .above))
        let before = store.priceAlerts
        defaults.set("invalid", forKey: "stocksage_price_alerts")
        switch edit {
        case "add": #expect(!store.addPriceAlert(symbol: "MSFT", target: 200, direction: .above))
        case "remove": store.removePriceAlert(before[0].id)
        default: store.resetPriceAlert(before[0].id)
        }
        #expect(store.priceAlerts == before)
        #expect(store.priceAlertsPersistenceError != nil)
        #expect(defaults.string(forKey: "stocksage_price_alerts") == "invalid")
    }
    @MainActor @Test(arguments: ["removed", "muted", "triggered", "edited", "replaced", "rearmed", "cancelled", "unchanged"])
    func changesDuringQuoteFetchInvalidateTheCapturedAlert(change: String) async throws {
        let name = "price-alert.fetch.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = PriceAlert(symbol: "TEST", target: 100, direction: .above)
        var live = [original]
        var sent: [UUID] = []
        var marked: [UUID] = []
        let monitor = StockSageMonitor(defaults: defaults)
        let run = Task {
            await monitor.checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { symbols in
                #expect(symbols == ["TEST"])
                switch change {
                case "removed": live = []
                case "muted":
                    defaults.set(false, forKey: StockSageNotifyPrefs.priceAlertsKey)
                    #expect(!StockSageNotifyPrefs.enabled(StockSageNotifyPrefs.priceAlertsKey, defaults: defaults))
                case "triggered": live[0].triggeredAt = Date()
                case "edited": live = [PriceAlert(id: original.id, symbol: "TEST", target: 120, direction: .above)]
                case "replaced": live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
                case "rearmed":
                    live[0].triggeredAt = Date() // another cycle completes before the owner re-arms
                    live[0] = live[0].rearmed()
                case "cancelled": withUnsafeCurrentTask { $0?.cancel() }
                default: break
                }
                await Task.yield()
                return ["TEST": .init(symbol: "TEST", price: 110, previousClose: 100, marketTime: Date())]
            }, enqueue: { alert, price in
                #expect(price == 110)
                sent.append(alert.id)
                return true
            }, markTriggered: { marked.append(contentsOf: $0) })
        }
        await run.value
        let expected = change == "unchanged" ? [original.id] : []
        #expect(sent == expected, "obsolete alert sent after \(change) during fetch")
        #expect(marked == expected)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == expected.count)
    }

    @MainActor @Test(arguments: ["removed", "muted", "triggered", "edited", "rearmed", "cancelled", "unchanged"])
    func changesDuringFirstEnqueueProtectTheRestOfTheBatch(change: String) async throws {
        let name = "price-alert.batch.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = PriceAlert(symbol: "FIRST", target: 100, direction: .above)
        let second = PriceAlert(symbol: "SECOND", target: 100, direction: .above)
        var live = [first, second]
        var sent: [UUID] = []
        var marked: [UUID] = []
        let monitor = StockSageMonitor(defaults: defaults)
        let run = Task {
            await monitor.checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { symbols in
                Dictionary(uniqueKeysWithValues: symbols.map {
                    ($0, .init(symbol: $0, price: 110, previousClose: 100, marketTime: Date()))
                })
            }, enqueue: { alert, _ in
                sent.append(alert.id)
                if alert.id == first.id {
                    switch change {
                    case "removed": live.removeLast()
                    case "muted": defaults.set(false, forKey: StockSageNotifyPrefs.priceAlertsKey)
                    case "triggered": live[1].triggeredAt = Date()
                    case "edited": live[1] = PriceAlert(id: second.id, symbol: "SECOND", target: 120, direction: .above)
                    case "rearmed":
                        live[1].triggeredAt = Date()
                        live[1] = live[1].rearmed()
                    case "cancelled": withUnsafeCurrentTask { $0?.cancel() }
                    default: break
                    }
                    await Task.yield()
                }
                return true
            }, markTriggered: { marked.append(contentsOf: $0) })
        }
        await run.value
        let expected = change == "unchanged" ? [first.id, second.id] : [first.id]
        #expect(sent == expected)
        // The first accepted enqueue MUST be latched even if its task was cancelled meanwhile.
        #expect(marked == expected)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == expected.count)
    }

    @MainActor @Test func rearmUsesANewOneShotIdentityWithoutChangingThePriceRule() throws {
        let old = PriceAlert(symbol: "TEST", target: 100, direction: .above, triggeredAt: Date())
        let fresh = old.rearmed()
        #expect(fresh.id != old.id)
        #expect(fresh.symbol == old.symbol && fresh.target == old.target && fresh.direction == old.direction)
        #expect(fresh.isArmed && !old.isArmed)
        #expect(fresh.rearmed().id != fresh.id) // even an armed→armed reset invalidates old work
        let decoded = try JSONDecoder().decode(PriceAlert.self, from: JSONEncoder().encode(fresh))
        #expect(decoded == fresh)
    }

    @MainActor @Test(arguments: ["failed", "rearmed"])
    func lateEnqueueResultOnlyConsumesItsOriginalArm(change: String) async throws {
        let name = "price-alert.completion.\(UUID().uuidString)"
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var live = [PriceAlert(symbol: "TEST", target: 100, direction: .above)]
        let originalID = live[0].id
        var attempts = 0
        let monitor = StockSageMonitor(defaults: defaults)
        func cycle() async {
            await monitor.checkPriceAlerts(currentAlerts: { live }, fetchQuotes: { _ in
                ["TEST": .init(symbol: "TEST", price: 110, previousClose: 100, marketTime: Date())]
            }, enqueue: { _, _ in
                attempts += 1
                if attempts == 1 {
                    if change == "failed" { return false }
                    live[0] = live[0].rearmed()
                    await Task.yield()
                }
                return true
            }, markTriggered: { ids in
                // Same ID-filtered latch as Store.markPriceAlertsTriggered; never overwrite
                // a replacement arm merely because it occupies the old array position.
                for i in live.indices where ids.contains(live[i].id) { live[i].triggeredAt = Date() }
            })
        }
        await cycle()
        #expect(attempts == 1 && live[0].isArmed)
        #expect((live[0].id != originalID) == (change == "rearmed"))
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == (change == "failed" ? 0 : 1))
        await cycle()
        #expect(attempts == 2 && !live[0].isArmed)
        #expect(StockSageNotificationBudget(loadingFrom: defaults).recentAlerts.count == (change == "failed" ? 1 : 2))
        await cycle()
        #expect(attempts == 2)
    }

    @Test func isMetAboveAndBelow() {
        let above = PriceAlert(symbol: "AAPL", target: 150, direction: .above)
        #expect(above.isMet(by: 150))
        #expect(above.isMet(by: 151))
        #expect(!above.isMet(by: 149))
        let below = PriceAlert(symbol: "AAPL", target: 100, direction: .below)
        #expect(below.isMet(by: 100))
        #expect(below.isMet(by: 99))
        #expect(!below.isMet(by: 101))
    }

    @Test func newlyTriggeredFiltersArmedMetWithPrice() {
        let a = PriceAlert(symbol: "AAPL", target: 150, direction: .above)                       // armed, met @151
        let b = PriceAlert(symbol: "NVDA", target: 200, direction: .above)                       // armed, not met @150
        let c = PriceAlert(symbol: "MSFT", target: 300, direction: .above, triggeredAt: Date())  // already triggered
        let d = PriceAlert(symbol: "TSLA", target: 100, direction: .below)                       // no price supplied
        let fired = StockSagePriceAlertEngine.newlyTriggered(
            [a, b, c, d], prices: ["AAPL": 151, "NVDA": 150, "MSFT": 350])
        #expect(fired.map(\.symbol) == ["AAPL"])
    }

    // BATCH 12.3 (2026-09-12) — a legacy lowercase alert must still fire.
    //
    // `PriceAlert.init` uppercases, but Codable synthesis does NOT call init, so a record written
    // before that normalization keeps its spelling on disk. Every producer of `prices` keys
    // uppercase (StockSageMonitor:371, StockSageQuoteService:87/:106), so the raw lookup missed
    // and the alert silently never fired. The monitor's `?? a.target` fallback then pushed the
    // alert's OWN TARGET as the observed price — a fabricated market observation.
    //
    // The fixture is built by DECODING RAW JSON on purpose. Constructing it with `PriceAlert(...)`
    // would uppercase the symbol and this test would pass with or without the fix — the exact
    // vacuity that let the defect survive `codableRoundTripAndUppercasing`.
    @Test func aLegacyLowercaseAlertStillMatchesAnUppercasedQuote() throws {
        let json = Data("""
        {"id":"00000000-0000-0000-0000-0000000000AA","symbol":"nvda","target":200,"direction":"above"}
        """.utf8)
        let legacy = try JSONDecoder().decode(PriceAlert.self, from: json)
        // Premise: decoding really does bypass the uppercasing init. If this ever fails, the
        // storage contract changed and the rest of this test is no longer measuring anything.
        #expect(legacy.symbol == "nvda", "decode must bypass init, or this test is vacuous")

        let fired = StockSagePriceAlertEngine.newlyTriggered([legacy], prices: ["NVDA": 201])
        #expect(fired.count == 1, "a legacy lowercase alert must still match an uppercased quote")
        // And it must still respect the level — normalizing the key cannot loosen the trigger.
        #expect(StockSagePriceAlertEngine.newlyTriggered([legacy], prices: ["NVDA": 199]).isEmpty)
        // An unrelated symbol is still no match.
        #expect(StockSagePriceAlertEngine.newlyTriggered([legacy], prices: ["AAPL": 500]).isEmpty)
    }

    @Test func validateTargetParsesAndRejects() {
        #expect(StockSagePriceAlertEngine.validateTarget("").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("abc").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("0").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("-5").price == nil)
        #expect(StockSagePriceAlertEngine.validateTarget("150").price == 150)
        #expect(StockSagePriceAlertEngine.validateTarget("1,500.5").price == 1500.5)
        // A comma is a DECIMAL separator on the market the owner actually trades. Stripping it
        // turned "28,50" into 2850 — a 100x price target, silently accepted.
        #expect(StockSagePriceAlertEngine.validateTarget("28,50").price == 28.5)
        #expect(StockSagePriceAlertEngine.validateTarget("2,5").price == 2.5)
        #expect(StockSagePriceAlertEngine.validateTarget("1,000").price == 1000)
    }

    @Test func codableRoundTripAndUppercasing() throws {
        let a = PriceAlert(symbol: "aapl", target: 150, direction: .below)   // init uppercases
        let data = try JSONEncoder().encode([a])
        let back = try JSONDecoder().decode([PriceAlert].self, from: data)
        #expect(back.first?.symbol == "AAPL")
        #expect(back.first?.direction == .below)
        #expect(back.first?.isArmed == true)
    }
}
