import Foundation
import Combine
import CryptoKit

/// Completed research snapshots and later price-direction checks. No model, feed, paper or broker work.
@MainActor
final class StockSageResearchHistory: ObservableObject {
    static let shared = StockSageResearchHistory(storageURL: StockSageStore.isRunningTests ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/ResearchHistory/runs.json"))

    nonisolated enum Horizon: Int, Codable, Sendable, CaseIterable {
        case week = 7, fortnight = 14
        var title: String { self == .week ? "1–7 trading days" : "7–14 trading days" }
    }
    nonisolated enum MeasurementPolicy: Int, Codable, Sendable {
        /// Seven/fourteen whole sessions beginning on the next trading date, never completion's date.
        case nextTradingDateSessions = 1
    }
    /// Versioned so legacy runs keep their endpoint-only evaluation. Unknown raw values
    /// throw while decoding rather than silently downgrading to another policy.
    nonisolated enum OutcomePolicy: Int, Codable, Sendable {
        /// Settled adjusted daily OHLC bars, completing at the first target or stop event.
        case dailyBarFirstHit = 2
        /// Session-open crossings are ordered before the later high/low range.
        case dailyBarOpeningFirst = 3
    }
    nonisolated struct DailyBar: Codable, Sendable, Equatable {
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
    }
    nonisolated struct Levels: Codable, Sendable, Equatable {
        let entry: Double
        let stop: Double
        let target: Double
        let at: Date
        let basis: String
    }
    nonisolated struct Prediction: Codable, Sendable, Equatable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let name: String
        let action: String
        let reason: String
        let risk: String
        let evidence: [String]
        let facts: [String]
        let model: String
        let note: String
        let referencePrice: Double?
        let referenceDate: Date?
        let levels: Levels?
        var inferenceProfile: StockSageAIAssessment.InferenceProfile? = nil
        var qualityReport: StockSageAIAssessment.QualityReport? = nil
        var evidenceReceipt: StockSageAIAssessment.EvidenceCoverage? = nil
        var qualification: StockSageResearchQualification.Receipt? = nil
        var factClasses: [StockSageAIAssessment.FactClass]? = nil
        var insiderEvidence: StockSageMassiveEvents.Observation? = nil
        var insiderCoverage: CompletedCheck.SourceCoverage? = nil

        var hasRecordedInsiderEvidence: Bool { insiderEvidence != nil || insiderCoverage != nil }
    }
    nonisolated struct SelectionReceipt: Codable, Sendable, Equatable {
        let session: String
        let requestedAt: Date
        let returnedCount: Int
        let eligibleCount: Int
        let directoryCount: Int
        let partialSession: Bool
        let fallback: Bool
        let dollarVolume: [String: Double]
    }
    nonisolated struct Coverage: Codable, Sendable, Equatable {
        let requested: Int
        let checked: Int
        let incomplete: Int
        let buyCount: Int
        let selection: SelectionReceipt?
        /// Absent in legacy runs. Raw model Buy counts remain unchanged by qualification.
        var qualifiedBuyCount: Int? = nil
    }
    nonisolated struct Run: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let startedAt: Date
        let completedAt: Date
        let horizon: Horizon
        let predictions: [Prediction]
        let coverage: Coverage
        /// Missing in older files: retain the legacy count of future closes after completion.
        let measurementPolicy: MeasurementPolicy?
        /// Captured comparison and failure are immutable; absent in legacy activity-ordered runs.
        let ranking: StockSageResearchRanking.Receipt?
        let rankingFailure: String?
        /// Exact deterministic visible selection, independent of strict model predictions.
        /// Missing on older runs: no historical rank or scoring clock is reconstructed.
        let deterministicRanking: StockSageTopFiveRanking.Result?
        var rankingScoredAt: Date? { deterministicRanking?.scoredAt }
        var usesDailyBarFirstHit: Bool { outcomePolicy != nil }
        /// A later comparison of the same captured checks; original failed history is retained.
        let originalRunID: UUID?
        /// A new capture of only incomplete checks, retaining completed results from this run.
        let retainedFromRunID: UUID?
        /// Absent in every run saved before first-hit completion existed; never inferred.
        let outcomePolicy: OutcomePolicy?
        // Only these subsequent receipts change; the original prediction fields above never do.
        var evaluations: [String: Evaluation] = [:]
        /// Separate from immutable terminal outcomes; absent on legacy documents.
        var reviewProgress: [String: ReviewProgress]? = nil

