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
//
// Owner request (2026-09-06, "okay"): this is now a ROUTER over TWO backends — the on-device
// FoundationModels path above, and an optional LOCAL SERVER (Ollama / LM Studio, via
// `StockSageLocalModelServer`) for a viewer who wants a bigger model than what ships on-device.
// `Source` on `Result.text` says which one actually wrote a given paragraph, so the label under
// it is never ambiguous about where the text came from.
enum StockSageCatalystNarrator {

    // MARK: Source (which backend actually wrote a given paragraph)

    /// `.localServer` carries the model name CAPTURED AT GENERATION TIME (from `config.model`
    /// inside `explainViaServer`, fix pass 2026-09-06 review blocker) — never read back from the
    /// live `serverModel` settings binding, which a viewer can edit at any time after a paragraph
    /// was already generated. Carrying the name on the value itself (rather than a second,
    /// separately-passed argument) makes it structurally impossible for the label to drift from
    /// the model that actually wrote the text.
    enum Source: Sendable, Equatable {
        case onDevice
        case localServer(model: String)
    }

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
    /// idea-specific), so this string is also what a test pins. Tightened 90→80 words and added
    /// the ticker-only sentence (fix pass 2026-09-06): the owner's smoke test against qwen3.8
    /// produced "Apple" from a bare "AAPL" fact and ran 95–106 words despite the 90-word ask.
    nonisolated static let instructions =
        "You receive verified facts about one stock idea. Write at most 80 words of plain "
        + "English explaining why the catalyst matters for THIS idea and what to watch. Use "
        + "ONLY the facts. Do not add or change any number, date, or name. Refer to the "
        + "company only by its ticker symbol; never name the company. Do not predict "
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
        case text(String, Source)
        case withheld(String)
        case unavailable(String)
    }

    /// Always present on a rendered paragraph — names what it is (a paraphrase, not the engine's
    /// own rationale) and its limits, per the house honesty floor. This is the ON-DEVICE text;
    /// `label(for:)` is the source-aware version the view actually renders.
    nonisolated static let label =
        "Model-written on-device from the facts above — a paraphrase, not analysis; it can "
        + "misstate; unvalidated; not advice."

    /// Source-aware label — `.onDevice` reads exactly as `label` above (so that test keeps
    /// passing byte-for-byte); `.localServer` names the model CARRIED ON `source` itself (the one
    /// that actually wrote this text), never a live settings value, so editing the Model field
    /// after generating a paragraph can never retroactively relabel it.
    nonisolated static func label(for source: Source) -> String {
        switch source {
        case .onDevice:
            return label
        case .localServer(let model):
            return "Model-written by the local server model \(model) from the facts above — "
                + "a paraphrase, not analysis; it can misstate; unvalidated; not advice."
        }
    }

    // MARK: Backend selection (router)

    /// Maps the raw `UserDefaults` string (nil, or anything not a valid case) to `.auto` — the
    /// safe default that tries a server if one looks reachable and otherwise falls back
    /// on-device, so a fresh install or a typo'd defaults value never silently reads as `.off`.
    nonisolated static func selectedBackend(_ raw: String?) -> StockSageLocalModelServer.Backend {
        guard let raw, let backend = StockSageLocalModelServer.Backend(rawValue: raw) else { return .auto }
        return backend
    }

    /// Pure truth table the view's "Explain" button gates on — no I/O, no UserDefaults reads,
    /// just the three inputs a caller already has in hand.
    nonisolated static func explainAvailable(backend: StockSageLocalModelServer.Backend,
                                             onDevice: Availability,
                                             probe: StockSageLocalModelServer.Probe?) -> Bool {
        // `Availability`'s synthesized `Equatable` is MainActor-isolated under this module's
        // default isolation (mirrors the `SparkSeries.Extreme` note in StockSageCatalystWatch) —
        // pattern-match instead of `==` so this stays callable from a nonisolated context.
        let onDeviceReady: Bool
        if case .available = onDevice { onDeviceReady = true } else { onDeviceReady = false }
        let serverReady = probe?.reachable == true && probe?.hasModel == true
        switch backend {
        case .off:             return false
        case .onDeviceOnly:    return onDeviceReady
        case .localServerOnly: return serverReady
        case .auto:            return serverReady || onDeviceReady
        }
    }

    /// Reads the current local-server settings from `UserDefaults` (falling back to the shared
    /// defaults when unset) and probes it — `nil` when the settings don't even parse into a
    /// `Config`. What the view's "Test connection" button and its auto-probe `.task` both call.
    static func probeServer() async -> StockSageLocalModelServer.Probe? {
        let url = UserDefaults.standard.string(forKey: StockSageLocalModelServer.urlKey)
            ?? StockSageLocalModelServer.defaultURL
        let model = UserDefaults.standard.string(forKey: StockSageLocalModelServer.modelKey)
            ?? StockSageLocalModelServer.defaultModel
        guard let config = StockSageLocalModelServer.config(url: url, model: model) else { return nil }
        return await StockSageLocalModelServer.probe(config)
    }

    /// Availability check → local session → respond → trim → number-fence. Never throws, never
    /// fabricates: an unavailable model or a request error both come back as `.unavailable`
    /// (never silently as `.text`), and a response that names an off-facts number comes back as
    /// `.withheld` rather than shown. The session is local to this call — no shared mutable state.
    private static func explainOnDevice(_ brief: StockSageCatalystWatch.Brief) async -> Result {
        #if canImport(FoundationModels)
        guard case .available = availability else {
            if case .unavailable(let reason) = availability { return .unavailable(reason) }
            return .unavailable("On-device model not available in this build.")
        }
        let briefFacts = facts(for: brief)
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt(facts: briefFacts),
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 200))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if introducesForeignNumbers(text, facts: briefFacts) {
                return .withheld("Withheld: the model introduced a number that is not in the facts.")
            }
            return .text(text, .onDevice)
        } catch {
            #if DEBUG
            print("StockSageCatalystNarrator: on-device explain failed: \(error)")
            #endif
            return .unavailable(humanOnDeviceError(error))
        }
        #else
        return .unavailable("On-device model not available in this build.")
        #endif
    }

    /// Maps a raw FoundationModels error to a short human sentence (fix pass 2026-09-06, review
    /// minor (b)): the previous code surfaced `String(describing: error)` — a `GenerationError`
    /// dump — straight to the viewer. The raw description is still available, but only in the
    /// `#if DEBUG` print at the call site above, never in what a viewer reads.
    private nonisolated static func humanOnDeviceError(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation, .refusal:
                return "The on-device model declined this request (content guardrail)."
            default:
                return "The on-device model failed — try again."
            }
        }
        #endif
        return "The on-device model failed — try again."
    }

    /// The local-server counterpart of `explainOnDevice(_:)`: same facts/prompt/number-fence
    /// contract, over `StockSageLocalModelServer.complete(_:)` instead of a local session.
    private static func explainViaServer(_ brief: StockSageCatalystWatch.Brief,
                                         config: StockSageLocalModelServer.Config,
                                         isOllama: Bool) async -> Result {
        let briefFacts = facts(for: brief)
        let result = await StockSageLocalModelServer.complete(
            config, isOllama: isOllama, system: instructions, user: prompt(facts: briefFacts))
        switch result {
        case .success(let text):
            if introducesForeignNumbers(text, facts: briefFacts) {
                return .withheld("Withheld: the model introduced a number that is not in the facts.")
            }
            return .text(text, .localServer(model: config.model))
        case .failure(let error):
            return .unavailable(humanServerError(error))
        }
    }

    private nonisolated static func humanServerError(_ error: StockSageLocalModelServer.ServerError) -> String {
        switch error {
        case .invalidConfig:
            return "The local server URL or model is not set correctly in the Explanation model settings."
        case .unreachable(let detail):
            return "Could not reach the local server: \(detail)"
        case .modelMissing(let detail):
            return "The local server does not have the requested model: \(detail)"
        case .badResponse(let detail):
            return "The local server returned an unexpected response: \(detail)"
        }
    }

    /// Routes to a backend per the persisted setting (`UserDefaults.standard`, defaulting exactly
    /// like `selectedBackend`/the server defaults do when unset): `.off` explains nothing;
    /// `.onDeviceOnly`/`.localServerOnly` try exactly one backend; `.auto` probes the server
    /// first and falls back on-device, surfacing BOTH reasons only when neither is available.
    static func explain(_ brief: StockSageCatalystWatch.Brief) async -> Result {
        let backend = selectedBackend(UserDefaults.standard.string(forKey: StockSageLocalModelServer.backendKey))
        let urlSetting = UserDefaults.standard.string(forKey: StockSageLocalModelServer.urlKey)
            ?? StockSageLocalModelServer.defaultURL
        let modelSetting = UserDefaults.standard.string(forKey: StockSageLocalModelServer.modelKey)
            ?? StockSageLocalModelServer.defaultModel

        switch backend {
        case .off:
            return .unavailable("Explanations are turned off in the Explanation model settings.")

        case .onDeviceOnly:
            return await explainOnDevice(brief)

        case .localServerOnly:
            guard let config = StockSageLocalModelServer.config(url: urlSetting, model: modelSetting) else {
                return .unavailable(humanServerError(.invalidConfig))
            }
            let probe = await StockSageLocalModelServer.probe(config)
            guard probe.reachable, probe.hasModel else {
                return .unavailable("Local server unavailable: \(probe.detail)")
            }
            return await explainViaServer(brief, config: config, isOllama: probe.isOllama)

        case .auto:
            guard let config = StockSageLocalModelServer.config(url: urlSetting, model: modelSetting) else {
                return await explainOnDevice(brief)
            }
            let probe = await StockSageLocalModelServer.probe(config)
            if probe.reachable, probe.hasModel {
                return await explainViaServer(brief, config: config, isOllama: probe.isOllama)
            }
            let onDeviceResult = await explainOnDevice(brief)
            if case .unavailable(let onDeviceReason) = onDeviceResult {
                return .unavailable("Local server: \(probe.detail). On-device: \(onDeviceReason)")
            }
            return onDeviceResult
        }
    }
}
