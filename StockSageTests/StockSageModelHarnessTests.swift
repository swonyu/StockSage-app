import Testing
import Foundation
@testable import StockSage

// Harness regressions for the shared local-model seam (2026-09-10).
//
// Every case here reproduces a defect confirmed by reading the shipped source, or a measured
// failure from the frozen baseline in `StockSage-harness-20260910.opus/`. No live network:
// each test injects a transport closure, exactly like the existing suite.
/// Releases every waiter once two have arrived, so two requests are provably in flight at the
/// same moment without a sleep-based guess.
///
/// BOUNDED ON PURPOSE: a caller can short-circuit before reaching the gate (a policy or settings
/// check ahead of the transport), leaving the first arriver parked forever. The waiter is
/// therefore released by a deadline as well as by a partner, so a mis-set precondition fails the
/// assertion instead of hanging the whole test run.
private actor AsyncGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    private func releaseAll() {
        guard !opened else { return }
        opened = true
        let held = waiting
        waiting.removeAll()
        held.forEach { $0.resume() }
    }

    func arriveAndWait(timeout: Duration = .seconds(5)) async {
        if opened { return }
        if !waiting.isEmpty { releaseAll(); return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.releaseAll()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { waiting.append($0) }
    }
}

// `.serialized`: three cases below assert EXACT values of `StockSageLocalModelServer.inFlight`,
// which is one counter for the whole process. Swift Testing parallelises across suites by
// default, and every `completeDetailed` call in the test target now passes through that counter,
// so without this an unrelated suite's in-flight request makes `concurrentRequests == 0` fail.
// Mirrors the reasoning in `ToolPolicyTestLock`.
@Suite("Model harness — budget, truncation and identity across every backend", .serialized)
struct StockSageModelHarnessTests {

    typealias S = StockSageLocalModelServer

    // A generic Ollama backend fixture, distinct from StockSageLocalModelServer's shipped
    // defaultURL/defaultModel so that flipping the shipped default (Qwen removal Step 7) does
    // not silently repoint what these tests exercise. These constants describe "a generic
    // Ollama server", not the app's default.
    static let ollamaFixtureURL = "http://127.0.0.1:11434"
    static let ollamaFixtureModel = "fixture-ollama-model"

