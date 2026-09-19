import Foundation
import Combine

/// Frozen prospective price comparisons. Descriptive research only; never orders or model work.
@MainActor
final class StockSageResearchEvaluation: ObservableObject {
    typealias History = StockSageResearchHistory
    static let shared = StockSageResearchEvaluation(storageURL: StockSageStore.isRunningTests ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/ResearchHistory/evaluations.json"))
    nonisolated static let provider = "Massive split-adjusted daily aggregates"
    nonisolated static let disclosure = "Descriptive price comparison, not evidence of predictive skill or realized profit. Nonoverlapping windows can still be statistically dependent. Excludes dividends; costs are assumptions, not observed fills."

    nonisolated struct Contract: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        let frozenAt: Date
        let model: String
        let endpointProfile: StockSageAIAssessment.InferenceProfile.EndpointProfile
        let promptVersion: Int
        let schemaVersion: Int
        let rankingVersion: Int
        let qualificationPolicyVersion: Int
        let benchmark: String
        let roundTripCostBPS: Double
        let minimumWindows: Int
        let calendarBasis: String
        let profileVersion: Int
        let packetVersion: Int
        let temperature: Double
        let topP: Double?
        let seed: Int?
        let contextTokens: Int
        let initialOutputTokens: Int
        let maxOutputTokens: Int
    }
    nonisolated struct Pair: Codable, Sendable, Equatable {
        let symbol: String
        let stock: [History.DailyBar]
        let benchmark: [History.DailyBar]
        let stockFetchedAt: Date
        let benchmarkFetchedAt: Date
        let provider: String
        var stockReturn: Double? { Self.priceReturn(stock) }
        var benchmarkReturn: Double? { Self.priceReturn(benchmark) }
        func netReturn(costBPS: Double) -> Double? { stockReturn.map { $0 - costBPS / 10_000 } }
        func netBenchmarkReturn(costBPS: Double) -> Double? { benchmarkReturn.map { $0 - costBPS / 10_000 } }
        private static func priceReturn(_ bars: [History.DailyBar]) -> Double? {
            guard let first = bars.first, let last = bars.last, first.open.isFinite, first.open > 0,
                  last.close.isFinite, last.close > 0 else { return nil }
            let value = last.close / first.open - 1
            return value.isFinite ? value : nil
        }
    }
    nonisolated struct Attempt: Codable, Sendable, Equatable {
        let symbol: String
        let checkedAt: Date
        let pair: Pair?
    }
    nonisolated struct Review: Codable, Sendable, Equatable {
        let run: History.Run
        var attempts: [Attempt] = []
    }
    nonisolated struct Study: Codable, Sendable, Equatable, Identifiable {
        var id: UUID { contract.id }
        let contract: Contract
        var reviews: [Review] = []
    }
    nonisolated struct HorizonSummary {
        let horizon: History.Horizon
        var eligibleRuns = 0, excludedRuns = 0, sameDateRuns = 0, overlappingRuns = 0, calendarUnavailableRuns = 0
        var selectedWindows = 0, waitingWindows = 0, uncheckedWindows = 0, unavailableWindows = 0, measuredWindows = 0
        var expectedPredictions = 0, measuredPredictions = 0
        var meanNetReturn: Double?, meanBenchmarkNetReturn: Double?, meanExcessReturn: Double?
        var readiness = "Not enough evidence. The disclosed minimum is 20 complete nonoverlapping windows per horizon for descriptive review; reaching it does not establish predictive skill."
    }

    @Published private(set) var studies: [Study] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isChecking = false
    private let storageURL: URL?
    private let defaults: UserDefaults