        init(id: UUID, startedAt: Date, completedAt: Date, horizon: Horizon,
             predictions: [Prediction], coverage: Coverage, evaluations: [String: Evaluation] = [:],
             measurementPolicy: MeasurementPolicy? = nil,
             ranking: StockSageResearchRanking.Receipt? = nil, rankingFailure: String? = nil,
             originalRunID: UUID? = nil, retainedFromRunID: UUID? = nil,
             outcomePolicy: OutcomePolicy? = nil,
             deterministicRanking: StockSageTopFiveRanking.Result? = nil) {
            self.id = id; self.startedAt = startedAt; self.completedAt = completedAt
            self.horizon = horizon; self.predictions = predictions; self.coverage = coverage
            self.evaluations = evaluations; self.measurementPolicy = measurementPolicy
            self.ranking = ranking; self.rankingFailure = rankingFailure; self.originalRunID = originalRunID
            self.retainedFromRunID = retainedFromRunID; self.outcomePolicy = outcomePolicy
            self.deterministicRanking = deterministicRanking
        }
    }
    nonisolated struct ReviewProgress: Codable, Sendable, Equatable {
        let checkedAt: Date
        /// A fully verified quiet daily window, never inferred from a failed fetch.
        let verifiedThrough: Date?
    }
    nonisolated struct DailyClose: Codable, Sendable, Equatable {
        let date: Date
        let price: Double
    }
    nonisolated struct Evaluation: Codable, Sendable, Equatable {
        enum State: String, Codable, Sendable { case notDue, due, dataUnavailable, evaluated }
        enum Direction: String, Codable, Sendable { case rose, fell, flat }
        /// Unknown stored values throw while decoding; a receipt never degrades into another kind.
        enum TerminalKind: String, Codable, Sendable { case targetHit, stopHit, horizonClose }
        let state: State
        let checkedAt: Date
        let targetCloseAt: Date?
        var calendarBasis = StockSageResearchHistory.benchmarkCalendarBasis
        var provider: String? = nil
        var fetchedAt: Date? = nil
        var comparisonReferencePrice: Double? = nil
        var comparisonReferenceDate: Date? = nil
        var targetPrice: Double? = nil
        var priceReturn: Double? = nil
        var direction: Direction? = nil
        /// Flat is reported separately, not counted as support or converted into a win probability.
        var buyDirectionSupported: Bool? = nil
        /// Complete comparison-date path only; nil means unrecorded or missing sessions.
        var dailyCloses: [DailyClose]? = nil
        // Daily-bar first-hit receipts only. Absent on every endpoint-policy receipt.
        var terminalKind: TerminalKind? = nil
        /// The New York session that produced the terminal event, not the scheduled horizon close.
        var terminalAt: Date? = nil
        /// The daily-bar observation price: a gap uses the session open, otherwise the captured level.
        var outcomePrice: Double? = nil
        /// Freshly adjusted close on the saved reference date divided by the immutable saved price.
        var adjustmentRatio: Double? = nil
        var adjustedEntry: Double? = nil
        var adjustedStop: Double? = nil
        var adjustedTarget: Double? = nil
        /// Every verified session examined through the terminal one; holes are never bridged.
        var dailyBars: [DailyBar]? = nil
        /// Present only when one bar reached both levels and the conservative stop-first rule applied.
        var sameBarStopFirst: Bool? = nil
        let note: String
    }
    nonisolated struct Observation: Sendable {
        let history: StockSagePriceHistory
        /// Must come from verified response metadata; `.massiveDaily` alone does not prove adjustment.
        let splitAdjusted: Bool
        let provider: String
        let fetchedAt: Date
    }
    private struct Document: Codable {
        var version = 1
        var runs: [Run] = []
    }
    @Published private(set) var runs: [Run] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckSummary: String?
    nonisolated static let maximumChecksPerRequest = 25
    nonisolated static let benchmarkCalendarBasis = "Nasdaq published 2026 holiday and early-close schedule; next trading-date daily open to target daily close"
    private let storageURL: URL?
    private let defaults: UserDefaults
    private var readable = true
    private var completedMemory: [Horizon: CompletedCheckpoint] = [:]
    private var interruptedMemory: [Horizon: InterruptedCheckpoint] = [:]
    private var archiveIndexMemory = FullChecksIndex()
    private var archiveMemory: [UUID: Data] = [:]
    /// Only immutable listing identities are cached, never large evidence packets.
    private var fullCheckSearchIdentities: [UUID: [String]] = [:]

    /// nil is deliberately memory-only. Test hosts cannot resolve the owner's production file.
    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.storageURL = storageURL
        self.defaults = defaults
        guard storageURL != nil else { return }
        guard StockSageRecordWriter.mayRead(defaults) else {
            readable = false
            lastError = "Research history is unavailable in this isolated test context."
            return
        }
        do { runs = try read().runs }
        catch {
            readable = false
            lastError = "Saved research could not be read. Original bytes are preserved; no predictions were replaced."
        }
    }

    /// Call only after the complete run succeeds. Partial and cancelled scans are not completed predictions.
    static func snapshot(id: UUID = UUID(), startedAt: Date, completedAt: Date,
                         horizon: StockSageHorizonResearch.Horizon,
                         scan: StockSageHorizonResearch.Scan, originalRunID: UUID? = nil) -> Run {
        let predictions = scan.topBuys.compactMap { listing -> Prediction? in
            scan.results[listing.ticker].flatMap { CompletedCheck(listing: listing, result: $0).prediction }
        }
        let selection = scan.selection.map {
            SelectionReceipt(session: $0.session, requestedAt: $0.requestedAt, returnedCount: $0.returnedCount,
                eligibleCount: $0.eligibleCount, directoryCount: $0.directoryCount,
                partialSession: $0.partialSession, fallback: $0.fallback, dollarVolume: $0.dollarVolume)
        }
        return Run(id: id, startedAt: startedAt, completedAt: completedAt,
            horizon: horizon == .week ? .week : .fortnight, predictions: predictions,
            coverage: Coverage(requested: scan.listings.count, checked: scan.results.count,
                incomplete: scan.results.values.filter { $0.verdict == nil }.count,
                buyCount: scan.results.values.filter { $0.verdict?.action == .buy || $0.verdict?.action == .strongBuy }.count,
                selection: selection, qualifiedBuyCount: scan.qualificationPolicyVersion == 1
                    ? scan.listings.filter { scan.isEligible($0.ticker) }.count : nil), measurementPolicy: .nextTradingDateSessions,
            ranking: scan.ranking, rankingFailure: scan.rankingFailure, originalRunID: originalRunID,
            retainedFromRunID: scan.retainedFromRunID, outcomePolicy: .dailyBarOpeningFirst,
            deterministicRanking: scan.deterministicRanking ?? (scan.completedAt == nil
                ? StockSageTopFiveRanking.capture(listings: scan.listings, results: scan.results, horizon: horizon, at: completedAt) : nil))
    }

    @discardableResult func record(_ run: Run) -> Bool {
        guard run.evaluations.isEmpty, run.reviewProgress == nil, Self.valid(run), run.coverage.checked == run.coverage.requested else {
            lastError = "Only a complete, valid research snapshot can be saved. Existing predictions are preserved."
            return false
        }
        return commit { document in
            guard Self.validOriginalLink(run, in: document.runs) else { throw CocoaError(.fileWriteInvalidFileName) }
            if var existing = document.runs.first(where: { $0.id == run.id }) {
                existing.evaluations = [:]
                existing.reviewProgress = nil
                guard existing == run else { throw CocoaError(.fileWriteInvalidFileName) }
                return // Same completion cannot overwrite later evaluations.
            }
            document.runs.insert(run, at: 0)
        }
    }

    private func recordReviewProgress(_ evaluation: Evaluation, runID: UUID, symbol: String) -> Bool {
        commit { document in
            guard let index = document.runs.firstIndex(where: { $0.id == runID }),
                  document.runs[index].predictions.contains(where: { $0.symbol == symbol }),
                  Self.validDate(evaluation.checkedAt), evaluation.checkedAt >= document.runs[index].completedAt else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let run = document.runs[index]
            if let previous = run.reviewProgress?[symbol], previous.checkedAt > evaluation.checkedAt {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let quiet = evaluation.state == .notDue && run.usesDailyBarFirstHit
                && Self.availability(for: run, now: evaluation.checkedAt).state == .due
            let through = quiet ? Self.settledReviewDate(for: run, now: evaluation.checkedAt) : nil
            var progress = run.reviewProgress ?? [:]
            progress[symbol] = .init(checkedAt: evaluation.checkedAt,
                verifiedThrough: through ?? progress[symbol]?.verifiedThrough)
            document.runs[index].reviewProgress = progress
            if quiet, run.evaluations[symbol]?.state == .dataUnavailable {
                document.runs[index].evaluations.removeValue(forKey: symbol)
            }
        }
    }

    @discardableResult func recordEvaluation(_ evaluation: Evaluation, runID: UUID, symbol: String) -> Bool {
        commit { document in
            guard let index = document.runs.firstIndex(where: { $0.id == runID }),
                  document.runs[index].predictions.contains(where: { $0.symbol == symbol }),
                  evaluation.targetCloseAt == Self.targetClose(for: document.runs[index]),
                  evaluation.calendarBasis == Self.calendarBasis(for: document.runs[index]),
                  evaluation.state != .evaluated || evaluation.comparisonReferenceDate == Self.benchmarkDay(after: document.runs[index].completedAt),
                  Self.valid(evaluation, run: document.runs[index], symbol: symbol) else { throw CocoaError(.fileWriteInvalidFileName) }
            if let old = document.runs[index].evaluations[symbol] {
                guard evaluation.checkedAt >= old.checkedAt else { throw CocoaError(.fileWriteInvalidFileName) }
                // A later provider revision or richer path must not rewrite an observed outcome.
                if old.state == .evaluated { return }
            }
            document.runs[index].evaluations[symbol] = evaluation
        }
    }

    nonisolated struct HomeSummary {
        var latest: [Run] = []
        var ready: [Run] = []
        var readyPredictions = 0
        var waitingPredictions = 0
        var unavailablePredictions = 0
        var nextReviewAt: Date?
        var completedToday = 0
        var evaluatedPredictions = 0
        var rosePredictions = 0
        var fellPredictions = 0
        var flatPredictions = 0
        // Daily-bar first-hit receipts only, reported separately and never blended into a win rate.
        var targetHits = 0
        var stopHits = 0
        var horizonCloses = 0
    }

    nonisolated static func pendingPredictions(in run: Run) -> [Prediction] {
        run.predictions.filter { run.evaluations[$0.symbol]?.state != .evaluated }
    }

    /// A dated projection of completed records, never a new ranking or a partial live scan.
    nonisolated static func homeSummary(_ runs: [Run], now: Date) -> HomeSummary {
        var summary = HomeSummary()
        for horizon in Horizon.allCases {
            if let latest = runs.filter({ $0.horizon == horizon }).max(by: {
                $0.completedAt == $1.completedAt ? $0.id.uuidString < $1.id.uuidString : $0.completedAt < $1.completedAt
            }) { summary.latest.append(latest) }
        }
        for run in runs {
            for receipt in run.evaluations.values where receipt.state == .evaluated {
                // A terminal scenario is counted by the level it reached. A horizon close keeps its
                // own signed return and is never converted into a target hit.
                if let terminal = receipt.terminalKind, run.usesDailyBarFirstHit {
                    switch terminal {
                    case .targetHit: summary.targetHits += 1
                    case .stopHit: summary.stopHits += 1
                    case .horizonClose: summary.horizonCloses += 1
                    }
                    summary.evaluatedPredictions += 1
                    continue
                }
                switch receipt.direction {
                case .rose: summary.rosePredictions += 1
                case .fell: summary.fellPredictions += 1
                case .flat: summary.flatPredictions += 1
                case nil: continue
                }
                summary.evaluatedPredictions += 1
            }
            if validDate(now), run.completedAt <= now, calendar.isDate(run.completedAt, inSameDayAs: now) {
                summary.completedToday += 1
            }
            let pending = pendingPredictions(in: run).count
            guard pending > 0 else { continue }
            switch availability(for: run, now: now).state {
            case .due:
                summary.ready.append(run)
                summary.readyPredictions += pending
            case .notDue:
                summary.waitingPredictions += pending
                if let date = checkAvailableAt(for: run) {
                    summary.nextReviewAt = min(summary.nextReviewAt ?? date, date)
                }
            case .dataUnavailable:
                summary.unavailablePredictions += pending
            case .evaluated: break
            }
        }
        summary.ready.sort { $0.completedAt == $1.completedAt ? $0.id.uuidString < $1.id.uuidString : $0.completedAt < $1.completedAt }
        return summary
    }

    /// Sequential and bounded per pass, from either the Saved Research action or one foreground
    /// activation. Cancellation or a revoked policy after an await discards that response without
    /// persisting even an unavailable-data receipt. A verified no-hit result before the horizon
    /// leaves the prediction active, with review progress separate from outcome receipts.
    func checkActive(clock: @escaping @MainActor () -> Date = { Date() },
                     allowed: @escaping @MainActor () -> Bool,
                     fetch: @escaping @MainActor (Prediction, Run) async -> Observation?) async {
        guard !isChecking, !Task.isCancelled, allowed(), readable else { return }
        isChecking = true
        lastCheckSummary = nil
        defer { isChecking = false }
        let pending = runs.flatMap { run -> [(Run, Prediction)] in
            guard Self.availability(for: run, now: clock()).state == .due else { return [] }
            return Self.pendingPredictions(in: run).map { (run, $0) }
        }.sorted { left, right in
            let leftCheck = left.0.reviewProgress?[left.1.symbol]?.checkedAt
                ?? left.0.evaluations[left.1.symbol]?.checkedAt ?? .distantPast
            let rightCheck = right.0.reviewProgress?[right.1.symbol]?.checkedAt
                ?? right.0.evaluations[right.1.symbol]?.checkedAt ?? .distantPast
            if leftCheck != rightCheck { return leftCheck < rightCheck }
            if left.0.completedAt != right.0.completedAt { return left.0.completedAt < right.0.completedAt }
            if left.0.id != right.0.id { return left.0.id.uuidString < right.0.id.uuidString }
            return left.1.symbol < right.1.symbol
        }
        var checked = 0
        var completed = 0
        for (run, prediction) in pending.prefix(Self.maximumChecksPerRequest) {
            guard !Task.isCancelled, allowed() else { return }
            let observation = await fetch(prediction, run)
            guard !Task.isCancelled, allowed() else { return }
            let receipt = Self.evaluate(prediction, in: run, observation: observation, now: clock())
            // A still-active prediction has no outcome to record; only a terminal result or a
            // verified inability to obtain the required bars becomes a stored receipt.
            if receipt.state == .evaluated || receipt.state == .dataUnavailable {
                guard recordEvaluation(receipt, runID: run.id, symbol: prediction.symbol) else { return }
                if receipt.state == .evaluated { completed += 1 }
            }
            guard recordReviewProgress(receipt, runID: run.id, symbol: prediction.symbol) else { return }
            checked += 1
        }
        let remaining = pending.count - checked
        lastCheckSummary = "Checked \(checked) active prediction\(checked == 1 ? "" : "s")."
            + (completed > 0 ? " \(completed) completed." : "")
            + (remaining > 0 ? " \(remaining) remain\(remaining == 1 ? "s" : "") for another pass." : "")
    }

    private func read() throws -> Document {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return Document() }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: storageURL))
        guard document.version == 1, Set(document.runs.map(\.id)).count == document.runs.count,
              document.runs.allSatisfy({ Self.valid($0) && Self.validOriginalLink($0, in: document.runs) }) else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }
    private func commit(_ update: (inout Document) throws -> Void) -> Bool {
        guard readable else { return false }
        do {
            if let storageURL {
                try StockSageRecordWriter.require(defaults)
                let lease = try StockSageFileLock(url: storageURL.appendingPathExtension("lock"))
                defer { withExtendedLifetime(lease) {} }
                var document: Document
                do { document = try read() }
                catch { readable = false; throw error }
                try update(&document)
                let data = try JSONEncoder().encode(document)
                try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
                runs = document.runs
            } else {
                var document = Document(runs: runs)
                try update(&document)
                runs = document.runs
            }
            lastError = nil
            return true
        } catch {
            lastError = "Research history could not be saved. Existing predictions are preserved. \(error.localizedDescription)"
            return false
        }
    }

    private nonisolated static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    /// Skip completion's entire New York date. The next trading date's daily aggregate open
    /// is wholly after the prediction, including any qualifying extended-hours trades.
    /// This is a daily-bar benchmark, not a promised 09:30 execution price.
    nonisolated static func benchmarkDay(after completedAt: Date) -> Date? {
        guard validDate(completedAt) else { return nil }
        let calendar = calendar
        let firstDay = calendar.startOfDay(for: completedAt)
        for offset in 1..<10 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let schedule = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            if schedule.trading { return day }
        }
        return nil
    }
    nonisolated static func targetClose(for run: Run) -> Date? {
        targetClose(after: run.completedAt, horizon: run.horizon, policy: run.measurementPolicy)
    }
    /// Legacy callers count future CLOSE instants, including today's when still future.
    /// New runs exclude completion's date, matching their next-date opening benchmark.
    nonisolated static func targetClose(after completedAt: Date, horizon: Horizon,
                                       policy: MeasurementPolicy? = nil) -> Date? {
        guard validDate(completedAt) else { return nil }
        let calendar = calendar
        let firstDay = calendar.startOfDay(for: completedAt)
        var remaining = horizon.rawValue
        for offset in (policy == .nextTradingDateSessions ? 1 : 0)..<45 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let schedule = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            guard schedule.trading,
                  let close = calendar.date(bySettingHour: schedule.regularClose, minute: 0, second: 0, of: day),
                  close > completedAt else { continue }
            remaining -= 1
            if remaining == 0 { return close }
        }
        return nil
    }
    private nonisolated static func calendarBasis(for run: Run) -> String {
        benchmarkCalendarBasis + (run.measurementPolicy == .nextTradingDateSessions
            ? "; seven/fourteen full sessions from the next trading-date open (policy 1)" : "")
            + (run.usesDailyBarFirstHit
                ? "; completed at the first verified target or stop on settled adjusted daily bars, otherwise at the horizon session close (outcome policy \(run.outcomePolicy!.rawValue))" : "")
    }
    /// A provider daily close can change after the regular close. Wait until the entire
    /// target New York date has ended before accepting its completed daily aggregate.
    nonisolated static func reviewAvailableAt(for run: Run) -> Date? {
        guard let target = targetClose(for: run) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target))
    }
    /// New runs become checkable once the FIRST monitoring session has entirely ended, because a
    /// terminal target or stop can occur long before the scheduled horizon. Legacy runs keep
    /// waiting for the whole target date, so their captured schedule is unchanged.
    nonisolated static func checkAvailableAt(for run: Run) -> Date? {
        guard run.usesDailyBarFirstHit else { return reviewAvailableAt(for: run) }
        guard let benchmark = benchmarkDay(after: run.completedAt) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: benchmark))
    }
    /// The latest whole New York trading date that has entirely ended, capped at the scheduled
    /// horizon date. nil until the first monitoring session has settled.
    nonisolated static func settledReviewDate(for run: Run, now: Date) -> Date? {
        guard validDate(now), let target = targetClose(for: run),
              let benchmark = benchmarkDay(after: run.completedAt) else { return nil }
        let calendar = calendar
        var day = calendar.startOfDay(for: now)
        var latest: Date?
        for _ in 0..<10 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day),
                  let schedule = StockSageMarketHours.nasdaqDay(at: previous) else { return nil }
            day = previous
            if schedule.trading { latest = previous; break }
        }
        guard let latest else { return nil }
        let settled = min(latest, calendar.startOfDay(for: target))
        return settled >= benchmark ? settled : nil
    }
    nonisolated static func availability(for run: Run, now: Date) -> Evaluation {
        guard valid(run), validDate(now), now >= run.completedAt,
              let target = targetClose(for: run),
              let availableAt = checkAvailableAt(for: run) else {
            return Evaluation(state: .dataUnavailable, checkedAt: now, targetCloseAt: nil, calendarBasis: calendarBasis(for: run),
                note: "The future Nasdaq session calendar or evaluation clock could not be verified.")
        }
        let firstHit = run.usesDailyBarFirstHit
        return Evaluation(state: now < availableAt ? .notDue : .due, checkedAt: now, targetCloseAt: target, calendarBasis: calendarBasis(for: run),
            note: now < availableAt ? (firstHit
                    ? "Waiting until the first monitoring New York date ends, so its daily aggregate is complete. " + measurementDescription(for: run)
                    : "Waiting until the target New York date ends, so its daily aggregate is complete. " + measurementDescription(for: run))
                : (firstHit ? "Active. Settled daily bars are checked for the first target or stop event; no outcome has been observed yet."
                    : "Due for a dated price-direction check. No outcome has been observed yet."))
    }
    nonisolated static func evaluate(_ prediction: Prediction, in run: Run,
                                     observation: Observation?, now: Date) -> Evaluation {
        if run.usesDailyBarFirstHit {
            return evaluateFirstHit(prediction, in: run, observation: observation, now: now)
        }
        let available = availability(for: run, now: now)
        guard available.state == .due, let target = available.targetCloseAt else { return available }
        func unavailable(_ note: String) -> Evaluation {
            Evaluation(state: .dataUnavailable, checkedAt: now, targetCloseAt: target, calendarBasis: calendarBasis(for: run),
                provider: observation?.provider,
                fetchedAt: observation.flatMap { validDate($0.fetchedAt) && $0.fetchedAt <= now ? $0.fetchedAt : nil }, note: note)
        }
        guard run.predictions.contains(prediction), let observation, observation.splitAdjusted,
              !observation.provider.isEmpty, validDate(observation.fetchedAt),
              let availableAt = reviewAvailableAt(for: run),
              observation.fetchedAt >= availableAt, observation.fetchedAt <= now,
              let benchmark = benchmarkDay(after: run.completedAt), benchmark < target else {
            return unavailable("A verified split-adjusted daily history containing both comparison dates is unavailable.")
        }
        let history = observation.history
        let count = history.dates.count
        guard history.symbol == prediction.symbol, history.priceSource == .massiveDaily, count > 0,
              [history.opens.count, history.highs.count, history.lows.count, history.closes.count, history.volumes.count]
                .allSatisfy({ $0 == count }) else { return unavailable("Daily history has a mismatched symbol, source or bar structure.") }
        let calendar = calendar
        var priorDay: Date?
        for index in 0..<count {
            let stamp = history.dates[index]
            guard validDate(stamp), stamp <= observation.fetchedAt else { return unavailable("Daily bar dates are invalid or in the future.") }
            let day = calendar.startOfDay(for: stamp)
            guard priorDay.map({ day > $0 }) ?? true,
                  [history.opens[index], history.highs[index], history.lows[index], history.closes[index]]
                    .allSatisfy({ $0.isFinite && $0 > 0 }),
                  history.highs[index] >= max(history.opens[index], history.closes[index]),
                  history.lows[index] <= min(history.opens[index], history.closes[index]),
                  history.volumes[index].isFinite, history.volumes[index] >= 0 else {
                return unavailable("Daily bars are duplicated, unordered or numerically invalid.")
            }
            priorDay = day
        }
        guard let baselineIndex = history.dates.firstIndex(where: { calendar.isDate($0, inSameDayAs: benchmark) }),
              let targetIndex = history.dates.firstIndex(where: { calendar.isDate($0, inSameDayAs: target) }),
              baselineIndex < targetIndex else {
            return unavailable("The next trading-date benchmark or the exact target session is missing; no adjacent bar is substituted.")
        }
        // Both values come from ONE freshly adjusted series. Never divide a post-split price by
        // the originally saved pre-split reference. That original remains immutable in Prediction.
        let baseline = history.opens[baselineIndex]
        let targetPrice = history.closes[targetIndex]
        let change = targetPrice / baseline - 1
        guard change.isFinite else { return unavailable("The comparable price return is not finite.") }
        let direction: Evaluation.Direction = targetPrice == baseline ? .flat : (targetPrice > baseline ? .rose : .fell)
        let isBuy = prediction.action == "Buy" || prediction.action == "Strong Buy"
        let byDate = Dictionary(uniqueKeysWithValues: (baselineIndex...targetIndex).map {
            (calendar.startOfDay(for: history.dates[$0]), history.closes[$0])
        })
        let sessionDates = comparisonSessionDates(from: benchmark, through: target)
        let path: [DailyClose]? = sessionDates.flatMap { dates in
            guard dates.allSatisfy({ byDate[$0] != nil }) else { return nil }
            return dates.map { DailyClose(date: $0, price: byDate[$0]!) }
        }
        return Evaluation(state: .evaluated, checkedAt: now, targetCloseAt: target, calendarBasis: calendarBasis(for: run),
            provider: observation.provider, fetchedAt: observation.fetchedAt,
            comparisonReferencePrice: baseline, comparisonReferenceDate: benchmark,
            targetPrice: targetPrice, priceReturn: change, direction: direction,
            buyDirectionSupported: isBuy && direction != .flat ? direction == .rose : nil, dailyCloses: path,
            note: "Price direction from the next trading day's daily open to the target day's daily close, on the same split-adjusted basis. Daily aggregates may include qualifying extended-hours trades; this is not a guaranteed execution price. Excludes dividends, fees and execution costs; not realized trading profit or a win probability. No market comparison is made."
                + (path == nil ? " Complete daily-close path unavailable; intervening sessions are missing or unverified." : ""))
    }


    // MARK: - Daily-bar first-hit evaluation (outcome policies 2 and 3)

    private nonisolated struct TerminalEvent {
        let kind: Evaluation.TerminalKind
        let bar: DailyBar
        let price: Double
        let sameBar: Bool
        let gapped: Bool
    }

    /// Pure and chronological. The FIRST session that reaches a level ends the scenario; a bar that
    /// opens between levels and reaches both cannot be ordered, so the conservative stop is recorded.
    /// Policy 3 orders known session-open crossings first; policy 2 retains its original stop precedence.
    private nonisolated static func terminalEvent(bars: [DailyBar], stop: Double?, target: Double?,
                                                  horizonEnded: Bool, policy: OutcomePolicy) -> TerminalEvent? {
        if let stop, let target {
            for bar in bars {
                if policy == .dailyBarOpeningFirst {
                    if bar.open <= stop {
                        return TerminalEvent(kind: .stopHit, bar: bar, price: bar.open, sameBar: false, gapped: true)
                    }
                    if bar.open >= target {
                        return TerminalEvent(kind: .targetHit, bar: bar, price: bar.open, sameBar: false, gapped: true)
                    }
                }
                let stopHit = bar.low <= stop
                let targetHit = bar.high >= target
                if stopHit {
                    let gapped = bar.open <= stop
                    return TerminalEvent(kind: .stopHit, bar: bar, price: gapped ? bar.open : stop,
                                         sameBar: targetHit, gapped: gapped)
                }
                if targetHit {
                    let gapped = bar.open >= target
                    return TerminalEvent(kind: .targetHit, bar: bar, price: gapped ? bar.open : target,
                                         sameBar: false, gapped: gapped)
                }
            }
        }
        guard horizonEnded, let last = bars.last else { return nil }
        return TerminalEvent(kind: .horizonClose, bar: last, price: last.close, sameBar: false, gapped: false)
    }

    /// Whole verified trading dates from `start` through `last`, inclusive, from the published
    /// Nasdaq schedule. Never a weekday guess and never more than one fortnight.
    private nonisolated static func tradingSessionDates(from start: Date, through end: Date) -> [Date]? {
        let calendar = calendar
        guard validDate(start), validDate(end) else { return nil }
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard start == first, first <= last else { return nil }
        var dates: [Date] = []
        for offset in 0..<45 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first), day <= last,
                  let schedule = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            if schedule.trading {
                guard dates.count < 14 else { return nil }
                dates.append(day)
            }
            if day == last { return dates.first == first && dates.last == last ? dates : nil }
        }
        return nil
    }

    /// Structural verification of ONE adjusted series before any level is compared to it.
    private nonisolated static func verifiedBars(_ observation: Observation, symbol: String) -> [Date: DailyBar]? {
        let history = observation.history
        let count = history.dates.count
        guard history.symbol == symbol, history.priceSource == .massiveDaily, count > 0,
              [history.opens.count, history.highs.count, history.lows.count, history.closes.count, history.volumes.count]
                .allSatisfy({ $0 == count }) else { return nil }
        let calendar = calendar
        var bars: [Date: DailyBar] = [:]
        var priorDay: Date?
        for index in 0..<count {
            let stamp = history.dates[index]
            guard validDate(stamp), stamp <= observation.fetchedAt else { return nil }
            let day = calendar.startOfDay(for: stamp)
            guard priorDay.map({ day > $0 }) ?? true,
                  [history.opens[index], history.highs[index], history.lows[index], history.closes[index]]
                    .allSatisfy({ $0.isFinite && $0 > 0 }),
                  history.highs[index] >= max(history.opens[index], history.closes[index]),
                  history.lows[index] <= min(history.opens[index], history.closes[index]),
                  history.volumes[index].isFinite, history.volumes[index] >= 0 else { return nil }
            bars[day] = DailyBar(date: day, open: history.opens[index], high: history.highs[index],
                                 low: history.lows[index], close: history.closes[index])
            priorDay = day
        }
        return bars
    }

    private nonisolated static let firstHitDisclosure = "Daily bars cannot establish high/low ordering or an actual fill. This is a measured research scenario, not an order, an execution price or realized profit."

    private nonisolated static func evaluateFirstHit(_ prediction: Prediction, in run: Run,
                                                     observation: Observation?, now: Date) -> Evaluation {
        let available = availability(for: run, now: now)
        guard available.state == .due, let target = available.targetCloseAt else { return available }
        let calendar = calendar
        func receipt(_ state: Evaluation.State, _ note: String) -> Evaluation {
            Evaluation(state: state, checkedAt: now, targetCloseAt: target, calendarBasis: calendarBasis(for: run),
                provider: observation?.provider,
                fetchedAt: observation.flatMap { validDate($0.fetchedAt) && $0.fetchedAt <= now ? $0.fetchedAt : nil },
                note: note)
        }
        guard run.predictions.contains(prediction), let observation, observation.splitAdjusted,
              !observation.provider.isEmpty, validDate(observation.fetchedAt), observation.fetchedAt <= now,
              let benchmark = benchmarkDay(after: run.completedAt),
              let settled = settledReviewDate(for: run, now: now),
              let settledAt = calendar.date(byAdding: .day, value: 1, to: settled),
              observation.fetchedAt >= settledAt,
              let expected = tradingSessionDates(from: benchmark, through: settled) else {
            return receipt(.dataUnavailable, "A verified split-adjusted daily window of settled Nasdaq sessions is unavailable.")
        }
        guard let bars = verifiedBars(observation, symbol: prediction.symbol) else {
            return receipt(.dataUnavailable, "Daily bars have a mismatched symbol or source, or are duplicated, unordered or numerically invalid.")
        }
        // The captured levels stay immutable. Only this receipt carries the comparison levels,
        // rebased by the freshly adjusted close on the saved reference date. Mixing a pre-split
        // saved price with a post-split bar would silently change the scenario, so it fails closed.
        var ratio: Double?
        var levels: (entry: Double, stop: Double, target: Double)?
        if let captured = prediction.levels {
            guard let referenceDate = prediction.referenceDate, let referencePrice = prediction.referencePrice,
                  referencePrice.isFinite, referencePrice > 0,
                  let referenceBar = bars[calendar.startOfDay(for: referenceDate)] else {
                return receipt(.dataUnavailable, "The saved reference session could not be re-verified on the fresh adjusted basis, so the captured levels cannot be compared.")
            }
            let value = referenceBar.close / referencePrice
            let adjusted = (entry: captured.entry * value, stop: captured.stop * value, target: captured.target * value)
            guard value.isFinite, value > 0,
                  [adjusted.entry, adjusted.stop, adjusted.target].allSatisfy({ $0.isFinite && $0 > 0 }),
                  adjusted.stop < adjusted.entry, adjusted.entry < adjusted.target else {
                return receipt(.dataUnavailable, "The corporate-action adjustment ratio or the adjusted stop/entry/target ordering could not be verified.")
            }
            ratio = value
            levels = adjusted
        }
        // Longest contiguous verified prefix: a hole cannot be bridged by a neighbouring session,
        // but a terminal event strictly before the hole is still the verified first event.
        var path: [DailyBar] = []
        for day in expected {
            guard let bar = bars[day] else { break }
            path.append(bar)
        }
        let atHorizon = settled == calendar.startOfDay(for: target)
        let horizonEnded = atHorizon && path.count == expected.count
        guard let event = terminalEvent(bars: path, stop: levels?.stop, target: levels?.target,
                                        horizonEnded: horizonEnded, policy: run.outcomePolicy!) else {
            guard atHorizon || path.count != expected.count else {
                return receipt(.notDue, "Active. No verified target or stop event yet; the scenario continues until its next settled session or the scheduled horizon close. "
                    + measurementDescription(for: run))
            }
            return receipt(.dataUnavailable, "A required settled session is missing or unverified; no adjacent bar is substituted and the first target or stop event cannot yet be established.")
        }
        guard let terminalIndex = path.firstIndex(where: { $0.date == event.bar.date }) else {
            return receipt(.dataUnavailable, "The terminal session could not be located in the verified path.")
        }
        let examined = Array(path[0...terminalIndex])
        let baseline = examined[0].open
        let change = event.price / baseline - 1
        guard change.isFinite else { return receipt(.dataUnavailable, "The measured outcome return is not finite.") }
        let direction: Evaluation.Direction = event.price == baseline ? .flat : (event.price > baseline ? .rose : .fell)
        let isBuy = prediction.action == "Buy" || prediction.action == "Strong Buy"
        let headline: String
        switch event.kind {
        case .targetHit: headline = "Reached the adjusted target."
        case .stopHit: headline = "Reached the adjusted stop."
        case .horizonClose: headline = "Neither level was reached; measured at the scheduled \(run.horizon.rawValue)th session close."
        }
        var result = Evaluation(state: .evaluated, checkedAt: now, targetCloseAt: target,
            calendarBasis: calendarBasis(for: run), provider: observation.provider, fetchedAt: observation.fetchedAt,
            comparisonReferencePrice: baseline, comparisonReferenceDate: benchmark,
            targetPrice: event.price, priceReturn: change, direction: direction,
            buyDirectionSupported: isBuy && direction != .flat ? direction == .rose : nil,
            note: headline + " Measured from the next trading date's daily open on one split-adjusted basis. " + firstHitDisclosure
                + (event.sameBar ? " The daily bar reached both levels; intraday order is unavailable, so the conservative stop-first rule was applied." : "")
                + (event.gapped ? " The session gapped through the level, so its daily open is the observed outcome price." : "")
                + (prediction.levels == nil ? " No scenario levels were captured, so only the horizon close could complete this prediction." : "")
                + " Excludes dividends, fees and execution costs; no market comparison is made.")
        result.terminalKind = event.kind
        result.terminalAt = event.bar.date
        result.outcomePrice = event.price
        result.adjustmentRatio = ratio
        result.adjustedEntry = levels?.entry
        result.adjustedStop = levels?.stop
        result.adjustedTarget = levels?.target
        result.dailyBars = examined
        result.sameBarStopFirst = event.sameBar ? true : nil
        return result
    }

    /// A daily-policy receipt must be reproducible from its OWN stored bars. Nothing here trusts
    /// the writer: the terminal kind, price, same-bar rule and adjusted levels are recomputed.
    private nonisolated static func validFirstHit(_ evaluation: Evaluation, run: Run, symbol: String) -> Bool {
        guard run.usesDailyBarFirstHit, validDate(evaluation.checkedAt),
              evaluation.checkedAt >= run.completedAt, !evaluation.calendarBasis.isEmpty,
              evaluation.dailyCloses == nil else { return false }
        if let target = evaluation.targetCloseAt {
            guard validDate(target), target > run.completedAt else { return false }
        } else if evaluation.state != .dataUnavailable { return false }
        if let fetched = evaluation.fetchedAt {
            guard validDate(fetched), fetched <= evaluation.checkedAt else { return false }
        }
        guard evaluation.state == .evaluated else {
            if evaluation.state == .notDue || evaluation.state == .due {
                guard let availableAt = checkAvailableAt(for: run),
                      evaluation.state == .notDue ? evaluation.checkedAt < availableAt
                        : evaluation.checkedAt >= availableAt else { return false }
            }
            return evaluation.comparisonReferenceDate == nil && evaluation.comparisonReferencePrice == nil
                && evaluation.targetPrice == nil && evaluation.priceReturn == nil && evaluation.direction == nil
                && evaluation.buyDirectionSupported == nil && evaluation.terminalKind == nil
                && evaluation.terminalAt == nil && evaluation.outcomePrice == nil && evaluation.dailyBars == nil
                && evaluation.adjustmentRatio == nil && evaluation.adjustedEntry == nil
                && evaluation.adjustedStop == nil && evaluation.adjustedTarget == nil
                && evaluation.sameBarStopFirst == nil
        }
        guard let target = evaluation.targetCloseAt, let kind = evaluation.terminalKind,
              let terminalAt = evaluation.terminalAt, let price = evaluation.outcomePrice,
              let bars = evaluation.dailyBars, let first = bars.first,
              let fetched = evaluation.fetchedAt, evaluation.provider?.isEmpty == false,
              let benchmark = benchmarkDay(after: run.completedAt),
              let expected = tradingSessionDates(from: benchmark, through: terminalAt),
              bars.map(\.date) == expected, bars.last?.date == terminalAt,
              terminalAt <= calendar.startOfDay(for: target),
              let settledAt = calendar.date(byAdding: .day, value: 1, to: terminalAt),
              fetched >= settledAt, evaluation.checkedAt >= settledAt,
              evaluation.comparisonReferenceDate == benchmark,
              evaluation.comparisonReferencePrice == first.open,
              evaluation.targetPrice == price, price.isFinite, price > 0 else { return false }
        guard bars.allSatisfy({ bar in
            [bar.open, bar.high, bar.low, bar.close].allSatisfy { $0.isFinite && $0 > 0 }
                && bar.high >= max(bar.open, bar.close) && bar.low <= min(bar.open, bar.close)
        }) else { return false }
        guard let change = evaluation.priceReturn, change.isFinite, change == price / first.open - 1 else { return false }
        let direction: Evaluation.Direction = price == first.open ? .flat : (price > first.open ? .rose : .fell)
        guard evaluation.direction == direction,
              evaluation.buyDirectionSupported == (direction == .flat ? nil : direction == .rose) else { return false }
        var stopLevel: Double?, targetLevel: Double?
        if let captured = run.predictions.first(where: { $0.symbol == symbol })?.levels {
            guard let ratio = evaluation.adjustmentRatio, ratio.isFinite, ratio > 0,
                  let entry = evaluation.adjustedEntry, let stop = evaluation.adjustedStop,
                  let level = evaluation.adjustedTarget,
                  entry == captured.entry * ratio, stop == captured.stop * ratio,
                  level == captured.target * ratio, stop < entry, entry < level else { return false }
            stopLevel = stop; targetLevel = level
        } else {
            guard evaluation.adjustmentRatio == nil, evaluation.adjustedEntry == nil,
                  evaluation.adjustedStop == nil, evaluation.adjustedTarget == nil else { return false }
        }
        guard let recomputed = terminalEvent(bars: bars, stop: stopLevel, target: targetLevel,
                                             horizonEnded: terminalAt == calendar.startOfDay(for: target), policy: run.outcomePolicy!),
              recomputed.kind == kind, recomputed.bar.date == terminalAt, recomputed.price == price,
              evaluation.sameBarStopFirst == (recomputed.sameBar ? true : nil) else { return false }
        return true
    }

    nonisolated static func measurementDescription(for run: Run) -> String {
        if run.usesDailyBarFirstHit {
            return "Completes at the first settled daily session that reaches the captured stop or target, otherwise at the \(run.horizon.rawValue)th session close. Monitoring starts at the next trading-date open."
                + (run.outcomePolicy == .dailyBarOpeningFirst ? " A session-open crossing takes precedence; when the open is between levels and both are reached, the conservative stop-first rule applies." : " Legacy policy 2 gives the stop precedence whenever a daily bar reaches both levels.")
        }
        return run.measurementPolicy == .nextTradingDateSessions
            ? "\(run.horizon.rawValue) full Nasdaq sessions, starting at the next trading-date open."
            : "Legacy schedule: the \(run.horizon.rawValue)th close after completion; a still-future completion-day close counted, so the opening benchmark may cover one fewer session."
    }

    /// Whole verified comparison dates, never adjacent-row positions or a weekday-only guess.
    private nonisolated static func comparisonSessionDates(from start: Date, through target: Date) -> [Date]? {
        let calendar = calendar
        let last = calendar.startOfDay(for: target)
        guard validDate(start), validDate(target), start == calendar.startOfDay(for: start), start < last else { return nil }
        var dates: [Date] = []
        for offset in 0..<45 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start), day <= last,
                  let schedule = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            if schedule.trading {
                guard dates.count < 14 else { return nil }
                dates.append(day)
            }
            if day == last { return dates.first == start && dates.last == last ? dates : nil }
        }
        return nil
    }

    nonisolated static func seventhSessionClose(in evaluation: Evaluation, for run: Run) -> DailyClose? {
        guard let target = targetClose(after: run.completedAt, horizon: .week, policy: run.measurementPolicy) else { return nil }
        return evaluation.dailyCloses?.first { calendar.isDate($0.date, inSameDayAs: target) }
    }

    private nonisolated static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0..<253_402_300_800).contains(date.timeIntervalSince1970)
    }
    nonisolated static func valid(_ run: Run) -> Bool {
        guard validDate(run.startedAt), validDate(run.completedAt), run.startedAt <= run.completedAt,
              run.predictions.count <= 5, Set(run.predictions.map(\.symbol)).count == run.predictions.count,
              run.coverage.requested >= 0, run.coverage.checked == run.coverage.requested,
              (0...run.coverage.checked).contains(run.coverage.incomplete),
              (0...run.coverage.checked - run.coverage.incomplete).contains(run.coverage.buyCount) else { return false }
        if let qualified = run.coverage.qualifiedBuyCount {
            guard (0...run.coverage.buyCount).contains(qualified) else { return false }
        }
        if let visible = run.deterministicRanking {
            guard StockSageTopFiveRanking.valid(visible), visible.horizon == run.horizon.title,
                  let clock = visible.scoredAt, validDate(clock), clock >= run.startedAt, clock <= run.completedAt,
                  visible.ranked.count <= run.coverage.checked - run.coverage.incomplete else { return false }
        }
        if let ranking = run.ranking {
            guard run.rankingFailure == nil, StockSageResearchRanking.valid(ranking),
                  StockSageResearchRanking.supports(version: ranking.version,
                    strictQualification: run.coverage.qualifiedBuyCount != nil),
                  ranking.horizon == run.horizon.title,
                  ranking.symbols == run.predictions.map(\.symbol),
                  ranking.candidateSymbols.count == (run.coverage.qualifiedBuyCount ?? run.coverage.buyCount),
                  validDate(ranking.at), ranking.at >= run.startedAt, ranking.at <= run.completedAt else { return false }
        } else if let failure = run.rankingFailure {
            guard !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  run.predictions.isEmpty else { return false }
        } else {
            // Older runs retain their original order. A new unfinished comparison with buys
            // has no predictions, so it cannot masquerade as a complete legacy snapshot.
            guard run.coverage.qualifiedBuyCount == nil,
                  run.predictions.count == min(5, run.coverage.buyCount) else { return false }
        }
        for prediction in run.predictions {
            guard !prediction.symbol.isEmpty, !prediction.name.isEmpty,
                  prediction.action == "Buy" || prediction.action == "Strong Buy",
                  (prediction.referencePrice == nil) == (prediction.referenceDate == nil) else { return false }
            guard validEvidence(prediction.evidenceReceipt, profile: prediction.inferenceProfile,
                model: prediction.model, symbol: prediction.symbol, factCount: prediction.facts.count,
                citations: prediction.evidence) else { return false }
            if let qualification = prediction.qualification {
                guard let evidence = prediction.evidenceReceipt,
                      qualification.originalAction == prediction.action,
                      qualification.capturedAt <= run.completedAt, qualification.evidenceAsOf <= run.completedAt,
                      Set(qualification.candidateCatalysts.map(\.key)).isSubset(of: Set(evidence.offeredKeys)),
                      StockSageResearchQualification.valid(qualification, symbol: prediction.symbol,
                        horizon: run.horizon.title, at: qualification.capturedAt, citedKeys: evidence.citedKeys) else { return false }
            }
            if let quality = prediction.qualityReport,
               !quality.valid(action: prediction.action, evidenceCount: prediction.evidence.count, factCount: prediction.facts.count) { return false }
            if let classes = prediction.factClasses, classes.count != prediction.facts.count { return false }
            guard validInsiderEvidence(prediction.insiderEvidence, coverage: prediction.insiderCoverage,
                symbol: prediction.symbol, through: run.completedAt) else { return false }
            if let price = prediction.referencePrice, let date = prediction.referenceDate {
                guard price.isFinite, price > 0, validDate(date), date <= run.completedAt else { return false }
            }
            if let levels = prediction.levels {
                guard [levels.entry, levels.stop, levels.target].allSatisfy({ $0.isFinite && $0 > 0 }),
                      validDate(levels.at), levels.at <= run.completedAt else { return false }
            }
        }
        if let selection = run.coverage.selection {
            guard validDate(selection.requestedAt), selection.requestedAt <= run.completedAt,
                  selection.returnedCount >= 0, selection.eligibleCount >= 0, selection.directoryCount >= 0,
                  selection.dollarVolume.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        }
        guard (run.reviewProgress ?? [:]).allSatisfy({ symbol, progress in
            guard run.predictions.contains(where: { $0.symbol == symbol }), validDate(progress.checkedAt),
                  progress.checkedAt >= run.completedAt else { return false }
            guard let through = progress.verifiedThrough else { return true }
            guard run.usesDailyBarFirstHit, validDate(through),
                  let first = benchmarkDay(after: run.completedAt),
                  let settled = settledReviewDate(for: run, now: progress.checkedAt) else { return false }
            return through >= first && through <= settled && calendar.startOfDay(for: through) == through
                && StockSageMarketHours.nasdaqDay(at: through)?.trading == true
        }) else { return false }
        return run.evaluations.allSatisfy { symbol, evaluation in
            guard run.predictions.contains(where: { $0.symbol == symbol }) else { return false }
            return valid(evaluation, run: run, symbol: symbol)
        }
    }
    private nonisolated static func valid(_ evaluation: Evaluation, run: Run, symbol: String) -> Bool {
        guard run.outcomePolicy == nil else { return validFirstHit(evaluation, run: run, symbol: symbol) }
        // An endpoint-policy receipt never carries a terminal field; new keys stay absent.
        guard evaluation.terminalKind == nil, evaluation.terminalAt == nil, evaluation.outcomePrice == nil,
              evaluation.adjustmentRatio == nil, evaluation.adjustedEntry == nil, evaluation.adjustedStop == nil,
              evaluation.adjustedTarget == nil, evaluation.dailyBars == nil,
              evaluation.sameBarStopFirst == nil else { return false }
        // Read old receipts against their captured schedule, not a future calendar revision.
        guard validDate(evaluation.checkedAt), evaluation.checkedAt >= run.completedAt,
              !evaluation.calendarBasis.isEmpty else { return false }
        if let target = evaluation.targetCloseAt {
            guard validDate(target), target > run.completedAt else { return false }
        } else if evaluation.state != .dataUnavailable { return false }
        if let fetched = evaluation.fetchedAt {
            guard validDate(fetched), fetched <= evaluation.checkedAt else { return false }
        }
        guard evaluation.state == .evaluated else {
            if evaluation.state == .notDue {
                guard let target = evaluation.targetCloseAt,
                      let availableAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target)),
                      evaluation.checkedAt < availableAt else { return false }
            } else if evaluation.state == .due {
                guard let target = evaluation.targetCloseAt,
                      let availableAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target)),
                      evaluation.checkedAt >= availableAt else { return false }
            }
            return evaluation.comparisonReferenceDate == nil && evaluation.comparisonReferencePrice == nil && evaluation.targetPrice == nil
                && evaluation.priceReturn == nil && evaluation.direction == nil && evaluation.buyDirectionSupported == nil
                && evaluation.dailyCloses == nil
        }
        guard let target = evaluation.targetCloseAt,
              let availableAt = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target)),
              evaluation.checkedAt >= availableAt,
              let fetched = evaluation.fetchedAt, fetched >= availableAt, evaluation.provider?.isEmpty == false,
              let baseline = evaluation.comparisonReferencePrice, baseline.isFinite, baseline > 0,
              let targetPrice = evaluation.targetPrice, targetPrice.isFinite, targetPrice > 0,
              let change = evaluation.priceReturn, change.isFinite, change == targetPrice / baseline - 1,
              let referenceDate = evaluation.comparisonReferenceDate, validDate(referenceDate) else { return false }
        guard referenceDate > run.completedAt, referenceDate < target,
              referenceDate == calendar.startOfDay(for: referenceDate) else { return false }
        if let path = evaluation.dailyCloses {
            guard let dates = comparisonSessionDates(from: referenceDate, through: target),
                  path.count <= 14, path.map(\.date) == dates,
                  path.allSatisfy({ $0.price.isFinite && $0.price > 0 }),
                  path.last?.price == targetPrice else { return false }
        }
        let direction: Evaluation.Direction = targetPrice == baseline ? .flat : (targetPrice > baseline ? .rose : .fell)
        return evaluation.direction == direction && evaluation.buyDirectionSupported == (direction == .flat ? nil : direction == .rose)
    }
}

