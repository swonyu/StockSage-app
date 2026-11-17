import Foundation

/// Provisional AM.* nominations only. Massive can revise minute aggregates; REST must confirm
/// every nominee before any financial fact, alert or model assessment is published.
nonisolated enum StockSageMomentumStream {
    static let maximumAge: TimeInterval = 180
    static let maximumSymbols = 32_768

    struct Minute: Sendable, Equatable, Hashable {
        let symbol: String
        let start: Date
        let end: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double

        var isValid: Bool {
            let seconds = start.timeIntervalSince1970
            return supported(symbol) && seconds.isFinite && seconds > 0
                && seconds.truncatingRemainder(dividingBy: 60) == 0
                && end.timeIntervalSince(start) == 60
                && [open, high, low, close].allSatisfy { $0.isFinite && $0 > 0 }
                && low <= min(open, close) && high >= max(open, close)
                && volume.isFinite && volume >= 0
        }
    }

    struct Candidate: Sendable, Equatable, Hashable {
        let symbol: String
        /// End of the last completed minute, never the local polling clock.
        let at: Date
        /// In-memory identity of the completed 20-minute window; never persisted or security-sensitive.
        var revision: Int = 0
    }

    struct Snapshot: Sendable, Equatable {
        var feedID = UUID()
        var configurationID = UUID()
        var symbols: Set<String> = []
        var observedAt = Date()
        var ready = 0
        var warming = 0
        var staleOrGapped = 0
        var unsupported = 0
        var candidates: [Candidate] = []
    }

    static func supported(_ symbol: String) -> Bool {
        symbol == symbol.uppercased() && StockSageHorizonResearch.validTicker(symbol)
            && StockSageLiveStream.stockSymbol(symbol) == symbol
    }

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    struct State: Sendable {
        let feedID: UUID
        private(set) var configurationID: UUID
        let symbolLimit: Int
        private(set) var symbols: Set<String> = []
        private var history: [String: [Date: Minute]] = [:]
        private var memberships: [String: UUID] = [:]

        init(feedID: UUID = UUID(), configurationID: UUID = UUID(), symbolLimit: Int = maximumSymbols) {
            self.feedID = feedID
            self.configurationID = configurationID
            self.symbolLimit = min(maximumSymbols, max(0, symbolLimit))
        }

        /// Removing a symbol discards its warmup, including a stop followed by re-enabling it.
        /// Capacity failure is explicit; callers must invalidate the session, never take a prefix.
        @discardableResult
        mutating func configure(symbols requested: Set<String>, configurationID: UUID? = nil,
                                memberships requestedMemberships: [String: UUID]? = nil) -> Bool {
            guard requested.count <= symbolLimit else { return false }
            let next = requestedMemberships ?? Dictionary(uniqueKeysWithValues: requested.map {
                ($0, memberships[$0] ?? UUID())
            })
            guard Set(next.keys) == requested else { return false }
            if requested != symbols || next != memberships || configurationID.map({ $0 != self.configurationID }) == true {
                self.configurationID = configurationID ?? UUID()
                history = history.filter { next[$0.key] != nil && next[$0.key] == memberships[$0.key] }
                memberships = next
                symbols = requested
            }
            return true
        }

        mutating func invalidate(symbol: String) {
            guard symbols.contains(symbol) else { return }
            history[symbol] = nil
        }

        mutating func consume(_ minute: Minute, now: Date) {
            guard symbols.contains(minute.symbol), minute.isValid,
                  now.timeIntervalSince1970.isFinite, minute.start <= now,
                  minute.end > now.addingTimeInterval(-3_600) else { return }
            var buckets = history[minute.symbol] ?? [:]
            guard buckets[minute.start] != minute else { return }
            // A correction replaces the complete candle, including volume. Never add it twice.
            buckets[minute.start] = minute
            let retained = buckets.keys.filter { $0 >= now.addingTimeInterval(-3_600) }.sorted().suffix(60)
            history[minute.symbol] = Dictionary(uniqueKeysWithValues: retained.compactMap { key in
                buckets[key].map { (key, $0) }
            })
        }

        func snapshot(symbols requested: Set<String>, profile: StockSageMicrocapScreen.Profile,
                      now: Date) -> Snapshot {
            var result = Snapshot(feedID: feedID, configurationID: configurationID,
                                  symbols: requested, observedAt: now)
            guard now.timeIntervalSince1970.isFinite else {
                result.staleOrGapped = requested.count; return result
            }
            for symbol in requested.sorted() {
                guard supported(symbol), symbols.contains(symbol) else { result.unsupported += 1; continue }
                let completed = (history[symbol]?.values.map { $0 } ?? [])
                    .filter { $0.end <= now }.sorted { $0.start < $1.start }.suffix(20)
                guard let last = completed.last else { result.warming += 1; continue }
                guard (0...maximumAge).contains(now.timeIntervalSince(last.end)) else {
                    result.staleOrGapped += 1; continue
                }
                let bars = Array(completed)
                let contiguous = zip(bars, bars.dropFirst()).allSatisfy { $0.0.end == $0.1.start }
                guard contiguous, bars.allSatisfy({ $0.volume > 0 }),
                      let first = bars.first, newYork.isDate(first.start, inSameDayAs: last.start) else {
                    result.staleOrGapped += 1; continue
                }
                guard bars.count == 20 else { result.warming += 1; continue }
                let change = last.close / bars[14].close - 1
                let recentVolume = bars.suffix(5).reduce(0) { $0 + $1.volume }
                let baselineVolume = bars.prefix(15).reduce(0) { $0 + $1.volume } / 3
                guard change.isFinite, recentVolume.isFinite, baselineVolume.isFinite, baselineVolume > 0 else {
                    result.staleOrGapped += 1; continue
                }
                result.ready += 1
                let threshold = profile == .microcap ? 0.03 : 0.01
                let volumeMultiple = recentVolume / baselineVolume
                if abs(change) >= threshold, volumeMultiple.isFinite, volumeMultiple >= 3 {
                    result.candidates.append(Candidate(symbol: symbol, at: last.end,
                                                       revision: bars.hashValue))
                }
            }
            return result
        }
    }
}
