import Foundation
import Synchronization
import Testing
@testable import StockSage

@Suite(.serialized) @MainActor struct StockSageScreenerNewsTests {
    typealias N = StockSageScreenerNews
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var access: StockSageMassive.Access {
        .init(key: { "fixture" }, credentialRevision: { "one" }, policyRevision: { "one" }, allowed: { true })
    }
    private func row(_ index: Int, cap: Double? = 100_000_000) -> N.Row {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return .init(symbol: "T\(letters[index / 26])\(letters[index % 26])", name: "Company \(index)",
                     date: "2026-09-20", marketCap: cap, metrics: [], note: "")
    }
    private func answer(_ symbol: String) -> N.Observation {
        .init(attempts: [.init(provider: .benzinga, checkedAt: now, status: .answered, items: [
            .init(date: now.addingTimeInterval(-60), title: "\(symbol) cuts outlook", snippet: "Adverse evidence stays visible.",
                  link: nil, sentiment: -1, source: "Fixture")])])
    }

    @Test func fullMatchingSetAndNegativeNewsSurviveWithBoundedRequests() async {
        let eligible = (0..<65).map { row($0) }
        let selected = N.matchingRows(eligible + [eligible[0], row(66, cap: nil), row(67, cap: 9_000_000_000)],
                                     filters: .init(), search: "")
        #expect(selected.count == 65)
        #expect(N.matchingRows(eligible, filters: .init(), search: "company 64").map(\.symbol) == [row(64).symbol])
        #expect(N.matchingRows(eligible, filters: nil, search: "").isEmpty)
        var active = 0, peak = 0, calls: [String] = []
        let model = N(access: access, clock: { now }, loader: { item, at in
            #expect(at == now)
            active += 1; peak = max(peak, active); calls.append(item.symbol)
            try? await Task.sleep(for: .milliseconds(1))
            active -= 1
            if item.symbol == eligible[0].symbol {
                return .init(attempts: [.init(provider: .benzinga, checkedAt: at, status: .unavailable(.entitlement))])
            }
            if item.symbol == eligible[1].symbol {
                return .init(attempts: [.init(provider: .benzinga, checkedAt: at, status: .notChecked(.throttled))])
            }
            return answer(item.symbol)
        })
        #expect(calls.isEmpty)
        await model.load(rows: selected)
        #expect(Set(calls).count == 65 && calls.count == 65)
        #expect(peak > 1 && peak <= 4)
        #expect(model.rows.count == 65 && model.observations.count == 65 && !model.isLoading)
        #expect(model.observations[eligible[0].symbol]?.items.isEmpty == true)
        #expect(model.observations[eligible[1].symbol]?.latestCheckAt == nil)
        #expect(model.observations[eligible[64].symbol]?.items.first?.sentiment == -1)
    }

    @Test func cancelledAndObsoleteBatchesCannotPublishOrClearTheirReplacement() async {
        let gate = Gate()
        var calls = 0
        let model = N(access: access, clock: { now }, loader: { item, _ in
            calls += 1
            if item.symbol != row(100).symbol { await gate.wait() }
            return answer(item.symbol)
        })
        let old = Task { await model.load(rows: (0..<65).map { row($0) }) }
        let deadline = Date().addingTimeInterval(2)
        while gate.continuations.count < 4, Date() < deadline { await Task.yield() }
        guard gate.continuations.count == 4 else { old.cancel(); gate.release(); Issue.record("Four fixture loads did not start"); return }
        model.clear()
        await model.load(rows: [row(100)])
        gate.release()
        await old.value
        #expect(calls == 5, "Cancelled batch must not admit the other 61 symbols")
        #expect(model.rows.map(\.symbol) == [row(100).symbol])
        #expect(Set(model.observations.keys) == [row(100).symbol])
        #expect(!model.isLoading)
        model.clear()
        #expect(model.rows.isEmpty && model.observations.isEmpty && model.startedAt == nil)
    }

    @Test func accessChangesAndDeniedRequestsFailClosed() async {
        let revision = Mutex("one")
        var calls = 0
        let model = N(access: .init(key: { "fixture" }, credentialRevision: { revision.withLock { $0 } },
            policyRevision: { "one" }, allowed: { true }), clock: { now }, loader: { item, _ in
                calls += 1
                revision.withLock { $0 = "two" }
                return answer(item.symbol)
            })
        await model.load(rows: (0..<65).map { row($0) })
        #expect(calls > 0 && calls <= 4)
        #expect(model.observations.isEmpty && !model.isLoading)
        #expect(model.status.localizedCaseInsensitiveContains("access changed"))
        let denied = N(access: .init(key: { "fixture" }, credentialRevision: { nil }, policyRevision: { nil }, allowed: { false }),
                       loader: { item, _ in Issue.record("Denied access invoked news loader"); return answer(item.symbol) })
        await denied.load(rows: [row(0)])
        #expect(denied.observations.isEmpty && !denied.isLoading)
    }

    private final class Gate {
        var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { continuations.append($0) } }
        func release() { let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
    }
}
