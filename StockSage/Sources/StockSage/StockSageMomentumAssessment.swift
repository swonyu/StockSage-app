import Foundation

/// Descriptive Astra review of an already captured movement. Never qualifies a trade or derives levels.
@MainActor enum StockSageMomentumAssessment {
    typealias Assessment = @MainActor (String, String, Data) async -> Result<StockSageCodexResearch.Completion, StockSageCodexResearch.Failure>

    nonisolated static let instructions = StockSageAIAssessment.instructions.replacingOccurrences(
        of: "Assess the supplied stock for the next trading week.",
        with: "MOMENTUM REVIEW: describe the supplied stock's immediate intraday movement and its limitations.") + """

    This descriptive review can occur in pre-market, regular or post-market hours within the supplied tracking window. Explain the observed momentum and volume, and any supported alignment or divergence from the market proxies. The trigger is an unvalidated measurement threshold, not a qualified setup, evidence of a catalyst, institutional demand or future returns. Missing or stale intervals are unavailable, not flat. News, filings, earnings, company-quality metrics and an eligible executable quote were not collected for this review. Do not infer their contents or claim a complete company assessment. No scenario or price levels were supplied: do not invent or recommend entry, stop or target prices, even in words. Any action label is only an unqualified descriptive opinion, never permission to buy or sell. No orders, position management, holding-period promise or guaranteed outcome.
    """

    static func assess(trigger: StockSageMomentum.Trigger, stock: StockSageMomentum.Stock,
        market: StockSageMomentum.Market, allowed: @escaping @MainActor () -> Bool,
        clock: @escaping @MainActor () -> Date = Date.init,
        codexAssessment: Assessment? = nil) async -> StockSageSameDayResearch.Check {
        let began = clock()
        var result = StockSageSameDayResearch.Check(symbol: stock.symbol, name: stock.symbol,
            at: began.timeIntervalSince1970.isFinite ? began : Date(timeIntervalSince1970: 0),
            note: "Momentum review not assessed.")
        result.model = StockSageCodexResearch.model
        result.momentum = stock; result.momentumTrigger = trigger
        func failed(_ reason: String) -> StockSageSameDayResearch.Check {
            result.note = reason; return result
        }
        guard !Task.isCancelled, allowed(), began.timeIntervalSince1970.isFinite,
              let window = StockSageMicrocapMonitor.trackingWindow(at: began),
              stock.symbol == trigger.symbol,
              stock.heavyMomentum(profile: trigger.profile, now: began) == trigger else {
            return failed("Momentum review refused: the original trigger is mismatched, stale, interrupted or outside the weekday Riyadh tracking window.")
        }
        let deadline = min(trigger.at.addingTimeInterval(180), window.end)
        result.expiresAt = deadline
        func active() -> Bool {
            let now = clock()
            return !Task.isCancelled && allowed() && now.timeIntervalSince1970.isFinite
                && now >= began && now < deadline
                && StockSageMicrocapMonitor.trackingWindow(at: now) != nil
                && stock.heavyMomentum(profile: trigger.profile, now: now) == trigger
        }
        // Revalidate original observations without renewing their capture timestamps.
        let stockFacts = stock.facts(at: began, market: market)
        func missing(_ key: String, _ text: String) -> StockSageAIAssessment.EvidenceFact {
            .init(key: key, text: text, required: true, availability: .missing, factClass: .coverageGap,
                source: "StockSage momentum-only capture", observedAt: began)
        }
        let facts = trigger.facts + stockFacts + market.facts(at: began) + [
            StockSageAIAssessment.EvidenceFact(key: "momentumReview.scope",
                text: "Descriptive momentum review for \(stock.symbol), \(trigger.profile.rawValue) profile. Tracking window ends \(window.end.ISO8601Format()); captured trigger expires \(deadline.ISO8601Format()). No qualified trade, executable entry, stop or target is established by this capture.",
                required: true, availability: .available, factClass: .risk,
                source: "StockSage momentum review policy", observedAt: began),
            missing("momentumReview.quote", "Eligible bid/ask, spread, executable liquidity, halt status and a trade scenario were not collected. A minute close is not an executable quote; no entry, stop or target is supplied."),
            missing("momentumReview.catalyst", "Company news and catalyst records were not collected for this review. Price and volume do not establish the cause, presence or absence of a catalyst."),
            missing("momentumReview.company", "Company filings, earnings calendar, financial ratios and insider evidence were not collected for this review. Company quality and absence of earnings or dilution risk are unknown.")
        ]
        let packet = StockSageAIAssessment.EvidencePacket(facts: facts, prePromptOmittedRecordCount: 0)
        result.packet = packet
        guard packet.isWellFormed,
              let fitted = StockSageAIAssessment.fittedResearchPrompt(optional: [], mandatory: facts.map(\.text),
                system: { _ in instructions }, outputTokens: 384),
              let schema = StockSageAIAssessment.responseSchema(facts: fitted.facts) else {
            return failed("Required momentum evidence could not fit or be represented by the bounded native response contract. No Astra request was sent.")
        }
        guard active() else { return failed("Momentum evidence expired or review was interrupted before inference.") }
        let response: Result<StockSageCodexResearch.Completion, StockSageCodexResearch.Failure>
        if let codexAssessment { response = await codexAssessment(fitted.system, fitted.user, schema) }
        else {
            #if os(macOS)
            response = await StockSageCodexResearch.complete(system: fitted.system, user: fitted.user,
                schema: schema, deadline: deadline, allowed: active)
            #else
            return failed("Codex momentum review is available on macOS.")
            #endif
        }
        switch response {
        case .failure(let failure):
            result.codexAudit = failure.audit
            return failed(failure.message)
        case .success(let completion):
            result.codexAudit = completion.audit; result.rawModelOutput = completion.text
            guard active() else { return failed("Momentum evidence expired or review stopped during Astra assessment. The original response is retained; no opinion was accepted.") }
            guard completion.audit.requestedModel == StockSageCodexResearch.model,
                  completion.audit.requestedEffort == "ultra", completion.audit.terminalStatus == "completed",
                  completion.audit.reportedModel.map({ $0 == StockSageCodexResearch.model }) ?? true,
                  case .success(let verdict) = StockSageAIAssessment.validate(completion.text, facts: fitted.facts) else {
                return failed("Astra momentum output failed native model, schema or evidence validation. The original response is retained; no opinion was accepted.")
            }
            result.action = verdict.action.rawValue; result.reason = verdict.reason; result.risk = verdict.risk
            result.evidence = verdict.evidence
            result.quality = StockSageAIAssessment.quality(verdict, offered: facts, symbol: stock.symbol)
            result.note = "Astra descriptive momentum opinion only; not a qualified trade. No entry, stop or target is established."
            return result
        }
    }
}
