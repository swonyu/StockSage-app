import Foundation
import Combine

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
        // Only these subsequent receipts change; the original prediction fields above never do.
        var evaluations: [String: Evaluation] = [:]
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
                         scan: StockSageHorizonResearch.Scan) -> Run {
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
                selection: selection))
    }

    @discardableResult func record(_ run: Run) -> Bool {
        guard run.evaluations.isEmpty, Self.valid(run), run.coverage.checked == run.coverage.requested else {
            lastError = "Only a complete, valid research snapshot can be saved. Existing predictions are preserved."
            return false
        }
        return commit { document in
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
                  evaluation.targetCloseAt == Self.targetClose(after: document.runs[index].completedAt,
                      horizon: document.runs[index].horizon),
                  evaluation.calendarBasis == Self.benchmarkCalendarBasis,
                  evaluation.state != .evaluated || evaluation.comparisonReferenceDate == Self.benchmarkDay(after: document.runs[index].completedAt),
                  Self.valid(evaluation, run: document.runs[index]) else { throw CocoaError(.fileWriteInvalidFileName) }
            if let old = document.runs[index].evaluations[symbol] {
                guard evaluation.checkedAt >= old.checkedAt else { throw CocoaError(.fileWriteInvalidFileName) }
                // A failed retry does not erase an already observed outcome.
                if old.state == .evaluated && evaluation.state != .evaluated { return }
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
              document.runs.allSatisfy(Self.valid) else { throw CocoaError(.fileReadCorruptFile) }
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
    /// Count CLOSE instants strictly after completion: today's close counts only when still future.
    /// Calendar-day arithmetic preserves DST and the verified exchange calendar handles half days.
    nonisolated static func targetClose(after completedAt: Date, horizon: Horizon) -> Date? {
        guard validDate(completedAt) else { return nil }
        let calendar = calendar
        let firstDay = calendar.startOfDay(for: completedAt)
        var remaining = horizon.rawValue
        for offset in 0..<45 {
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
    /// A provider daily close can change after the regular close. Wait until the entire
    /// target New York date has ended before accepting its completed daily aggregate.
    nonisolated static func reviewAvailableAt(for run: Run) -> Date? {
        guard let target = targetClose(after: run.completedAt, horizon: run.horizon) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: target))
    }
    nonisolated static func availability(for run: Run, now: Date) -> Evaluation {
        guard valid(run), validDate(now), now >= run.completedAt,
              let target = targetClose(after: run.completedAt, horizon: run.horizon),
              let availableAt = reviewAvailableAt(for: run) else {
            return Evaluation(state: .dataUnavailable, checkedAt: now, targetCloseAt: nil,
                note: "The future Nasdaq session calendar or evaluation clock could not be verified.")
        }
        return Evaluation(state: now < availableAt ? .notDue : .due, checkedAt: now, targetCloseAt: target,
            note: now < availableAt ? "Waiting until the New York date of the \(run.horizon.rawValue)th future Nasdaq regular-session close ends, so its daily aggregate is complete."
                : "Due for a dated price-direction check. No outcome has been observed yet.")
    }
    nonisolated static func evaluate(_ prediction: Prediction, in run: Run,
                                     observation: Observation?, now: Date) -> Evaluation {
        let available = availability(for: run, now: now)
        guard available.state == .due, let target = available.targetCloseAt else { return available }
        func unavailable(_ note: String) -> Evaluation {
            Evaluation(state: .dataUnavailable, checkedAt: now, targetCloseAt: target,
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
        return Evaluation(state: .evaluated, checkedAt: now, targetCloseAt: target,
            provider: observation.provider, fetchedAt: observation.fetchedAt,
            comparisonReferencePrice: baseline, comparisonReferenceDate: benchmark,
            targetPrice: targetPrice, priceReturn: change, direction: direction,
            buyDirectionSupported: isBuy && direction != .flat ? direction == .rose : nil,
            note: "Price direction from the next trading day's daily open to the target day's daily close, on the same split-adjusted basis. Daily aggregates may include qualifying extended-hours trades; this is not a guaranteed execution price. Excludes dividends, fees and execution costs; not realized trading profit or a win probability.")
    }

    private nonisolated static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0..<253_402_300_800).contains(date.timeIntervalSince1970)
    }
    private nonisolated static func valid(_ run: Run) -> Bool {
        guard validDate(run.startedAt), validDate(run.completedAt), run.startedAt <= run.completedAt,
              run.predictions.count <= 5, Set(run.predictions.map(\.symbol)).count == run.predictions.count,
              run.coverage.requested >= 0, run.coverage.checked == run.coverage.requested,
              (0...run.coverage.checked).contains(run.coverage.incomplete),
              (0...run.coverage.checked - run.coverage.incomplete).contains(run.coverage.buyCount),
              run.predictions.count == min(5, run.coverage.buyCount) else { return false }
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
        let direction: Evaluation.Direction = targetPrice == baseline ? .flat : (targetPrice > baseline ? .rose : .fell)
        return evaluation.direction == direction && evaluation.buyDirectionSupported == (direction == .flat ? nil : direction == .rose)
    }
}
