import Foundation

/// Deterministic, explainable Top-5 selection for a completed 1-7/7-14 research run.
///
/// This NEVER calls a model and never rewrites an action, a receipt, or the strict qualification
/// gate: `StockSageResearchQualification.Receipt.isQualified`/`exclusions()` are read, not changed.
/// It only decides ORDER and which five eligible, fully-checked candidates are shown, from
/// already-captured evidence (technical confluence, insider transactions, catalysts, freshness).
/// Every run of `rank(...)` on the same inputs produces byte-identical output.
enum StockSageTopFiveRanking {
    nonisolated static let version = 1

    // Documented, fixed constants so a reviewer or test can hand-verify every threshold without
    // reading the scoring body. Changing any of these is a scoring-behavior change, not a bugfix.
    nonisolated static let staleCapturePenalty = -50.0
    nonisolated static let contradictoryBasisPenalty = -50.0
    nonisolated static let noCatalystPenalty = -10.0
    nonisolated static let contraryConfluencePenaltyPerCheck = -2.0
    /// An insider transaction older than this contributes zero weight.
    nonisolated static let insiderDecayWindowDays = 14.0
    /// 2+ distinct owners, same direction, within this window count as a cluster.
    nonisolated static let insiderClusterWindowDays = 7.0
    nonisolated static let insiderClusterMultiplier = 1.5
    /// At most this many of the final five may share one concentration key (sector, or catalyst
    /// identity when sector is unknown) unless the material-advantage margin below is met.
    nonisolated static let maximumPerConcentrationKey = 2
    /// The minimum score lead a concentrated candidate must hold over the best available
    /// different-key alternative to be kept despite exceeding the concentration cap.
    nonisolated static let materialAdvantageMargin = 5.0

    nonisolated enum QualificationStatus: String, Codable, Sendable {
        case qualified, notQualified
    }

    /// Every component is independently inspectable; nothing is folded into an opaque total
    /// without also keeping the pieces. `counterevidence` and `hardPenalties` are always <= 0.
    nonisolated struct ScoreComponents: Codable, Equatable, Sendable {
        let horizonFit: Double
        let technicalConfluence: Double
        let catalystQuality: Double
        let liquidity: Double
        let evidenceFreshness: Double
        let insiderRelevance: Double
        let counterevidence: Double
        let hardPenalties: Double
        var total: Double {
            horizonFit + technicalConfluence + catalystQuality + liquidity
                + evidenceFreshness + insiderRelevance + counterevidence + hardPenalties
        }
    }

    /// One insider transaction's ACTUAL contribution to `insiderRelevance`, so the weight beside
    /// a rank is exact, never a re-derived approximation. Every `InsiderTransaction` this system
    /// captures is already an open-market Form 4 purchase or sale by construction — the parser
    /// (StockSageMassiveEvents) only accepts transaction codes P and S, never option exercises,
    /// awards, or plan grants — so no separate open-market flag is needed to make that distinction.
    nonisolated struct InsiderSignal: Codable, Equatable, Sendable {
        let direction: StockSageMassiveEvents.InsiderTransaction.Direction
        let ownerName: String
        let ageDays: Double
        /// Signed: positive for a purchase's contribution, negative for a sale's. Freshness- and
        /// cluster-adjusted. This is a SCORE WEIGHT, never a claim about the insider's motive.
        let contribution: Double
    }

    nonisolated struct Ranked: Codable, Equatable, Sendable {
        let rank: Int
        let symbol: String
        /// The model's REAL original action. Never fabricated into Buy/Strong Buy for a fallback row.
        let action: String
        let status: QualificationStatus
        let components: ScoreComponents
        let insiderSignals: [InsiderSignal]
        /// Populated only when `status == .notQualified`: the receipt's own exclusion reasons.
        let failedGates: [String]
        /// Populated only when a hard penalty applied: which ones and why.
        let hardPenaltyReasons: [String]
    }

    nonisolated struct Result: Codable, Equatable, Sendable {
        let version: Int
        let horizon: String
        /// Exactly `min(5, pool.count)`, ranks 1...N ascending, most preferred first.
        let ranked: [Ranked]
        /// True when the concentration guard changed the ranking that raw score alone would have produced.
        let concentrationGuardApplied: Bool
    }

    /// One eligible, fully-checked candidate. `sector` and `catalystIdentity` may be nil when
    /// unknown; the concentration guard degrades gracefully to no-op when both are nil for a
    /// candidate (it is simply never grouped with anything).
    nonisolated struct Candidate: Sendable {
        let symbol: String
        let action: String
        let sector: String?
        let catalystIdentity: String?
        let qualification: StockSageResearchQualification.Receipt
        let insiderTransactions: [StockSageMassiveEvents.InsiderTransaction]

        init(symbol: String, action: String, sector: String? = nil, catalystIdentity: String? = nil,
             qualification: StockSageResearchQualification.Receipt,
             insiderTransactions: [StockSageMassiveEvents.InsiderTransaction] = []) {
            self.symbol = symbol; self.action = action; self.sector = sector
            self.catalystIdentity = catalystIdentity; self.qualification = qualification
            self.insiderTransactions = insiderTransactions
        }
    }

