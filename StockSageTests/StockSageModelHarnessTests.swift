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