// Latest checkpoints support recovery; bounded per-run archives support exact historical inspection.
extension StockSageResearchHistory {
    nonisolated static let maximumCompletedChecksBytes = 16_777_216

    nonisolated struct CompletedCheck: Codable, Equatable, Sendable {
        struct Verdict: Codable, Equatable, Sendable {
            let action: String
            let reason: String
            let risk: String
            let evidence: [String]

            var value: StockSageAIAssessment.Verdict? {
                guard let action = TradeAdvice.Action(rawValue: action) else { return nil }
                return .init(action: action, reason: reason, risk: risk, evidence: evidence)
            }
        }
        struct Reference: Codable, Equatable, Sendable { let value: Double; let at: Date }
        struct SourceCoverage: Codable, Equatable, Sendable {
            let source: String
            let state: String
            let checkedAt: Date?
        }
        let listing: StockSageHorizonResearch.Listing
        let verdict: Verdict?
        let levels: Levels?
        let referenceClose: Reference?
        let facts: [String]
        let note: String
        let at: Date
        let model: String
        let coverage: [SourceCoverage]
        let evidenceReceipt: StockSageAIAssessment.EvidenceCoverage?
        let diagnosticID: UUID?
        let diagnosticsComplete: Bool?
        var qualification: StockSageResearchQualification.Receipt? = nil
        /// Absent on every archive written before this existed; decodes as empty, never guessed.
        var insiderTransactions: [StockSageMassiveEvents.InsiderTransaction] = []
        var factClasses: [StockSageAIAssessment.FactClass] = []
        var inferenceProfile: StockSageAIAssessment.InferenceProfile? = nil
        var qualityReport: StockSageAIAssessment.QualityReport? = nil
        var insiderEvidence: StockSageMassiveEvents.Observation? = nil
        var insiderCoverage: SourceCoverage? = nil
        var validationOutcome: StockSageHorizonResearch.Result.ValidationOutcome? = nil
        var validationFailure: String? = nil
        var newsCheckedAt: Date? = nil
        var newestNewsAt: Date? = nil
        var newsCheckSummary: String? = nil
        var hasRecordedInsiderTransactions: Bool { includesInsiderTransactions }

        init(listing: StockSageHorizonResearch.Listing, result: StockSageHorizonResearch.Result) {
            self.listing = listing
            verdict = result.verdict.map { .init(action: $0.action.rawValue, reason: $0.reason,
                                                  risk: $0.risk, evidence: $0.evidence) }
            levels = result.levels.map { .init(entry: $0.entry, stop: $0.stop, target: $0.target, at: $0.at, basis: $0.basis) }
            referenceClose = result.referenceClose.map { .init(value: $0.value, at: $0.at) }
            facts = result.facts; note = result.note; at = result.at; model = result.model
            coverage = result.coverage.map { .init(source: $0.source, state: $0.state.rawValue, checkedAt: $0.checkedAt) }
            evidenceReceipt = result.evidenceReceipt
            diagnosticID = result.diagnosticID; diagnosticsComplete = result.diagnosticsComplete
            qualification = result.qualification
            insiderTransactions = result.insiderTransactions
            factClasses = result.factClasses
            inferenceProfile = result.inferenceProfile; qualityReport = result.qualityReport
            insiderEvidence = result.insiderEvidence
            validationOutcome = result.validationOutcome == .unknown ? nil : result.validationOutcome
            validationFailure = result.validationFailure
            newsCheckedAt = result.newsCheckedAt; newestNewsAt = result.newestNewsAt
            newsCheckSummary = result.newsCheckSummary
            includesInsiderTransactions = result.hasRecordedInsiderTransactions
            if insiderEvidence != nil || qualityReport != nil {
                insiderCoverage = coverage.first { $0.source == StockSageMassiveEvents.Feed.insider.source }
            }
        }

        // Older checks omit this key; the first insider-aware writer also saved empty arrays.
        // Preserve both representations when reading, without reconstructing historical data.
        private var includesInsiderTransactions = true
        private enum CodingKeys: String, CodingKey {
            case listing, verdict, levels, referenceClose, facts, note, at, model, coverage
            case evidenceReceipt, diagnosticID, diagnosticsComplete, qualification, insiderTransactions
            case factClasses, inferenceProfile, qualityReport, insiderEvidence, insiderCoverage
            case validationOutcome, validationFailure, newsCheckedAt, newestNewsAt, newsCheckSummary
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            listing = try c.decode(StockSageHorizonResearch.Listing.self, forKey: .listing)
            verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
            levels = try c.decodeIfPresent(Levels.self, forKey: .levels)
            referenceClose = try c.decodeIfPresent(Reference.self, forKey: .referenceClose)
            facts = try c.decode([String].self, forKey: .facts)
            note = try c.decode(String.self, forKey: .note)
            at = try c.decode(Date.self, forKey: .at)
            model = try c.decode(String.self, forKey: .model)
            coverage = try c.decode([SourceCoverage].self, forKey: .coverage)
            evidenceReceipt = try c.decodeIfPresent(StockSageAIAssessment.EvidenceCoverage.self, forKey: .evidenceReceipt)
            diagnosticID = try c.decodeIfPresent(UUID.self, forKey: .diagnosticID)
            diagnosticsComplete = try c.decodeIfPresent(Bool.self, forKey: .diagnosticsComplete)
            qualification = try c.decodeIfPresent(StockSageResearchQualification.Receipt.self, forKey: .qualification)
            includesInsiderTransactions = c.contains(.insiderTransactions)
            insiderTransactions = includesInsiderTransactions
                ? try c.decode([StockSageMassiveEvents.InsiderTransaction].self, forKey: .insiderTransactions) : []
            factClasses = try c.decodeIfPresent([StockSageAIAssessment.FactClass].self, forKey: .factClasses) ?? []
            inferenceProfile = try c.decodeIfPresent(StockSageAIAssessment.InferenceProfile.self, forKey: .inferenceProfile)
            qualityReport = try c.decodeIfPresent(StockSageAIAssessment.QualityReport.self, forKey: .qualityReport)
            insiderEvidence = try c.decodeIfPresent(StockSageMassiveEvents.Observation.self, forKey: .insiderEvidence)
            insiderCoverage = try c.decodeIfPresent(SourceCoverage.self, forKey: .insiderCoverage)
            validationOutcome = try c.decodeIfPresent(StockSageHorizonResearch.Result.ValidationOutcome.self, forKey: .validationOutcome)
            validationFailure = try c.decodeIfPresent(String.self, forKey: .validationFailure)
            newsCheckedAt = try c.decodeIfPresent(Date.self, forKey: .newsCheckedAt)
            newestNewsAt = try c.decodeIfPresent(Date.self, forKey: .newestNewsAt)
            newsCheckSummary = try c.decodeIfPresent(String.self, forKey: .newsCheckSummary)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(listing, forKey: .listing)
            try c.encodeIfPresent(verdict, forKey: .verdict)
            try c.encodeIfPresent(levels, forKey: .levels)
            try c.encodeIfPresent(referenceClose, forKey: .referenceClose)
            try c.encode(facts, forKey: .facts)
            try c.encode(note, forKey: .note)
            try c.encode(at, forKey: .at)
            try c.encode(model, forKey: .model)
            try c.encode(coverage, forKey: .coverage)
            try c.encodeIfPresent(evidenceReceipt, forKey: .evidenceReceipt)
            try c.encodeIfPresent(diagnosticID, forKey: .diagnosticID)
            try c.encodeIfPresent(diagnosticsComplete, forKey: .diagnosticsComplete)
            try c.encodeIfPresent(qualification, forKey: .qualification)
            if includesInsiderTransactions || !insiderTransactions.isEmpty { try c.encode(insiderTransactions, forKey: .insiderTransactions) }
            if !factClasses.isEmpty { try c.encode(factClasses, forKey: .factClasses) }
            try c.encodeIfPresent(inferenceProfile, forKey: .inferenceProfile)
            try c.encodeIfPresent(qualityReport, forKey: .qualityReport)
            try c.encodeIfPresent(insiderEvidence, forKey: .insiderEvidence)
            try c.encodeIfPresent(insiderCoverage, forKey: .insiderCoverage)
            try c.encodeIfPresent(validationOutcome, forKey: .validationOutcome)
            try c.encodeIfPresent(validationFailure, forKey: .validationFailure)
            try c.encodeIfPresent(newsCheckedAt, forKey: .newsCheckedAt)
            try c.encodeIfPresent(newestNewsAt, forKey: .newestNewsAt)
            try c.encodeIfPresent(newsCheckSummary, forKey: .newsCheckSummary)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            // Encoding-key presence is provenance, not a change to the captured evidence.
            lhs.listing == rhs.listing && lhs.verdict == rhs.verdict && lhs.levels == rhs.levels
                && lhs.referenceClose == rhs.referenceClose && lhs.facts == rhs.facts && lhs.note == rhs.note
                && lhs.at == rhs.at && lhs.model == rhs.model && lhs.coverage == rhs.coverage
                && lhs.evidenceReceipt == rhs.evidenceReceipt && lhs.diagnosticID == rhs.diagnosticID
                && lhs.diagnosticsComplete == rhs.diagnosticsComplete && lhs.qualification == rhs.qualification
                && lhs.insiderTransactions == rhs.insiderTransactions && lhs.factClasses == rhs.factClasses
                && lhs.inferenceProfile == rhs.inferenceProfile && lhs.qualityReport == rhs.qualityReport
                && lhs.insiderEvidence == rhs.insiderEvidence && lhs.insiderCoverage == rhs.insiderCoverage
                && lhs.validationOutcome == rhs.validationOutcome && lhs.validationFailure == rhs.validationFailure
                && lhs.newsCheckedAt == rhs.newsCheckedAt && lhs.newestNewsAt == rhs.newestNewsAt
                && lhs.newsCheckSummary == rhs.newsCheckSummary
        }

        var result: StockSageHorizonResearch.Result? {
            guard verdict == nil || verdict?.value != nil else { return nil }
            let sources: [StockSageHorizonResearch.EvidenceCoverage] = coverage.compactMap {
                guard let state = StockSageHorizonResearch.EvidenceCoverage.State(rawValue: $0.state) else { return nil }
                return .init(source: $0.source, state: state, checkedAt: $0.checkedAt)
            }
            guard sources.count == coverage.count else { return nil }
            return .init(verdict: verdict?.value,
                levels: levels.map { .init(entry: $0.entry, stop: $0.stop, target: $0.target, at: $0.at, basis: $0.basis) },
                facts: facts, note: note, at: at, model: model,
                validationOutcome: validationOutcome ?? .unknown, validationFailure: validationFailure,
                referenceClose: referenceClose.map { (value: $0.value, at: $0.at) }, coverage: sources,
                evidenceReceipt: evidenceReceipt, diagnosticID: diagnosticID, diagnosticsComplete: diagnosticsComplete,
                qualification: qualification, insiderTransactions: insiderTransactions, factClasses: factClasses,
                inferenceProfile: inferenceProfile, qualityReport: qualityReport, insiderEvidence: insiderEvidence,
                hasRecordedInsiderTransactions: includesInsiderTransactions,
                newsCheckedAt: newsCheckedAt, newestNewsAt: newestNewsAt, newsCheckSummary: newsCheckSummary)
        }

        var prediction: Prediction? {
            guard let verdict = verdict?.value, verdict.action == .buy || verdict.action == .strongBuy else { return nil }
            // Older checkpoints have evidence/qualification fields but their original Predictions
            // did not. Keep that original projection, rather than invalidating legacy checkpoints.
            let recorded = inferenceProfile != nil || qualityReport != nil || insiderEvidence != nil
            return .init(symbol: listing.ticker, name: listing.name, action: verdict.action.rawValue,
                reason: verdict.reason, risk: verdict.risk, evidence: verdict.evidence, facts: facts,
                model: model, note: note, referencePrice: referenceClose?.value, referenceDate: referenceClose?.at, levels: levels,
                inferenceProfile: inferenceProfile, qualityReport: qualityReport,
                evidenceReceipt: recorded ? evidenceReceipt : nil, qualification: recorded ? qualification : nil,
                factClasses: factClasses.isEmpty ? nil : factClasses,
                insiderEvidence: insiderEvidence, insiderCoverage: insiderCoverage)
        }
    }

