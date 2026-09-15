import Foundation

/// A local rules summary of recorded daily moves. No model or network request.
enum StockSageBriefingService {
    /// Deterministic, hallucination-free summary built purely from the data +
    /// signal engine. Also the offline fallback. Pure (sync) so it's unit-testable.
    static func deterministicSummary(for symbols: [StockSageSymbol], compact: Bool = false) -> String {
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

        func names(_ rows: [(String, StockSageSignal, Bool)]) -> String {
            let shown = compact ? Array(rows.prefix(3)) : rows
            let text = shown.map(label).joined(separator: ", ")
            return text + (shown.count < rows.count ? " · \(rows.count - shown.count) more" : "")
        }
        var out = "Rules-based · \(symbols.count) symbols\n"
        let missing = symbols.count - signals.count
        if missing > 0 { out += "\n\(missing) of \(symbols.count) symbols lack a verified previous-close basis; excluded from this assessment." }
        guard !signals.isEmpty else { return out + "\nNo evaluable daily moves — market tone is unassessed." }
        out += "\nTone of evaluated symbols: \(gainers.count > losers.count ? "Constructive" : losers.count > gainers.count ? "Defensive" : "Neutral")"
        if !gainers.isEmpty {
            out += "\n\nStrength (\(gainers.count)): " + names(gainers)
        }
        if !losers.isEmpty {
            out += "\n\nWeakness (\(losers.count)): " + names(losers)
        }
        if gainers.isEmpty && losers.isEmpty {
            out += "\nNo directional rules signal among the \(signals.count) evaluated symbols."
        }
        return out
    }
}
