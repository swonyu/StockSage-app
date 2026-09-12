import Foundation
import Combine

/// One holding: a symbol, how many shares, and the per-share cost basis.
struct PortfolioPosition: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let symbol: String
    var shares: Double
    var costBasis: Double   // per-share purchase price

    /// Cost of the whole position.
    var totalCost: Double { shares * costBasis }
}

/// Tiny persisted portfolio for the Markets tab. UserDefaults-backed (JSON) —
/// holdings are small + local, so no SwiftData/Core Data needed. Current value /
/// P&L is computed against `StockSageStore`'s latest prices by the view, so this
/// store stays a pure holdings record with no price coupling.
@MainActor
final class StockSagePortfolio: ObservableObject {
    static let shared = StockSagePortfolio()

    @Published private(set) var positions: [PortfolioPosition] = []
    @Published private(set) var lastError: String?
    @Published private(set) var hasLoadedRecords = false

    private static let key = "stocksage_portfolio_v1"
    private let defaults: UserDefaults
    private var deletions: StockSageRecordDeletions { .init(defaults: defaults, recordKey: Self.key) }

    private init() {
        self.defaults = .standard
        let ownership = Result { try StockSageRecordWriter.require(defaults) }
        load()
        if case .failure(let error) = ownership, lastError == nil { lastError = error.localizedDescription }
    }

    init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        let ownership = Result { try StockSageRecordWriter.require(defaults) }
        load()
        if case .failure(let error) = ownership, lastError == nil { lastError = error.localizedDescription }
    }

    /// Add a position. No-ops on a blank symbol or non-positive share count, so a
    /// fat-fingered form submit can't store garbage.
    @discardableResult func add(symbol: String, shares: Double, costBasis: Double) -> Bool {
        let s = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty, shares > 0, shares.isFinite, costBasis >= 0, costBasis.isFinite else {
            lastError = "Enter a symbol, positive finite shares and a nonnegative finite cost basis."
            return false
        }
        let before = positions
        positions.append(PortfolioPosition(symbol: s, shares: shares, costBasis: costBasis))
        guard save() else { positions = before; return false }
        return true
    }

    // Deletes merge foreign lots, excluding only the explicitly deleted IDs.
    func remove(_ id: UUID) {
        _ = save(removing: [id])
    }

    func clear() {
        _ = save(clearAll: true)
    }

    /// Current committed lots, excluding deletion markers, without changing the displayed book.
    func backupRecords() throws -> [PortfolioPosition] {
        do { return try deletions.read(PortfolioPosition.self).filter { !deletions.contains($0.id) } }
        catch { throw StockSageBackup.BackupError.sourceReadFailed("portfolio") }
    }

    /// Validated backup lots keep their IDs. Never call add() here: it creates a fresh ID,
    /// which would duplicate every holding on repeat restore and erase lot provenance.
    func prepareBackupImport(_ incoming: [PortfolioPosition]) throws -> (added: Int, apply: () throws -> Void) {
        try StockSageRecordWriter.require(defaults)
        let disk = try deletions.read(PortfolioPosition.self)
        var merged = positions.filter { !deletions.contains($0.id) }
        var ids = Set(merged.map(\.id))
        for lot in disk where !deletions.contains(lot.id) && ids.insert(lot.id).inserted { merged.append(lot) }
        let additions = incoming.filter { ids.insert($0.id).inserted }
        merged.append(contentsOf: additions)
        let data = try JSONEncoder().encode(merged)
        let records = merged
        return (additions.count, {
            try self.deletions.restore(Set(additions.map(\.id)))
            self.defaults.set(data, forKey: Self.key)
            self.positions = records
            self.hasLoadedRecords = true
            self.lastError = nil
        })
    }

    /// LOST-UPDATE FIX (2026-07-09, C8 — same cross-process clobber class as the paper/journal
    /// stores, fixed the same day from LIVE paper-store evidence). This is the owner's REAL
    /// position book. Lots are IMMUTABLE once added (add/remove/clear only — no in-place
    /// edits exist), so the ONLY cross-process hazard is a stale whole-array write DROPPING
    /// another instance's lot: reconcile by preserving foreign ids; per-id conflicts are
    /// impossible. Deletes retain markers; `qaSeed` never touches disk.
    private func save(removing: Set<UUID> = [], clearAll: Bool = false) -> Bool {
        do { try StockSageRecordWriter.require(defaults) }
        catch { lastError = error.localizedDescription; return false }
        guard let disk = try? deletions.read(PortfolioPosition.self) else {
            hasLoadedRecords = false
            lastError = "Couldn't read the saved portfolio; no records were changed."; return false
        }
        let removed = clearAll ? Set((positions + disk).map(\.id)) : removing
        var records = positions.filter { !removed.contains($0.id) && !deletions.contains($0.id) }
        var ids = Set(records.map(\.id))
        for lot in disk where !removed.contains(lot.id) && !deletions.contains(lot.id) && ids.insert(lot.id).inserted {
            records.append(lot)
        }
        guard let data = try? JSONEncoder().encode(records) else {
            lastError = "Couldn't encode the portfolio; the previous saved records were kept."; return false
        }
        do { try deletions.mark(removed) }
        catch { lastError = error.localizedDescription; return false }
        defaults.set(data, forKey: Self.key)
        positions = records
        hasLoadedRecords = true
        lastError = nil
        return true
    }

    private func load() {
        do {
            let decoded = try deletions.read(PortfolioPosition.self)
            positions = decoded.filter { !deletions.contains($0.id) }
            hasLoadedRecords = true
            lastError = nil
        } catch {
            hasLoadedRecords = false
            lastError = "Portfolio unavailable: couldn't read the saved holdings. Existing data was preserved."
        }
    }

    /// QA-only in-memory seed: assigns `positions` directly, bypassing `save()` so nothing
    /// touches UserDefaults. Multiple lots of the same symbol are legal (see Gotchas in the
    /// map entry) — this is a raw assign, not a merge; callers wanting the "own it" aggregate
    /// view use `StockSagePortfolio.holding(for:in:)` below on whatever `positions` holds.
    func qaSeed(_ seeded: [PortfolioPosition]) {
        positions = seeded
    }
}

