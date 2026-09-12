import Foundation
import Synchronization
import Testing
@testable import StockSage

// BATCH 6.1 (2026-09-12) — a failed or denied SEC fetch must not render as "checked and empty".
//
// `recentFilings` returns `[]` for ALL of: web access off, a cancelled task, no CIK for the
// ticker, an unreachable feed, a malformed payload, and "this company filed no 8-K in the window".
// The Catalysts panel printed the last of those — "No 8-K found in the window we looked at" — for
// every one of them, which states a check that never ran. Worse, the policy-denied path published
// nothing at all AND cached the symbol as fetched, so the Filings button was a dead control that
// stayed dead.
//
// `recentFilings` itself is deliberately UNCHANGED — `hasDisclosure` calls it and
// StockSageSECRequestTests:153 pins `.isEmpty` on a cancelled caller.
@Suite("SEC filings — outcome, not just rows")
struct StockSageFilingsObservationTests {

    private typealias D = StockSageDisclosureService
    private let now = Date(timeIntervalSince1970: 1_757_500_000)
    nonisolated private static let tickers = Data(#"{"0":{"ticker":"TEST","cik_str":123}}"#.utf8)
    nonisolated private static let filingsJSON = Data(#"{"filings":{"recent":{"form":["8-K"],"accessionNumber":["0000000123-26-000001"],"filingDate":["2026-09-08"]}}}"#.utf8)

    nonisolated private static func ok(_ req: URLRequest, _ body: Data, status: Int = 200) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    /// Serves the ticker map, then the submissions payload.
    nonisolated private static func wire(_ filingsBody: Data, status: Int = 200) -> D.Transport {
        { req in
            let isMap = req.url!.absoluteString.contains("company_tickers")
            return ok(req, isMap ? tickers : filingsBody, status: isMap ? 200 : status)
        }
    }

    // The state the owner actually hits: web access off. The button did nothing at all.
    @Test @MainActor func aPolicyDenialIsAnOutcome() async {
        let calls = Mutex(0)
        let transport: D.Transport = { req in calls.withLock { $0 += 1 }; return Self.ok(req, Self.tickers) }
        let obs = await D.recentFilingsObservation(for: "TEST", map: D.CIKMap(transport: transport),
                                                   transport: transport, allowed: { false }, now: now)
        #expect(obs.outcome == .unavailable(.externalAccessDisabled))
        #expect(obs.filings.isEmpty)
        #expect(obs.checkedAt == now, "the failure is DATED, so the panel can say when it looked")
        #expect(calls.withLock { $0 } == 0, "nothing may be requested once access is denied")
        // The message is the shared one, so this reads the same as every other denied feed.
        #expect(obs.outcome.failureMessage == StockSageMassiveEvents.Failure.externalAccessDisabled.message)
    }

    @Test @MainActor func anUnreachableFeedIsNotAnEmptyResult() async {
        let t = Self.wire(Data("nope".utf8), status: 503)
        let obs = await D.recentFilingsObservation(for: "TEST", map: D.CIKMap(transport: t),
                                                   transport: t, allowed: { true }, now: now)
        #expect(obs.outcome == .unavailable(.unreachable))
        #expect(obs.filings.isEmpty)
    }

    @Test @MainActor func aMalformedPayloadIsNotAnEmptyResult() async {
        let t = Self.wire(Data("<html>not json</html>".utf8))
        let obs = await D.recentFilingsObservation(for: "TEST", map: D.CIKMap(transport: t),
                                                   transport: t, allowed: { true }, now: now)
        #expect(obs.outcome == .unavailable(.invalidPayload))
    }

    @Test @MainActor func aTickerWithNoCIKIsNotAnEmptyResult() async {
        let t = Self.wire(Self.filingsJSON)
        let obs = await D.recentFilingsObservation(for: "NOSUCH", map: D.CIKMap(transport: t),
                                                   transport: t, allowed: { true }, now: now)
        #expect(obs.outcome == .unavailable(.noCIK))
    }

    // The ONE case that may print "no 8-K found": the feed answered and the window was empty.
    @Test @MainActor func anAnsweredCheckWithNoRowsIsDistinctFromAFailedOne() async {
        let empty = Data(#"{"filings":{"recent":{"form":["10-Q"],"accessionNumber":["0000000123-26-000009"],"filingDate":["2026-09-08"]}}}"#.utf8)
        let t = Self.wire(empty)
        let obs = await D.recentFilingsObservation(for: "TEST", map: D.CIKMap(transport: t),
                                                   transport: t, allowed: { true }, now: now)
        #expect(obs.outcome == .answered, "the feed answered — there simply was no 8-K in the window")
        #expect(obs.filings.isEmpty)
    }

    @Test @MainActor func anAnsweredCheckReturnsItsRows() async {
        let t = Self.wire(Self.filingsJSON)
        let obs = await D.recentFilingsObservation(for: "TEST", map: D.CIKMap(transport: t),
                                                   transport: t, allowed: { true }, now: now)
        #expect(obs.outcome == .answered)
        #expect(obs.filings.count == 1)
    }

    // Every failure message must be a fixed category — never a raw URL, status code or body.
    @Test func failureMessagesLeakNothingAndAllDiffer() {
        let all: [D.FilingsObservation.Failure] = [.externalAccessDisabled, .cancelled, .noCIK,
                                                   .unreachable, .invalidPayload]
        let messages = all.map(\.message)
        #expect(Set(messages).count == all.count, "each failure must be distinguishable to the reader")
        for m in messages {
            #expect(!m.isEmpty)
            #expect(!m.contains("http") && !m.contains("sec.gov") && !m.contains("503"))
        }
    }

    // The wrapper `hasDisclosure` and the existing SEC suite depend on is untouched.
    @Test @MainActor func theThinWrapperKeepsItsEmptyOnFailureContract() async {
        let t = Self.wire(Data("nope".utf8), status: 503)
        let rows = await D.recentFilings(for: "TEST", map: D.CIKMap(transport: t),
                                         transport: t, allowed: { true })
        #expect(rows.isEmpty)
    }
}

private extension StockSageDisclosureService.FilingsObservation.Outcome {
    var failureMessage: String? {
        if case .unavailable(let f) = self { return f.message }
        return nil
    }
}