    private static func ok(_ object: [String: Any], _ request: URLRequest) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // Qwen removal Step 7: the shipped default flipped from the generic Ollama pair to the
    // managed Gemma one. A fresh install must get a servable, strict-output pair, not silently
    // regress to something requiresStrictOutput treats as generic.
    @Test func theShippedDefaultIsTheManagedGemmaProfile() throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        #expect(config.isLMStudioGemma == true)
        #expect(config.requiresStrictOutput == true)
    }

    // MARK: Budget is shared, not LM-Studio-only

    // Confirmed defect: `promptFits` ran only when `Config.isLMStudio9B`, so the shipped default
    // (Ollama, 127.0.0.1:11434, "qwen3.8") dispatched any size of prompt and relied on the server
    // to truncate silently. A caller that packs 12,000 bytes into a 4,096-unit window must be told.
    @Test @MainActor func defaultOllamaBackendAlsoBoundsThePromptBeforeDispatch() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        var calls = 0
        let result = await S.completeDetailed(config, isOllama: true, system: "instructions",
            user: String(repeating: "b", count: 12_000), maxTokens: 192, transport: { request in
                calls += 1
                return try Self.ok(["message": ["content": "hi"], "done_reason": "stop"], request)
            })
        #expect(calls == 0, "an oversized prompt must not reach any backend")
        guard case .failure(let failure) = result else {
            Issue.record("oversized prompt was dispatched"); return
        }
        #expect(failure.diagnostic.category == .contextBudget)
    }

    // A larger declared context window must actually raise the allowance; the budget was hardcoded
    // to 4096 regardless of the `contextTokens` the caller asked for.
    @Test @MainActor func budgetFollowsTheDeclaredContextWindow() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let user = String(repeating: "b", count: 6_000)
        var narrowCalls = 0, wideCalls = 0
        _ = await S.completeDetailed(config, isOllama: true, system: "s", user: user,
            maxTokens: 192, contextTokens: 4096, transport: { request in
                narrowCalls += 1
                return try Self.ok(["message": ["content": "hi"], "done_reason": "stop"], request)
            })
        _ = await S.completeDetailed(config, isOllama: true, system: "s", user: user,
            maxTokens: 192, contextTokens: 16_384, transport: { request in
                wideCalls += 1
                return try Self.ok(["message": ["content": "hi"], "done_reason": "stop"], request)
            })
        #expect(narrowCalls == 0, "6,000 bytes must not fit a 4,096-unit window")
        #expect(wideCalls == 1, "6,000 bytes must fit a 16,384-unit window")
    }

    // Callers currently hardcode 12,000 UTF-8 bytes and then fail the whole request when the seam
    // rejects it. They need the real allowance so they can pack to it and report what was dropped.
    @Test func callersCanAskForTheExactByteAllowance() {
        let allowance = S.maximumUserBytes(system: "instructions", outputTokens: 192, contextTokens: 4096)
        #expect(allowance > 0)
        #expect(allowance < 12_000, "the real 4k allowance is far below the hardcoded 12,000")
        #expect(S.promptFits(system: "instructions", user: String(repeating: "x", count: allowance),
                             outputTokens: 192, contextTokens: 4096))
        #expect(!S.promptFits(system: "instructions", user: String(repeating: "x", count: allowance + 1),
                              outputTokens: 192, contextTokens: 4096))
    }

    // MARK: Every real caller's own instructions must fit its declared window

    // The suite originally exercised the seam with `system: "s"`, which is why applying the
    // budget to every backend silently broke AI assessment and the Catalyst narrator: both
    // compile up to 12,000 bytes of facts, and neither fitted a 4,096-unit window. These cases
    // use each caller's ACTUAL instruction string and ACTUAL output budget.
    //
    // STRENGTHENED (Qwen removal Step 3): production never sends a caller's raw output token
    // count -- it sends `config.reservedOutputTokens(for:)`, which DOUBLES any initial value in
    // 1...512 once `requiresStrictOutput` is true. After Step 7 the strict Gemma profile is the
    // DEFAULT path, so this guard must model that doubling, not the pre-doubling raw value, or a
    // caller could pass this test while trimming evidence on real requests. Qualified research
    // must include its production suffix for BOTH horizons and the larger 384-token retry.
    @Test func everyEvidenceHeavyCallerFitsItsDeclaredWindow() {
        let research = S.researchContextTokens
        let strictConfig = try! #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        #expect(strictConfig.requiresStrictOutput)
        let callers: [(name: String, system: String, outputTokens: Int, context: Int)] = [
            ("assessment", StockSageAIAssessment.instructions, 240, research),
            ("paper", StockSagePaperAutomation.researchInstructions,
             StockSagePaperAutomation.researchOutputTokens, research),
            ("horizon-week", StockSageHorizonResearch.Horizon.week.instructions,
             StockSageHorizonResearch.researchOutputTokens, research),
            ("horizon-fortnight", StockSageHorizonResearch.Horizon.fortnight.instructions,
             StockSageHorizonResearch.researchOutputTokens, research),
            ("same-day", StockSageSameDayResearch.instructions, StockSageHorizonResearch.researchOutputTokens, research),
            ("narrator", StockSageCatalystNarrator.instructions, 170, research),
        ] + StockSageHorizonResearch.Horizon.allCases.flatMap { horizon in
            [StockSageHorizonResearch.researchOutputTokens, 384].map { output in
                ("qualified-\(horizon.rawValue)-\(output)", horizon.assessmentInstructions(qualify: true), output, research)
            }
        }
        for caller in callers {
            let reserved = strictConfig.reservedOutputTokens(for: caller.outputTokens)
            let allowance = S.maximumUserBytes(system: caller.system, outputTokens: reserved,
                                               contextTokens: caller.context)
            // Each of these callers caps its compiled facts at 12,000 UTF-8 bytes. If the
            // allowance drops below that, a full packet requires disclosed evidence omissions.
            // Measured, not guessed: print the actual headroom above the 12,000-byte floor.
            print("[everyEvidenceHeavyCallerFitsItsDeclaredWindow] \(caller.name): raw=\(caller.outputTokens) reserved=\(reserved) allowance=\(allowance) headroom=\(allowance - 12_000)")
            #expect(allowance >= 12_000,
                    "\(caller.name) allows only \(allowance) bytes (reserved output \(reserved), doubled from \(caller.outputTokens)) but compiles up to 12,000")
        }
    }

    @Test(arguments: StockSageHorizonResearch.Horizon.allCases, [StockSageHorizonResearch.researchOutputTokens, 384])
    func qualifiedResearchFitsFullTwelveKilobyteEvidence(horizon: StockSageHorizonResearch.Horizon,
                                                        outputTokens: Int) throws {
        let config = try #require(S.config(url: S.lmStudioURL, model: S.gemmaModel))
        let reserved = config.reservedOutputTokens(for: outputTokens)
        let system = horizon.assessmentInstructions(qualify: true)
        let mandatory = [
            "Requested holding horizon: \(horizon.rawValue). Research only, no orders or position management.",
            "Earnings holding-window check: unknown; next report date unavailable.",
            "Strict screen: no critical unresolved data gap is allowed for Buy / Strong Buy.",
        ]
        var optional = (1...40).map { "Evidence record \($0): " + String(repeating: "e", count: 240) }
        let padding = 12_000 - StockSageAIAssessment.prompt(facts: optional + mandatory).utf8.count
        try #require(padding > 0)
        optional[optional.count - 1] += String(repeating: "e", count: padding)
        let fullPrompt = StockSageAIAssessment.prompt(facts: optional + mandatory)
        #expect(fullPrompt.utf8.count == 12_000, "the fixture includes numbering and mandatory facts")
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: optional, mandatory: mandatory, system: { _ in system },
            outputTokens: reserved, contextTokens: S.researchContextTokens))
        #expect(fitted.isComplete)
        #expect(fitted.omitted == 0)
        #expect(fitted.facts == optional + mandatory)
        #expect(fitted.user == fullPrompt)
        #expect(S.promptFits(system: fitted.system, user: fitted.user,
                             outputTokens: reserved, contextTokens: S.researchContextTokens))
    }

    // Chat's own prompt budget must stay strictly inside the seam's, or every Chat turn
    // would fail. (Chat sat at a 4,096 interactive target until 2026-09-11; see the note on
    // `StockSageChat.contextTokens` for why that bound was starving answers rather than
    // protecting them, and `chatBudgetHoldsItsLargestRequiredInput` below for the floor.)
    @Test func chatOwnBudgetStaysInsideTheSeamBudget() {
        let allowance = S.maximumUserBytes(system: StockSageChat.instructions,
                                           outputTokens: StockSageChat.outputTokens,
                                           contextTokens: StockSageChat.contextTokens)
        #expect(StockSageChat.promptByteLimit > 0)
        #expect(StockSageChat.promptByteLimit <= allowance,
                "Chat packs \(StockSageChat.promptByteLimit) bytes into a \(allowance)-byte allowance")
    }

    // The ceiling has to clear the largest SINGLE required input, or the trimming loop in
    // `StockSageChat.request` cannot converge without gutting the evidence it was given.
    //
    // This is the check that would have caught the defect the owner hit on 2026-09-11. At
    // contextTokens 4,096 the whole-prompt budget resolved to 1,283 bytes while the Benzinga
    // projection alone asks for up to 12,000, so the loop dropped every source and all but two
    // facts, and the model then correctly refused to form a view: "Budget: 2 facts, 6/6 sources
    // omitted. 47 Benzinga records omitted."
    //
    // The 12,000 is not a magic number here: it is `benzingaBudget`'s initial value in
    // `StockSageChat.request`, so this asserts the two agree rather than restating a constant.
    @Test func chatBudgetHoldsItsLargestRequiredInput() {
        let benzingaProjectionBudget = 12_000   // StockSageChat.request's opening benzingaBudget
        #expect(StockSageChat.promptByteLimit > benzingaProjectionBudget,
                """
                Chat's whole-prompt budget is \(StockSageChat.promptByteLimit) bytes, which cannot \
                hold the \(benzingaProjectionBudget)-byte Benzinga projection it is asked to send. \
                The trimming loop will drop sources and facts to converge, and the model will report \
                the evidence as missing. Raise StockSageChat.contextTokens.
                """)
        // And leave room for the rest of the payload, not just that one input: sources, facts,
        // the question and a few history turns all share this budget.
        #expect(StockSageChat.promptByteLimit > benzingaProjectionBudget * 2,
                "budget \(StockSageChat.promptByteLimit) leaves under 12,000 bytes for sources, facts, question and history")
    }

    // MARK: Research prompt fitting — the logic paper and horizon research both run

    // Extracted from the two research callers so their trimming and disclosure behaviour is
    // testable without their network paths. `analyze()` does real HTTP through a shared
    // session with no injectable seam, so this is the part that can be pinned.

    private static let evidence = (1...30).map { "Optional evidence record \($0): ACME reported an item of dated news on 2026-09-\(String(format: "%02d", ($0 % 28) + 1))." }
    private static let mandatory = [
        "Settled paper cash available for entries: 4210.55 USD. Maximum per new position: 2000 USD.",
        "Currently held in the paper account: 12 shares, simulated entry 37.50 USD.",
        "Authoritative decision-clock snapshot: 2026-09-10 15:04:00 America/New_York.",
    ]

    @Test func everythingFitsWhenTheBudgetIsAmpleAndNothingIsDisclosedAsOmitted() throws {
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: Self.evidence, mandatory: Self.mandatory, system: { _ in "instructions" },
            outputTokens: 192, contextTokens: S.researchContextTokens))
        #expect(fitted.omitted == 0)
        #expect(fitted.isComplete)
        #expect(fitted.facts.count == Self.evidence.count + Self.mandatory.count)
        #expect(fitted.facts.suffix(Self.mandatory.count) == Self.mandatory[...])
    }

    // Mandatory facts are last and must survive every level of trimming: a cash constraint or a
    // decision clock silently dropped is the failure this whole path exists to prevent.
    @Test func mandatoryFactsSurviveEveryLevelOfTrimming() throws {
        // A window small enough to force heavy trimming but still hold the mandatory tail.
        for context in [1_024, 1_536, 2_048, 3_072] {
            guard let fitted = StockSageAIAssessment.fittedResearchPrompt(
                optional: Self.evidence, mandatory: Self.mandatory, system: { _ in "instructions" },
                outputTokens: 64, contextTokens: context) else { continue }
            #expect(fitted.facts.suffix(Self.mandatory.count) == Self.mandatory[...],
                    "mandatory facts dropped at context \(context)")
            #expect(fitted.omitted == Self.evidence.count - (fitted.facts.count - Self.mandatory.count))
            #expect(S.promptFits(system: fitted.system, user: fitted.user,
                                 outputTokens: 64, contextTokens: context),
                    "returned prompt does not actually fit at context \(context)")
        }
    }

    // When even the mandatory facts cannot fit, the caller must be told to report a budget
    // limit — never handed a prompt with mandatory content quietly removed.
    @Test func returnsNilRatherThanDroppingMandatoryContent() {
        let huge = Array(repeating: String(repeating: "m", count: 4_000), count: 4)
        #expect(StockSageAIAssessment.fittedResearchPrompt(
            optional: Self.evidence, mandatory: huge, system: { _ in "instructions" },
            outputTokens: 64, contextTokens: 1_024) == nil)
    }

    @Test func fittedPromptRetainsExactOmittedSupplementalKeys() throws {
        let optional = (1...12).map { "Optional \($0): " + String(repeating: "x", count: 260) }
        let keys = (1...12).map { "news.item.\($0)" }
        let mandatory = ["Required quote and source state.", "Required earnings state."]
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: optional, mandatory: mandatory, system: { _ in "instructions" }, optionalKeys: keys,
            outputTokens: 64, contextTokens: 1_024))
        #expect(fitted.facts.suffix(mandatory.count) == mandatory[...])
        #expect(fitted.omittedKeys == Array(keys.dropFirst(fitted.optionalKept)))
    }

    @Test func malformedCoverageKeysFailBeforeAnyModelPrompt() {
        #expect(StockSageAIAssessment.fittedResearchPrompt(
            optional: ["optional"], mandatory: ["required"], system: { _ in "instructions" },
            optionalKeys: [], outputTokens: 64, contextTokens: S.researchContextTokens) == nil)
    }

    // Paper research names its intraday facts by F-number in the system string. If trimming
    // shifted the numbering, the "cite an intraday observation" gate would validate against the
    // wrong evidence — so the kept facts must keep their original positions and F-numbers.
    @Test func trimmingPreservesTheFNumberingOfEveryKeptFact() throws {
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: Self.evidence, mandatory: Self.mandatory, system: { _ in "instructions" },
            outputTokens: 64, contextTokens: 2_048))
        let kept = fitted.facts.count - Self.mandatory.count
        #expect(kept < Self.evidence.count, "this case must actually trim to be meaningful")
        // Optional records are dropped from the END, so record N keeps F-number N.
        for index in 0..<kept {
            #expect(fitted.facts[index] == Self.evidence[index])
            #expect(fitted.user.contains("F\(index + 1): \(Self.evidence[index])"))
        }
        // And the mandatory tail is numbered immediately after whatever was kept.
        for (offset, fact) in Self.mandatory.enumerated() {
            #expect(fitted.user.contains("F\(kept + offset + 1): \(fact)"))
        }
    }

    // The system string is rebuilt for the count that actually fits, because paper research's
    // instruction interpolates the F-numbers of its intraday facts.
    @Test func theSystemStringIsBuiltForTheCountThatActuallyFits() throws {
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: Self.evidence, mandatory: Self.mandatory,
            system: { "instructions for exactly \($0) optional records" },
            outputTokens: 64, contextTokens: 2_048))
        let kept = fitted.facts.count - Self.mandatory.count
        #expect(fitted.system == "instructions for exactly \(kept) optional records")
    }

    @Test func anEmptyOptionalSetIsCompleteNotOmitted() throws {
        let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
            optional: [], mandatory: Self.mandatory, system: { _ in "instructions" },
            outputTokens: 192, contextTokens: S.researchContextTokens))
        #expect(fitted.isComplete)
        #expect(fitted.facts == Self.mandatory)
    }

    // Both research callers must be able to send their full 12,000-byte evidence budget at the
    // declared research context. This is the regression guard for the P0 the review caught.
    @Test func bothResearchCallersFitAFullTwelveKilobyteEvidenceSet() throws {
        let bulky = (1...40).map { "Evidence record \($0): " + String(repeating: "e", count: 280) }
        #expect(bulky.joined(separator: "\n").utf8.count >= 11_000)
        for (name, system) in [("paper", StockSagePaperAutomation.researchInstructions),
                               ("horizon", StockSageHorizonResearch.Horizon.week.instructions)] {
            let fitted = try #require(StockSageAIAssessment.fittedResearchPrompt(
                optional: bulky, mandatory: Self.mandatory, system: { _ in system },
                outputTokens: StockSagePaperAutomation.researchOutputTokens,
                contextTokens: S.researchContextTokens))
            #expect(fitted.isComplete, "\(name) had to omit \(fitted.omitted) records of a normal evidence set")
        }
    }

    // MARK: Truncation is rejected on every backend

    // Measured 2026-09-10: the frozen `holdout_01_loss` case returned finish_reason "length" with a
    // truncated P/L whose headline figure its own unfinished working contradicted.
    //
    // The seam deliberately keeps `finish` OBSERVATIONAL — it reports truncation and preserves the
    // text, because a cut-off Chat answer is still worth reading. The refusal therefore belongs to
    // the callers that publish a financial verdict, and is expressed by this predicate.
    @Test @MainActor func truncationIsReportedBySeamAndRefusedByVerdictCallers() async throws {
        for (url, model, isOllama) in [(Self.ollamaFixtureURL, Self.ollamaFixtureModel, true),
                                       ("http://127.0.0.1:9999", "some-other-model", false)] {
            let config = try #require(S.config(url: url, model: model))
            let result = await S.completeDetailed(config, isOllama: isOllama, system: "s", user: "f",
                transport: { request in
                    let body: [String: Any] = isOllama
                        ? ["model": model, "message": ["content": "Gross P/L: -$9.50 and the rest of the"],
                           "done_reason": "length"]
                        : ["model": model, "choices": [["message": ["content": "Gross P/L: -$9.50 and the rest of the"],
                                                       "finish_reason": "length"]]]
                    return try Self.ok(body, request)
                })
            let completion = try #require(try? result.get(), "the seam preserves truncated text")
            #expect(completion.diagnostic.finish == .tokenLimit)
            #expect(S.rejectsTruncatedOutput(completion), "a verdict caller must refuse this answer")
        }
    }

    @Test @MainActor func aFinishedAnswerIsNotTreatedAsTruncated() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "Complete."],
                             "done_reason": "stop"], request)
            })
        let completion = try #require(try? result.get())
        #expect(!S.rejectsTruncatedOutput(completion))
        #expect(S.financialOutputRejection(completion) == nil)
    }

    @Test func explicitNonfinalMetadataRejectsFinancialVerdictsButPreservesChatText() throws {
        let text = #"{"action":"Hold","reason":"Outlook mixed.","risk":"Loss possible.","evidence":["F1"]}"#
        let cases: [(Any, S.Finish)] = [
            ("content_filter", .filtered), ("tool_calls", .toolCall), ("function_call", .toolCall),
            ("unexpected", .unknown), (42, .malformed)
        ]
        for isOllama in [true, false] {
            for (rawFinish, expected) in cases {
                let body: [String: Any] = isOllama
                    ? ["message": ["content": text], "done_reason": rawFinish]
                    : ["choices": [["message": ["content": text], "finish_reason": rawFinish]]]
                let bytes = try JSONSerialization.data(withJSONObject: body)
                let completion = try S.parseCompletion(bytes, isOllama: isOllama).get()
                #expect(completion.diagnostic.finish == expected)
                #expect(S.financialOutputRejection(completion) != nil, "Explicit \(expected) is not a completed verdict")
                #expect(!S.rejectsTruncatedOutput(completion), "These states are not Chat token-limit notices")
                #expect(S.parseChatResponse(bytes, isOllama: isOllama) == text,
                        "Generic Chat retains usable text and observes the finish metadata separately")
            }
        }
    }

    // The strict LM Studio profile keeps its stricter rule: it requires a positively confirmed
    // "stop", so absent metadata is refused there and accepted everywhere else.
    @Test @MainActor func absentFinishMetadataStaysAcceptableOffTheStrictProfile() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "A complete answer."]], request)
            })
        #expect((try? result.get())?.text == "A complete answer.")
        let completion = try result.get()
        #expect(S.financialOutputRejection(completion) == nil)
    }

    // MARK: Model identity on every backend, without breaking Ollama's ":latest" spelling

    @Test @MainActor func anotherModelsAnswerIsRejectedOnEveryBackend() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": "some-other-model", "message": ["content": "answer"],
                             "done_reason": "stop"], request)
            })
        guard case .failure(let failure) = result else {
            Issue.record("an answer from another model was accepted"); return
        }
        #expect(failure.diagnostic.category == .responseShape)
    }

    // Ollama tags a served model "name:latest" while the viewer types the bare name. The identity
    // check must not reject the very server the app ships pointed at.
    @Test @MainActor func ollamaLatestSuffixIsTheSameModel() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": Self.ollamaFixtureModel + ":latest", "message": ["content": "answer"],
                             "done_reason": "stop"], request)
            })
        #expect((try? result.get())?.text == "answer")
    }

    // A server that reports no model at all stays acceptable off the strict profile.
    @Test @MainActor func absentModelMetadataStaysAcceptableOffTheStrictProfile() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["message": ["content": "answer"], "done_reason": "stop"], request)
            })
        #expect((try? result.get())?.text == "answer")
    }

    // Confirmed defect: ValidationFailure.explanation hardcoded "Qwen" regardless of which model
    // actually answered. Every model-facing message must name the REPLY's reported model
    // (completion.model), not the requested config.model, and never say "Qwen" for any model.
    @Test func everyModelFacingMessageNamesTheAnsweringModel() throws {
        typealias A = StockSageAIAssessment
        for failure in [A.ValidationFailure.foreignNumber, .unboundNumber, .nonASCIINumber,
                        .emptyEvidence, .tooManyEvidence, .duplicateEvidence, .unknownEvidence,
                        .unknownReference, .unsupportedResearchClaim, .malformedJSON, .schema] {
            let named = failure.explanation(model: "fixture-model-A")
            #expect(!named.contains("Qwen"))
            let generic = failure.explanation(model: nil)
            #expect(!generic.contains("Qwen"))
            switch failure {
            case .foreignNumber, .unboundNumber, .nonASCIINumber, .emptyEvidence, .tooManyEvidence,
                 .duplicateEvidence, .unknownEvidence, .unknownReference, .unsupportedResearchClaim:
                #expect(named.hasPrefix("The model fixture-model-A "))
                #expect(generic.hasPrefix("The model "), "\(failure) generic case: \(generic)")
                #expect(!generic.hasPrefix("The model  "))
            default:
                #expect(named.hasPrefix("The model "))
            }
        }

        let facts = ["Observed price 2000.0 USD."]
        let validJSON = #"{"action":"Hold","reason":"Outlook uncertain (F1).","risk":"A loss remains possible.","evidence":["F1"]}"#
        let foreignNumberText = validJSON.replacingOccurrences(of: "(F1)", with: "99999")
        try #require(A.validate(foreignNumberText, facts: facts) == .failure(.foreignNumber))

        let completion = S.Completion(text: foreignNumberText, diagnostic: .init(finish: .stop), model: "fixture-model-A")
        let summary = StockSageAIAssessments.failureSummary(.success(completion), facts: facts, leadCount: 0)
        #expect(summary.contains("fixture-model-A"))
        #expect(!summary.contains("Qwen"))
    }

    // MARK: Phase timings

    // Nothing anywhere measured how long a model turn spent waiting versus generating, so no
    // caller could show elapsed time or explain a slow turn.
    @Test @MainActor func completionCarriesItsOwnElapsedTime() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try await Task.sleep(nanoseconds: 20_000_000)
                return try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "answer"],
                                    "done_reason": "stop"], request)
            })
        let completion = try #require(try? result.get())
        let elapsed = try #require(completion.diagnostic.elapsedMilliseconds)
        #expect(elapsed >= 15, "a 20 ms transport must record at least ~15 ms")
        #expect(elapsed < 60_000)
        #expect(completion.diagnostic.summary.contains("elapsedMs="))
    }

    @Test @MainActor func elapsedTimeIsRecordedForFailuresToo() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { _ in throw URLError(.timedOut) })
        guard case .failure(let failure) = result else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(failure.diagnostic.category == .timeout)
        #expect(failure.diagnostic.elapsedMilliseconds != nil)
    }

    // MARK: Failures stay distinguishable on every surface

    // Diagnostic categories used to collapse into one message per surface,
    // so a server that WAS reached and answered still told the user to check their connection.
    @Test func everyDiagnosticCategoryKeepsADistinguishableCause() {
        let categories: [S.FailureCategory] = [.invalidConfig, .unavailable, .modelMissing, .unsupportedModel,
            .nonHTTP, .http, .malformedJSON, .responseShape, .missingContent, .emptyContent, .timeout,
            .cancelled, .network, .obsoleteRequest, .policyDenied, .responseTooLarge, .contextBudget,
            .incompleteOutput, .degenerateOutput]
        var seen: Set<S.FailureCause> = []
        for category in categories {
            seen.insert(S.cause(for: .init(category: category)))
        }
        // Every cause except the catch-all must be reachable from a real category.
        #expect(seen.count >= 12, "categories collapsed too far: \(seen.count) distinct causes")
        #expect(!seen.contains(.unknown), "no real category may fall through to unknown")
        #expect(S.cause(for: .init()) == .unknown)
    }

    // The reached-and-answered failures must never be described as connection problems.
    @Test func reachedAndAnsweredFailuresAreNotCalledConnectionProblems() {
        // These are the categories that mean the server was reached and answered.
        for category in [S.FailureCategory.http, .responseTooLarge, .incompleteOutput, .degenerateOutput,
                         .emptyContent, .malformedJSON, .responseShape, .modelMissing] {
            let message = StockSageChat.unavailableMessage(for: .init(category: category))
            #expect(!message.lowercased().contains("could not be reached"),
                    "\(category) must not be reported as unreachable")
        }
        // And the genuinely unreachable ones still say so.
        for category in [S.FailureCategory.unavailable, .network, .nonHTTP] {
            #expect(StockSageChat.unavailableMessage(for: .init(category: category))
                .lowercased().contains("could not be reached"))
        }
    }

    @Test func chatMessagesAreDistinctAndCarryNoServerText() {
        var messages: Set<String> = []
        for category in [S.FailureCategory.invalidConfig, .unavailable, .modelMissing, .http,
                         .timeout, .cancelled, .obsoleteRequest, .policyDenied, .responseTooLarge,
                         .contextBudget, .incompleteOutput, .emptyContent, .malformedJSON] {
            let message = StockSageChat.unavailableMessage(for: .init(category: category))
            #expect(messages.insert(message).inserted, "duplicate message for \(category)")
            #expect(message.contains("no answer was assumed"))
        }
    }

    // Sentiment used to report a reachable-but-rejecting server as a connection problem.
    @Test func sentimentDistinguishesReachedFailuresFromUnreachableOnes() {
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .http)) == .serverRejected)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .contextBudget)) == .contextBudget)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .emptyContent)) == .emptyAnswer)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .responseShape)) == .unreadable)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .policyDenied)) == .notAllowed)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .incompleteOutput)) == .incomplete)
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .cancelled)) == .cancelled)
        // Genuinely unreachable stays the connection message.
        #expect(StockSageLocalSentiment.Failure.from(.init(category: .network)) == .modelUnavailable)
        #expect(!StockSageLocalSentiment.Failure.serverRejected.message.lowercased().contains("connection and try again"))
    }

    // MARK: Chat phase progress

    // The pending notice was written once and never updated, and iOS ignored it entirely in
    // favour of a hardcoded string. Stages are named; no percentage is invented.
    @Test @MainActor func chatPhasesAdvanceOnlyForThePendingTurn() throws {
        let session = StockSageChatSession(historyURL: nil)
        let snapshot = StockSageChat.Snapshot(at: Date(), facts: [], context: "test")
        let id = try #require(session.begin(question: "What happened today?", snapshot: snapshot, model: "m"))
        let initial = try #require(session.turns.last?.notice)

        session.advance(id: id, to: .sources)
        #expect(session.turns.last?.notice == StockSageChatSession.Phase.sources.notice)
        session.advance(id: id, to: .checkingModel)
        #expect(session.turns.last?.notice == StockSageChatSession.Phase.checkingModel.notice)
        session.advance(id: id, to: .generating)
        #expect(session.turns.last?.notice == StockSageChatSession.Phase.generating.notice)

        // Each stage is a distinct, non-empty sentence and none of them fakes a percentage.
        let notices = [initial] + StockSageChatSession.Phase.allNotices
        #expect(Set(notices).count == notices.count)
        #expect(notices.allSatisfy { !$0.contains("%") })

        // A superseded request must not relabel a newer turn.
        session.advance(id: UUID(), to: .sources)
        #expect(session.turns.last?.notice == StockSageChatSession.Phase.generating.notice)
    }

    // MARK: A same-day entry cannot be approved without a dated intraday observation

    // `intradayIndices` deliberately SKIPS the first intraday fact, which is the caveat/summary
    // line. On the SIP-trade fallback that caveat is the ONLY intraday fact, so the index range
    // is empty and no entry may qualify. That safety property had no test, and it rests on a
    // subtlety: an empty Set is disjoint from everything, so `isDisjoint` returns true and
    // `hasIntradayEvidence` returns false. If that ever inverted, the paper account could open a
    // same-day position with no dated observation behind it.
    @Test func theSIPFallbackCannotApproveASameDayEntry() {
        typealias Paper = StockSagePaperAutomation
        // One intraday fact (the caveat) at optional-count 4 -> (5)..<(5): empty.
        let fallbackOnly = (4 + 1)..<(4 + 1)
        #expect(fallbackOnly.isEmpty)
        #expect(!Paper.hasIntradayEvidence(["F1", "F5", "F6"], factIndices: fallbackOnly),
                "an empty intraday index set must never satisfy the entry gate")
        #expect(!Paper.hasIntradayEvidence([], factIndices: fallbackOnly))

        // With real per-minute bars the gate opens only for the observations, never the caveat.
        // Six intraday facts at optional-count 4 -> (5)..<(10) -> F6...F10; F5 is the caveat.
        let withBars = (4 + 1)..<(4 + 6)
        #expect(!Paper.hasIntradayEvidence(["F5"], factIndices: withBars),
                "citing only the caveat line must not satisfy the entry gate")
        #expect(Paper.hasIntradayEvidence(["F6"], factIndices: withBars))
        #expect(Paper.hasIntradayEvidence(["F1", "F10"], factIndices: withBars))
        #expect(!Paper.hasIntradayEvidence(["F11"], factIndices: withBars),
                "a fact beyond the intraday block must not satisfy the gate")
    }

    // MARK: Cross-caller contention is observed, not assumed

    // Nothing in the app serialises model work across callers: the assessment object's
    // single-active-symbol guard is local to itself, so a Chat turn and a background research
    // cycle can generate simultaneously and neither knows. The approved design gates its
    // admission policy on instrumenting the callers FIRST, so this counts rather than locks —
    // it must never block a request, and it must never leave a request permanently counted.

    @Test @MainActor func aLoneRequestReportsNoContention() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        // The release is deferred onto an unstructured task, so an earlier case's slot may still
        // be draining. Wait for zero before asserting zero, or this reads another test's request.
        for _ in 0..<100 where await S.currentInFlight() != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "answer"],
                             "done_reason": "stop"], request)
            })
        let completion = try #require(try? result.get())
        #expect(completion.diagnostic.concurrentRequests == 0)
        #expect(completion.diagnostic.summary.contains("concurrent=0"))
    }

    // Two overlapping requests must each observe the other. The transport blocks until both
    // have entered, which is only possible if the counter does not serialise them.
    @Test @MainActor func overlappingRequestsEachObserveTheOther() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        let bothEntered = AsyncGate()
        func call() async -> S.CompletionResult {
            await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
                transport: { request in
                    await bothEntered.arriveAndWait()
                    return try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "answer"],
                                        "done_reason": "stop"], request)
                })
        }
        async let first = call()
        async let second = call()
        let results = await [first, second]
        let observed = results.compactMap { try? $0.get() }.map(\.diagnostic.concurrentRequests)
        #expect(observed.count == 2)
        // Whichever entered second saw one already running; the counter did not block either.
        #expect(observed.contains(1), "no request observed the other: \(observed)")
    }

    // A request that fails must still release its slot, or observed concurrency would creep
    // upward forever and the measurement would be worthless.
    @Test @MainActor func aFailedRequestDoesNotStayCounted() async throws {
        let config = try #require(S.config(url: Self.ollamaFixtureURL, model: Self.ollamaFixtureModel))
        for _ in 0..<5 {
            _ = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
                transport: { _ in throw URLError(.timedOut) })
        }
        // Give the deferred release a chance to run, then confirm the counter drained.
        for _ in 0..<50 where await S.currentInFlight() != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await S.currentInFlight() == 0)

        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": Self.ollamaFixtureModel, "message": ["content": "answer"],
                             "done_reason": "stop"], request)
            })
        #expect((try? result.get())?.diagnostic.concurrentRequests == 0,
                "a later request inherited contention from failed ones")
    }

    // Catalysts Explain showed one unlabelled spinner across source collection, a 2.5-second
    // probe and a completion that can run for 90 seconds. Stages are named, distinct, and
    // invent no percentage.
    @Test func explainStagesAreNamedDistinctAndInventNoPercentage() {
        let labels = StockSageCatalystNarrator.Stage.allCases.map(\.label)
        #expect(labels.count == StockSageCatalystNarrator.Stage.allCases.count)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty && !$0.contains("%") })
        // Ordered: evidence is collected before the model is asked.
        #expect(StockSageCatalystNarrator.Stage.allCases.first == .sources)
        #expect(StockSageCatalystNarrator.Stage.allCases.last == .explaining)
    }

    // Chat and Catalysts describe the same two phases, so a user reads consistent wording for
    // the same underlying work on both surfaces.
    @Test func chatAndExplainAgreeOnWhatTheStagesMean() {
        #expect(StockSageChatSession.Phase.sources.notice.localizedCaseInsensitiveContains("evidence")
                || StockSageChatSession.Phase.sources.notice.localizedCaseInsensitiveContains("source"))
        #expect(StockSageCatalystNarrator.Stage.sources.label.localizedCaseInsensitiveContains("source"))
        #expect(StockSageChatSession.Phase.generating.notice.localizedCaseInsensitiveContains("model"))
        #expect(StockSageCatalystNarrator.Stage.explaining.label.localizedCaseInsensitiveContains("explanation"))
        // The second stage covers the probe as well as generation, so it must say so rather than
        // claiming the model is writing while it is still being checked.
        #expect(StockSageCatalystNarrator.Stage.explaining.label.localizedCaseInsensitiveContains("checking"))
    }

    // MARK: The diagnostic must never carry server text

    @Test func diagnosticSummaryStaysFixedKeysAndNumbers() {
        var diagnostic = S.Diagnostic(category: .http, httpStatus: 500, bodyBytes: 12)
        diagnostic.elapsedMilliseconds = 1234
        let summary = diagnostic.summary
        #expect(summary.contains("server=http"))
        #expect(summary.contains("status=500"))
        #expect(summary.contains("elapsedMs=1234"))
        // No free-form server text may ever be interpolated into a user-visible summary.
        #expect(!summary.contains("\""))
    }
}