    nonisolated struct CompletedChecks: Codable, Equatable, Sendable {
        let version: Int
        let horizon: Horizon
        let startedAt: Date
        let checks: [CompletedCheck]
        var qualificationPolicyVersion: Int? = nil
    }

    static func captureChecks(scan: StockSageHorizonResearch.Scan, horizon: StockSageHorizonResearch.Horizon,
                              startedAt: Date, completedAt: Date, capturedSince: Date? = nil) -> CompletedChecks? {
        guard Set(scan.listings.map(\.ticker)) == Set(scan.results.keys),
              scan.listings.count == scan.results.count else { return nil }
        let archive = CompletedChecks(version: 1, horizon: horizon == .week ? .week : .fortnight,
            startedAt: startedAt, checks: scan.listings.map { .init(listing: $0, result: scan.results[$0.ticker]!) },
            qualificationPolicyVersion: scan.qualificationPolicyVersion)
        guard capturedSince == nil || scan.retainedFromRunID != nil else { return nil }
        return validChecks(archive, through: completedAt, capturedSince: capturedSince) ? archive : nil
    }

    /// Pure decode of supplied bytes, not a file reader, import UI or automatic owner-data writer.
    static func decodeCapturedChecks(_ data: Data, matching original: Run) throws -> CompletedChecks {
        guard data.count <= maximumCompletedChecksBytes else { throw CocoaError(.fileReadTooLarge) }
        let archive = try JSONDecoder().decode(CompletedChecks.self, from: data)
        guard checksMatch(archive, run: original) else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }

