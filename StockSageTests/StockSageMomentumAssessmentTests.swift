import Foundation
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageMomentumAssessmentTests {
    typealias M = StockSageMomentum
    typealias A = StockSageMomentumAssessment
    typealias C = StockSageCodexResearch
    let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:20Z")!

    func fixture(at: Date? = nil, profile: StockSageMicrocapScreen.Profile = .microcap,
                 marketAt: Date? = nil) throws -> (M.Trigger, M.Stock, M.Market) {
        let captured = at ?? now
        let end = Date(timeIntervalSince1970: floor(captured.timeIntervalSince1970 / 60) * 60)
        let bars = (0..<20).map { index -> StockSageMassiveTicks.Minute in
            let close = index < 15 ? 100.0 : 105.0
            return .init(at: end.addingTimeInterval(Double(index - 20) * 60),
                open: close, high: close + 1, low: close - 1, close: close, volume: index < 15 ? 100 : 400)
        }
        let market = M.market(spy: nil, qqq: nil, now: marketAt ?? captured)
        let stock = M.stock(symbol: "TEST", intraday: .init(facts: [], asOf: end, bars: bars, verifiedMinutes: true),
            market: market, now: captured)
        return (try #require(stock.heavyMomentum(profile: profile, now: captured)), stock, market)
    }

    func completion(_ user: String, action: String = "Buy", model: String = "gpt-6-astra",
                    effort: String = "ultra", status: String = "completed", text: String? = nil) -> C.Completion {
        let output = text ?? "{\"action\":\"\(action)\",\"reason\":\"The completed candles show a sharp move with stronger recent volume.\",\"risk\":\"Missing quotes and company catalysts leave execution and the cause uncertain.\",\"evidence\":[\"F1\"]}"
        return .init(text: output, audit: .init(requestedModel: model, requestedEffort: effort, reportedModel: model,
            cliVersion: "offline-fixture", terminalStatus: status, systemSHA256: "fixture", userSHA256: "fixture",
            schemaSHA256: "fixture", inputTokens: 100, outputTokens: 60, elapsedMilliseconds: 1))
    }

    @Test(arguments: [StockSageMicrocapScreen.Profile.microcap, .largecap])
    func freshPremarketReviewPreservesOpinionWithoutQualifyingTrade(profile: StockSageMicrocapScreen.Profile) async throws {
        let (trigger, stock, market) = try fixture(profile: profile)
        var calls = 0
        let result = await A.assess(trigger: trigger, stock: stock, market: market, allowed: { true }, clock: { now },
            codexAssessment: { system, user, schema in
                calls += 1
                #expect(system.contains("MOMENTUM REVIEW") && !system.contains("next trading week"))
                #expect(system.contains("pre-market") && system.contains("do not invent or recommend entry"))
                #expect(user.contains("Pre-market") && user.contains("not collected"))
                let object = try? JSONSerialization.jsonObject(with: schema) as? [String: Any]
                #expect(Set(object?["required"] as? [String] ?? []) == ["action", "reason", "risk", "evidence"])
                #expect(object?["additionalProperties"] as? Bool == false)
                return .success(completion(user))
            })
        #expect(calls == 1 && result.action == "Buy" && result.model == C.model)
        #expect(!result.qualified && result.scenario == nil && result.verifiedQuote == nil && result.capturedQuote == nil)
        #expect(result.profile == nil && result.setupID == nil && result.fundamentals == nil)
        #expect(result.momentum == stock && result.momentumTrigger == trigger)
        #expect(result.rawModelOutput != nil && result.codexAudit?.terminalStatus == "completed")
        #expect(result.expiresAt == trigger.at.addingTimeInterval(180))
        #expect(result.note.contains("not a qualified trade") && result.note.contains("No entry, stop or target"))
        let facts = try #require(result.packet?.facts)
        for key in ["momentumReview.quote", "momentumReview.catalyst", "momentumReview.company"] {
            let missing = try #require(facts.first { $0.key == key })
            #expect(missing.required && missing.availability == .missing && missing.factClass == .coverageGap)
        }
        #expect(try JSONDecoder().decode(StockSageSameDayResearch.Check.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test(arguments: ["stale", "wrongTrigger", "outsideWindow", "denied", "cancelled", "expiredBeforeInference"])
    func invalidOrInterruptedTriggerConsumesNoCodexUsage(mode: String) async throws {
        let (original, stock, market) = try fixture()
        var trigger = original
        if mode == "wrongTrigger" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(trigger)) as? [String: Any])
            object["symbol"] = "OTHER"
            trigger = try JSONDecoder().decode(M.Trigger.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var clockCalls = 0, calls = 0
        let capturedTrigger = trigger
        let run = Task { @MainActor in
            if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return await A.assess(trigger: capturedTrigger, stock: stock, market: market, allowed: { mode != "denied" }, clock: {
                clockCalls += 1
                if mode == "outsideWindow" { return now.addingTimeInterval(2 * 86_400) }
                if mode == "stale" || (mode == "expiredBeforeInference" && clockCalls > 1) { return now.addingTimeInterval(181) }
                return now
            }, codexAssessment: { _, user, _ in
                calls += 1; return .success(completion(user))
            })
        }
        let result = await run.value
        #expect(calls == 0 && result.action == nil && result.codexAudit == nil && !result.qualified)
        #expect(result.scenario == nil && result.momentumTrigger == trigger)
    }

    @Test(arguments: ["malformed", "numeric", "schema", "model", "effort", "terminal", "failure"])
    func rejectedOutputAndAuditRemainVisibleWithoutAcceptedOpinion(mode: String) async throws {
        let (trigger, stock, market) = try fixture()
        var sent: C.Completion?
        let result = await A.assess(trigger: trigger, stock: stock, market: market, allowed: { true }, clock: { now },
            codexAssessment: { _, user, _ in
                var text: String?
                if mode == "malformed" { text = "incomplete response" }
                if mode == "numeric" { text = #"{"action":"Buy","reason":"Buy at 105.","risk":"A reversal is possible.","evidence":["F1"]}"# }
                if mode == "schema" { text = #"{"action":"Hold","reason":"Movement lacks context.","risk":"A reversal is possible.","evidence":["F1"],"target":110}"# }
                let response = completion(user, model: mode == "model" ? "other-model" : C.model,
                    effort: mode == "effort" ? "high" : "ultra", status: mode == "terminal" ? "failed" : "completed", text: text)
                sent = response
                return mode == "failure" ? .failure(.init(message: "Offline refusal", audit: response.audit)) : .success(response)
            })
        #expect(result.action == nil && result.reason == nil && result.risk == nil && !result.qualified)
        #expect(result.codexAudit == sent?.audit && result.rawModelOutput == (mode == "failure" ? nil : sent?.text))
        #expect(result.scenario == nil && result.verifiedQuote == nil)
    }

    @Test func trackingWindowDeadlineAndPostResponseExpiryPreserveRawReply() async throws {
        let nearClose = ISO8601DateFormatter().date(from: "2026-09-18T19:59:20Z")!
        let (trigger, stock, market) = try fixture(at: nearClose)
        var clock = nearClose
        let result = await A.assess(trigger: trigger, stock: stock, market: market, allowed: { true }, clock: { clock },
            codexAssessment: { _, user, _ in
                clock = nearClose.addingTimeInterval(41)
                return .success(completion(user))
            })
        #expect(result.expiresAt == ISO8601DateFormatter().date(from: "2026-09-18T20:00:00Z"))
        #expect(result.action == nil && !result.qualified && result.rawModelOutput != nil && result.codexAudit != nil)
        #expect(result.note.contains("expired") && result.scenario == nil)
    }

    @Test func oldAvailableProxyCaptureBecomesMissingWithoutBlockingFreshStockReview() async throws {
        let (_, oldStock, _) = try fixture(at: now.addingTimeInterval(-240))
        let prior = StockSageMassiveTicks.Intraday(facts: [], asOf: try #require(oldStock.series.asOf),
            bars: oldStock.series.bars, verifiedMinutes: true)
        let oldMarket = M.market(spy: prior, qqq: prior, now: oldStock.capturedAt)
        #expect(oldMarket.facts.first { $0.key == "technical.momentum.market.SPY" }?.availability == .available)
        let (trigger, stock, _) = try fixture()
        var calls = 0
        let result = await A.assess(trigger: trigger, stock: stock, market: oldMarket, allowed: { true }, clock: { now },
            codexAssessment: { _, user, _ in calls += 1; return .success(completion(user, action: "Hold")) })
        #expect(calls == 1 && result.action == "Hold" && !result.qualified)
        let facts = try #require(result.packet?.facts)
        for key in ["technical.momentum.market.SPY", "technical.momentum.market.QQQ",
                    "technical.momentum.relative.SPY", "technical.momentum.relative.QQQ"] {
            #expect(facts.first { $0.key == key }?.availability == .missing)
        }
        #expect(result.momentum == stock && result.scenario == nil)
    }
}
