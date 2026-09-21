import Foundation
import Combine

/// A manual, bounded news sample for every matching symbol. No model or trading side effects.
@MainActor final class StockSageScreenerNews: ObservableObject {
    typealias Row = StockSageStockScreener.Row
    typealias Observation = StockSageNewsService.Observation
    typealias Loader = @MainActor @Sendable (Row, Date) async -> Observation
    @Published private(set) var rows: [Row] = []
    @Published private(set) var observations: [String: Observation] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Load news for the current matching stocks."
    @Published private(set) var startedAt: Date?
    private let access: StockSageMassive.Access
    private let clock: () -> Date
    private let loader: Loader?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(access: StockSageMassive.Access = .init(), clock: @escaping () -> Date = { Date() }, loader: Loader? = nil) {
        self.access = access; self.clock = clock; self.loader = loader
    }

    nonisolated static func matchingRows(_ rows: [Row], filters: StockSageStockScreener.Filters?, search: String) -> [Row] {
        guard let filters, filters.isValid else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return rows.filter {
            filters.classify($0).status == .matched
                && (query.isEmpty || $0.symbol.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query))
                && seen.insert($0.symbol).inserted
        }.sorted { $0.symbol < $1.symbol }
    }

    func load(rows: [Row]) async {
        guard !isLoading, !Task.isCancelled else { return }
        guard !StockSageStore.isRunningTests || loader != nil else { return }
        clear()
        guard rows.count <= StockSageStockScreener.maximumRows,
              Set(rows.map(\.symbol)).count == rows.count,
              rows.allSatisfy({ StockSageHorizonResearch.validTicker($0.symbol) }) else {
            status = "News unavailable: invalid matching list. Reload the daily screen."; return
        }
        self.rows = rows
        guard !rows.isEmpty else { status = "No matching stocks to check."; return }
        let captured = access.capture()
        guard !captured.key.isEmpty, captured.isCurrent() else {
            status = "News not checked: market-data access is unavailable."; return
        }
        let operation = generation, at = clock()
        startedAt = at; isLoading = true
        status = "Checking news for all \(rows.count) matching stocks…"
        let load: Loader = loader ?? { row, at in
            await StockSageNewsService.observation(for: row.symbol, limit: 5, maxAgeDays: 7,
                                                   now: at, companyName: row.name)
        }
        let work = Task { await collect(rows, at: at, operation: operation, isCurrent: captured.isCurrent, load: load) }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard generation == operation else { return }
        isLoading = false; task = nil
        if Task.isCancelled { status = "Cancelled. Completed observations remain dated; remaining stocks were not checked." }
    }

    private func collect(_ rows: [Row], at: Date, operation: UUID,
                         isCurrent: @escaping @Sendable () -> Bool, load: @escaping Loader) async {
        await withTaskGroup(of: (String, Observation?).self) { group in
            var next = 0
            @MainActor func admit() {
                guard next < rows.count, !Task.isCancelled, isCurrent(), generation == operation else { return }
                let row = rows[next]; next += 1
                group.addTask { @MainActor @Sendable in
                    guard !Task.isCancelled, isCurrent() else { return (row.symbol, nil) }
                    return (row.symbol, await load(row, at))
                }
            }
            // Four rolling symbols, while the shared client owns the smaller HTTP limit.
            for _ in 0..<min(4, rows.count) { admit() }
            for await (symbol, observation) in group {
                guard generation == operation else { group.cancelAll(); return }
                guard !Task.isCancelled else {
                    status = "Cancelled. Completed observations remain dated; remaining stocks were not checked."
                    group.cancelAll(); return
                }
                guard isCurrent() else {
                    observations = [:]
                    status = "News unavailable: access changed. Reload to use the current access settings."
                    group.cancelAll(); return
                }
                if let observation { observations[symbol] = observation }
                admit()
            }
            guard generation == operation, !Task.isCancelled else { return }
            guard isCurrent() else {
                observations = [:]
                status = "News unavailable: access changed. Reload to use the current access settings."; return
            }
            status = "News collection finished for \(observations.count) of \(rows.count) stocks. Read coverage for failed or skipped checks."
        }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false
        status = "Cancelled. Completed observations remain dated; remaining stocks were not checked."
    }

    func clear() {
        cancel(); rows = []; observations = [:]; startedAt = nil
        status = "Load news for the current matching stocks."
    }
}
