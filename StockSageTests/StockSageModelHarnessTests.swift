import Testing
import Foundation
@testable import StockSage

// Harness regressions for the shared local-model seam (2026-09-10).
//
// Every case here reproduces a defect confirmed by reading the shipped source, or a measured
// failure from the frozen baseline in `StockSage-harness-20260910.opus/`. No live network:
// each test injects a transport closure, exactly like the existing suite.
@Suite("Model harness — budget, truncation and identity across every backend")
struct StockSageModelHarnessTests {

    typealias S = StockSageLocalModelServer

    private static func ok(_ object: [String: Any], _ request: URLRequest) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: Budget is shared, not LM-Studio-only

    // Confirmed defect: `promptFits` ran only when `Config.isLMStudio9B`, so the shipped default
    // (Ollama, 127.0.0.1:11434, "qwen3.8") dispatched any size of prompt and relied on the server
    // to truncate silently. A caller that packs 12,000 bytes into a 4,096-unit window must be told.
    @Test @MainActor func defaultOllamaBackendAlsoBoundsThePromptBeforeDispatch() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
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
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
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
    @Test func everyEvidenceHeavyCallerFitsItsDeclaredWindow() {
        let research = S.researchContextTokens
        let callers: [(name: String, system: String, outputTokens: Int, context: Int)] = [
            ("assessment", StockSageAIAssessment.instructions, 240, research),
            ("paper", StockSagePaperAutomation.researchInstructions,
             StockSagePaperAutomation.researchOutputTokens, research),
            ("horizon-week", StockSageHorizonResearch.Horizon.week.instructions,
             StockSageHorizonResearch.researchOutputTokens, research),
            ("horizon-fortnight", StockSageHorizonResearch.Horizon.fortnight.instructions,
             StockSageHorizonResearch.researchOutputTokens, research),
            ("narrator", StockSageCatalystNarrator.instructions, 170, research),
        ]
        for caller in callers {
            let allowance = S.maximumUserBytes(system: caller.system, outputTokens: caller.outputTokens,
                                               contextTokens: caller.context)
            // Each of these callers caps its compiled facts at 12,000 UTF-8 bytes. If the
            // allowance drops below that, the caller starts failing on every real request.
            #expect(allowance >= 12_000,
                    "\(caller.name) allows only \(allowance) bytes but compiles up to 12,000")
        }
    }

    // Conversational Chat deliberately keeps the owner's 4,096 interactive target. Its own
    // prompt budget must stay strictly inside the seam's, or every Chat turn would fail.
    @Test func chatOwnBudgetStaysInsideTheSeamBudget() {
        let allowance = S.maximumUserBytes(system: StockSageChat.instructions,
                                           outputTokens: StockSageChat.outputTokens,
                                           contextTokens: StockSageChat.contextTokens)
        #expect(StockSageChat.promptByteLimit > 0)
        #expect(StockSageChat.promptByteLimit <= allowance,
                "Chat packs \(StockSageChat.promptByteLimit) bytes into a \(allowance)-byte allowance")
    }

    // MARK: Truncation is rejected on every backend

    // Measured 2026-09-10: the frozen `holdout_01_loss` case returned finish_reason "length" with a
    // truncated P/L whose headline figure its own unfinished working contradicted.
    //
    // The seam deliberately keeps `finish` OBSERVATIONAL — it reports truncation and preserves the
    // text, because a cut-off Chat answer is still worth reading. The refusal therefore belongs to
    // the callers that publish a financial verdict, and is expressed by this predicate.
    @Test @MainActor func truncationIsReportedBySeamAndRefusedByVerdictCallers() async throws {
        for (url, model, isOllama) in [(S.defaultURL, S.defaultModel, true),
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
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": S.defaultModel, "message": ["content": "Complete."],
                             "done_reason": "stop"], request)
            })
        let completion = try #require(try? result.get())
        #expect(!S.rejectsTruncatedOutput(completion))
    }

    // The strict LM Studio profile keeps its stricter rule: it requires a positively confirmed
    // "stop", so absent metadata is refused there and accepted everywhere else.
    @Test @MainActor func absentFinishMetadataStaysAcceptableOffTheStrictProfile() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": S.defaultModel, "message": ["content": "A complete answer."]], request)
            })
        #expect((try? result.get())?.text == "A complete answer.")
    }

    // MARK: Model identity on every backend, without breaking Ollama's ":latest" spelling

    @Test @MainActor func anotherModelsAnswerIsRejectedOnEveryBackend() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
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
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["model": S.defaultModel + ":latest", "message": ["content": "answer"],
                             "done_reason": "stop"], request)
            })
        #expect((try? result.get())?.text == "answer")
    }

    // A server that reports no model at all stays acceptable off the strict profile.
    @Test @MainActor func absentModelMetadataStaysAcceptableOffTheStrictProfile() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try Self.ok(["message": ["content": "answer"], "done_reason": "stop"], request)
            })
        #expect((try? result.get())?.text == "answer")
    }

    // MARK: Phase timings

    // Nothing anywhere measured how long a model turn spent waiting versus generating, so no
    // caller could show elapsed time or explain a slow turn.
    @Test @MainActor func completionCarriesItsOwnElapsedTime() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { request in
                try await Task.sleep(nanoseconds: 20_000_000)
                return try Self.ok(["model": S.defaultModel, "message": ["content": "answer"],
                                    "done_reason": "stop"], request)
            })
        let completion = try #require(try? result.get())
        let elapsed = try #require(completion.diagnostic.elapsedMilliseconds)
        #expect(elapsed >= 15, "a 20 ms transport must record at least ~15 ms")
        #expect(elapsed < 60_000)
        #expect(completion.diagnostic.summary.contains("elapsedMs="))
    }

    @Test @MainActor func elapsedTimeIsRecordedForFailuresToo() async throws {
        let config = try #require(S.config(url: S.defaultURL, model: S.defaultModel))
        let result = await S.completeDetailed(config, isOllama: true, system: "s", user: "f",
            transport: { _ in throw URLError(.timedOut) })
        guard case .failure(let failure) = result else {
            Issue.record("expected a timeout failure"); return
        }
        #expect(failure.diagnostic.category == .timeout)
        #expect(failure.diagnostic.elapsedMilliseconds != nil)
    }

    // MARK: Failures stay distinguishable on every surface

    // Sixteen of eighteen diagnostic categories used to collapse into one message per surface,
    // so a server that WAS reached and answered still told the user to check their connection.
    @Test func everyDiagnosticCategoryKeepsADistinguishableCause() {
        let categories: [S.FailureCategory] = [.invalidConfig, .unavailable, .modelMissing, .unsupportedModel,
            .nonHTTP, .http, .malformedJSON, .responseShape, .missingContent, .emptyContent, .timeout,
            .cancelled, .network, .obsoleteRequest, .policyDenied, .responseTooLarge, .contextBudget, .incompleteOutput]
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
        for category in [S.FailureCategory.http, .responseTooLarge, .incompleteOutput,
                         .emptyContent, .malformedJSON, .responseShape, .modelMissing] {
            let cause = S.cause(for: .init(category: category))
            #expect(cause.serverAnswered, "\(category) reached the server")
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
