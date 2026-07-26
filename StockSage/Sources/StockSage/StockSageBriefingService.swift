import Foundation

// MARK: - StockSageBriefingService
//
// Reworked from the package's `AppleIntelligenceService`. The package claimed
// "On-device LLM summary generation (the local model
// ready)" but actually just concatenated strings. Here the summary is generated
// for real by the app's `LocalLLM` (whatever brain the
// user pinned), with the deterministic gainers/losers concat kept ONLY as the
// offline fallback when no brain is reachable.
enum StockSageBriefingService {

    /// Produce a market briefing over the given symbols.
    ///
    /// 1. Compute deterministic facts (signals, gainers, losers) locally — these
    ///    are always correct and never hallucinated.
    /// 2. Hand those facts to **`LocalLLM.generateOnDevice`** — local tier only
    ///    (Ollama) — to write a natural, concise briefing.
    ///    The tool description + header label this "on-device / computed locally,"
    ///    so we must NEVER route through `LocalLLM.generate` (which would go to
    ///    the user's pinned cloud brain — a privacy/honesty violation).
    /// 3. If no on-device model is available, return the deterministic summary
    ///    verbatim. The deterministic path is itself honest, correct, and cheap.
    static func generateBriefing(for symbols: [StockSageSymbol]) async -> String {
        // STANDALONE DEVIATION (extraction @ fc8f383): the parent app optionally polished this
        // text through its on-device LLM (`LocalLLM.generateOnDevice`) with the deterministic
        // summary as the documented fallback. The standalone app has no LLM stack, so the
        // fallback path IS the briefing — same honest, hallucination-free text the parent
        // shows whenever no on-device model is available. No behavior invented.
        deterministicSummary(for: symbols)
    }

    /// Deterministic, hallucination-free summary built purely from the data +
    /// signal engine. Also the offline fallback. Pure (sync) so it's unit-testable.
    static func deterministicSummary(for symbols: [StockSageSymbol]) -> String {
        guard !symbols.isEmpty else {
            return "No symbols are being tracked yet."
        }

        // Staleness carried per symbol (review 2026-07-26): the row-level UI already badges a
        // stale quote "⚠︎ stale", but the briefing folded the same symbol into Strength/Weakness
        // unannotated — a recommendation off a days-old quote must say so where it's read.
        let signals = symbols.compactMap { sym -> (String, StockSageSignal, Bool)? in
            guard let s = StockSageSignalEngine.generateSignal(for: sym) else { return nil }
            return (sym.symbol, s, sym.isStale())
        }
        let gainers = signals.filter { $0.1.recommendation == .strongBuy || $0.1.recommendation == .buy }
        let losers  = signals.filter { $0.1.recommendation == .strongSell || $0.1.recommendation == .sell }
        func label(_ row: (String, StockSageSignal, Bool)) -> String {
            "\(row.0) (\(row.1.recommendation.rawValue)\(row.2 ? ", stale quote" : ""))"
        }

        // "Rules-based", not "On-device" (review 2026-07-26): this is a deterministic string
        // join off the signal engine — "on-device briefing" implied model inference that never
        // happens in this target (honesty floor: provenance must not overstate).
        var out = "📊 Market briefing — rules-based (\(symbols.count) symbols)\n"
        if !gainers.isEmpty {
            out += "\nStrength: " + gainers.map(label).joined(separator: ", ")
        }
        if !losers.isEmpty {
            out += "\nWeakness: " + losers.map(label).joined(separator: ", ")
        }
        if gainers.isEmpty && losers.isEmpty {
            out += "\nAll tracked symbols are consolidating — no strong signals."
        }
        out += "\n\nTone: \(gainers.count > losers.count ? "Constructive" : losers.count > gainers.count ? "Defensive" : "Neutral")"
        return out
    }
}
