import Foundation
import Testing
#if os(macOS)
import SwiftUI
import AppKit
#endif
@testable import StockSage

@Suite("Manual same-day research", .serialized)
@MainActor struct StockSageSameDayResearchTests {
    typealias S = StockSageSameDayResearch
    typealias T = StockSageMassiveTicks
    let now = ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z")!

    func bars(gap: Bool = false) -> T.Intraday {
        let end = now.addingTimeInterval(-30)
        let values = (0..<60).filter { !gap || $0 != 58 }.map { index in
            T.Minute(at: end.addingTimeInterval(Double(index - 60) * 60),
                open: 100, high: index < 55 ? 104 : 100.2, low: 99,
                close: 100, volume: 1000)
        }
        return .init(facts: ["completed bars"], asOf: end, bars: values, verifiedMinutes: true)
    }
    func quote(age: TimeInterval = 0, ask: Double = 100.1, bid: Double = 100) -> StockSageNBBO {
        var value = StockSageNBBO(symbol: "AAPL", bid: bid, ask: ask, bidSize: 100, askSize: 100,
            bidExchange: 1, askExchange: 1, timestamp: now.addingTimeInterval(-age), sequence: 1)
        value.conditions = [701]
        return value.qualifyingCosts(regularConditions: [701])
    }

    @Test func manualSameDayRunBlocksProductionTopFiveStart() async throws {
        let suite = "stocksage.same-day-exclusion." + UUID().uuidString
        let defaults = try #require(StockSageRecordWriter.fixtureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        #expect(store.isSampleData, "The fixture must prevent provider access even if the exclusion guard regresses")
        let horizon = StockSageHorizonResearch()
        await S.shared.run(selection: .init([listing("AAPL")]), capacity: { 1 }, allowed: { true }, clock: { now },
            analyze: { item, _, _ in
                #expect(!horizon.start(.week, store: store))
                #expect(horizon.scans[.week]?.status.localizedCaseInsensitiveContains("same-day") == true)
                return .init(symbol: item.ticker, name: item.name, at: now, note: "Not qualified")
            }, refreshQuote: { _ in Issue.record("Unqualified fixture must not request a quote"); return nil })
        #expect(!S.shared.isRunning)
    }

    @Test func regularSessionHonorsEntryCutoffEarlyCloseAndCalendarCoverage() throws {
        #expect(S.session(at: now) != nil)
        for text in ["2026-09-19T15:00:00Z", "2026-09-18T13:00:00Z", "2026-11-27T17:55:00Z", "2027-01-04T15:00:00Z"] {
            #expect(S.session(at: ISO8601DateFormatter().date(from: text)!) == nil)
        }
        #expect(S.session(at: .init(timeIntervalSince1970: .nan)) == nil)
    }

    @Test func observedLevelsRequireRecentContinuousMinutesAndRealTarget() throws {
        let plan = try #require(S.scenario(bars(), quote: quote(), at: now))
        #expect(plan.entry == 100.1 && plan.stop == 99 && plan.target == 104)
        #expect(plan.rewardRisk >= 2)
        #expect(S.scenario(bars(gap: true), quote: quote(), at: now) == nil)
        #expect(S.scenario(.init(facts: ["qualified trade"], asOf: now), quote: quote(), at: now) == nil)
        #expect(S.scenario(bars(), quote: quote(age: 6), at: now) == nil)
        #expect(S.scenario(bars(), quote: quote(age: -1), at: now) == nil)
        #expect(S.scenario(bars(), quote: quote(ask: 105), at: now) == nil)
        #expect(S.scenario(bars(), quote: quote(ask: 100.4), at: now) == nil)
    }

    @Test func buyRequiresActualIntradayAndTodayPublicCitation() {
        let facts: [StockSageAIAssessment.EvidenceFact] = [
            .init(key: "sameDay.minute.1", text: "Observed completed minute", required: true,
                availability: .available, factClass: .technical, source: "Massive", observedAt: now.addingTimeInterval(-60)),
            .init(key: "sameDay.catalyst.news.1", text: "Published company report", required: true,
                availability: .available, factClass: .news, source: "Public news", observedAt: now.addingTimeInterval(-600)),
            .init(key: "sameDay.summary", text: "No complete tape", required: true, availability: .unknown)
        ]
        func verdict(_ ids: [String]) -> StockSageAIAssessment.Verdict {
            .init(action: .buy, reason: "Observed support", risk: "Reversal remains possible", evidence: ids)
        }
        #expect(S.qualifies(verdict(["F1", "F2"]), facts: facts, at: now))
        #expect(!S.qualifies(verdict(["F2", "F3"]), facts: facts, at: now))
        #expect(!S.qualifies(verdict(["F1"]), facts: facts, at: now))
        #expect(!S.qualifies(verdict(["F1", "F2"]), facts: facts, at: now.addingTimeInterval(86400)))
    }

