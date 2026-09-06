import Testing
import Foundation
@testable import StockSage

// Pure-part tests for the optional on-device catalyst paragraph (owner request 2026-09-06,
// build step C2-narrator). No model calls here — FoundationModels needs a real device/session
// and is explicitly out of scope for this suite; every case below exercises the deterministic
// facts/prompt/number-fence machinery that `explain(_:)` is built on.
@Suite("Catalyst narrator (facts + number fence)")
struct StockSageCatalystNarratorTests {

    typealias N = StockSageCatalystNarrator
    static let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func brief(symbol: String, rr: Double? = 2.0) -> StockSageCatalystWatch.Brief {
        let idea = SageFix.idea(symbol, conviction: 0.6, rr: rr, price: 100, riskDistance: 10)
        let inputs = StockSageCatalystWatch.Inputs(earningsDate: Self.now.addingTimeInterval(2 * 86_400), now: Self.now)
        return StockSageCatalystWatch.brief(for: idea, inputs: inputs)
    }

    // MARK: facts(for:)

    @Test("facts carries the exact stop price when a stop exists")
    func factsContainsStopWhenPresent() {
        let facts = N.facts(for: brief(symbol: "STOP"))
        // price 100, riskDistance 10 ⇒ stop 90.00 (SageFix long-side math)
        #expect(facts.contains("Stop: 90.00"))
    }

    @Test("facts reads 'Stop: none' when the idea carries no defined risk")
    func factsContainsNoneStopWhenAbsent() {
        let facts = N.facts(for: brief(symbol: "NOSTOP", rr: nil))
        #expect(facts.contains("Stop: none"))
        #expect(facts.contains("Target: none"))
    }

    // MARK: prompt(facts:)

    @Test("prompt contains every fact line plus the closing instruction")
    func promptContainsEveryFact() {
        let facts = N.facts(for: brief(symbol: "PROMPT"))
        let prompt = N.prompt(facts: facts)
        for fact in facts { #expect(prompt.contains(fact)) }
        #expect(prompt.hasSuffix("Write the explanation."))
    }

    // MARK: numericTokens

    @Test("numericTokens extracts every maximal digit run, signs and percent stripped")
    func numericTokensExtraction() {
        let tokens = N.numericTokens("Stop 178.50 (\u{2212}5.1% from 188.20), 3 days")
        #expect(tokens == ["178.50", "5.1", "188.20", "3"])
    }

    // MARK: introducesForeignNumbers

    @Test("introducesForeignNumbers is true for a number absent from the facts, false when reused")
    func introducesForeignNumbersDetectsForeign() {
        let facts = ["Watch: report lands in 3 days"]
        #expect(N.introducesForeignNumbers("about 5 days out", facts: facts))
        #expect(!N.introducesForeignNumbers("roughly 3 days from now", facts: facts))
    }

    // MARK: label

    @Test("label names the source and the non-advice caveat")
    func labelNamesSourceAndCaveat() {
        #expect(N.label.contains("on-device"))
        #expect(N.label.contains("not advice"))
    }

    // MARK: label(for:model:)

    @Test("label(for: .localServer, model:) names the server model and the non-advice caveat")
    func labelForLocalServerNamesModel() {
        let text = N.label(for: .localServer, model: "qwen3.8")
        #expect(text.contains("qwen3.8"))
        #expect(text.contains("not advice"))
    }

    @Test("label(for: .onDevice, model:) is byte-identical to the plain `label` constant")
    func labelForOnDeviceMatchesPlainLabel() {
        #expect(N.label(for: .onDevice, model: nil) == N.label)
    }

    // MARK: instructions

    @Test("instructions cap the word count at 80 and require the ticker-only rule")
    func instructionsCapWordsAndRequireTickerOnly() {
        #expect(N.instructions.contains("80 words"))
        #expect(N.instructions.contains("ticker symbol"))
    }

    // MARK: selectedBackend

    @Test("selectedBackend defaults to .auto for nil or an unrecognized raw value")
    func selectedBackendDefaultsToAuto() {
        #expect(N.selectedBackend(nil) == .auto)
        #expect(N.selectedBackend("bogus") == .auto)
        #expect(N.selectedBackend("off") == .off)
    }

    // MARK: explainAvailable (n=8 rows)

    @Test("explainAvailable truth table")
    func explainAvailableTruthTable() {
        typealias Row = (backend: StockSageLocalModelServer.Backend, onDeviceAvailable: Bool,
                         reachable: Bool, hasModel: Bool, expected: Bool)
        let rows: [Row] = [
            (.off, true, true, true, false),
            (.off, false, false, false, false),
            (.onDeviceOnly, true, false, false, true),
            (.onDeviceOnly, false, true, true, false),
            (.localServerOnly, false, true, true, true),
            (.localServerOnly, true, true, false, false),
            (.auto, false, false, false, false),
            (.auto, false, true, true, true),
        ]
        #expect(rows.count == 8)   // n=8 rows
        for (i, row) in rows.enumerated() {
            let onDevice: N.Availability = row.onDeviceAvailable ? .available : .unavailable("nope")
            let probe = StockSageLocalModelServer.Probe(reachable: row.reachable, isOllama: true, models: [],
                                                        hasModel: row.hasModel, detail: "x")
            let got = N.explainAvailable(backend: row.backend, onDevice: onDevice, probe: probe)
            #expect(got == row.expected, "row \(i): \(row.backend) onDevice=\(row.onDeviceAvailable) reachable=\(row.reachable) hasModel=\(row.hasModel)")
        }
    }

    // MARK: Result equality

    @Test("Result compares by case and payload")
    func resultEqualityByValue() {
        #expect(N.Result.text("a", .onDevice) == .text("a", .onDevice))
        #expect(N.Result.text("a", .onDevice) != .text("b", .onDevice))
        #expect(N.Result.text("a", .onDevice) != .text("a", .localServer))
        #expect(N.Result.withheld("x") == .withheld("x"))
        #expect(N.Result.unavailable("y") == .unavailable("y"))
        #expect(N.Result.text("a", .onDevice) != .withheld("a"))
    }
}