    /// Pure and deterministic. `now` drives freshness decay only; pass the run's own evidence
    /// clock, never a live wall-clock read inside a test.
    nonisolated static func rank(_ pool: [Candidate], horizon: StockSageHorizonResearch.Horizon, now: Date) -> Result {
        let scored = pool.map { candidate -> (Candidate, ScoreComponents, [InsiderSignal], [String]) in
            let (components, signals, penaltyReasons) = score(candidate, horizon: horizon, now: now)
            return (candidate, components, signals, penaltyReasons)
        }
        // Primary key: qualified before not-qualified. This is what guarantees insider evidence
        // (or any other component) can never by itself promote a hard-gate failure over a pass.
        // Secondary: total score descending. Final: symbol ascending, for a total, stable order.
        let sorted = scored.sorted { lhs, rhs in
            let lq = lhs.0.qualification.isQualified, rq = rhs.0.qualification.isQualified
            if lq != rq { return lq && !rq }
            if lhs.1.total != rhs.1.total { return lhs.1.total > rhs.1.total }
            return lhs.0.symbol < rhs.0.symbol
        }
        let (final, guardApplied) = applyConcentrationGuard(sorted)
        let ranked = final.prefix(5).enumerated().map { index, entry -> Ranked in
            let (candidate, components, signals, penaltyReasons) = entry
            let status: QualificationStatus = candidate.qualification.isQualified ? .qualified : .notQualified
            return Ranked(rank: index + 1, symbol: candidate.symbol, action: candidate.action, status: status,
                components: components, insiderSignals: signals,
                failedGates: status == .notQualified ? candidate.qualification.reasons : [],
                hardPenaltyReasons: penaltyReasons)
        }
        return Result(version: version, horizon: horizon.rawValue, ranked: ranked, concentrationGuardApplied: guardApplied)
    }

    private nonisolated static func score(_ candidate: Candidate, horizon: StockSageHorizonResearch.Horizon,
                                          now: Date) -> (ScoreComponents, [InsiderSignal], [String]) {
        let receipt = candidate.qualification
        let m = receipt.measurements

        // Horizon fit: the measured historical return over the SELECTED horizon, capped so one
        // outsized reading cannot dominate the total. 0 when unmeasured — a gap, not a penalty.
        let horizonFit = (m.horizonReturnPercent.map { min(max($0, 0), 20) } ?? 0) / 20 * 10

        // Technical confluence: reuses Task 8's neutral verdict directly. insufficient scores 0
        // (a data gap), never negative — missing data is never treated as negative evidence.
        let technicalConfluence: Double
        switch receipt.confluence?.verdict {
        case .aligned: technicalConfluence = 10
        case .mixed: technicalConfluence = 5
        case .conflicted, .insufficient, nil: technicalConfluence = 0
        }

        // Catalyst quality: a CITED qualifying record only; an offered-but-uncited catalyst
        // cannot buy points it was never credited for supporting the action.
        let catalystQuality: Double = receipt.citedQualifyingKeys.isEmpty ? 0
            : (receipt.candidateCatalysts.first { receipt.citedQualifyingKeys.contains($0.key) }?.kind == .publicInsiderFiling ? 8 : 6)

        // Liquidity: the same measured volume ratio the strict screen itself requires >= 1.5 for;
        // here it is a smooth 0-10 score instead of a pass/fail bar, capped at 4x.
        let liquidity = (m.volumeRatio.map { min($0, 4) } ?? 0) / 4 * 10

        // Evidence freshness: linear decay from the run's own evidence clock, 1 point per stale
        // hour, floored at 0. This is about DATA age, not the technical bar date.
        let freshnessHours = max(0, now.timeIntervalSince(receipt.evidenceAsOf) / 3600)
        let evidenceFreshness = max(0, 10 - freshnessHours)

        // Insider relevance: the first-class signal. Every transaction is scored individually so
        // its exact, signed contribution is visible beside the rank; sales are never dropped and
        // never scored as if they were purchases.
        let signals = insiderSignals(for: candidate, now: now)
        let insiderRelevance = signals.reduce(0) { $0 + $1.contribution }

        // Counterevidence: each contrary confluence check is evidence AGAINST the setup, reused
        // directly from Task 8 rather than re-derived. Always <= 0.
        let contraryChecks = [receipt.confluence?.trendAlignment, receipt.confluence?.momentumDirection,
            receipt.confluence?.volatilitySuitability, receipt.confluence?.liquidityConfirmation,
            receipt.confluence?.resistanceDistance].filter { $0 == .contrary }.count
        let counterevidence = Double(contraryChecks) * contraryConfluencePenaltyPerCheck

        // Hard penalties: flat, named, and surfaced by reason string, distinct from the smooth
        // components above. Stale/unverified capture and a contradictory technical basis are
        // penalized heavily rather than merely scoring zero in one component.
        var reasons: [String] = []
        var hardPenalties = 0.0
        if !receipt.criticalCaptureReady {
            hardPenalties += staleCapturePenalty
            reasons.append("Critical capture identity, currency, access or timing is unverified.")
        }
        if receipt.confluence?.verdict == .insufficient, receipt.confluence?.reasons.contains(where: {
            $0.contains("reference close") || $0.contains("session") || $0.contains("symbol")
        }) == true {
            hardPenalties += contradictoryBasisPenalty
            reasons.append("The technical snapshot's basis contradicts the qualification measurements.")
        }
        if receipt.candidateCatalysts.isEmpty {
            hardPenalties += noCatalystPenalty
            reasons.append("No dated catalyst record was offered at all.")
        }

        return (ScoreComponents(horizonFit: horizonFit, technicalConfluence: technicalConfluence,
            catalystQuality: catalystQuality, liquidity: liquidity, evidenceFreshness: evidenceFreshness,
            insiderRelevance: insiderRelevance, counterevidence: counterevidence, hardPenalties: hardPenalties),
            signals, reasons)
    }

