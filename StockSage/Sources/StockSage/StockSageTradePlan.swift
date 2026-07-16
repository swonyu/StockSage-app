import Foundation

// MARK: - Trade-plan export
//
// Writing the plan down BEFORE the trade is the single cheapest discipline there
// is — it turns a vibe into entry / stop / target / size you can be held to. This
// renders an idea into a clean, copyable text plan (broker note, journal, message).
// Pure + tested. It restates the app's numbers and its caveat; it promises nothing.

enum StockSageTradePlan {
    // aa#4: ladder and chandelierLevel added so Copy Plan exports the scale-out rungs
    // and chandelier exit level that the sheet displays — the pasted broker note now
    // matches what the trader read on screen. Both parameters are optional; nil callers
    // (e.g. card-level copyIdeaPlan) skip those lines. Wave 9 also switched all price
    // lines to adaptivePrice and relabeled the Action line, so the nil path is NOT
    // byte-identical to pre-wave-8 output for sub-$1 prices / the conviction wording.

    // ALERT-FMT-1: thin alias onto the single shared formatter (StockSageCurrency.adaptivePrice,
    // pure, tested there) — keeps the pasted broker note consistent with what the sheet shows.
    // nonisolated so it can be called from the nonisolated text() function.
    nonisolated private static func adaptivePrice(_ v: Double) -> String { StockSageCurrency.adaptivePrice(v) }

    nonisolated static func text(symbol: String, market: String, price: Double,
                                 advice: TradeAdvice, rewardRisk: RewardRisk?,
                                 size: PositionSize?, flags: [RiskFlag],
                                 ladder: PartialLadder? = nil,
                                 chandelierLevel: Double? = nil) -> String {
        var lines: [String] = []
        lines.append("TRADE PLAN — \(symbol) (\(market))")
        // Wave-8 relabeled: "signal strength X/100" replaces "conviction X%".
        // The old label said "conviction" which contradicts the sheet's honesty relabel
        // (conviction != win probability); the new label matches the sheet and adds the
        // explicit disclaimer so the pasted plan is self-contained.
        lines.append("Action: \(advice.action.rawValue) · signal strength \(Int(advice.conviction * 100))/100 · \(advice.regime.rawValue) — rules-based score, not a win probability")
        lines.append("Entry: \(adaptivePrice(price))")
        if let s = advice.stopPrice { lines.append("Stop: \(adaptivePrice(s))") }
        if let t = advice.targetPrice { lines.append("Target: \(adaptivePrice(t))") }
        if let rr = rewardRisk {
            // "gross" label (wave-11/F28): this R:R is before round-trip costs; the net figure
            // is appended separately by the MarketsView call site — label both so they can never
            // appear to say the same thing with different values (matches RewardRisk.note wording).
            lines.append(String(format: "R:R: %.1f gross (%@) — needs a >%.1f%% win-rate to break even",
                                rr.ratio, rr.quality.rawValue, rr.breakevenWinRate * 100))
        }
        // aa#4: scale-out ladder rungs — prices use adaptivePrice so sub-dollar names
        // never show "0.00" in the pasted plan, matching what the sheet displays.
        if let ld = ladder, !ld.rungs.isEmpty {
            let rungText = ld.rungs.map { "\(adaptivePrice($0.price)) (+\(String(format: "%.1f", $0.rMultiple))R)" }.joined(separator: " / ")
            lines.append(String(format: "Scale-out (⅓ each): %@ — blended exit +%.1fR. Assumes each level fills.", rungText, ld.blendedExitR))
        }
        // aa#4: chandelier exit level — adaptivePrice ensures sub-dollar levels show
        // real magnitude (e.g. "0.006200" not "0.00") matching the sheet's display.
        if let cl = chandelierLevel {
            lines.append("Chandelier exit: ~\(adaptivePrice(cl)) — a STARTING trailing level; move it up as new highs print, never down. An exit rule, not a target.")
        }
        if let ps = size {
            // Audit 2026-07-12 (export-parity): dollarsAtRisk is in the SYMBOL's own currency (SAR for
            // 2222.SR, pence for .L), so a hardcoded "$" mislabeled the pasted-into-broker figure
            // ~3.75×/100× AND diverged from the now-currency-correct on-screen sheet. approxAmount
            // renders the true currency (+ the pence ÷100), matching every other "at risk" surface.
            let atRisk = StockSageCurrency.approxAmount(ps.dollarsAtRisk, symbol: symbol)
            lines.append(String(format: "Size: %d shares · %@ at risk · %.0f%% of account",
                                ps.shares, atRisk, ps.pctOfAccount))
            // Mirror the on-screen leverage warning so the pasted plan can't understate risk.
            // NOTE: pctOfAccount compares native notional to the account currency — for a non-USD
            // symbol on a USD account this can over-warn (safe direction: it never HIDES leverage).
            // The MarketsView export call site is where the FX-correct pct lives; here we keep the
            // engine pure and label the amount in its own currency.
            if ps.pctOfAccount > 100 {
                lines.append(String(format: "⚠ Notional exceeds the account — needs margin/leverage; a gap THROUGH the stop can lose well more than the %@ stated risk.",
                                    atRisk))
            }
        }
        if !flags.isEmpty {
            lines.append("Risk flags: " + flags.map(\.label).joined(separator: ", "))
        }
        if !advice.rationale.isEmpty {
            lines.append("")
            lines.append("Why: " + advice.rationale.joined(separator: "; "))
        }
        lines.append("")
        lines.append(advice.caveat)
        return lines.joined(separator: "\n")
    }
}