    func listing(_ ticker: String) -> StockSageHorizonResearch.Listing {
        .init(ticker: ticker, name: ticker, market: "stocks", locale: "us", active: true,
            type: "CS", currency_name: "usd", primary_exchange: "XNAS")
    }
    func check(_ symbol: String) throws -> S.Check {
        var check = S.Check(symbol: symbol, name: symbol, at: now, note: "Qualified fixture")
        check.action = "Buy"; check.reason = "Observed support"; check.risk = "Reversal remains possible"
        check.scenario = try #require(S.scenario(bars(), quote: quote(), at: now))
        check.expiresAt = now.addingTimeInterval(120)
        check.qualified = true
        return check
    }

    @Test func manualRunPersistsEveryCheckAndOnlyOneFrozenWinner() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = StockSageResearchReceiptStore(directory: folder)
        let engine = S(receiptStore: receipts)
        let candidate = try check("AAPL")
        let requested = now.addingTimeInterval(-30), id = receipts.beginSameDay(at: now.addingTimeInterval(-30))
        let initial = S.Receipt(id: id, startedAt: requested, selection: "Preparing the manual run", checks: [])
        #expect(receipts.saveSameDay(initial))
        await engine.run(selection: .init([listing("AAPL"), listing("MSFT")]), initial: initial, capacity: { 24 },
            allowed: { true }, clock: { now }, analyze: { item, _, _ in
                if item.ticker == "AAPL" { return candidate }
                return .init(symbol: item.ticker, name: item.name, at: now, note: "Missing recent catalyst")
            }, refreshQuote: { _ in quote() })
        let result = try #require(engine.receipt)
        #expect(result.id == id && result.startedAt == requested, "Preparation and collection must retain the same durable request")
        #expect(result.selectedSymbol == "AAPL" && result.checks.count == 2)
        #expect(result.checks.first?.scenario == candidate.scenario, "Final quote must not move the captured levels")
        let restored = try #require(StockSageResearchReceiptStore(directory: folder).latestSameDay)
        #expect(restored == result)
        #expect(receipts.receipt(scanID: result.id)?.horizon == "same-day")
        #expect(receipts.receipt(scanID: result.id)?.attempts.count == 2)
        #expect(!S.current(result, at: now.addingTimeInterval(6)), "Saved pick stops claiming a fresh verified quote")
        await engine.run(selection: .init([]), capacity: { 1 }, allowed: { true }, clock: { now.addingTimeInterval(60) },
            analyze: { _, _, _ in Issue.record("Empty selection cannot infer"); return candidate }, refreshQuote: { _ in nil })
        #expect(engine.receipt?.selectedSymbol == nil)
        #expect(engine.savedReceipts.contains(where: { $0.id == result.id && $0.selectedSymbol == "AAPL" }),
            "A failed new run must not make the earlier successful pick inaccessible")
    }

    @Test func staleWinnerDoesNotSubstituteRunnerUpAndRevokedRunPublishesNoPick() async throws {
        let first = try check("AAPL"), second = try check("MSFT")
        let selection = StockSageResearchUniverse.Selection([listing("AAPL"), listing("MSFT")])
        let engine = S()
        var requested: [String] = []
        await engine.run(selection: selection, capacity: { 24 }, allowed: { true }, clock: { now },
            analyze: { item, _, _ in item.ticker == "AAPL" ? first : second },
            refreshQuote: { symbol in requested.append(symbol); return nil })
        #expect(requested == ["AAPL"])
        #expect(engine.receipt?.selectedSymbol == nil)
        #expect(engine.receipt?.blocker?.contains("winner") == true)
        var access = true
        await engine.run(selection: selection, capacity: { 1 }, allowed: { access }, clock: { now },
            analyze: { _, _, _ in access = false; return first },
            refreshQuote: { _ in Issue.record("No quote after revocation"); return quote() })
        #expect(engine.receipt?.selectedSymbol == nil)
        #expect(engine.receipt?.blocker?.contains("interrupted") == true)
        #expect(engine.receipt?.checks.count == 2, "Not-started checks must remain visible")
    }

    @Test func capturedAssessmentUsesActualStrictGemmaPromptAndNativeCitationValidation() async throws {
        typealias Server = StockSageLocalModelServer
        let config = try #require(Server.config(url: "http://127.0.0.1:1234", model: Server.gemmaModel))
        let latest = try #require(StockSageMarketHours.latestCompletedDailySession(at: now))
        let dates = (0..<30).map { latest.addingTimeInterval(Double($0 - 29) * 86400) }
        let history = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 30),
            highs: Array(repeating: 104, count: 30), lows: Array(repeating: 99, count: 30),
            closes: Array(repeating: 100, count: 30), volumes: Array(repeating: 1000, count: 30), priceSource: .massiveDaily)
        let advice = TradeAdvice(action: .hold, conviction: 0, regime: .range, rationale: ["Daily background"],
            stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Unvalidated")
        let idea = StockSageIdea(symbol: "AAPL", market: "US", price: 100, advice: advice, spark: [100],
            generatedAt: now, priceAsOf: latest, priceSource: .massiveDaily)
        for variant in 0...2 {
            let news = StockSageNewsService.NewsItem(date: now.addingTimeInterval(variant == 2 ? -86400 : -600),
                title: "Contract progress", snippet: "The company reported contract progress; price effects remain uncertain.",
                link: URL(string: "https://example.com/public-report"), sentiment: nil, source: "Synthetic public provider")
            let context = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: [:], news: [news], at: now, quotedInUSD: true)
            let packet = context.evidencePacket()
            let capture = StockSageHorizonResearch.Capture(history: history, context: context, facts: packet.facts.map(\.text),
                coverage: [], at: now, blockedByThrottle: false, evidencePacket: packet)
            var posts = 0
            let result = await S.assessCaptured(capture, item: listing("AAPL"), activity: 1_000_000,
                intraday: bars(), quote: quote(), config: config, allowed: { true }, clock: { now }, modelTransport: { request in
                    let body: Data
                    if request.httpMethod == "GET" {
                        #expect(request.url?.path == "/api/v1/models")
                        let inventory = StockSageManagedModelLifecycleTests.installed.replacingOccurrences(of: "\"loaded_instances\":[]",
                            with: #""loaded_instances":[{"id":"\#(Server.gemmaModel)","config":{"context_length":16384,"parallel":1}}]"#)
                        body = Data(inventory.utf8)
                    } else {
                        posts += 1
                        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                        #expect(object["model"] as? String == Server.gemmaModel)
                        let format = try #require(object["response_format"] as? [String: Any])
                        #expect(format["type"] as? String == "json_schema")
                        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
                        #expect(Set(schema["required"] as? [String] ?? []) == ["evidence", "action", "reason", "risk"])
                        let messages = try #require(object["messages"] as? [[String: String]])
                        let system = try #require(messages.first(where: { $0["role"] == "system" })?["content"])
                        #expect(system.contains("remainder of today's regular trading session"))
                        #expect(!system.contains("Assess the supplied stock for the next trading week."))
                        let prompt = try #require(messages.first(where: { $0["role"] == "user" })?["content"])
                        #expect(!prompt.contains("Settled paper cash") && !prompt.contains("Currently held"))
                        let lines = prompt.components(separatedBy: "\n")
                        let minute = try #require(lines.first(where: { $0.contains("Completed minute starting") })?.components(separatedBy: ": ").first)
                        let catalyst = try #require(lines.first(where: { $0.contains("Public news, untrusted source data") })?.components(separatedBy: ": ").first)
                        let verdict: [String: Any] = ["action": "Buy", "reason": "The observed setup has public support.",
                            "risk": "A reversal would invalidate the setup.", "evidence": variant == 1 ? [catalyst] : [minute, catalyst]]
                        let text = String(decoding: try JSONSerialization.data(withJSONObject: verdict), as: UTF8.self)
                        body = try JSONSerialization.data(withJSONObject: ["model": Server.gemmaModel,
                            "choices": [["message": ["content": text], "finish_reason": "stop"]]])
                    }
                    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            #expect(posts == (variant == 2 ? 0 : 1))
            #expect(result.qualified == (variant == 0), "\(variant): \(result.note)")
            if variant == 0 {
                #expect(result.profile?.model == Server.gemmaModel)
                let reference = try #require(result.packet?.facts.first(where: { $0.key == "sameDay.targetReference" }))
                #expect(reference.required && reference.factClass == .technical && reference.source.contains("Massive"))
                #expect(reference.observedAt! < now.addingTimeInterval(-300) && reference.text.contains("104"))
            }
        }
    }

    #if os(macOS)
    @Test func populatedDatedCardRendersAtPhoneAndMacWidths() async throws {
        let suite = "stocksage.same-day-render." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let engine = S(), candidate = try check("AAPL")
        await engine.run(selection: .init([listing("AAPL")]), capacity: { 1 }, allowed: { true }, clock: { now },
            analyze: { _, _, _ in candidate }, refreshQuote: { _ in quote() })
        #expect(engine.receipt?.selectedSymbol == "AAPL")
        #expect(!S.current(try #require(engine.receipt), at: now.addingTimeInterval(86400)))
        for width in [393.0, 1100.0] {
            let height = width < 500 ? 852.0 : 1000.0
            let view = StockSageSameDayResearchPanel(store: store, research: engine)
                .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.dark).environment(\.colorScheme, .dark)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutSubtreeIfNeeded()
            #expect(host.view.bounds.size == CGSize(width: width, height: height))
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-same-day-card-\(Int(width)).png")
            try png.write(to: path, options: .atomic)
            print("SAME_DAY_RENDER \(path.path)")
        }
    }
    #endif
}
