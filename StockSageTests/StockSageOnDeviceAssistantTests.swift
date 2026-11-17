import Foundation
import Testing
@testable import StockSage

/// These tests exercise the real admission, deadline, cancellation and context
/// contracts with a controllable generator. They never use an OS model or server.
@Suite(.serialized)
@MainActor
struct StockSageOnDeviceAssistantTests {
    private func request(tokens: Int = 200) -> StockSageOnDeviceRequest {
        .init(instructions: "Explain captured facts", prompt: "What does this mean?",
              localeIdentifier: "ar-SA", format: .text, maximumResponseTokens: tokens)
    }

    private func fact(id: String = "f1", value: String = "125.50") -> StockSageChat.Fact {
        .init(id: id, subject: "EXAMPLE", field: "Recorded price", value: value,
              unit: "USD", asOf: Date(timeIntervalSince1970: 1_700_000_000),
              source: "Manual fixture", status: "Historical; not a live quote")
    }

    private func snapshot(facts: [StockSageChat.Fact]? = nil) -> StockSageChat.Snapshot {
        .init(at: Date(timeIntervalSince1970: 1_700_000_100), facts: facts ?? [fact()],
              context: "User-entered fixture records", sources: nil, researchStatus: nil)
    }

    private func turn(_ question: String, answer: String = "A historical explanation.") -> StockSageChatSession.Turn {
        .init(id: UUID(), question: question, snapshot: snapshot(), model: "Prior model",
              answer: answer, evidence: [], notice: "Historical")
    }

    @Test func unavailableModelsDoNotStartGenerationAndPreserveLocale() async {
        let generator = ControlledOnDeviceGenerator()
        generator.state = .unavailable("Model not ready")
        let client = StockSageOnDeviceAssistant(generator: generator)
        do {
            _ = try await client.respond(request())
            Issue.record("Unavailable model must not answer")
        } catch {
            #expect(error as? StockSageOnDeviceFailure == .unavailable("Model not ready"))
        }
        #expect(generator.requests.isEmpty)
        #expect(generator.lastLocale == "ar-SA")
    }

    @Test func invalidResponseBudgetsNeverReachGenerator() async {
        let generator = ControlledOnDeviceGenerator()
        let client = StockSageOnDeviceAssistant(generator: generator)
        for tokens in [Int.min, -1, 0, 513, Int.max] {
            do {
                _ = try await client.respond(request(tokens: tokens))
                Issue.record("Invalid response budget was accepted")
            } catch {
                #expect(error as? StockSageOnDeviceFailure == .contextLimit)
            }
        }
        #expect(generator.requests.isEmpty)
    }

    @Test func completedResponseReleasesSlotAndRejectsUnreadableText() async throws {
        let generator = ControlledOnDeviceGenerator()
        let client = StockSageOnDeviceAssistant(generator: generator)
        generator.result = .success("  A complete explanation.\n")
        #expect(try await client.respond(request()) == "A complete explanation.")
        for text in [" \n\t", String(repeating: "x", count: 16_385)] {
            generator.result = .success(text)
            do {
                _ = try await client.respond(request())
                Issue.record("Unreadable response was accepted")
            } catch {
                #expect(error as? StockSageOnDeviceFailure == .invalidResponse)
            }
        }
        generator.result = .success("A later complete reply.")
        #expect(try await client.respond(request()) == "A later complete reply.")
        #expect(generator.requests.count == 4)
    }

    @Test func refusalIsTerminalWithoutRetries() async {
        let generator = ControlledOnDeviceGenerator()
        generator.result = .failure(StockSageOnDeviceFailure.refused)
        let client = StockSageOnDeviceAssistant(generator: generator)
        do {
            _ = try await client.respond(request())
            Issue.record("Refusal must remain a refusal")
        } catch {
            #expect(error as? StockSageOnDeviceFailure == .refused)
        }
        #expect(generator.requests.count == 1)
    }

    @Test func concurrentRequestCannotStartSecondGeneration() async throws {
        let generator = ControlledOnDeviceGenerator()
        generator.hold = true
        let client = StockSageOnDeviceAssistant(generator: generator, timeout: .seconds(2))
        let first = Task { try await client.respond(request()) }
        defer { first.cancel(); generator.complete("Test cleanup") }
        try await generator.waitUntilStarted()
        do {
            _ = try await client.respond(request())
            Issue.record("Concurrent generation was accepted")
        } catch {
            #expect(error as? StockSageOnDeviceFailure == .busy)
        }
        #expect(generator.requests.count == 1)
        generator.complete("First response")
        #expect(try await first.value == "First response")
    }

