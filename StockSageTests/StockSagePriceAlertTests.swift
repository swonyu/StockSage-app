import Testing
import Foundation
@testable import StockSage

// MARK: - User-set price alerts (async race replay + pure rules)

struct StockSagePriceAlertTests {
    @MainActor @Test(arguments: ["removed", "muted", "triggered", "edited", "replaced", "rearmed", "cancelled", "unchanged"])
    func changesDuringQuoteFetchInvalidateTheCapturedAlert(change: String) async throws {
        let name = "price-alert.fetch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
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
        let defaults = try #require(UserDefaults(suiteName: name))
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
        let defaults = try #require(UserDefaults(suiteName: name))
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
