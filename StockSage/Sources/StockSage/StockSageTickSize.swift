import Foundation

// MARK: - Tadawul tick sizes (first-real-trade review, 2026-07-16)
//
// The engine's ATR-derived stop/target prices are arbitrary-decimal; Tadawul rejects orders
// that aren't on the tick grid, so the app's copy-plan could hand the owner an UNPLACEABLE
// price for a `.SR` order (e.g. "Stop: 28.63" in the 0.02-tick band). This helper computes the
// placeable equivalent and a DISPLAY-ONLY advisory line — the engine's stopPrice/targetPrice
// (which feed EV/R:R) are never changed; the note is the honest bridge to the broker ticket.
//
// TICK TABLE — Saudi Exchange amended regime, effective 2025-06-29 (sourced 2026-07-16 from
// two agreeing secondary sources of the exchange announcement: Argaam #1823880 + Sahm Capital
// support), Main Market + Nomu, excluding debt instruments:
//   < 25.00 → 0.01 · 25.00–49.98 → 0.02 · 50.00–99.95 → 0.05 · 100.00–249.90 → 0.10 ·
//   250.00–499.80 → 0.20 · ≥ 500.00 → 0.50
// US/NASDAQ needs no equivalent (US equities tick at $0.01 above $1 — any 2-dp price places).

enum StockSageTickSize {

    /// The Tadawul tick for a given SAR price (the 2025-06-29 band table).
    nonisolated static func tadawulTick(forPrice p: Double) -> Double {
        switch p {
        case ..<25:    return 0.01
        case ..<50:    return 0.02
        case ..<100:   return 0.05
        case ..<250:   return 0.10
        case ..<500:   return 0.20
        default:       return 0.50
        }
    }

    /// Nearest tick-grid price for a Tadawul order at this level.
    nonisolated static func tadawulRounded(_ p: Double) -> Double {
        let tick = tadawulTick(forPrice: p)
        return (p / tick).rounded() * tick
    }

    /// True when the price already sits on the tick grid (within float noise).
    nonisolated static func tadawulAligned(_ p: Double) -> Bool {
        abs(p - tadawulRounded(p)) < 1e-9
    }

    /// DISPLAY-ONLY placeability advisory for a `.SR` order plan. nil for non-Tadawul symbols,
    /// nil when every leg's DISPLAYED price already sits on the grid. Legs are evaluated at
    /// 2-dp DISPLAY precision — the price the owner actually reads and types — so float noise
    /// beyond the ticket's precision never fires the note (in the 0.01 band every 2-dp price is
    /// placeable by construction; the raw-Double check used to fire "23.46 → place as 23.46"
    /// there — 2026-07-16 review score-100 fix). Each leg is rounded with ITS OWN band tick and
    /// the clause names that tick (legs can straddle band boundaries, so the former single
    /// headline tick was wrong for one of them). Rounds to the NEAREST tick (≤ half a tick of
    /// drift, ≤ ~7bps at typical .SR prices — disclosed, never applied to the engine's numbers).
    nonisolated static func placeabilityNote(symbol: String, entry: Double?, stop: Double?,
                                             target: Double?) -> String? {
        guard symbol.uppercased().hasSuffix(".SR") else { return nil }
        var parts: [String] = []
        for (label, value) in [("entry", entry), ("stop", stop), ("target", target)] {
            guard let v = value, v > 0, v.isFinite else { continue }
            let shown = (v * 100).rounded() / 100          // the 2-dp price the ticket displays
            guard !tadawulAligned(shown) else { continue }
            parts.append(String(format: "%@ %.2f → place as %.2f (%.2f tick)",
                                label, shown, tadawulRounded(shown), tadawulTick(forPrice: shown)))
        }
        guard !parts.isEmpty else { return nil }
        return "Tadawul tick grid — engine levels off the grid: " + parts.joined(separator: "; ")
             + " (nearest tick; ≤½-tick drift, engine math unchanged)."
    }

    /// DISPLAY-ONLY placeability advisory for a SINGLE typed price (the close-form exit) on a
    /// `.SR` order. nil for non-Tadawul symbols and nil when the DISPLAYED (2-dp) price already
    /// sits on the grid — same display-precision rule as `placeabilityNote` (the owner types a
    /// 2-dp price, so float noise beyond that never fires; in the 0.01 band every 2-dp price is
    /// placeable). Cycle-1/24h-run (2026-07-16): the entry side already warned on off-grid
    /// stop/target; the close form's exit price got no such guard — a Tadawul broker rejects an
    /// off-tick exit just as it does an off-tick entry.
    nonisolated static func exitPlaceabilityNote(symbol: String, exit: Double) -> String? {
        guard symbol.uppercased().hasSuffix(".SR"), exit > 0, exit.isFinite else { return nil }
        let shown = (exit * 100).rounded() / 100
        guard !tadawulAligned(shown) else { return nil }
        return String(format: "Tadawul tick grid — exit %.2f is off the grid: place as %.2f (%.2f tick).",
                      shown, tadawulRounded(shown), tadawulTick(forPrice: shown))
    }
}
