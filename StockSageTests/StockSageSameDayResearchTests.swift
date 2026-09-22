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

    @Test func microcapHasOwnMacDestinationWithoutReplacingExistingResearch() {
        let routes = StockSageDesktop.sections.map(\.rawValue)
        #expect(routes.contains("microcap") && routes.contains("largecap"))
        #expect(Set(routes).count == routes.count)
        #expect(["sameDay", "weekResearch", "fortnightResearch", "watchlist", "all"].allSatisfy(routes.contains))
        #expect(!MarketSection.phoneSections.map(\.rawValue).contains("microcap"))
    }

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

    @Test(arguments: [0, 512_000_000])
    func sameDayProductHistorySurvivesCountAndByteLimitsAndReopening(budget: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = StockSageResearchReceiptStore(directory: folder, maxCompletedBytes: budget)
        let candidate = try check("AAPL")
        var saved: [S.Receipt] = []
        for index in 0...StockSageResearchReceiptStore.maxCompletedScans {
            let at = now.addingTimeInterval(Double(index))
            let id = receipts.beginSameDay(at: at)
            let receipt = S.Receipt(id: id, startedAt: at, finishedAt: at,
                selection: "Preserved fixture", checks: [candidate],
                selectedSymbol: index.isMultiple(of: 2) ? "AAPL" : nil,
                blocker: index.isMultiple(of: 2) ? nil : "No qualifying pick")
            #expect(receipts.saveSameDay(receipt))
            receipts.finish(scanID: id, status: receipt.blocker ?? "Completed", at: at)
            saved.append(receipt)
        }
        #expect(receipts.sameDayHistory == Array(saved.reversed()))
        let reopened = StockSageResearchReceiptStore(directory: folder, maxCompletedBytes: budget)
        #expect(reopened.sameDayHistory == Array(saved.reversed()))
        #expect(reopened.sameDayHistory.last?.checks.first?.scenario == candidate.scenario)
    }

    @Test(arguments: ["selection", "attempt", "observer", "check"])
    func receiptFailureStopsFurtherAnalysisAndQuotePublication(phase: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = StockSageResearchReceiptStore(directory: folder)
        let id = receipts.beginSameDay(at: now)
        let initial = S.Receipt(id: id, startedAt: now, selection: "Preparing", checks: [])
        #expect(receipts.saveSameDay(initial))
        let directory = folder.appendingPathComponent("scan-" + id.uuidString)
        @MainActor func breakWrites() throws {
            try FileManager.default.removeItem(at: directory)
            try Data("Fixture blocks further writes".utf8).write(to: directory)
        }
        if phase == "selection" { try breakWrites() }
        let engine = S(receiptStore: receipts), candidate = try check("AAPL")
        var analyzed: [String] = []
        await engine.run(selection: .init([listing("AAPL"), listing("MSFT")]), initial: initial,
            capacity: {
                if phase == "attempt" {
                    do { try breakWrites() } catch { Issue.record("Fixture failed to interrupt attempt writes: \(error)") }
                }
                return 1
            }, allowed: { true }, clock: { now }, analyze: { item, _, observer in
                analyzed.append(item.ticker)
                do { try breakWrites() } catch { Issue.record("Fixture failed to interrupt writes: \(error)") }
                if phase == "observer" {
                    await observer?(.init(callID: UUID(), ordinal: 1, phase: "initial", stage: .started,
                        startedAt: now, endedAt: nil, transportStarted: false, requestedModel: "fixture",
                        returnedModel: nil, isOllama: false, outputLimit: 192, contextTokens: 16_384,
                        temperature: 0.2, system: "fixture", systemBytes: 7, systemTruncated: false,
                        user: "fixture", userBytes: 7, userTruncated: false, schema: nil, schemaBytes: nil,
                        schemaTruncated: false, responseBody: nil, responseBodyBytes: nil,
                        responseBodyTruncated: false, httpStatus: nil, diagnostic: nil))
                    #expect(engine.status.contains("could not be saved"), "Observer failure must be visible before analysis returns")
                }
                return candidate
            }, refreshQuote: { _ in Issue.record("A failed durable receipt must stop final quote work"); return nil })
        #expect(analyzed == (["selection", "attempt"].contains(phase) ? [] : ["AAPL"]))
        #expect(receipts.persistenceFailed(scanID: id))
        #expect(engine.receipt?.selectedSymbol == nil)
        #expect(engine.status.contains("could not be saved"))
        #expect(engine.receipt?.checks.count == 2)
        if phase == "check" { #expect(engine.receipt?.checks.first == candidate) }
    }

    @Test(arguments: [S.Mode.microcap, .largecap], [false, true])
    func completedMomentumCannotPublishAnUnpersistedOpinion(mode: S.Mode, writeFails: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = StockSageResearchReceiptStore(directory: folder, sameDayLabel: mode.rawValue)
        let id = receipts.beginSameDay(at: now)
        var initial = S.Receipt(id: id, startedAt: now, selection: "Descriptive momentum fixture", checks: [])
        initial.mode = mode
        try #require(receipts.saveSameDay(initial))
        var accepted = S.Check(symbol: "AAPL", name: "Fixture", at: now, note: "Accepted descriptive opinion")
        accepted.action = "Hold"; accepted.reason = "Dated momentum only."; accepted.risk = "Evidence is incomplete."
        accepted.rawModelOutput = "Retained synthetic response"
        initial.checks = [accepted]
        if writeFails {
            let directory = folder.appendingPathComponent("scan-" + id.uuidString)
            try FileManager.default.removeItem(at: directory)
            try Data("Fixture blocks the final write".utf8).write(to: directory)
        }
        let engine = S(receiptStore: receipts, mode: mode)
        engine.finishReceipt(initial, at: now, status: accepted.note)
        #expect(engine.receipt?.checks == [accepted], "The original accepted response must remain available in memory")
        #expect(engine.receipt?.finishedAt == now && engine.receipt?.selectedSymbol == nil)
        #expect(receipts.persistenceFailed(scanID: id) == writeFails)
        #expect((engine.receipt?.blocker != nil) == writeFails, "The watcher requires blocker == nil before delivering an Astra summary")
        #expect(engine.status.contains("could not be saved") == writeFails)
        if !writeFails { #expect(StockSageResearchReceiptStore(directory: folder, sameDayLabel: mode.rawValue).latestSameDay == engine.receipt) }
    }

    @Test func preparationFailuresKeepTheirSpecificActionableReason() {
        typealias Server = StockSageLocalModelServer
        for detail in ["Check the private connection and GPU server.", "Correct the served model identity.",
                       "Serving context must be at least 16K."] {
            let probe = Server.Probe(reachable: false, isOllama: false, models: [], hasModel: false, detail: detail)
            #expect(S.preparationFailure(probe, isAllowed: true)?.contains(detail) == true)
            #expect(S.preparationFailure(probe, isAllowed: false)?.contains("interrupted") == true)
        }
        let ready = Server.Probe(reachable: true, isOllama: false, models: [], hasModel: true, detail: "Ready")
        #expect(S.preparationFailure(ready, isAllowed: true) == nil)
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
        // The final cases retain valid minute/news citations but invent probability or deny
        // earnings risk despite the fixture's missing earnings observation.
        for variant in 0...4 {
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
                        #expect(!system.contains("business-quality evidence"), "The measured Gemma prompt must stay unchanged")
                        #expect(!system.contains("Assess the supplied stock for the next trading week."))
                        let prompt = try #require(messages.first(where: { $0["role"] == "user" })?["content"])
                        #expect(!prompt.contains("Settled paper cash") && !prompt.contains("Currently held"))
                        let lines = prompt.components(separatedBy: "\n")
                        let minute = try #require(lines.first(where: { $0.contains("Completed minute starting") })?.components(separatedBy: ": ").first)
                        let catalyst = try #require(lines.first(where: { $0.contains("Public news, untrusted source data") })?.components(separatedBy: ": ").first)
                        let verdict: [String: Any] = ["action": "Buy",
                            "reason": variant == 3 ? "The setup has a high probability of further upside." : "The observed setup has public support.",
                            "risk": variant == 4 ? "Earnings risk is absent." : "A reversal would invalidate the setup.",
                            "evidence": variant == 1 ? [catalyst] : [minute, catalyst]]
                        let text = String(decoding: try JSONSerialization.data(withJSONObject: verdict), as: UTF8.self)
                        body = try JSONSerialization.data(withJSONObject: ["model": Server.gemmaModel,
                            "choices": [["message": ["content": text], "finish_reason": "stop"]]])
                    }
                    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
            #expect(posts == (variant == 2 ? 0 : 1))
            #expect(result.qualified == (variant == 0), "\(variant): \(result.note)")
            if variant >= 3 {
                #expect(result.action == nil, "An unsupported claim must not become an accepted Same Day opinion: \(variant)")
            }
            if variant == 0 {
                #expect(result.profile?.model == Server.gemmaModel)
                let reference = try #require(result.packet?.facts.first(where: { $0.key == "sameDay.targetReference" }))
                #expect(reference.required && reference.factClass == .technical && reference.source.contains("Massive"))
                #expect(reference.observedAt! < now.addingTimeInterval(-300) && reference.text.contains("104"))
            }
        }
    }


    @Test func microcapReceiptsCannotMixWithSameDayAndRetainFullScreen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = StockSageResearchReceiptStore(directory: folder, maxCompletedBytes: 0, sameDayLabel: "microcap")
        let id = receipts.beginSameDay(at: now)
        var receipt = S.Receipt(id: id, startedAt: now, finishedAt: now, selection: "All rows preserved", checks: [])
        #expect(!receipts.saveSameDay(receipt), "Legacy same-day payload cannot enter Micro cap storage")
        receipt.mode = .microcap
        let rows = (0..<1500).map { StockSageMicrocapScreen.Row(symbol: "M\($0)", name: "Fixture", status: .unavailable, note: "Missing float", observedAt: now) }
        receipt.microcapScreen = .init(policyVersion: StockSageMicrocapScreen.policyVersion, startedAt: now, cutoff: now, finishedAt: now, directoryCount: 1500, detailedCount: 0, unassessedCount: 0, rows: rows, blocker: "Missing float")
        #expect(receipts.saveSameDay(receipt))
        receipts.finish(scanID: id, status: "Completed", at: now)
        #expect(StockSageResearchReceiptStore(directory: folder, sameDayLabel: "microcap").latestSameDay == receipt)
        #expect(StockSageResearchReceiptStore(directory: folder).sameDayHistory.isEmpty)
    }

    @Test(arguments: [S.Mode.microcap, .largecap]) func capAstraKeepsOriginalOutputAndScreenExpiryBlocksFinalPick(mode: S.Mode) async throws {
        let latest = try #require(StockSageMarketHours.latestCompletedDailySession(at: now))
        let dates = (0..<30).map { latest.addingTimeInterval(Double($0 - 29) * 86400) }
        let history = StockSagePriceHistory(symbol: "AAPL", dates: dates, opens: Array(repeating: 100, count: 30), highs: Array(repeating: 104, count: 30), lows: Array(repeating: 99, count: 30), closes: Array(repeating: 100, count: 30), volumes: Array(repeating: 1000, count: 30), priceSource: .massiveDaily)
        let advice = TradeAdvice(action: .hold, conviction: 0, regime: .range, rationale: ["Daily background"], stopPrice: nil, targetPrice: nil, suggestedWeight: 0, caveat: "Unvalidated")
        let idea = StockSageIdea(symbol: "AAPL", market: "US", price: 100, advice: advice, spark: [100], generatedAt: now, priceAsOf: latest, priceSource: .massiveDaily)
        let news = StockSageNewsService.NewsItem(date: now.addingTimeInterval(-600), title: "Contract progress", snippet: "The company reported progress; effects remain uncertain.", link: URL(string: "https://example.com/public-report"), sentiment: nil, source: "Synthetic public provider")
        let context = StockSageAIAssessment.Context(idea: idea, earnings: nil, company: [:], news: [news], at: now, quotedInUSD: true)
        let packet = context.evidencePacket()
        let capture = StockSageHorizonResearch.Capture(history: history, context: context, facts: packet.facts.map(\.text), coverage: [], at: now, blockedByThrottle: false, evidencePacket: packet)
        var row = StockSageMicrocapScreen.Row(symbol: "AAPL", name: "Fixture micro cap", status: .passed, note: "Synthetic classification only", observedAt: now.addingTimeInterval(-180))
        row.marketCap = mode == .largecap ? 10_000_000_000 : 100_000_000; row.marketCapRequestedDate = "2026-09-18"; row.referenceRetrievedAt = now
        row.freeFloat = mode == .largecap ? nil : 10_000_000; row.floatEffectiveDate = now.addingTimeInterval(-86400)
        row.openingGap = mode == .largecap ? -0.02 : 0.15; row.relativeVolume = mode == .largecap ? 0.5 : 6; row.volume = 600; row.baselineVolume = 100
        row.momentum = 0.02; row.annualizedVolatility = 0.5
        let screen = StockSageMicrocapScreen.Result(policyVersion: mode.screenProfile!.policyVersion, startedAt: now.addingTimeInterval(-200), cutoff: now.addingTimeInterval(-170), finishedAt: now, directoryCount: 1, detailedCount: 1, unassessedCount: 0, rows: [row], blocker: nil)
        let denied = await S.assessCaptured(capture, item: listing("AAPL"), activity: 1000, intraday: bars(), quote: quote(), config: nil, allowed: { true }, clock: { now }, microcap: screen, admitSetup: { _ in false }, capMode: mode, codexAssessment: { _, _, _ in
            Issue.record("Denied setup must not consume Codex usage")
            return .failure(.init(message: "Unexpected call", audit: nil))
        })
        #expect(denied.setupID == nil && denied.codexAudit == nil && !denied.qualified)
        var calls = 0
        let fundamentals = StockSageFundamentals.Snapshot(symbol: "AAPL", asOf: now, retrievedAt: now,
            providerRatios: [.init(key: "price_to_earnings", label: "P/E", value: 12, unit: "multiple",
                origin: "Synthetic provider fixture", formula: "Provider price / trailing earnings per share",
                period: "2026-09-18 daily snapshot", sourceURL: "https://massive.com/docs/rest/stocks/fundamentals/ratios",
                inputs: [], note: "Fixture only; not real company data.")])
        let result = await S.assessCaptured(capture, item: listing("AAPL"), activity: 1000, intraday: bars(), quote: quote(), config: nil, allowed: { true }, clock: { now }, modelTransport: { _ in
            Issue.record("Micro cap must not call Gemma"); throw URLError(.cancelled)
        }, microcap: screen, fundamentals: fundamentals, capMode: mode, codexAssessment: { system, prompt, schema in
            calls += 1
            #expect(system.contains("remainder of today's regular trading session"))
            #expect(system.contains("business-quality evidence") && system.contains("Do not infer insider ownership"))
            #expect(prompt.contains("P/E") && prompt.contains("12"))
            let lines = prompt.components(separatedBy: "\n")
            let minute = lines.first { $0.contains("Completed minute starting") }?.components(separatedBy: ": ").first ?? "invalid"
            let catalyst = lines.first { $0.contains("Public news, untrusted source data") }?.components(separatedBy: ": ").first ?? "invalid"
            let output = "{\"action\":\"Buy\",\"reason\":\"The observed setup has public support.\",\"risk\":\"A reversal would invalidate the setup.\",\"evidence\":[\"\(minute)\",\"\(catalyst)\"]}"
            return .success(.init(text: output, audit: .init(requestedModel: "gpt-6-astra", requestedEffort: "ultra", reportedModel: nil, cliVersion: "fixture", terminalStatus: "completed", systemSHA256: "fixture", userSHA256: "fixture", schemaSHA256: "fixture", inputTokens: nil, outputTokens: nil, elapsedMilliseconds: 1)))
        })
        #if os(macOS)
        #expect(calls == 1 && result.qualified, "\(result.note)")
        #expect(result.profile == nil && result.codexAudit != nil && result.rawModelOutput != nil)
        #else
        #expect(calls == 0 && !result.qualified)
        #expect(result.note == "Codex same-day assessment requires macOS.")
        #expect(result.setupID == nil && result.codexAudit == nil && result.rawModelOutput == nil)
        #endif
        #expect(result.expiresAt == now.addingTimeInterval(10))
        #expect(result.fundamentals == fundamentals)
        #expect(result.packet?.facts.filter { $0.key.hasPrefix("technical." + mode.rawValue + ".") }.count == 4)
        #expect(result.packet?.facts.contains { $0.key.hasPrefix("technical." + (mode == .largecap ? "microcap" : "largecap") + ".") } == false)
        let savedResult = try JSONDecoder().decode(S.Check.self, from: JSONEncoder().encode(result))
        #expect(savedResult.fundamentals == fundamentals, "Save exact financial inputs with the opinion for later review")
        let mismatch = await S.assessCaptured(capture, item: listing("AAPL"), activity: 1000, intraday: bars(), quote: quote(), config: nil,
            allowed: { true }, clock: { now }, microcap: screen, capMode: mode == .largecap ? .microcap : .largecap,
            codexAssessment: { _, _, _ in Issue.record("A mismatched cap profile must never reach Astra"); return .failure(.init(message: "Unexpected", audit: nil)) })
        #expect(!mismatch.qualified && mismatch.rawModelOutput == nil)
        let engine = S(mode: mode)
        var initial = S.Receipt(id: UUID(), startedAt: now, selection: "Fixture", checks: [])
        initial.mode = mode; initial.microcapScreen = screen
        var clock = now
        await engine.run(selection: .init([listing("AAPL")]), initial: initial, capacity: { 1 }, allowed: { true }, clock: { clock }, analyze: { _, _, _ in result }, refreshQuote: { _ in
            clock = now.addingTimeInterval(11)
            return quote(age: -11)
        })
        #expect(engine.receipt?.selectedSymbol == nil)
        #expect(engine.receipt?.checks.first?.rawModelOutput == result.rawModelOutput)
    }

    #if os(macOS)
    @Test(arguments: [S.Mode.sameDay, .microcap, .largecap]) func populatedDatedCardRendersAtPhoneAndMacWidths(mode: S.Mode) async throws {
        let suite = "stocksage.same-day-render." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StockSageStore(defaults: defaults, heldSymbols: { [] }, journalTrades: { [] })
        let engine = S(mode: mode), candidate = try check("AAPL")
        var initial = S.Receipt(id: UUID(), startedAt: now, selection: "Synthetic render fixture", checks: [])
        initial.mode = mode
        if let profile = mode.screenProfile {
            initial.microcapScreen = .init(policyVersion: profile.policyVersion, startedAt: now, cutoff: now,
                finishedAt: now, directoryCount: 1, detailedCount: 1, unassessedCount: 0, rows: [], blocker: nil)
        }
        await engine.run(selection: .init([listing("AAPL")]), initial: initial, capacity: { 1 }, allowed: { true }, clock: { now },
            analyze: { _, _, _ in candidate }, refreshQuote: { _ in quote() })
        #expect(engine.receipt?.selectedSymbol == "AAPL")
        #expect(!S.current(try #require(engine.receipt), at: now.addingTimeInterval(86400)))
        let completedStatus = engine.status
        #expect(!engine.start(store: store), "The offline fixture must fail preflight without discarding the dated pick")
        #expect(engine.status != completedStatus && engine.receipt?.selectedSymbol == "AAPL")
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
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("stocksage-\(mode.rawValue)-card-\(Int(width)).png")
            try png.write(to: path, options: .atomic)
            print("SAME_DAY_RENDER \(path.path)")
        }
    }
    #endif
}