/// One symbol's aggregated holding across every lot: total shares + weighted-average cost
/// basis. Multiple `PortfolioPosition` rows can share a symbol (multi-lot books — see
/// StockSagePortfolio's Gotchas); "own it" surfaces (ideas card/sheet) show ONE number per
/// symbol, so lots must be summed/weighted here rather than each caller re-deriving it.
struct AggregatedHolding: Equatable {
    let symbol: String
    let shares: Double
    /// Weighted-average cost basis across lots: Σ(shares·costBasis) / Σ(shares).
    let costBasis: Double

    /// Unrealized % vs `price`, signed raw math: (price/costBasis − 1) × 100, one decimal.
    /// nil when either side is non-positive (a nil/zero cost or price must not render a
    /// fabricated percent — honesty floor, same convention as the rest of StockSage's
    /// nil-on-insufficient-data functions).
    ///
    /// Normalizes IEEE -0.0 → 0: a price just under breakeven can round to -0.0, which prints
    /// as "-0.0" and, combined with callers' `pct >= 0 ? "+" : ""` prefix logic (-0.0 >= 0 is
    /// true), renders "+-0.0%". `r == 0` is true for both since -0.0 == 0 in Swift.
    func unrealizedPct(vs price: Double) -> Double? {
        guard costBasis > 0, price > 0 else { return nil }
        let r = ((price / costBasis - 1) * 100 * 10).rounded() / 10
        return r == 0 ? 0 : r
    }
}

extension StockSagePortfolio {
    /// Aggregates every lot matching `symbol` (case-insensitive — positions are stored
    /// uppercased by `add()`, but this defends a caller that isn't). Returns nil when the
    /// symbol isn't held or every matching lot has zero/invalid shares (avoids a
    /// divide-by-zero weighted average).
    nonisolated static func holding(for symbol: String, in positions: [PortfolioPosition]) -> AggregatedHolding? {
        let target = symbol.uppercased()
        let lots = positions.filter { $0.symbol.uppercased() == target && $0.shares > 0 }
        guard !lots.isEmpty else { return nil }
        let totalShares = lots.reduce(0) { $0 + $1.shares }
        guard totalShares > 0 else { return nil }
        let weightedCost = lots.reduce(0) { $0 + $1.shares * $1.costBasis } / totalShares
        return AggregatedHolding(symbol: target, shares: totalShares, costBasis: weightedCost)
    }

    /// Same result as `holding(for:in:)`, for every symbol in `positions`, computed in one O(P)
    /// pass instead of O(P) per symbol — for callers (the ideas board) that need this per-card
    /// across many symbols each render. `holding(for:in:)` stays the semantic source of truth;
    /// this is a batch-lookup convenience keyed the same way (uppercased symbol), proven identical
    /// by StockSagePortfolioTests.holdingBySymbolMatchesHoldingForEverySymbol.
    /// TODAY-PARITY: marked `nonisolated` — pure over `Sendable` value types, no actor-state
    /// access, exact same reasoning as the sibling `StockSageJournal.historyBySymbol` — so
    /// `StockSageTodayPlan.rankedActions` (itself `nonisolated`) can call it directly.
    nonisolated static func holdingBySymbol(in positions: [PortfolioPosition]) -> [String: AggregatedHolding] {
        var lotsBySymbol: [String: [PortfolioPosition]] = [:]
        for p in positions where p.shares > 0 {
            lotsBySymbol[p.symbol.uppercased(), default: []].append(p)
        }
        return lotsBySymbol.compactMapValues { lots in
            let totalShares = lots.reduce(0) { $0 + $1.shares }
            guard totalShares > 0 else { return nil }
            let weightedCost = lots.reduce(0) { $0 + $1.shares * $1.costBasis } / totalShares
            return AggregatedHolding(symbol: lots[0].symbol.uppercased(), shares: totalShares, costBasis: weightedCost)
        }
    }
}
