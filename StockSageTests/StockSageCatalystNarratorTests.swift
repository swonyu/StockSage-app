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

    // MARK: label(for:)

    @Test("label(for: .localServer(model:)) names the server model and the non-advice caveat")
    func labelForLocalServerNamesModel() {
        let text = N.label(for: .localServer(model: "qwen3.8"))
        #expect(text.contains("qwen3.8"))
        #expect(text.contains("not advice"))
    }

    @Test("label(for: .onDevice) is byte-identical to the plain `label` constant")
    func labelForOnDeviceMatchesPlainLabel() {
        #expect(N.label(for: .onDevice) == N.label)
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

    // MARK: explainAvailable (n=10 rows)

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
            // Review major (fix pass 2026-09-06): the two rows above both have
            // onDeviceAvailable=false, so they pin only the `serverReady` half of `.auto`'s
            // `serverReady || onDeviceReady` — dropping the on-device fallback entirely
            // (`serverReady` alone) would still pass every row above. These two pin the OR:
            // the on-device fallback firing when the server is unreachable, and both being
            // available at once.
            (.auto, true, false, false, true),
            (.auto, true, true, true, true),
        ]
        #expect(rows.count == 10)   // n=10 rows
        for (i, row) in rows.enumerated() {
            let onDevice: N.Availability = row.onDeviceAvailable ? .available : .unavailable("nope")
            let probe = StockSageLocalModelServer.Probe(reachable: row.reachable, isOllama: true, models: [],
                                                        hasModel: row.hasModel, detail: "x")
            let got = N.explainAvailable(backend: row.backend, onDevice: onDevice, probe: probe)
            #expect(got == row.expected, "row \(i): \(row.backend) onDevice=\(row.onDeviceAvailable) reachable=\(row.reachable) hasModel=\(row.hasModel)")
        }
    }

    // MARK: facts(for:sources:) — the number-fence extension (W4)

    /// Hand-derived: a source dated 2026-09-01 (UTC) named "EODHD news" citing a title with a
    /// number in it. `facts(for:sources:)` must append EXACTLY one numbered line in the pinned
    /// "[n] YYYY-MM-DD <source>: <title> — <snippet> (<link>)" format, and that line's own numeric
    /// tokens ("1", "2026", "09", "01" from the date plus any in the title) become part of the
    /// fence — so a paragraph that reuses ONLY those numbers passes, and one that adds a number
    /// found nowhere in the facts is still caught.
    private func oneSource(date: Date = Date(timeIntervalSince1970: 1_788_220_800),   // 2026-09-01T00:00:00Z
                           title: String = "Guidance raised") -> N.CitedSource {
        N.CitedSource(date: date, source: "EODHD news", title: title,
                      snippet: "Company raised guidance.", link: URL(string: "https://eodhd.com/x"))
    }

    @Test("facts(for:sources:) appends one pinned numbered line per source, in order")
    func factsAppendsNumberedSourceLines() {
        let facts = N.facts(for: brief(symbol: "SRC"), sources: [oneSource(), oneSource(title: "Second item")])
        #expect(facts.contains("[1] 2026-09-01 EODHD news: Guidance raised — Company raised guidance. (https://eodhd.com/x)"))
        #expect(facts.contains("[2] 2026-09-01 EODHD news: Second item — Company raised guidance. (https://eodhd.com/x)"))
    }

    @Test("facts(for:sources:) with no sources is byte-identical to facts(for:)")
    func factsWithEmptySourcesUnchanged() {
        #expect(N.facts(for: brief(symbol: "NOSRC")) == N.facts(for: brief(symbol: "NOSRC"), sources: []))
    }

    @Test("a number reused from a numbered source line passes the fence; a foreign number is withheld")
    func fenceExtensionAcceptsSourceNumbersRejectsForeign() {
        let facts = N.facts(for: brief(symbol: "FENCE"), sources: [oneSource()])
        // "2026" and "09" and "01" all appear in the source's own date line "[1] 2026-09-01 ...".
        #expect(!N.introducesForeignNumbers("As of 2026 the report cites source [1].", facts: facts))
        // "2027" appears nowhere in the brief's facts OR the source line — must be caught.
        #expect(N.introducesForeignNumbers("The company will report again in 2027.", facts: facts))
    }

    @Test("sourceLine renders 'no link' when a source carries none")
    func sourceLineNoLink() {
        let s = N.CitedSource(date: Date(timeIntervalSince1970: 0), source: "SEC Form 4",
                              title: "Doe John bought 100 shares", snippet: "", link: nil)
        let line = N.sourceLine(number: 3, source: s)
        #expect(line == "[3] 1970-01-01 SEC Form 4: Doe John bought 100 shares (no link)")
    }

    // MARK: citationsValid — the citation parser (W4)

    @Test("a citation in range is valid")
    func citationsValidInRange() {
        #expect(N.citationsValid("See [1] and [2] for detail.", sourceCount: 2))
    }

    @Test("a citation exactly at n == sourceCount is valid; n == sourceCount + 1 is not (straddle)")
    func citationsValidBoundaryStraddle() {
        #expect(N.citationsValid("Per [3].", sourceCount: 3))          // n == count: valid
        #expect(!N.citationsValid("Per [4].", sourceCount: 3))         // n == count + 1: invalid
    }

    @Test("a malformed bracket like [1a] is ignored, not treated as a citation at all")
    func citationsValidIgnoresMalformed() {
        // No well-formed "[n]" in the text at all, so nothing to invalidate — vacuously true even
        // though "1" alone would be out of a zero-source range.
        #expect(N.citationsValid("Filed under [1a] for reference.", sourceCount: 0))
        #expect(N.citationsValid("See [1a].", sourceCount: 1))
    }

    @Test("zero sources means no citation can ever be valid")
    func citationsValidZeroSources() {
        #expect(N.citationsValid("No citation here.", sourceCount: 0))
        #expect(!N.citationsValid("See [1].", sourceCount: 0))
    }

    // MARK: label(for:sourceCount:)

    @Test("evidence labels retain the generating backend, model, and caveats")
    func labelForSourceCountPositive() {
        let sources: [N.Source] = [.onDevice, .localServer(model: "qwen3.8"), .localServer(model: "salehman-qwen38-27b-4bit")]
        for source in sources {
            for count in [1, 3] {
                let text = N.label(for: source, sourceCount: count)
                #expect(text.hasPrefix(N.label(for: source)))
                #expect(text.hasSuffix("Evidence: \(count) \(count == 1 ? "source" : "sources") (listed)."))
            }
        }
    }

    @Test("nonpositive source counts leave the backend label unchanged")
    func labelForSourceCountZeroFallsBack() {
        for count in [0, -1] {
            #expect(N.label(for: .onDevice, sourceCount: count) == N.label(for: .onDevice))
            #expect(N.label(for: .localServer(model: "qwen3.8"), sourceCount: count) == N.label(for: .localServer(model: "qwen3.8")))
        }
    }

    // MARK: instructions gain the citation rule

    @Test("instructions now tell the model how to cite a numbered source")
    func instructionsGainCitationRule() {
        #expect(N.instructions.contains("[n]"))
        #expect(N.instructions.contains("80 words"))          // unchanged prior requirement
        #expect(N.instructions.contains("ticker symbol"))     // unchanged prior requirement
    }

    // MARK: Result equality

    @Test("Result compares by case and payload")
    func resultEqualityByValue() {
        #expect(N.Result.text("a", .onDevice) == .text("a", .onDevice))
        #expect(N.Result.text("a", .onDevice) != .text("b", .onDevice))
        #expect(N.Result.text("a", .onDevice) != .text("a", .localServer(model: "qwen3.8")))
        #expect(N.Result.text("a", .localServer(model: "qwen3.8")) == .text("a", .localServer(model: "qwen3.8")))
        #expect(N.Result.text("a", .localServer(model: "qwen3.8")) != .text("a", .localServer(model: "llama3")))
        #expect(N.Result.withheld("x") == .withheld("x"))
        #expect(N.Result.unavailable("y") == .unavailable("y"))
        #expect(N.Result.text("a", .onDevice) != .withheld("a"))
    }
}