    private var readable = true
    private static let maximumBytes = 16_777_216
    private struct Document: Codable { var version = 1; var studies: [Study] = [] }
    private nonisolated static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private nonisolated static func finite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0
    }
    private nonisolated static func original(_ run: History.Run) -> History.Run {
        var copy = run; copy.evaluations = [:]; copy.reviewProgress = nil
        return copy
    }

    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.storageURL = storageURL; self.defaults = defaults
        guard let storageURL else { return }
        guard StockSageRecordWriter.mayRead(defaults) else {
            readable = false; lastError = "Study storage is unavailable in this process."; return
        }
        do { studies = try Self.read(storageURL).studies }
        catch { readable = false; lastError = "Saved studies are unreadable or invalid. Existing bytes were preserved." }
    }

    @discardableResult
    func freeze(config: StockSageLocalModelServer.Config, costBPS: Double, at: Date = Date()) -> Bool {
        guard config.requiresStrictOutput, Self.finite(at), costBPS.isFinite, (0...1000).contains(costBPS),
              StockSageMarketHours.nasdaqDay(at: at) != nil else {
            lastError = "Start requires a supported Gemma endpoint profile, an explicit cost from 0 to 1,000 basis points, and the verified 2026 calendar."
            return false
        }
        let output = StockSageHorizonResearch.researchOutputTokens
        let contract = Contract(id: UUID(), frozenAt: at, model: config.model,
            endpointProfile: config.isRunPodGemma ? .runPodGemma : .lmStudioGemma,
            promptVersion: StockSageAIAssessment.PromptVersion.current.rawValue,
            schemaVersion: StockSageAIAssessment.PromptVersion.current.rawValue,
            rankingVersion: StockSageResearchRanking.currentVersion, qualificationPolicyVersion: 1,
            benchmark: "SPY", roundTripCostBPS: costBPS, minimumWindows: 20,
            calendarBasis: History.benchmarkCalendarBasis, profileVersion: 1,
            packetVersion: StockSageAIAssessment.EvidencePacket.currentVersion,
            temperature: StockSageLocalModelServer.researchTemperature, topP: nil, seed: nil,
            contextTokens: StockSageLocalModelServer.researchContextTokens,
            initialOutputTokens: output, maxOutputTokens: config.reservedOutputTokens(for: output))
        return update { document in
            guard document.studies.count < 20 else { throw StorageFailure.invalid }
            document.studies.append(.init(contract: contract))
        }
    }

    private nonisolated static func valid(_ contract: Contract) -> Bool {
        finite(contract.frozenAt) && StockSageMarketHours.nasdaqDay(at: contract.frozenAt) != nil
            && contract.model == StockSageLocalModelServer.gemmaModel
            && [.lmStudioGemma, .runPodGemma].contains(contract.endpointProfile)
            && StockSageAIAssessment.PromptVersion(rawValue: contract.promptVersion) != nil
            && contract.schemaVersion == contract.promptVersion && contract.rankingVersion == 3
            && contract.qualificationPolicyVersion == 1 && contract.benchmark == "SPY"
            && contract.roundTripCostBPS.isFinite && (0...1000).contains(contract.roundTripCostBPS)
            && contract.minimumWindows == 20 && contract.calendarBasis == History.benchmarkCalendarBasis
            && contract.profileVersion == 1 && contract.packetVersion == 2
            && contract.temperature.isFinite && (0...2).contains(contract.temperature)
            && (contract.topP.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && contract.contextTokens > 0 && contract.contextTokens <= 1_048_576
            && contract.initialOutputTokens > 0 && contract.maxOutputTokens >= contract.initialOutputTokens
            && contract.maxOutputTokens < contract.contextTokens
    }

    private nonisolated static func eligible(_ run: History.Run, contract: Contract) -> Bool {
        guard valid(contract), History.valid(run), run.startedAt >= contract.frozenAt,
              run.originalRunID == nil, run.retainedFromRunID == nil,
              run.measurementPolicy == .nextTradingDateSessions, run.coverage.incomplete == 0,
              run.coverage.qualifiedBuyCount != nil, !run.predictions.isEmpty,
              let ranking = run.ranking, ranking.version == contract.rankingVersion,
              ranking.model == contract.model, ranking.rounds.allSatisfy({ $0.model == contract.model }) else { return false }
        return run.predictions.allSatisfy { prediction in
            guard prediction.qualification?.isQualified == true,
                  let profile = prediction.inferenceProfile, profile.valid(model: contract.model) else { return false }
            return profile.version == contract.profileVersion && profile.endpointProfile == contract.endpointProfile
                && profile.promptVersion == contract.promptVersion && profile.schemaVersion == contract.schemaVersion
                && profile.packetVersion == contract.packetVersion && profile.temperature == contract.temperature
                && profile.topP == contract.topP && profile.seed == contract.seed
                && profile.contextTokens == contract.contextTokens && profile.initialOutputTokens == contract.initialOutputTokens
                && profile.maxOutputTokens == contract.maxOutputTokens
        }
    }

    private nonisolated struct Window {
        let run: History.Run
        let dates: [Date]
        let availableAt: Date
    }
    private nonisolated static func window(_ run: History.Run) -> Window? {
        guard let first = History.benchmarkDay(after: run.completedAt), let close = History.targetClose(for: run),
              let available = History.reviewAvailableAt(for: run) else { return nil }
        let last = calendar.startOfDay(for: close)
        var day = first, dates: [Date] = []
        // The sourced calendar only covers 2026. Never substitute weekdays beyond its coverage.
        for _ in 0..<40 {
            guard let session = StockSageMarketHours.nasdaqDay(at: day) else { return nil }
            if session.trading { dates.append(day) }
            if day == last { break }
            guard day < last, let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        guard dates.count == run.horizon.rawValue, dates.last == last else { return nil }
        return .init(run: original(run), dates: dates, availableAt: available)
    }
    private nonisolated static func selection(study: Study, runs: [History.Run], horizon: History.Horizon)
        -> (windows: [Window], summary: HorizonSummary) {
        var summary = HorizonSummary(horizon: horizon)
        // Retained study sources keep previously selected windows from vanishing when the history list changes.
        var sources = Dictionary(uniqueKeysWithValues: study.reviews.map { ($0.run.id, $0.run) })
        var mismatched = Set<UUID>()
        for run in runs where run.horizon == horizon {
            let captured = original(run)
            if let prior = sources[run.id], prior != captured { mismatched.insert(run.id) }
            else { sources[run.id] = captured }
        }
        var days = Set<Date>(), end: Date?, windows: [Window] = []
        for run in sources.values.filter({ $0.horizon == horizon }).sorted(by: {
            $0.completedAt == $1.completedAt ? $0.id.uuidString < $1.id.uuidString : $0.completedAt < $1.completedAt
        }) {
            guard !mismatched.contains(run.id), eligible(run, contract: study.contract) else {
                summary.excludedRuns += 1; continue
            }
            summary.eligibleRuns += 1
            guard let window = window(run), let first = window.dates.first, let last = window.dates.last else {
                summary.calendarUnavailableRuns += 1; continue
            }
            guard days.insert(calendar.startOfDay(for: run.completedAt)).inserted else {
                summary.sameDateRuns += 1; continue
            }
            if let end, first <= end { summary.overlappingRuns += 1; continue }
            end = last; windows.append(window)
        }
        summary.selectedWindows = windows.count
        summary.expectedPredictions = windows.reduce(0) { $0 + $1.run.predictions.count }
        return (windows, summary)
    }

    func summary(studyID: UUID, runs: [History.Run], now: Date = Date()) -> [HorizonSummary] {
        guard let study = studies.first(where: { $0.id == studyID }) else { return [] }
        return History.Horizon.allCases.map { horizon in
            let selected = Self.selection(study: study, runs: runs, horizon: horizon)
            var summary = selected.summary, net: [Double] = [], benchmark: [Double] = []
            for window in selected.windows {
                guard Self.finite(now), now >= window.availableAt else { summary.waitingWindows += 1; continue }
                let review = study.reviews.first { $0.run == window.run }
                let pairs = window.run.predictions.compactMap { prediction in
                    review?.attempts.first(where: { $0.symbol == prediction.symbol })?.pair
                }
                summary.measuredPredictions += pairs.count
                guard pairs.count == window.run.predictions.count else {
                    if review?.attempts.isEmpty ?? true { summary.uncheckedWindows += 1 }
                    else { summary.unavailableWindows += 1 }
                    continue
                }
                let returns = pairs.compactMap { $0.netReturn(costBPS: study.contract.roundTripCostBPS) }
                let benchmarks = pairs.compactMap { $0.netBenchmarkReturn(costBPS: study.contract.roundTripCostBPS) }
                guard returns.count == pairs.count, benchmarks.count == pairs.count else {
                    summary.unavailableWindows += 1; continue
                }
                guard let mean = Self.finiteMean(returns), let benchmarkMean = Self.finiteMean(benchmarks) else {
                    summary.unavailableWindows += 1; continue
                }
                summary.measuredWindows += 1
                net.append(mean); benchmark.append(benchmarkMean)
            }
            if let mean = Self.finiteMean(net), let benchmarkMean = Self.finiteMean(benchmark),
               let excess = Self.finiteMean(zip(net, benchmark).map { $0.0 - $0.1 }) {
                summary.meanNetReturn = mean
                summary.meanBenchmarkNetReturn = benchmarkMean
                summary.meanExcessReturn = excess
            } else if !net.isEmpty {
                summary.readiness += " The aggregate exceeds the supported arithmetic range; no mean is displayed."
            }
            if summary.measuredWindows >= study.contract.minimumWindows, summary.meanExcessReturn != nil {
                summary.readiness = "The disclosed minimum descriptive sample is available. This does not establish predictive skill; inspect missing windows, uncertainty and the frozen assumptions."
            }
            if summary.calendarUnavailableRuns > 0 {
                summary.readiness += " Some windows extend beyond the verified 2026 calendar and cannot be measured."
            }
            return summary
        }
    }

    private nonisolated static func finiteMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        // Scale before summing: finite returns can have a representable mean even when their sum overflows.
        let count = Double(values.count)
        let mean = values.reduce(0) { $0 + $1 / count }
        return mean.isFinite ? mean : nil
    }

    private nonisolated static func bars(_ observation: History.Observation, symbol: String, window: Window, now: Date) -> [History.DailyBar]? {
        let history = observation.history, count = observation.history.count
        guard observation.splitAdjusted, observation.provider == provider, history.priceSource == .massiveDaily,
              history.symbol == symbol, finite(now), finite(observation.fetchedAt),
              observation.fetchedAt >= window.availableAt, observation.fetchedAt <= now,
              count == window.dates.count, [history.dates.count, history.opens.count, history.highs.count,
                history.lows.count, history.volumes.count].allSatisfy({ $0 == count }),
              history.volumes.allSatisfy({ $0.isFinite && $0 >= 0 }), history.dates.allSatisfy(finite) else { return nil }
        let captured = (0..<count).map { index in
            History.DailyBar(date: calendar.startOfDay(for: history.dates[index]), open: history.opens[index],
                high: history.highs[index], low: history.lows[index], close: history.closes[index])
        }
        return validBars(captured, dates: window.dates) ? captured : nil
    }
    private nonisolated static func validBars(_ bars: [History.DailyBar], dates: [Date]) -> Bool {
        bars.map(\.date) == dates && bars.allSatisfy {
            [$0.open, $0.high, $0.low, $0.close].allSatisfy { $0.isFinite && $0 > 0 }
                && $0.low <= min($0.open, $0.close) && $0.high >= max($0.open, $0.close) && $0.low <= $0.high
        }
    }
    private nonisolated static func valid(_ pair: Pair, window: Window, symbol: String, checkedAt: Date) -> Bool {
        pair.symbol == symbol && pair.provider == provider && finite(pair.stockFetchedAt) && finite(pair.benchmarkFetchedAt)
            && pair.stockFetchedAt >= window.availableAt && pair.benchmarkFetchedAt >= window.availableAt
            && pair.stockFetchedAt <= checkedAt && pair.benchmarkFetchedAt <= checkedAt
            && validBars(pair.stock, dates: window.dates) && validBars(pair.benchmark, dates: window.dates)
            && pair.stockReturn != nil && pair.benchmarkReturn != nil
    }
    nonisolated static func paired(run: History.Run, prediction: History.Prediction, contract: Contract,
        stock: History.Observation?, benchmark: History.Observation?, now: Date) -> Pair? {
        guard eligible(run, contract: contract), run.predictions.contains(prediction), let window = window(run),
              let stock, let benchmark,
              let stockBars = bars(stock, symbol: prediction.symbol, window: window, now: now),
              let benchmarkBars = bars(benchmark, symbol: contract.benchmark, window: window, now: now) else { return nil }
        let pair = Pair(symbol: prediction.symbol, stock: stockBars, benchmark: benchmarkBars,
            stockFetchedAt: stock.fetchedAt, benchmarkFetchedAt: benchmark.fetchedAt, provider: provider)
        return valid(pair, window: window, symbol: prediction.symbol, checkedAt: now) ? pair : nil
    }

    func check(studyID: UUID, runs: [History.Run], clock: @escaping @MainActor () -> Date = { Date() },
        allowed: @escaping @MainActor () -> Bool,
        fetch: @escaping @MainActor (String, Date, Date) async -> History.Observation?) async {
        guard !isChecking, readable, !Task.isCancelled, allowed(), Self.finite(clock()),
              let study = studies.first(where: { $0.id == studyID }) else { return }
        isChecking = true; defer { isChecking = false }
        let windows = History.Horizon.allCases.flatMap { Self.selection(study: study, runs: runs, horizon: $0).windows }
        let due = windows.filter { clock() >= $0.availableAt }
        let work = due.flatMap { window in
            window.run.predictions.compactMap { prediction -> (Window, History.Prediction, Date)? in
                let attempt = study.reviews.first(where: { $0.run.id == window.run.id })?.attempts.first { $0.symbol == prediction.symbol }
                guard attempt?.pair == nil else { return nil }
                return (window, prediction, attempt?.checkedAt ?? .distantPast)
            }
        }.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.0.run.completedAt != $1.0.run.completedAt { return $0.0.run.completedAt < $1.0.run.completedAt }
            return $0.1.symbol < $1.1.symbol
        }
        for (window, prediction, _) in work.prefix(History.maximumChecksPerRequest) {
            guard !Task.isCancelled, allowed(), let first = window.dates.first, let last = window.dates.last else { return }
            let requestedAt = clock()
            let stock = await fetch(prediction.symbol, first, last)
            guard !Task.isCancelled, allowed(), clock() >= requestedAt else { return }
            let benchmark = await fetch(study.contract.benchmark, first, last)
            guard !Task.isCancelled, allowed(), clock() >= requestedAt else { return }
            let checkedAt = clock()
            let pair = Self.paired(run: window.run, prediction: prediction, contract: study.contract,
                stock: stock, benchmark: benchmark, now: checkedAt)
            guard update({ document in
                guard let index = document.studies.firstIndex(where: { $0.id == studyID }),
                      document.studies[index].contract == study.contract else { throw StorageFailure.invalid }
                // Capture deterministic selection before any measured return can influence it.
                for selected in windows where !document.studies[index].reviews.contains(where: { $0.run.id == selected.run.id }) {
                    document.studies[index].reviews.append(.init(run: selected.run))
                }
                guard let review = document.studies[index].reviews.firstIndex(where: { $0.run == window.run }) else { throw StorageFailure.invalid }
                var attempts = document.studies[index].reviews[review].attempts
                if let existing = attempts.firstIndex(where: { $0.symbol == prediction.symbol }) {
                    guard attempts[existing].pair == nil, attempts[existing].checkedAt <= checkedAt else { throw StorageFailure.invalid }
                    attempts.remove(at: existing)
                }
                attempts.append(.init(symbol: prediction.symbol, checkedAt: checkedAt, pair: pair))
                document.studies[index].reviews[review].attempts = attempts
            }) else { return }
        }
    }

    func checkSaved(studyID: UUID, history: History, store: StockSageStore) async {
        if let reason = Self.accessReason(store: store) { lastError = reason; return }
        let access = StockSageMassive.Access().capture()
        guard access.isCurrent(), !access.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Massive access changed. Check the current settings and try again."; return
        }
        let allowed: @MainActor () -> Bool = {
            !StockSageStore.isRunningTests && !store.isSampleData && access.isCurrent()
        }
        await check(studyID: studyID, runs: history.runs, allowed: allowed) { symbol, first, last in
            guard allowed() else { return nil }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(identifier: "America/New_York")!
            guard let request = StockSageHorizonResearch.dailyHistoryRequest(symbol: symbol,
                from: formatter.string(from: first), to: formatter.string(from: last), key: access.key) else { return nil }
            do {
                let (data, response) = try await StockSageMassive.restTransport(request, maximumBytes: 2_000_000)
                guard allowed(), (response as? HTTPURLResponse)?.statusCode == 200, response.url == request.url,
                      let prices = StockSageHorizonResearch.parseResearchHistory(data, symbol: symbol) else { return nil }
                return .init(history: prices, splitAdjusted: true, provider: Self.provider, fetchedAt: Date())
            } catch { return nil }
        }
        if !allowed() { lastError = "Price review stopped because access changed. Previously saved comparisons remain." }
    }
    static func accessReason(store: StockSageStore) -> String? {
        if StockSageStore.isRunningTests { return "Live price checks are unavailable in the test host." }
        if let reason = ToolPolicy.webToolsDisabledReason() { return reason }
        if store.isSampleData { return "Sample mode cannot supply a prospective price comparison." }
        if !StockSageMassive.isConfigured { return "Configure Massive access before checking saved prices." }
        return nil
    }

    private enum StorageFailure: Error { case invalid }
    private static func valid(_ document: Document) -> Bool {
        guard document.version == 1, document.studies.count <= 20,
              Set(document.studies.map(\.id)).count == document.studies.count else { return false }
        return document.studies.allSatisfy { study in
            guard valid(study.contract), study.reviews.count <= 500,
                  Set(study.reviews.map { $0.run.id }).count == study.reviews.count else { return false }
            guard History.Horizon.allCases.reduce(0, { $0 + selection(study: study, runs: [], horizon: $1).windows.count })
                    == study.reviews.count else { return false }
            return study.reviews.allSatisfy { review in
                guard review.run == original(review.run), eligible(review.run, contract: study.contract),
                      let window = window(review.run), review.attempts.count <= review.run.predictions.count,
                      Set(review.attempts.map(\.symbol)).count == review.attempts.count else { return false }
                return review.attempts.allSatisfy { attempt in
                    review.run.predictions.contains(where: { $0.symbol == attempt.symbol }) && finite(attempt.checkedAt)
                        && attempt.checkedAt >= window.availableAt
                        && (attempt.pair.map { valid($0, window: window, symbol: attempt.symbol, checkedAt: attempt.checkedAt) } ?? true)
                }
            }
        }
    }
    private static func read(_ url: URL) throws -> Document {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .init() }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw StorageFailure.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw StorageFailure.invalid }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard valid(document) else { throw StorageFailure.invalid }
        return document
    }
    @discardableResult private func update(_ mutation: (inout Document) throws -> Void) -> Bool {
        guard readable else { lastError = "Saved studies are unreadable. Existing bytes were preserved."; return false }
        do {
            var document: Document
            let lease: StockSageFileLock?
            if let storageURL {
                try StockSageRecordWriter.require(defaults)
                lease = try StockSageFileLock(url: storageURL.appendingPathExtension("lock"))
                document = try Self.read(storageURL)
                // A disappeared file must not silently replace studies already loaded in this process.
                for prior in studies {
                    guard document.studies.first(where: { $0.id == prior.id }) == prior else { throw StorageFailure.invalid }
                }
            } else { lease = nil; document = .init(studies: studies) }
            try mutation(&document)
            guard Self.valid(document) else { throw StorageFailure.invalid }
            if let storageURL {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(document)
                guard data.count <= Self.maximumBytes else { throw StorageFailure.invalid }
                try data.write(to: storageURL, options: .atomic)
            }
            withExtendedLifetime(lease) {}
            studies = document.studies; lastError = nil
            return true
        } catch {
            lastError = "Could not save the study. Existing studies were preserved; check storage access or the 20-study, 500-window and 16 MiB limits."
            return false
        }
    }
}