    static func restoreChecks(_ archive: CompletedChecks, matching run: Run, capturedSince: Date? = nil) -> StockSageHorizonResearch.Scan? {
        guard checksMatch(archive, run: run, capturedSince: capturedSince) else { return nil }
        var scan = StockSageHorizonResearch.Scan()
        scan.listings = archive.checks.map(\.listing)
        scan.results = Dictionary(uniqueKeysWithValues: archive.checks.map { ($0.listing.ticker, $0.result!) })
        scan.at = archive.startedAt
        scan.retainedFromRunID = run.retainedFromRunID
        scan.qualificationPolicyVersion = archive.qualificationPolicyVersion
        scan.ranking = run.ranking; scan.rankingFailure = run.rankingFailure
        scan.deterministicRanking = run.deterministicRanking; scan.completedAt = run.completedAt
        scan.selection = run.coverage.selection.map {
            .init(session: $0.session, requestedAt: $0.requestedAt, returnedCount: $0.returnedCount,
                eligibleCount: $0.eligibleCount, directoryCount: $0.directoryCount, partialSession: $0.partialSession,
                fallback: $0.fallback, dollarVolume: $0.dollarVolume)
        }
        scan.status = "Completed checks restored from saved research; original evidence and dates retained."
        return scan
    }

    private nonisolated static func validChecks(_ archive: CompletedChecks, through completedAt: Date, capturedSince: Date? = nil) -> Bool {
        let earliest = capturedSince ?? archive.startedAt
        guard validDate(earliest), earliest <= archive.startedAt, archive.version == 1, validDate(archive.startedAt), validDate(completedAt), archive.startedAt <= completedAt,
              archive.qualificationPolicyVersion == nil || archive.qualificationPolicyVersion == 1,
              archive.checks.count <= StockSageHorizonResearch.scanLimit,
              Set(archive.checks.map { $0.listing.ticker }).count == archive.checks.count,
              let bytes = try? JSONEncoder().encode(archive), bytes.count <= maximumCompletedChecksBytes else { return false }
        return archive.checks.allSatisfy { check in
            let listing = check.listing
            guard StockSageHorizonResearch.validTicker(listing.ticker), !listing.name.isEmpty,
                  listing.active, listing.market == "stocks", listing.locale == "us", listing.type == "CS",
                  listing.primary_exchange == "XNAS", listing.currency_name?.lowercased() == "usd",
                  validDate(check.at), check.at >= earliest, check.at <= completedAt,
                  check.result != nil, check.facts.count <= 10_000, check.coverage.count <= 64,
                  check.coverage.allSatisfy({ !$0.source.isEmpty && ($0.checkedAt.map { validDate($0) && $0 <= completedAt } ?? true) }) else { return false }
            guard validEvidence(check.evidenceReceipt, profile: check.inferenceProfile,
                model: check.model, symbol: listing.ticker, factCount: check.facts.count,
                citations: check.verdict?.evidence ?? []) else { return false }
            guard check.factClasses.isEmpty || check.factClasses.count == check.facts.count else { return false }
            if let quality = check.qualityReport,
               !quality.valid(action: check.verdict?.action, evidenceCount: check.verdict?.evidence.count ?? 0, factCount: check.facts.count) { return false }
            guard validInsiderEvidence(check.insiderEvidence, coverage: check.insiderCoverage,
                symbol: listing.ticker, through: completedAt) else { return false }
            if let coverage = check.insiderCoverage,
               coverage != check.coverage.first(where: { $0.source == StockSageMassiveEvents.Feed.insider.source }) { return false }
            if let verdict = check.verdict {
                guard !verdict.reason.isEmpty, !verdict.risk.isEmpty, !verdict.evidence.isEmpty,
                      !check.model.isEmpty, check.model.utf8.count <= 512,
                      Set(verdict.evidence).count == verdict.evidence.count,
                      verdict.evidence.allSatisfy({ id in
                          guard id.first == "F", let index = Int(id.dropFirst()), id == "F\(index)" else { return false }
                          return index > 0 && index <= check.facts.count
                      }) else { return false }
                if archive.qualificationPolicyVersion == 1, check.qualification == nil { return false }
            }
            if let qualification = check.qualification {
                guard let verdict = check.verdict, let evidence = check.evidenceReceipt,
                      qualification.originalAction == verdict.action,
                      qualification.evidenceAsOf <= completedAt,
                      Set(qualification.candidateCatalysts.map(\.key)).isSubset(of: Set(evidence.offeredKeys)),
                      StockSageResearchQualification.valid(qualification, symbol: listing.ticker,
                        horizon: archive.horizon.title, at: check.at, citedKeys: evidence.citedKeys) else { return false }
            }
            guard (check.diagnosticID == nil) == (check.diagnosticsComplete == nil) else { return false }
            if let reference = check.referenceClose {
                guard reference.value.isFinite, reference.value > 0, validDate(reference.at), reference.at <= check.at else { return false }
            }
            if let levels = check.levels {
                guard [levels.entry, levels.stop, levels.target].allSatisfy({ $0.isFinite && $0 > 0 }),
                      validDate(levels.at), levels.at <= check.at else { return false }
            }
            return true
        }
    }