    /// Freshness-decayed, direction-signed, cluster-boosted. A purchase contributes positively,
    /// a sale contributes negatively — this is a QUANTITATIVE SCORE WEIGHT, never a claim about
    /// motive, and never described as momentum. Fully decayed (zero weight) past the decay window.
    private nonisolated static func insiderSignals(for candidate: Candidate, now: Date) -> [InsiderSignal] {
        let base = 6.0
        var clusterCount: [StockSageMassiveEvents.InsiderTransaction.Direction: Int] = [:]
        for transaction in candidate.insiderTransactions {
            let ageDays = now.timeIntervalSince(transaction.transactionDate) / 86_400
            guard ageDays >= 0, ageDays <= insiderClusterWindowDays else { continue }
            clusterCount[transaction.direction, default: 0] += 1
        }
        return candidate.insiderTransactions.map { transaction in
            let ageDays = max(0, now.timeIntervalSince(transaction.transactionDate) / 86_400)
            let decay = max(0, 1 - ageDays / insiderDecayWindowDays)
            let clustered = (clusterCount[transaction.direction] ?? 0) >= 2
            let magnitude = base * decay * (clustered ? insiderClusterMultiplier : 1)
            let signed = transaction.direction == .purchase ? magnitude : -magnitude
            return InsiderSignal(direction: transaction.direction, ownerName: transaction.ownerName,
                ageDays: ageDays, contribution: signed)
        }
    }

    /// Greedily fills the five FINAL slots directly (not a reorder-then-truncate), so a skip
    /// actually excludes a candidate from the top five rather than merely moving it later in a
    /// list that gets truncated anyway. At most `maximumPerConcentrationKey` of the final five may
    /// share one concentration key, UNLESS the concentrated candidate's lead over the best
    /// available different-key alternative is at least `materialAdvantageMargin`, OR there are
    /// not enough remaining candidates left to reach five without it (a "light" guard degrades
    /// gracefully rather than shorting the required five). Never promotes a not-qualified
    /// candidate ahead of a qualified one: `sorted`'s qualified-first partition is preserved
    /// because a skipped candidate is only ever pushed past OTHERS STILL TO COME, never ahead.
    private nonisolated static func applyConcentrationGuard(
        _ sorted: [(Candidate, ScoreComponents, [InsiderSignal], [String])]
    ) -> ([(Candidate, ScoreComponents, [InsiderSignal], [String])], Bool) {
        func key(_ candidate: Candidate) -> String? { candidate.sector ?? candidate.catalystIdentity }
        var chosen: [(Candidate, ScoreComponents, [InsiderSignal], [String])] = []
        var skipped: [(Candidate, ScoreComponents, [InsiderSignal], [String])] = []
        var counts: [String: Int] = [:]
        var applied = false
        for (index, entry) in sorted.enumerated() {
            guard chosen.count < 5 else { break }
            guard let k = key(entry.0) else { chosen.append(entry); continue }
            let count = counts[k, default: 0]
            if count < maximumPerConcentrationKey {
                counts[k] = count + 1
                chosen.append(entry)
                continue
            }
            // Over the cap for this key. Skipping is only affordable when enough OTHER
            // candidates remain after this one to still reach five without it.
            let remainingAfter = sorted.count - (index + 1)
            let stillNeeded = 5 - chosen.count
            if remainingAfter >= stillNeeded {
                let alternative = sorted[(index + 1)...].first { key($0.0) != k }
                if let alternative, entry.1.total - alternative.1.total < materialAdvantageMargin {
                    skipped.append(entry)
                    applied = true
                    continue
                }
            }
            counts[k] = count + 1
            chosen.append(entry)
        }
        // Only reached if the pool itself had fewer than five candidates overall; top up from
        // whatever was skipped rather than coming back short.
        for entry in skipped where chosen.count < 5 { chosen.append(entry) }
        return (chosen, applied)
    }
}
