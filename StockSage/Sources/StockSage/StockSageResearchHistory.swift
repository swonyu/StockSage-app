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
        /// A later comparison of the same captured checks; original failed history is retained.
        let originalRunID: UUID?
        /// A new capture of only incomplete checks, retaining completed results from this run.
        let retainedFromRunID: UUID?
        // Only these subsequent receipts change; the original prediction fields above never do.
        var evaluations: [String: Evaluation] = [:]

        init(id: UUID, startedAt: Date, completedAt: Date, horizon: Horizon,
             predictions: [Prediction], coverage: Coverage, evaluations: [String: Evaluation] = [:],
             measurementPolicy: MeasurementPolicy? = nil,
             ranking: StockSageResearchRanking.Receipt? = nil, rankingFailure: String? = nil,
             originalRunID: UUID? = nil, retainedFromRunID: UUID? = nil) {
            self.id = id; self.startedAt = startedAt; self.completedAt = completedAt
            self.horizon = horizon; self.predictions = predictions; self.coverage = coverage
            self.evaluations = evaluations; self.measurementPolicy = measurementPolicy
            self.ranking = ranking; self.rankingFailure = rankingFailure; self.originalRunID = originalRunID
            self.retainedFromRunID = retainedFromRunID
        }
    }
    nonisolated struct DailyClose: Codable, Sendable, Equatable {
        let date: Date
        let price: Double
    }
    nonisolated struct Evaluation: Codable, Sendable, Equatable {
        enum State: String, Codable, Sendable { case notDue, due, dataUnavailable, evaluated }
        enum Direction: String, Codable, Sendable { case rose, fell, flat }
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
            guard let result = scan.results[listing.ticker], let verdict = result.verdict else { return nil }
            return Prediction(symbol: listing.ticker, name: listing.name, action: verdict.action.rawValue,
                reason: verdict.reason, risk: verdict.risk, evidence: verdict.evidence, facts: result.facts,
                model: result.model, note: result.note, referencePrice: result.referenceClose?.value,
                referenceDate: result.referenceClose?.at, levels: result.levels.map {
                    Levels(entry: $0.entry, stop: $0.stop, target: $0.target, at: $0.at, basis: $0.basis)
                })
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
                selection: selection), measurementPolicy: .nextTradingDateSessions,
            ranking: scan.ranking, rankingFailure: scan.rankingFailure, originalRunID: originalRunID,
            retainedFromRunID: scan.retainedFromRunID)
    }

    @discardableResult func record(_ run: Run) -> Bool {
        guard run.evaluations.isEmpty, Self.valid(run), run.coverage.checked == run.coverage.requested else {
            lastError = "Only a complete, valid research snapshot can be saved. Existing predictions are preserved."
            return false
        }
        return commit { document in
            guard Self.validOriginalLink(run, in: document.runs) else { throw CocoaError(.fileWriteInvalidFileName) }
            if var existing = document.runs.first(where: { $0.id == run.id }) {
                existing.evaluations = [:]
                guard existing == run else { throw CocoaError(.fileWriteInvalidFileName) }
                return // Same completion cannot overwrite later evaluations.
            }
            document.runs.insert(run, at: 0)
        }
    }

    @discardableResult func recordEvaluation(_ evaluation: Evaluation, runID: UUID, symbol: String) -> Bool {
        commit { document in
            guard let index = document.runs.firstIndex(where: { $0.id == runID }),
                  document.runs[index].predictions.contains(where: { $0.symbol == symbol }),
                  evaluation.targetCloseAt == Self.targetClose(for: document.runs[index]),
                  evaluation.calendarBasis == Self.calendarBasis(for: document.runs[index]),
                  evaluation.state != .evaluated || evaluation.comparisonReferenceDate == Self.benchmarkDay(after: document.runs[index].completedAt),
                  Self.valid(evaluation, run: document.runs[index]) else { throw CocoaError(.fileWriteInvalidFileName) }
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
                if let date = reviewAvailableAt(for: run) {
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

    /// Manual only, sequential, and bounded per press. Cancellation or a revoked policy after
    /// an await discards that response without persisting even an unavailable-data receipt.
    func checkDue(clock: @escaping @MainActor () -> Date = { Date() },
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
            let leftCheck = left.0.evaluations[left.1.symbol]?.checkedAt ?? .distantPast
            let rightCheck = right.0.evaluations[right.1.symbol]?.checkedAt ?? .distantPast
            if leftCheck != rightCheck { return leftCheck < rightCheck }
            if left.0.completedAt != right.0.completedAt { return left.0.completedAt < right.0.completedAt }
            if left.0.id != right.0.id { return left.0.id.uuidString < right.0.id.uuidString }
            return left.1.symbol < right.1.symbol
        }
        var checked = 0
        for (run, prediction) in pending.prefix(Self.maximumChecksPerRequest) {
            guard !Task.isCancelled, allowed() else { return }
            let observation = await fetch(prediction, run)
            guard !Task.isCancelled, allowed() else { return }
            let receipt = Self.evaluate(prediction, in: run, observation: observation, now: clock())
            guard recordEvaluation(receipt, runID: run.id, symbol: prediction.symbol) else { return }
            checked += 1
        }
        let remaining = pending.count - checked
        lastCheckSummary = "Checked \(checked) saved prediction\(checked == 1 ? "" : "s")."
            + (remaining > 0 ? " \(remaining) more are due; check again to continue." : "")
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
    }
    /// A provider daily close can change after the regular close. Wait until the entire
    /// target New York date has ended before accepting its completed daily aggregate.
    nonisolated static func reviewAvailableAt(for run: Run) -> Date? {
        guard let target = targetClose(for: run) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target))
    }
    nonisolated static func availability(for run: Run, now: Date) -> Evaluation {
        guard valid(run), validDate(now), now >= run.completedAt,
              let target = targetClose(for: run),
              let availableAt = reviewAvailableAt(for: run) else {
            return Evaluation(state: .dataUnavailable, checkedAt: now, targetCloseAt: nil, calendarBasis: calendarBasis(for: run),
                note: "The future Nasdaq session calendar or evaluation clock could not be verified.")
        }
        return Evaluation(state: now < availableAt ? .notDue : .due, checkedAt: now, targetCloseAt: target, calendarBasis: calendarBasis(for: run),
            note: now < availableAt ? "Waiting until the target New York date ends, so its daily aggregate is complete. " + measurementDescription(for: run)
                : "Due for a dated price-direction check. No outcome has been observed yet.")
    }
    nonisolated static func evaluate(_ prediction: Prediction, in run: Run,
                                     observation: Observation?, now: Date) -> Evaluation {
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

    nonisolated static func measurementDescription(for run: Run) -> String {
        run.measurementPolicy == .nextTradingDateSessions
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
    private nonisolated static func valid(_ run: Run) -> Bool {
        guard validDate(run.startedAt), validDate(run.completedAt), run.startedAt <= run.completedAt,
              run.predictions.count <= 5, Set(run.predictions.map(\.symbol)).count == run.predictions.count,
              run.coverage.requested >= 0, run.coverage.checked == run.coverage.requested,
              (0...run.coverage.checked).contains(run.coverage.incomplete),
              (0...run.coverage.checked - run.coverage.incomplete).contains(run.coverage.buyCount) else { return false }
        if let ranking = run.ranking {
            guard run.rankingFailure == nil, StockSageResearchRanking.valid(ranking),
                  ranking.horizon == run.horizon.title,
                  ranking.symbols == run.predictions.map(\.symbol),
                  ranking.candidateSymbols.count == run.coverage.buyCount,
                  validDate(ranking.at), ranking.at >= run.startedAt, ranking.at <= run.completedAt else { return false }
        } else if let failure = run.rankingFailure {
            guard !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  run.predictions.isEmpty else { return false }
        } else {
            // Older runs retain their original order. A new unfinished comparison with buys
            // has no predictions, so it cannot masquerade as a complete legacy snapshot.
            guard run.predictions.count == min(5, run.coverage.buyCount) else { return false }
        }
        for prediction in run.predictions {
            guard !prediction.symbol.isEmpty, !prediction.name.isEmpty,
                  prediction.action == "Buy" || prediction.action == "Strong Buy",
                  (prediction.referencePrice == nil) == (prediction.referenceDate == nil) else { return false }
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
        return run.evaluations.allSatisfy { symbol, evaluation in
            guard run.predictions.contains(where: { $0.symbol == symbol }) else { return false }
            return valid(evaluation, run: run)
        }
    }
    private nonisolated static func valid(_ evaluation: Evaluation, run: Run) -> Bool {
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

// ponytail: retain only the latest complete checks per horizon; versioned run archives if older full scans are needed.
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

        init(listing: StockSageHorizonResearch.Listing, result: StockSageHorizonResearch.Result) {
            self.listing = listing
            verdict = result.verdict.map { .init(action: $0.action.rawValue, reason: $0.reason,
                                                  risk: $0.risk, evidence: $0.evidence) }
            levels = result.levels.map { .init(entry: $0.entry, stop: $0.stop, target: $0.target, at: $0.at, basis: $0.basis) }
            referenceClose = result.referenceClose.map { .init(value: $0.value, at: $0.at) }
            facts = result.facts; note = result.note; at = result.at; model = result.model
            coverage = result.coverage.map { .init(source: $0.source, state: $0.state.rawValue, checkedAt: $0.checkedAt) }
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
                referenceClose: referenceClose.map { (value: $0.value, at: $0.at) }, coverage: sources)
        }

        var prediction: Prediction? {
            guard let verdict = verdict?.value, verdict.action == .buy || verdict.action == .strongBuy else { return nil }
            return .init(symbol: listing.ticker, name: listing.name, action: verdict.action.rawValue,
                reason: verdict.reason, risk: verdict.risk, evidence: verdict.evidence, facts: facts,
                model: model, note: note, referencePrice: referenceClose?.value, referenceDate: referenceClose?.at, levels: levels)
        }
    }

    nonisolated struct CompletedChecks: Codable, Equatable, Sendable {
        let version: Int
        let horizon: Horizon
        let startedAt: Date
        let checks: [CompletedCheck]
    }

    static func captureChecks(scan: StockSageHorizonResearch.Scan, horizon: StockSageHorizonResearch.Horizon,
                              startedAt: Date, completedAt: Date, capturedSince: Date? = nil) -> CompletedChecks? {
        guard Set(scan.listings.map(\.ticker)) == Set(scan.results.keys),
              scan.listings.count == scan.results.count else { return nil }
        let archive = CompletedChecks(version: 1, horizon: horizon == .week ? .week : .fortnight,
            startedAt: startedAt, checks: scan.listings.map { .init(listing: $0, result: scan.results[$0.ticker]!) })
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
        scan.ranking = run.ranking; scan.rankingFailure = run.rankingFailure
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
            if let verdict = check.verdict {
                guard !verdict.reason.isEmpty, !verdict.risk.isEmpty, !verdict.evidence.isEmpty,
                      !check.model.isEmpty, check.model.utf8.count <= 512,
                      Set(verdict.evidence).count == verdict.evidence.count,
                      verdict.evidence.allSatisfy({ id in
                          guard id.first == "F", let index = Int(id.dropFirst()), id == "F\(index)" else { return false }
                          return index > 0 && index <= check.facts.count
                      }) else { return false }
            }
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

    /// A complete archive and its small Run receipt must agree exactly, including selected facts.
    private nonisolated static func checksMatch(_ archive: CompletedChecks, run: Run, capturedSince: Date? = nil) -> Bool {
        guard capturedSince == nil || run.retainedFromRunID != nil,
              Self.valid(run), validChecks(archive, through: run.completedAt, capturedSince: capturedSince), archive.horizon == run.horizon,
              archive.startedAt == run.startedAt, archive.checks.count == run.coverage.requested,
              run.coverage.checked == archive.checks.count,
              archive.checks.filter({ $0.verdict == nil }).count == run.coverage.incomplete,
              archive.checks.filter({ $0.prediction != nil }).count == run.coverage.buyCount else { return false }
        let bySymbol = Dictionary(uniqueKeysWithValues: archive.checks.map { ($0.listing.ticker, $0) })
        if let selection = run.coverage.selection, Set(selection.dollarVolume.keys) != Set(bySymbol.keys) { return false }
        if let ranking = run.ranking,
           Set(ranking.candidateSymbols) != Set(archive.checks.filter { $0.prediction != nil }.map { $0.listing.ticker }) { return false }
        return run.predictions.allSatisfy { bySymbol[$0.symbol]?.prediction == $0 }
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
            let restored = CompletedChecks(version: 1, horizon: source.horizon, startedAt: source.startedAt, checks: original)
            guard checksMatch(restored, run: source, capturedSince: source.retainedFromRunID == nil ? nil : sourceStart),
                  (try? checksDigest(restored)) == receipt.sourceChecksDigest else { return false }
            archive = restored; run = source
        }
        return run.retainedFromRunID == nil
    }

    private func checkpointURL(_ horizon: Horizon) -> URL? {
        storageURL?.deletingLastPathComponent().appendingPathComponent("completed-\(horizon.rawValue).json")
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
                let checkpoint = try replacement(readCheckpoint(run.horizon))
                let bytes = try JSONEncoder().encode(checkpoint)
                guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            } else {
                let checkpoint = try replacement(readCheckpoint(run.horizon))
                let bytes = try JSONEncoder().encode(checkpoint)
                guard bytes.count <= Self.maximumCompletedChecksBytes else { throw CocoaError(.fileWriteOutOfSpace) }
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
        }
        guard let originalID = run.originalRunID else { return true }
        guard originalID != run.id, let original = runs.first(where: { $0.id == originalID }),
              original.originalRunID == nil, original.horizon == run.horizon,
              original.startedAt == run.startedAt, original.completedAt <= run.completedAt,
              original.coverage == run.coverage, original.retainedFromRunID == run.retainedFromRunID,
              run.ranking.map({ $0.at >= original.completedAt }) ?? true else { return false }
        return true
    }
}