    private nonisolated static func validEvidence(_ receipt: StockSageAIAssessment.EvidenceCoverage?,
        profile: StockSageAIAssessment.InferenceProfile?, model: String, symbol: String,
        factCount: Int, citations: [String]) -> Bool {
        if let profile {
            guard profile.valid(model: model), profile.packetDigest == receipt?.packetDigest,
                  profile.packetVersion == receipt?.packetVersion else { return false }
        }
        guard let receipt else { return true }
        let offered = Set(receipt.offeredKeys), required = Set(receipt.requiredKeys)
        let omitted = Set(receipt.omittedKeys), missing = Set(receipt.missingOrUnknownRequiredKeys)
        let cited = Set(receipt.citedKeys), keys = receipt.offeredKeys + receipt.omittedKeys
        let expectedCited = citations.compactMap { id -> String? in
            guard id.first == "F", let index = Int(id.dropFirst()), id == "F\(index)",
                  index > 0, index <= receipt.offeredKeys.count else { return nil }
            return receipt.offeredKeys[index - 1]
        }
        return receipt.symbol == symbol && receipt.offeredKeys.count == factCount
            && keys.count <= 20_000 && keys.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            && offered.count == receipt.offeredKeys.count && omitted.count == receipt.omittedKeys.count
            && required.count == receipt.requiredKeys.count && missing.count == receipt.missingOrUnknownRequiredKeys.count
            && cited.count == receipt.citedKeys.count && required.isSubset(of: offered) && missing.isSubset(of: required)
            && offered.isDisjoint(with: omitted) && cited == Set(expectedCited) && expectedCited.count == citations.count
            && (0...1_000_000).contains(receipt.prePromptOmittedRecordCount)
    }

