import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - StockSageCatalystNarrator
//
// Owner request (2026-09-06): the catalyst calendar/cards' "why" is ALWAYS the engine's own
// rationale (StockSageCatalystWatch.Item.why/watch — build step C1) — this file is the OPTIONAL
// layer on top: a model-written paragraph, on tap, explaining the SAME facts in plain English.
// StockSage ships with no cloud LLM and no API keys, so "the model" is Apple's on-device
// FoundationModels framework (macOS 26 / iOS 26; deploy target is 26.5, so availability is
// unconditional — no `if #available` needed — but the import is still guarded so the module
// still compiles on an SDK that lacks the framework).
//
// The hard constraint (honesty floor: model text "can misstate") is that the model must never
// be allowed to LOOK authoritative about a number it made up. `facts(for:)` is the ONLY thing
// the model is shown; `introducesForeignNumbers` then checks its own output against those same
// facts and WITHHOLDS the paragraph rather than ship an invented figure. Everything here is a
// paraphrase layer — the engine's `why`/`watch` strings remain the primary, always-present
// explanation; this is additive, never load-bearing.
enum StockSageCatalystNarrator {

    // MARK: Availability

    enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    /// Maps `SystemLanguageModel.default.availability` to a human reason a viewer can read.
    /// MainActor (this module's default isolation) is fine — this is a cheap property read,
    /// not I/O; `explain(_:)` re-checks it itself so a caller never has to sequence the two.
    static var availability: Availability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This device cannot run the on-device model.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings to enable on-device explanations.")
            case .modelNotReady:
                return .unavailable("The on-device model is still downloading — try again later.")
            @unknown default:
                return .unavailable("This device cannot run the on-device model.")
            }
        }
        #else
        return .unavailable("On-device model not available in this build.")
        #endif
    }

    // MARK: Facts — the ONLY thing the model sees

    /// Pure, deterministic restatement of one brief as plain-text facts. Same formatting helpers
    /// as the engine (`StockSageCurrency.adaptivePrice`, `%.2f` conviction) so a number here reads
    /// byte-identical to what the card/sheet already shows — the model is never given a number
    /// the viewer can't cross-check on screen.
    nonisolated static func facts(for brief: StockSageCatalystWatch.Brief) -> [String] {
        let idea = brief.idea
        let advice = idea.advice
        var lines: [String] = []
        lines.append("Symbol: \(idea.symbol)")
        lines.append("Action: \(advice.action.rawValue) (rules-based conviction "
            + "\(String(format: "%.2f", advice.conviction)) — not a probability)")
        lines.append("Price: \(StockSageCurrency.adaptivePrice(idea.price))")
        if let stop = advice.stopPrice {
            lines.append("Stop: \(StockSageCurrency.adaptivePrice(stop))")
        } else {
            lines.append("Stop: none")
        }
        if let target = advice.targetPrice {
            lines.append("Target: \(StockSageCurrency.adaptivePrice(target))")
        } else {
            lines.append("Target: none")
        }
        lines.append("Catalyst: \(brief.primary.headline)")
        for bullet in brief.primary.why {
            lines.append("Why: \(bullet)")
        }
        lines.append("Watch: \(brief.primary.watch)")
        for item in brief.secondary {
            lines.append("Also: \(item.headline)")
        }
        if let regimeItem = brief.all.first(where: { $0.kind == .regime }) {
            lines.append("Regime: \(regimeItem.headline)")
        }
        return lines
    }

    /// System instructions for the session — fixed, never per-idea (the facts carry everything
    /// idea-specific), so this string is also what a test pins.
    nonisolated static let instructions =
        "You receive verified facts about one stock idea. Write at most 90 words of plain "
        + "English explaining why the catalyst matters for THIS idea and what to watch. Use "
        + "ONLY the facts. Do not add or change any number, date, or name. Do not predict "
        + "direction. Do not recommend buying or selling. No headings, no bullets."

    /// The facts, one per line, plus the closing instruction — this (not `instructions`) is the
    /// per-call prompt.
    nonisolated static func prompt(facts: [String]) -> String {
        facts.joined(separator: "\n") + "\nWrite the explanation."
    }

    // MARK: Number-fence — the facts guard

    /// Every maximal run of ASCII digits with an optional decimal point (e.g. "184.20", "3",
    /// "0.62"). Signs and "%" are never part of a digit run so they fall away on their own —
    /// nothing to strip. Deterministic: same string, same set, every time.
    nonisolated static func numericTokens(_ s: String) -> Set<String> {
        var tokens: Set<String> = []
        var current = ""
        func flush() {
            while current.hasSuffix(".") { current.removeLast() }   // trailing "." has no digits after
            if !current.isEmpty { tokens.insert(current) }
            current = ""
        }
        for ch in s {
            if ch.isASCII, ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// True when `text` contains a numeric token that appears nowhere in `facts` — the model
    /// invented (or mis-copied) a number. The check that lets `explain(_:)` withhold rather than
    /// ship a fabricated figure.
    nonisolated static func introducesForeignNumbers(_ text: String, facts: [String]) -> Bool {
        let factTokens = facts.reduce(into: Set<String>()) { $0.formUnion(numericTokens($1)) }
        return !numericTokens(text).isSubset(of: factTokens)
    }

    // MARK: Result + explain

    enum Result: Equatable, Sendable {
        case text(String)
        case withheld(String)
        case unavailable(String)
    }

    /// Always present on a rendered paragraph — names what it is (a paraphrase, not the engine's
    /// own rationale) and its limits, per the house honesty floor.
    nonisolated static let label =
        "Model-written on-device from the facts above — a paraphrase, not analysis; it can "
        + "misstate; unvalidated; not advice."

    /// Availability check → local session → respond → trim → number-fence. Never throws, never
    /// fabricates: an unavailable model or a request error both come back as `.unavailable`
    /// (never silently as `.text`), and a response that names an off-facts number comes back as
    /// `.withheld` rather than shown. The session is local to this call — no shared mutable state.
    static func explain(_ brief: StockSageCatalystWatch.Brief) async -> Result {
        #if canImport(FoundationModels)
        guard case .available = availability else {
            if case .unavailable(let reason) = availability { return .unavailable(reason) }
            return .unavailable("On-device model not available in this build.")
        }
        let brieFacts = facts(for: brief)
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt(facts: brieFacts),
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 200))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if introducesForeignNumbers(text, facts: brieFacts) {
                return .withheld("Withheld: the model introduced a number that is not in the facts.")
            }
            return .text(text)
        } catch {
            return .unavailable(String(describing: error))
        }
        #else
        return .unavailable("On-device model not available in this build.")
        #endif
    }
}