    @Test func timeoutReturnsWhileNoncooperativeModelRetainsAdmissionSlot() async throws {
        let generator = ControlledOnDeviceGenerator()
        generator.hold = true
        let client = StockSageOnDeviceAssistant(generator: generator, timeout: .milliseconds(50))
        let first = Task { try await client.respond(request()) }
        defer { first.cancel(); generator.complete("Test cleanup") }
        try await generator.waitUntilStarted()
        do {
            _ = try await first.value
            Issue.record("A model that never finishes must time out")
        } catch {
            #expect(error as? StockSageOnDeviceFailure == .timedOut)
        }
        do {
            _ = try await client.respond(request())
            Issue.record("Timeout must not allow overlapping OS generation")
        } catch {
            #expect(error as? StockSageOnDeviceFailure == .busy)
        }
        #expect(generator.requests.count == 1)
        generator.hold = false
        generator.result = .success("New response")
        generator.complete("Late response must be ignored")
        #expect(try await answerAfterSlotReleased(client) == "New response")
        #expect(generator.requests.count == 2)
    }

    @Test func cancellationReturnsAndIgnoresNoncooperativeLateReply() async throws {
        let generator = ControlledOnDeviceGenerator()
        generator.hold = true
        let client = StockSageOnDeviceAssistant(generator: generator, timeout: .seconds(2))
        let cancelledBeforeAdmission = Task { try await client.respond(request()) }
        cancelledBeforeAdmission.cancel()
        do {
            _ = try await cancelledBeforeAdmission.value
            Issue.record("A request cancelled before admission must not run")
        } catch { #expect(error is CancellationError) }
        #expect(generator.requests.isEmpty)
        let first = Task { try await client.respond(request()) }
        defer { first.cancel(); generator.complete("Test cleanup") }
        try await generator.waitUntilStarted()
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Cancelled question returned an answer")
        } catch { #expect(error is CancellationError) }
        do {
            _ = try await client.respond(request())
            Issue.record("Cancellation must retain the actual generation slot")
        } catch { #expect(error as? StockSageOnDeviceFailure == .busy) }
        generator.hold = false
        generator.result = .success("Fresh answer")
        generator.complete("Cancelled stale answer")
        #expect(try await answerAfterSlotReleased(client) == "Fresh answer")
        #expect(generator.requests.count == 2)
    }

    @Test func contextPreservesWholeFactsAndDisclosesHistoryOmissions() throws {
        let largeNumber = "12345678901234567890.123456789"
        let captured = snapshot(facts: [fact(value: largeNumber)])
        var action = turn("Add EXAMPLE to watchlist")
        action.isWatchlistAction = true
        let history = [turn("Older turn"), turn("Oversized turn", answer: String(repeating: "a", count: 1_201)),
                       turn("Whole recent turn"), turn("Other recent turn"), turn("Newest turn"), action]
        let prepared = try StockSageOnDeviceAssistant.prepareChat(question: "Explain the recorded price.",
            snapshot: captured, history: history, locale: Locale(identifier: "ar-SA"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(prepared.request.prompt.utf8)) as? [String: Any])
        let facts = try #require(object["facts"] as? [[String: String]])
        #expect(facts == [["id": "f1", "record": captured.facts[0].text]])
        #expect(facts[0]["record"]?.contains(largeNumber) == true)
        let included = try #require(object["historicalUnverifiedConversation"] as? [[String: String]])
        #expect(included.count == 3)
        #expect(included.first?["question"] == "Whole recent turn")
        #expect(prepared.snapshot.facts == captured.facts)
        #expect(prepared.snapshot.researchStatus?.contains("older or oversized turns omitted: 2") == true)
        #expect(prepared.request.localeIdentifier == "ar-SA")
    }

    @Test func oversizedRecordsAreRejectedWithoutPartialFinancialValues() {
        let captured = snapshot(facts: [fact(value: String(repeating: "1234567890", count: 2_500))])
        #expect(throws: StockSageOnDeviceFailure.contextLimit) {
            try StockSageOnDeviceAssistant.prepareChat(question: "Explain.", snapshot: captured, history: [])
        }
    }

    @Test func unsafeQuestionsAndUnboundEvidenceAreRejected() {
        let duplicate = snapshot(facts: [fact(), fact()])
        let tooMany = snapshot(facts: (0..<13).map { fact(id: "f\($0)") })
        for captured in [duplicate, tooMany] {
            #expect(throws: StockSageOnDeviceFailure.contextLimit) {
                try StockSageOnDeviceAssistant.prepareChat(question: "Explain.", snapshot: captured, history: [])
            }
        }
        for question in [" ", String(repeating: "x", count: 2_001), "password=not-a-real-test-password"] {
            #expect(throws: StockSageOnDeviceFailure.contextLimit) {
                try StockSageOnDeviceAssistant.prepareChat(question: question, snapshot: snapshot(), history: [])
            }
        }
        var withResearch = snapshot()
        withResearch.sources = [.init(id: "s1", subject: "EXAMPLE", attribution: "Unbound research",
                                      date: .now, excerpt: "Not fetched by this phone flow", warning: "Historical", link: nil)]
        #expect(throws: StockSageOnDeviceFailure.contextLimit) {
            try StockSageOnDeviceAssistant.prepareChat(question: "Explain.", snapshot: withResearch, history: [])
        }
    }

    @Test func responseRequiresExactSchemaAndOfferedUniqueEvidence() throws {
        let captured = snapshot()
        try StockSageOnDeviceAssistant.validateChatResponse(#"{"analysis":"See the recorded fact.","evidence":["f1"]}"#, snapshot: captured)
        try StockSageOnDeviceAssistant.validateChatResponse(#"{"analysis":"A general concept.","evidence":[]}"#, snapshot: captured)
        let invalid = [
            #"{"analysis":"Unknown evidence.","evidence":["invented"]}"#,
            #"{"analysis":"Duplicated evidence.","evidence":["f1","f1"]}"#,
            #"{"analysis":" ","evidence":[]}"#,
            #"{"analysis":"Extra action.","evidence":[],"action":"BUY"}"#,
            #"{"analysis":"Wrong type.","evidence":[1]}"#,
            "plain prose instead of JSON"
        ]
        for raw in invalid {
            #expect(throws: StockSageOnDeviceFailure.invalidResponse) {
                try StockSageOnDeviceAssistant.validateChatResponse(raw, snapshot: captured)
            }
        }
    }

    @Test func phoneBackendCannotRestorePaidOrRemoteModelSettings() {
        #if os(iOS)
        for raw in [nil, "", "local", "openAI", "gemma", "onDeviceOnly"] as [String?] {
            #expect(StockSageCatalystNarrator.selectedNarrationBackend(raw) == .onDeviceOnly)
        }
        #expect(StockSageCatalystNarrator.selectedNarrationBackend("off") == .off)
        #else
        for raw in [nil, "", "off", "local", "onDeviceOnly"] as [String?] {
            #expect(StockSageCatalystNarrator.selectedNarrationBackend(raw) == StockSageCatalystNarrator.selectedBackend(raw))
        }
        #endif
    }

    private func answerAfterSlotReleased(_ client: StockSageOnDeviceAssistant) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            do { return try await client.respond(request()) }
            catch StockSageOnDeviceFailure.busy { await Task.yield() }
        }
        Issue.record("Finished model did not release its admission slot")
        throw StockSageOnDeviceFailure.busy
    }
}

@MainActor
private final class ControlledOnDeviceGenerator: StockSageOnDeviceGenerating {
    var state: StockSageOnDeviceAvailability = .available
    var result: Result<String, Error> = .success("An explanation.")
    var hold = false
    private(set) var requests: [StockSageOnDeviceRequest] = []
    private(set) var lastLocale: String?
    private var continuation: CheckedContinuation<String, Error>?

    func availability(for locale: Locale) -> StockSageOnDeviceAvailability {
        lastLocale = locale.identifier
        return state
    }

    func generate(_ request: StockSageOnDeviceRequest) async throws -> String {
        requests.append(request)
        if !hold { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while requests.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !requests.isEmpty else {
            Issue.record("The controlled generator was not reached before the test deadline")
            throw StockSageOnDeviceFailure.timedOut
        }
    }

    func complete(_ text: String) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: text)
    }
}