@Suite("Evidence coverage checkpoint", .serialized)
@MainActor
struct StockSageCoverageCheckpointTests {
    @Test(arguments: [0, 1, 2, 6])
    func intradayCitationsExcludeCaveatAndFollowingDailyFact(_ count: Int) {
        let indices = StockSagePaperAutomation.intradayObservationIndices(precedingFactCount: 9, intradayFactCount: count)
        #expect(indices.count == max(0, count - 1))
        #expect(!StockSagePaperAutomation.hasIntradayEvidence(["F10"], factIndices: indices))
        #expect(!StockSagePaperAutomation.hasIntradayEvidence(["F\(10 + count)"], factIndices: indices))
        if count > 1 {
            #expect(StockSagePaperAutomation.hasIntradayEvidence(["F11"], factIndices: indices))
            #expect(StockSagePaperAutomation.hasIntradayEvidence(["F\(9 + count)"], factIndices: indices))
        }
    }

    @Test func oldPaperDecisionsDecodeAndNewCoverageRoundTrips() throws {
        typealias P = StockSagePaperAutomation
        let old = P.Decision(id: UUID(), at: Date(timeIntervalSince1970: 1), symbol: "ACME", action: "Hold",
                             reason: "Mixed", risk: "Uncertain", facts: [], evidence: [], model: "fixture")
        let legacyData = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(P.Decision.self, from: legacyData).evidenceCoverage == nil)
        var current = old
        current.evidenceCoverage = .init(symbol: "ACME", requiredKeys: ["earnings"],
            missingOrUnknownRequiredKeys: ["earnings"], offeredKeys: ["earnings"], omittedKeys: ["news.item.fixture"],
            prePromptOmittedRecordCount: 2, citedKeys: ["earnings"])
        #expect(try JSONDecoder().decode(P.Decision.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func frozenPackingCheckpoint() throws {
        typealias A = StockSageAIAssessment
        let at = Date(timeIntervalSince1970: 1_789_344_000)
        let idea = StockSageIdea(symbol: "ACME", market: "US", price: 50,
            advice: TradeAdvice(action: .hold, conviction: 0, regime: .range,
                rationale: ["Mixed technical direction."], stopPrice: nil,
                targetPrice: nil, suggestedWeight: 0, caveat: "Rules only."),
            spark: [49, 50], realizedVol: 0.2, generatedAt: at, priceAsOf: at, priceSource: .massiveSIP)
        let news = (0..<3).map { index in StockSageNewsService.NewsItem(date: at,
            title: "Synthetic coverage fixture \(index)", snippet: String(repeating: "Attributed news context. ", count: 18),
            link: nil, sentiment: nil, source: "Fixture") }
        let context = A.Context(idea: idea, earnings: nil, company: [:], news: news, at: at, quotedInUSD: true)
        let all = context.facts
        let required = all.filter { !$0.hasPrefix("Historical annualized volatility:") && !$0.hasPrefix("Attributed news,") }
        let mandatory = ["Requested holding horizon: 7–14 days. Research only."]
        for budget in [2_048, 3_072, 4_096, 6_144, 8_192, 16_384] {
            let compiled = context.evidencePacket().facts
            let optional = compiled.filter { !$0.required }
            let fitted = A.fittedResearchPrompt(optional: optional.map(\.text), mandatory: compiled.filter(\.required).map(\.text) + mandatory,
                system: { _ in "Frozen evidence packing fixture. Cite only offered facts." }, optionalKeys: optional.map(\.key),
                outputTokens: 192, contextTokens: budget)
            let accepted = try #require(fitted)
            #expect(required.allSatisfy(accepted.facts.contains))
            #expect(accepted.omittedKeys.count == accepted.omitted)
            let row: [String: Any] = ["context": budget, "required_total": required.count,
                "required_retained": required.filter { fitted?.facts.contains($0) == true }.count,
                "fit": fitted != nil, "omitted": fitted?.omitted ?? -1,
                "prompt_bytes": fitted?.user.utf8.count ?? 0]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("R27_BENCH " + String(decoding: data, as: UTF8.self))
            if let fitted { #expect(StockSageLocalModelServer.promptFits(system: fitted.system, user: fitted.user, outputTokens: 192, contextTokens: budget)) }
        }
    }
}