    private nonisolated static func validInsiderEvidence(_ evidence: StockSageMassiveEvents.Observation?,
        coverage: CompletedCheck.SourceCoverage?, symbol: String, through: Date) -> Bool {
        if let coverage {
            guard coverage.source == StockSageMassiveEvents.Feed.insider.source,
                  StockSageHorizonResearch.EvidenceCoverage.State(rawValue: coverage.state) != nil,
                  coverage.checkedAt.map({ validDate($0) && $0 <= through }) ?? true else { return false }
        }
        guard let evidence else { return true }
        guard evidence.symbol == symbol, evidence.feed == .insider,
              validDate(evidence.checkedAt), evidence.checkedAt <= through,
              coverage?.checkedAt == evidence.checkedAt,
              evidence.insiderOmittedRecordCount.map({ (0...1_000).contains($0) }) ?? true else { return false }
        switch evidence.outcome {
        case .unavailable:
            guard evidence.event == nil, evidence.insiderEvents == nil, evidence.insiderOmittedRecordCount == nil,
                  coverage?.state == "unavailable" || coverage?.state == "stale" else { return false }
        case .answered:
            guard coverage?.state == "answered" || coverage?.state == "stale" else { return false }
        }
        if let events = evidence.insiderEvents {
            guard events.first == evidence.event, evidence.insiderOmittedRecordCount != nil else { return false }
        } else if evidence.insiderOmittedRecordCount != nil { return false }
        let events = evidence.insiderEvents ?? evidence.event.map { [$0] } ?? []
        guard events.count <= StockSageMassiveEvents.insiderRecordLimit,
              Set(events.map(\.insiderIdentity)).count == events.count else { return false }
        return events.allSatisfy { event in
            guard event.symbol == symbol, event.feed == .insider, !event.id.isEmpty,
                  validDate(event.date), event.date <= through,
                  event.link.map({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) ?? true else { return false }
            guard let transaction = event.insider else { return true }
            return validDate(transaction.transactionDate) && validDate(transaction.filingDate)
                && transaction.transactionDate <= transaction.filingDate && transaction.filingDate <= through
                && !transaction.ownerName.isEmpty && transaction.shares.isFinite && transaction.shares > 0
                && (transaction.pricePerShare.map { $0.isFinite && $0 >= 0 } ?? true)
                && (transaction.reportedNotionalUSD.map { $0.isFinite && $0 >= 0 } ?? true)
        }
    }

    /// A complete archive and its small Run receipt must agree exactly, including selected facts.
    private nonisolated static func checksMatch(_ archive: CompletedChecks, run: Run, capturedSince: Date? = nil) -> Bool {
        guard capturedSince == nil || run.retainedFromRunID != nil,
              Self.valid(run), validChecks(archive, through: run.completedAt, capturedSince: capturedSince), archive.horizon == run.horizon,
              archive.startedAt == run.startedAt, archive.checks.count == run.coverage.requested,
              run.coverage.checked == archive.checks.count,
              archive.checks.filter({ $0.verdict == nil }).count == run.coverage.incomplete,
              archive.checks.filter({ $0.prediction != nil }).count == run.coverage.buyCount else { return false }
        let strict = archive.qualificationPolicyVersion == 1
        guard strict == (run.coverage.qualifiedBuyCount != nil) else { return false }
        let eligible = archive.checks.filter { $0.prediction != nil && (!strict || $0.qualification?.isQualified == true) }
        if strict, run.coverage.qualifiedBuyCount != eligible.count { return false }
        let bySymbol = Dictionary(uniqueKeysWithValues: archive.checks.map { ($0.listing.ticker, $0) })
        if let selection = run.coverage.selection, Set(selection.dollarVolume.keys) != Set(bySymbol.keys) { return false }
        if let ranking = run.ranking,
           Set(ranking.candidateSymbols) != Set(eligible.map { $0.listing.ticker }) { return false }
        if let visible = run.deterministicRanking {
            guard let clock = visible.scoredAt, archive.checks.allSatisfy({ $0.at <= clock }),
                  StockSageTopFiveRanking.capture(listings: archive.checks.map(\.listing),
                    results: Dictionary(uniqueKeysWithValues: archive.checks.map { ($0.listing.ticker, $0.result!) }),
                    horizon: run.horizon == .week ? .week : .fortnight, at: clock) == visible else { return false }
        }
        let eligibleSymbols = Set(eligible.map { $0.listing.ticker })
        return run.predictions.allSatisfy { eligibleSymbols.contains($0.symbol) && bySymbol[$0.symbol]?.prediction == $0 }
    }

    nonisolated struct Amendment: Codable, Equatable, Sendable {
        let sourceRunID: UUID
        /// Only overwritten failures; unchanged rows already remain in completedChecks.
        let previousFailures: [CompletedCheck]
        let sourceChecksDigest: String
    }

    nonisolated struct CompletedCheckpoint: Codable, Equatable, Sendable {
        let version: Int
        let run: Run
        let completedChecks: CompletedChecks
        let amendment: Amendment?
        /// Newest to oldest; keeps each prior overwritten failure without duplicating full scans.
        let previousAmendments: [Amendment]?

        init(version: Int, run: Run, completedChecks: CompletedChecks, amendment: Amendment? = nil,
             previousAmendments: [Amendment]? = nil) {
            self.version = version; self.run = run; self.completedChecks = completedChecks; self.amendment = amendment
            self.previousAmendments = previousAmendments
        }
    }

    private nonisolated static func checksDigest(_ archive: CompletedChecks) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(archive)).map { String(format: "%02x", $0) }.joined()
    }

    /// Repeated repairs retain older completed captures. Every parent starts strictly earlier.
    private nonisolated static func retainedCaptureStart(_ run: Run, in runs: [Run]) -> Date? {
        guard run.retainedFromRunID != nil else { return run.startedAt }
        var current = run
        var visited: Set<UUID> = [run.id]
        while let sourceID = current.retainedFromRunID {
            guard visited.insert(sourceID).inserted, let source = runs.first(where: { $0.id == sourceID }),
                  source.startedAt < current.startedAt, source.completedAt <= current.startedAt else { return nil }
            current = source
        }
        return current.startedAt
    }

    private nonisolated static func validCheckpoint(_ checkpoint: CompletedCheckpoint, in runs: [Run]) -> Bool {
        var run = checkpoint.run
        var archive = checkpoint.completedChecks
        let older = checkpoint.previousAmendments ?? []
        guard older.count < StockSageHorizonResearch.scanLimit,
              checkpoint.version == 1, valid(run), validOriginalLink(run, in: runs),
              let start = retainedCaptureStart(run, in: runs),
              checksMatch(archive, run: run, capturedSince: run.retainedFromRunID == nil ? nil : start) else { return false }
        guard let immediate = checkpoint.amendment else { return run.retainedFromRunID == nil && older.isEmpty }
        // Reconstruct and verify every generation. Missing or extra receipts cannot silently
        // erase an earlier failure or change a previously completed, nonselected result.
        for receipt in [immediate] + older {
            guard let sourceID = run.retainedFromRunID, receipt.sourceRunID == sourceID,
                  let source = runs.first(where: { $0.id == sourceID }),
                  valid(source), validOriginalLink(source, in: runs),
                  !receipt.previousFailures.isEmpty, receipt.previousFailures.count <= source.coverage.incomplete,
                  Set(receipt.previousFailures.map { $0.listing.ticker }).count == receipt.previousFailures.count,
                  receipt.previousFailures.allSatisfy({ $0.verdict == nil }),
                  let sourceStart = retainedCaptureStart(source, in: runs) else { return false }
            let previous = Dictionary(uniqueKeysWithValues: receipt.previousFailures.map { ($0.listing.ticker, $0) })
            guard Set(previous.keys).isSubset(of: Set(archive.checks.map { $0.listing.ticker })) else { return false }
            var original: [CompletedCheck] = []
            for check in archive.checks {
                if let failed = previous[check.listing.ticker] {
                    guard failed.listing == check.listing, failed != check, check.at >= run.startedAt else { return false }
                    original.append(failed)
                } else { original.append(check) }
            }
            let restored = CompletedChecks(version: 1, horizon: source.horizon, startedAt: source.startedAt, checks: original,
                qualificationPolicyVersion: source.coverage.qualifiedBuyCount == nil ? nil : 1)
            guard checksMatch(restored, run: source, capturedSince: source.retainedFromRunID == nil ? nil : sourceStart),
                  (try? checksDigest(restored)) == receipt.sourceChecksDigest else { return false }
            archive = restored; run = source
        }
        return run.retainedFromRunID == nil
    }

    private func checkpointURL(_ horizon: Horizon) -> URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("completed-\(horizon.rawValue).json")
    }

    private nonisolated static let maximumArchiveIndexBytes = 4_194_304
    nonisolated static let fullChecksRetentionPolicy = "Original full checks are retained without automatic expiration. Each archived capture is limited to 16 MiB; storage failures preserve existing evidence."

    nonisolated enum FullChecksState: String, Codable, Sendable {
        case available, legacyCheckpoint, missing, expired, corrupt
    }
    nonisolated struct FullChecksAvailability: Sendable {
        let runID: UUID
        let state: FullChecksState
        let checks: CompletedChecks?
        fileprivate init(runID: UUID, state: FullChecksState, checks: CompletedChecks? = nil) {
            self.runID = runID; self.state = state; self.checks = checks
        }
        var message: String {
            switch state {
            case .available: "Original full checks retained for this run."
            case .legacyCheckpoint: "Original full checks available from this run's exact recovery checkpoint. No per-run archive was recorded."
            case .missing: "Original full checks were not archived for this run. Only its saved shortlist and receipts are available; missing evidence is never reconstructed."
            case .expired: "An earlier app version expired this run's full-check archive. Its saved shortlist and outcomes remain; missing evidence is never reconstructed."
            case .corrupt: "This run's full checks could not be verified. Existing bytes are preserved; no other scan is substituted."
            }
        }
    }
    nonisolated struct FullChecksEntry: Codable {
        let runID: UUID
        var completedAt: Date
        let byteCount: Int
        let digest: String
        var expired = false
    }
    private struct FullChecksIndex: Codable {
        var version = 1
        var entries: [FullChecksEntry] = []
    }
    private struct FullChecksFile: Codable {
        var version = 1
        let runID: UUID
        let checks: CompletedChecks
    }

    private var fullChecksDirectory: URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("full-checks", isDirectory: true)
    }
    private func fullChecksURL(_ id: UUID) -> URL? {
        fullChecksDirectory?.appendingPathComponent(id.uuidString + ".json")
    }
    private func archivePathExists(_ url: URL) -> Bool {
        // attributes also sees a dangling symlink; it must not masquerade as a missing archive.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private func boundedArchiveBytes(_ url: URL, maximum: Int) throws -> Data {
        guard StockSageRecordWriter.mayRead(defaults) else { throw CocoaError(.fileReadNoPermission) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximum) else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
    private func readFullChecksIndex() throws -> FullChecksIndex {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        let index: FullChecksIndex
        if let url = fullChecksDirectory?.appendingPathComponent("index.json") {
            guard StockSageRecordWriter.mayRead(defaults) else { throw CocoaError(.fileReadNoPermission) }
            guard archivePathExists(url) else { return FullChecksIndex() }
            index = try JSONDecoder().decode(FullChecksIndex.self,
                from: boundedArchiveBytes(url, maximum: Self.maximumArchiveIndexBytes))
        } else { index = archiveIndexMemory }
        guard index.version == 1, Set(index.entries.map(\.runID)).count == index.entries.count,
              index.entries.allSatisfy({ Self.validDate($0.completedAt) && (1...Self.maximumCompletedChecksBytes).contains($0.byteCount)
                && $0.digest.count == 64 && $0.digest.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return index
    }
    private nonisolated static func archiveDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func checkedArchiveBytes(_ entry: FullChecksEntry) throws -> Data {
        let data: Data
        if let url = fullChecksURL(entry.runID) {
            data = try boundedArchiveBytes(url, maximum: Self.maximumCompletedChecksBytes)
        } else {
            guard let stored = archiveMemory[entry.runID] else { throw CocoaError(.fileReadNoSuchFile) }
            data = stored
        }
        guard data.count == entry.byteCount, Self.archiveDigest(data) == entry.digest else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    /// Separate from the mutable ranking receipt: a run ID can never acquire different check bytes.
    private func retainFullChecks(_ checkpoint: CompletedCheckpoint) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(FullChecksFile(runID: checkpoint.run.id, checks: checkpoint.completedChecks))
        guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let digest = Self.archiveDigest(bytes)
        let indexURL = fullChecksDirectory?.appendingPathComponent("index.json")
        var lease: StockSageFileLock?
        if let indexURL {
            try StockSageRecordWriter.require(defaults)
            lease = try StockSageFileLock(url: indexURL.appendingPathExtension("lock"))
        }
        defer { withExtendedLifetime(lease) {} }
        var index = try readFullChecksIndex()
        if let position = index.entries.firstIndex(where: { $0.runID == checkpoint.run.id }) {
            let existing = index.entries[position]
            guard existing.digest == digest, existing.byteCount == bytes.count else { throw CocoaError(.fileWriteInvalidFileName) }
            if existing.expired { return } // Preserve the honest availability recorded by earlier versions.
            guard try checkedArchiveBytes(existing) == bytes else { throw CocoaError(.fileReadCorruptFile) }
            index.entries[position].completedAt = max(existing.completedAt, checkpoint.run.completedAt)
        } else {
            // An interrupted index write may leave this exact file; any differing bytes are preserved.
            if let url = fullChecksURL(checkpoint.run.id), archivePathExists(url) {
                guard try boundedArchiveBytes(url, maximum: Self.maximumCompletedChecksBytes) == bytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            index.entries.append(.init(runID: checkpoint.run.id, completedAt: checkpoint.run.completedAt,
                byteCount: bytes.count, digest: digest))
        }
        let indexBytes = try encoder.encode(index)
        // The index remains an input trust boundary. Exhaustion fails the new save without
        // expiring, truncating or deleting any previously retained product evidence.
        guard indexBytes.count <= Self.maximumArchiveIndexBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        if let indexURL, let url = fullChecksURL(checkpoint.run.id) {
            if !archivePathExists(url) {
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            }
            try indexBytes.write(to: indexURL, options: [.atomic, .completeFileProtection])
        } else {
            archiveMemory[checkpoint.run.id] = bytes
            archiveIndexMemory = index
        }
        cacheSearchIdentities(checkpoint.completedChecks, runID: checkpoint.run.id)
    }

    private func cacheSearchIdentities(_ checks: CompletedChecks, runID: UUID) {
        fullCheckSearchIdentities[runID] = checks.checks.flatMap { [$0.listing.ticker, $0.listing.name] }
    }

    /// Searches every preserved checked listing, including failed gates and non-Buy opinions.
    /// No missing archive is reconstructed from another run or from current provider data.
    func matchesSearch(_ query: String, in run: Run) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if run.predictions.contains(where: { $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) })
            || run.deterministicRanking?.ranked.contains(where: { $0.symbol.localizedCaseInsensitiveContains(query) }) == true { return true }
        if fullCheckSearchIdentities[run.id] == nil {
            if let checks = fullChecks(runID: run.id).checks { cacheSearchIdentities(checks, runID: run.id) }
            else { fullCheckSearchIdentities[run.id] = [] }
        }
        return fullCheckSearchIdentities[run.id]?.contains { $0.localizedCaseInsensitiveContains(query) } == true
    }

    func fullChecks(runID: UUID) -> FullChecksAvailability {
        do {
            guard readable else { throw CocoaError(.fileReadNoPermission) }
            let current = storageURL == nil ? runs : try read().runs
            guard let run = current.first(where: { $0.id == runID }) else { return .init(runID: runID, state: .missing) }
            let index = try readFullChecksIndex()
            if let entry = index.entries.first(where: { $0.runID == runID }) {
                guard !entry.expired else { return .init(runID: runID, state: .expired) }
                let file = try JSONDecoder().decode(FullChecksFile.self, from: checkedArchiveBytes(entry))
                guard file.version == 1, file.runID == runID,
                      let start = Self.retainedCaptureStart(run, in: current),
                      Self.checksMatch(file.checks, run: run, capturedSince: run.retainedFromRunID == nil ? nil : start) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                cacheSearchIdentities(file.checks, runID: runID)
                return .init(runID: runID, state: .available, checks: file.checks)
            }
            if let url = checkpointURL(run.horizon), archivePathExists(url) {
                _ = try boundedArchiveBytes(url, maximum: Self.maximumCompletedChecksBytes)
            }
            if let legacy = try readCheckpoint(run.horizon), legacy.run.id == runID,
               let start = Self.retainedCaptureStart(run, in: current),
               Self.checksMatch(legacy.completedChecks, run: run, capturedSince: run.retainedFromRunID == nil ? nil : start) {
                cacheSearchIdentities(legacy.completedChecks, runID: runID)
                return .init(runID: runID, state: .legacyCheckpoint, checks: legacy.completedChecks)
            }
            return .init(runID: runID, state: .missing)
        } catch { return .init(runID: runID, state: .corrupt) }
    }

    /// Progress is deliberately a separate file/type: it is never a completed prediction Run.
    nonisolated struct InterruptedCheckpoint: Codable, Equatable, Sendable {
        let version: Int
        let updatedAt: Date
        let listings: [StockSageHorizonResearch.Listing]
        let selection: SelectionReceipt?
        let completedChecks: CompletedChecks
        let configurationID: String?
    }

    /// Only the digest is persisted. Endpoint credentials, query strings and settings stay private.
    nonisolated static func configurationIdentity(_ config: StockSageLocalModelServer.Config) -> String {
        let bytes = (try? JSONEncoder().encode([config.baseURL.absoluteString, config.model])) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func interruptedURL(_ horizon: Horizon) -> URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("interrupted-\(horizon.rawValue).json")
    }

    private nonisolated static func validInterrupted(_ checkpoint: InterruptedCheckpoint) -> Bool {
        let archive = checkpoint.completedChecks
        let symbols = checkpoint.listings.map(\.ticker)
        guard checkpoint.version == 1, validDate(checkpoint.updatedAt),
              symbols.count <= StockSageHorizonResearch.scanLimit, Set(symbols).count == symbols.count,
              validChecks(archive, through: checkpoint.updatedAt),
              archive.checks.count <= symbols.count,
              checkpoint.configurationID.map({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) ?? true,
              checkpoint.listings.allSatisfy({ listing in
                  StockSageHorizonResearch.validTicker(listing.ticker) && !listing.name.isEmpty
                    && listing.active && listing.market == "stocks" && listing.locale == "us"
                    && listing.type == "CS" && listing.primary_exchange == "XNAS"
                    && listing.currency_name?.lowercased() == "usd"
              }) else { return false }
        let bySymbol = Dictionary(uniqueKeysWithValues: checkpoint.listings.map { ($0.ticker, $0) })
        let capturedSymbols = Set(archive.checks.map(\.listing.ticker))
        guard archive.checks.allSatisfy({ bySymbol[$0.listing.ticker] == $0.listing }),
              archive.checks.map(\.listing.ticker) == symbols.filter(capturedSymbols.contains) else { return false }
        if let selection = checkpoint.selection {
            guard validDate(selection.requestedAt), selection.requestedAt <= checkpoint.updatedAt,
                  selection.returnedCount >= 0, selection.eligibleCount >= symbols.count,
                  selection.directoryCount >= symbols.count,
                  Set(selection.dollarVolume.keys) == Set(symbols),
                  selection.dollarVolume.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        }
        return true
    }

    private func readInterrupted(_ horizon: Horizon) throws -> InterruptedCheckpoint? {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        let checkpoint: InterruptedCheckpoint
        if let url = interruptedURL(horizon) {
            guard StockSageRecordWriter.mayRead(defaults) else { throw CocoaError(.fileReadNoPermission) }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.int64Value <= Int64(Self.maximumCompletedChecksBytes) else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileReadTooLarge) }
            checkpoint = try JSONDecoder().decode(InterruptedCheckpoint.self, from: bytes)
        } else {
            guard let saved = interruptedMemory[horizon] else { return nil }
            checkpoint = saved
        }
        guard checkpoint.completedChecks.horizon == horizon, Self.validInterrupted(checkpoint) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return checkpoint
    }

    @discardableResult func saveInterruptedChecks(_ scan: StockSageHorizonResearch.Scan,
                                                   horizon: StockSageHorizonResearch.Horizon) -> Bool {
        do {
            guard let started = scan.at, scan.retainedFromRunID == nil,
                  Set(scan.results.keys).isSubset(of: Set(scan.listings.map(\.ticker))) else { throw CocoaError(.fileWriteInvalidFileName) }
            let h: Horizon = horizon == .week ? .week : .fortnight
            let archive = CompletedChecks(version: 1, horizon: h, startedAt: started,
                checks: scan.listings.compactMap { listing in scan.results[listing.ticker].map { CompletedCheck(listing: listing, result: $0) } },
                qualificationPolicyVersion: scan.qualificationPolicyVersion)
            let selection = scan.selection.map { SelectionReceipt(session: $0.session, requestedAt: $0.requestedAt,
                returnedCount: $0.returnedCount, eligibleCount: $0.eligibleCount, directoryCount: $0.directoryCount,
                partialSession: $0.partialSession, fallback: $0.fallback, dollarVolume: $0.dollarVolume) }
            let checkpoint = InterruptedCheckpoint(version: 1, updatedAt: Date(), listings: scan.listings,
                selection: selection, completedChecks: archive, configurationID: scan.resumeConfigurationID)
            guard Self.validInterrupted(checkpoint) else { throw CocoaError(.fileWriteInvalidFileName) }
            let bytes = try JSONEncoder().encode(checkpoint)
            guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            func validateReplacement() throws {
                if let previous = try readInterrupted(h) {
                    guard started >= previous.completedChecks.startedAt else { throw CocoaError(.fileWriteInvalidFileName) }
                    if started == previous.completedChecks.startedAt {
                        let captured = Dictionary(uniqueKeysWithValues: archive.checks.map { ($0.listing.ticker, $0) })
                        guard checkpoint.listings == previous.listings, checkpoint.selection == previous.selection,
                              checkpoint.configurationID == previous.configurationID,
                              archive.qualificationPolicyVersion == previous.completedChecks.qualificationPolicyVersion,
                              previous.completedChecks.checks.allSatisfy({ captured[$0.listing.ticker] == $0 }) else {
                            throw CocoaError(.fileWriteInvalidFileName)
                        }
                    }
                }
            }
            if let url = interruptedURL(h) {
                try StockSageRecordWriter.require(defaults)
                let lease = try StockSageFileLock(url: url.appendingPathExtension("lock"))
                defer { withExtendedLifetime(lease) {} }
                try validateReplacement()
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            } else {
                try validateReplacement()
                interruptedMemory[h] = checkpoint
            }
            lastError = nil
            return true
        } catch {
            lastError = "Interrupted research could not be saved. Existing checkpoints are preserved. \(error.localizedDescription)"
            return false
        }
    }

    func interruptedScan(horizon: StockSageHorizonResearch.Horizon) -> StockSageHorizonResearch.Scan? {
        do {
            let h: Horizon = horizon == .week ? .week : .fortnight
            guard let checkpoint = try readInterrupted(h) else { return nil }
            if let completed = try readCheckpoint(h), completed.run.startedAt >= checkpoint.completedChecks.startedAt { return nil }
            var scan = StockSageHorizonResearch.Scan()
            scan.at = checkpoint.completedChecks.startedAt; scan.requestedAt = scan.at
            scan.listings = checkpoint.listings
            scan.results = Dictionary(uniqueKeysWithValues: checkpoint.completedChecks.checks.map { ($0.listing.ticker, $0.result!) })
            scan.qualificationPolicyVersion = checkpoint.completedChecks.qualificationPolicyVersion
            scan.resumeConfigurationID = checkpoint.configurationID; scan.isInterrupted = true
            scan.selection = checkpoint.selection.map { .init(session: $0.session, requestedAt: $0.requestedAt,
                returnedCount: $0.returnedCount, eligibleCount: $0.eligibleCount, directoryCount: $0.directoryCount,
                partialSession: $0.partialSession, fallback: $0.fallback, dollarVolume: $0.dollarVolume) }
            scan.status = "Interrupted research restored · \(scan.results.count)/\(scan.listings.count) checked. Original evidence and dates retained; resume remaining listings when ready."
            return scan
        } catch {
            lastError = "Interrupted research could not be restored. Original checkpoint bytes are preserved."
            return nil
        }
    }

    @discardableResult func clearInterruptedChecks(horizon: StockSageHorizonResearch.Horizon, startedAt: Date) -> Bool {
        do {
            let h: Horizon = horizon == .week ? .week : .fortnight
            if let url = interruptedURL(h) {
                try StockSageRecordWriter.require(defaults)
                let lease = try StockSageFileLock(url: url.appendingPathExtension("lock"))
                defer { withExtendedLifetime(lease) {} }
                if let saved = try readInterrupted(h), saved.completedChecks.startedAt == startedAt {
                    try FileManager.default.removeItem(at: url)
                }
            } else if interruptedMemory[h]?.completedChecks.startedAt == startedAt { interruptedMemory.removeValue(forKey: h) }
            return true
        } catch {
            lastError = "Completed research is saved, but its interrupted checkpoint could not be cleared."
            return false
        }
    }

    private func readCheckpoint(_ horizon: Horizon) throws -> CompletedCheckpoint? {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        var checkpoint: CompletedCheckpoint
        let current: [Run]
        if let url = checkpointURL(horizon) {
            guard StockSageRecordWriter.mayRead(defaults) else { throw CocoaError(.fileReadNoPermission) }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(Self.maximumCompletedChecksBytes) else {
                throw CocoaError(.fileReadTooLarge)
            }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileReadTooLarge) }
            checkpoint = try JSONDecoder().decode(CompletedCheckpoint.self, from: bytes)
            current = try read().runs
        } else {
            guard let stored = completedMemory[horizon] else { return nil }
            checkpoint = stored; current = runs
        }
        guard checkpoint.run.horizon == horizon, Self.validCheckpoint(checkpoint, in: current) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // History can be newer than its checkpoint. Recover that narrow failure window without
        // comparing an already-published prediction again or changing its original dates.
        let sourceID = checkpoint.run.originalRunID ?? checkpoint.run.id
        if let recorded = current.filter({ ($0.originalRunID ?? $0.id) == sourceID
            && $0.completedAt >= checkpoint.run.completedAt }).max(by: { $0.completedAt < $1.completedAt }) {
            checkpoint = .init(version: 1, run: recorded, completedChecks: checkpoint.completedChecks,
                amendment: checkpoint.amendment, previousAmendments: checkpoint.previousAmendments)
            guard Self.validCheckpoint(checkpoint, in: current) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return checkpoint
    }

    /// The scheduler calls this immediately after every listing has a result, BEFORE comparison.
    /// An explicit pending rankingFailure makes this a checkpoint with zero published picks.
    @discardableResult func saveCompletedChecks(_ run: Run, scan: StockSageHorizonResearch.Scan) -> Bool {
        guard readable else { return false }
        do {
            let current = storageURL == nil ? runs : try read().runs
            guard Self.valid(run), Self.validOriginalLink(run, in: current),
                  scan.retainedFromRunID == run.retainedFromRunID,
                  let start = Self.retainedCaptureStart(run, in: current),
                  let archive = Self.captureChecks(scan: scan, horizon: run.horizon == .week ? .week : .fortnight,
                    startedAt: run.startedAt, completedAt: run.completedAt, capturedSince: run.retainedFromRunID == nil ? nil : start),
                  Self.checksMatch(archive, run: run, capturedSince: run.retainedFromRunID == nil ? nil : start) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            func replacement(_ previous: CompletedCheckpoint?) throws -> CompletedCheckpoint {
                var amendment: Amendment?
                var previousAmendments: [Amendment]?
                if let previous {
                    guard run.startedAt >= previous.run.startedAt else { throw CocoaError(.fileWriteInvalidFileName) }
                    if run.startedAt == previous.run.startedAt {
                        guard run.completedAt >= previous.run.completedAt,
                              (run.originalRunID ?? run.id) == (previous.run.originalRunID ?? previous.run.id),
                              run.retainedFromRunID == previous.run.retainedFromRunID,
                              run.deterministicRanking == previous.run.deterministicRanking,
                              archive == previous.completedChecks else { throw CocoaError(.fileWriteInvalidFileName) }
                        amendment = previous.amendment
                        previousAmendments = previous.previousAmendments
                    } else if let sourceID = run.retainedFromRunID {
                        guard previous.run.id == sourceID,
                              archive.checks.map(\.listing) == previous.completedChecks.checks.map(\.listing) else {
                            throw CocoaError(.fileWriteInvalidFileName)
                        }
                        var failures: [CompletedCheck] = []
                        for (old, new) in zip(previous.completedChecks.checks, archive.checks) where old != new {
                            guard old.verdict == nil, new.at >= run.startedAt else { throw CocoaError(.fileWriteInvalidFileName) }
                            failures.append(old)
                        }
                        guard !failures.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
                        amendment = .init(sourceRunID: sourceID, previousFailures: failures,
                            sourceChecksDigest: try Self.checksDigest(previous.completedChecks))
                        if let prior = previous.amendment {
                            let retained = [prior] + (previous.previousAmendments ?? [])
                            guard retained.count < StockSageHorizonResearch.scanLimit else {
                                throw CocoaError(.fileWriteOutOfSpace)
                            }
                            previousAmendments = retained
                        }
                    }
                } else if run.retainedFromRunID != nil { throw CocoaError(.fileWriteInvalidFileName) }
                let checkpoint = CompletedCheckpoint(version: 1, run: run, completedChecks: archive,
                    amendment: amendment, previousAmendments: previousAmendments)
                guard Self.validCheckpoint(checkpoint, in: current) else { throw CocoaError(.fileWriteInvalidFileName) }
                return checkpoint
            }
            if let url = checkpointURL(run.horizon) {
                try StockSageRecordWriter.require(defaults)
                let lease = try StockSageFileLock(url: url.appendingPathExtension("lock"))
                defer { withExtendedLifetime(lease) {} }
                // An unreadable existing checkpoint is preserved. Do not overwrite it silently.
                let previous = try readCheckpoint(run.horizon)
                let checkpoint = try replacement(previous)
                let bytes = try JSONEncoder().encode(checkpoint)
                guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                if let previous { try retainFullChecks(previous) }
                try retainFullChecks(checkpoint)
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            } else {
                let previous = try readCheckpoint(run.horizon)
                let checkpoint = try replacement(previous)
                let bytes = try JSONEncoder().encode(checkpoint)
                guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                if let previous { try retainFullChecks(previous) }
                try retainFullChecks(checkpoint)
                completedMemory[run.horizon] = checkpoint
            }
            lastError = nil
            return true
        } catch {
            lastError = "Completed research checks could not be saved. Existing records are preserved. \(error.localizedDescription)"
            return false
        }
    }

    func completedScan(horizon: StockSageHorizonResearch.Horizon) -> (run: Run, scan: StockSageHorizonResearch.Scan)? {
        do {
            guard let checkpoint = try readCheckpoint(horizon == .week ? .week : .fortnight) else { return nil }
            let current = storageURL == nil ? runs : try read().runs
            guard let start = Self.retainedCaptureStart(checkpoint.run, in: current),
                  let scan = Self.restoreChecks(checkpoint.completedChecks, matching: checkpoint.run,
                    capturedSince: checkpoint.run.retainedFromRunID == nil ? nil : start) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (checkpoint.run, scan)
        } catch {
            lastError = "Saved completed checks could not be restored. Original bytes are preserved."
            return nil
        }
    }

    /// Exact original checks for this saved run; another run is never a substitute.
    func completedScan(runID: UUID) -> (run: Run, scan: StockSageHorizonResearch.Scan)? {
        guard let run = runs.first(where: { $0.id == runID }),
              let checks = fullChecks(runID: runID).checks,
              let start = Self.retainedCaptureStart(run, in: runs),
              let scan = Self.restoreChecks(checks, matching: run,
                capturedSince: run.retainedFromRunID == nil ? nil : start) else { return nil }
        return (run, scan)
    }

    /// Check under the existing history file lock on record(), and for every Run on read().
    /// Original small history records remain immutable after the latest checkpoint is replaced.
    private nonisolated static func validOriginalLink(_ run: Run, in runs: [Run]) -> Bool {
        if let retainedID = run.retainedFromRunID {
            guard retainedID != run.id, let source = runs.first(where: { $0.id == retainedID }),
                  source.horizon == run.horizon, source.startedAt < run.startedAt, source.completedAt <= run.startedAt,
                  source.coverage.incomplete > 0, run.coverage.incomplete <= source.coverage.incomplete,
                  source.coverage.requested == run.coverage.requested, source.coverage.checked == run.coverage.checked,
                  source.coverage.selection == run.coverage.selection,
                  run.coverage.buyCount >= source.coverage.buyCount,
                  run.coverage.buyCount <= source.coverage.buyCount + source.coverage.incomplete - run.coverage.incomplete else { return false }
            guard (run.coverage.qualifiedBuyCount == nil) == (source.coverage.qualifiedBuyCount == nil) else { return false }
            if let count = run.coverage.qualifiedBuyCount, let previous = source.coverage.qualifiedBuyCount {
                guard count >= previous,
                      count <= previous + source.coverage.incomplete - run.coverage.incomplete else { return false }
            }
        }
        guard let originalID = run.originalRunID else { return true }
        guard originalID != run.id, let original = runs.first(where: { $0.id == originalID }),
              original.originalRunID == nil, original.horizon == run.horizon,
              original.startedAt == run.startedAt, original.completedAt <= run.completedAt,
              original.coverage == run.coverage, original.retainedFromRunID == run.retainedFromRunID,
              original.deterministicRanking == run.deterministicRanking,
              run.ranking.map({ $0.at >= original.completedAt }) ?? true else { return false }
        return true
    }
}
