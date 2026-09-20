import Foundation
import CryptoKit
import Combine

/// App-lifetime, opt-in tracking within the owner's fixed weekday window. No background scheduler or broker dependency.
@MainActor final class StockSageMicrocapMonitor: ObservableObject {
    static let shared = StockSageMicrocapMonitor()
    static let largecap = StockSageMicrocapMonitor(mode: .largecap)
    let mode: StockSageSameDayResearch.Mode
    @Published private(set) var isEnabled = false
    @Published private(set) var status = "Tracking is off. Enable weekday momentum tracking; pair Telegram for fresh-setup assessments."
    @Published private(set) var nextCheck: Date?
    @Published private(set) var marketMomentum: StockSageMomentum.Market?
    @Published private(set) var stockMomentum: [StockSageMomentum.Stock] = []
    @Published private(set) var eligibleHeavySymbols: Set<String> = []
    @Published private(set) var momentumStatus = "Momentum tracking is off."
    @Published private(set) var momentumAlertStatus = "Pair Telegram for heavy-momentum observations and Astra reviews."
    @Published private(set) var momentumReviewsDeferred = 0
    @Published private(set) var momentumWorkStatus = "No momentum events are queued."
    @Published private(set) var nextMomentumCheck: Date?
    private var task: Task<Void, Never>?
    private var momentumTask: Task<Void, Never>?
    private var momentumReviewTask: Task<Void, Never>?
    private var momentumConfirmationTask: Task<Void, Never>?
    private var momentumDeliveryTask: Task<Void, Never>?
    private var momentumSession = UUID()
    private var momentumFeed: StockSageMomentumStream.Snapshot?
    private var nominations: [StockSageMomentumStream.Candidate] = []
    private var attemptedNominations: [String: StockSageMomentumStream.Candidate] = [:]
    private var pendingAlerts: [PendingMomentum] = []
    private var pendingReviews: [PendingMomentum] = []
    private var expiredConfirmations = 0, rejectedConfirmations = 0, revokedEvents = 0, expiredObservations = 0
    struct PendingMomentum {
        let id: String
        let stock: StockSageMomentum.Stock
        let market: StockSageMomentum.Market
        let trigger: StockSageMomentum.Trigger
        let stillValid: @MainActor () -> Bool
    }
    /// Preserve FIFO admission when newer evidence replaces an already-waiting event.
    static func enqueue(_ event: PendingMomentum, into queue: inout [PendingMomentum]) {
        // ponytail: bounded by the dated universe; use an ordered map only if measured bursts make array insertion costly.
        if let index = queue.firstIndex(where: { $0.id == event.id }) { queue[index] = event }
        else { queue.append(event) }
    }
    static func prune(_ queue: inout [PendingMomentum], at now: Date) -> (expired: Int, revoked: Int) {
        var expired = 0, revoked = 0
        queue.removeAll { event in
            if event.stock.heavyMomentum(profile: event.trigger.profile, now: now) != event.trigger { expired += 1; return true }
            if !event.stillValid() { revoked += 1; return true }
            return false
        }
        return (expired, revoked)
    }
    private var generation = UUID()
    private var ownedRun: UUID?
    private(set) var claimFailure: String?
    private let directory: URL?
    private let requireWriter: () throws -> Void
    /// Shared pause after each periodic setup check; research capacity and session gates still apply.
    static let interval: TimeInterval = 150
    nonisolated static let trackingPolicy = "Monday–Friday, 11:00–23:00 Asia/Riyadh; end exclusive. Streaming minute detection covers every dated eligible symbol while StockSage is open; fresh events require REST confirmation. Qualified setup research still requires the verified US regular-session setup window."
    private static var momentumOwner: UUID?
    private static var confirmationWaiters: Set<StockSageSameDayResearch.Mode> = []
    private static var lastConfirmationMode: StockSageSameDayResearch.Mode?
    private static var marketCache: (value: StockSageMomentum.Market, at: Date, key: String, isCurrent: @Sendable () -> Bool)?

    init(mode: StockSageSameDayResearch.Mode = .microcap, directory: URL? = nil,
         requireWriter: @escaping () throws -> Void = { try StockSageRecordWriter.require(.standard) }) {
        self.mode = mode
        self.directory = directory ?? (StockSageStore.isRunningTests ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("StockSage/" + mode.directoryName, isDirectory: true))
        self.requireWriter = requireWriter
    }

    private var research: StockSageSameDayResearch {
        switch mode {
        case .sameDay: .shared
        case .microcap: .microcap
        case .largecap: .largecap
        }
    }

    nonisolated private static var trackingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        return calendar
    }

    nonisolated static func trackingWindow(at date: Date) -> DateInterval? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let calendar = trackingCalendar
        guard (2...6).contains(calendar.component(.weekday, from: date)),
              let start = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: date),
              let end = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: date),
              date >= start, date < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    nonisolated static func nextTrackingStart(after date: Date) -> Date? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let calendar = trackingCalendar
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  (2...6).contains(calendar.component(.weekday, from: day)),
                  let start = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day), start > date else { continue }
            return start
        }
        return nil
    }

    nonisolated static func momentumSelection(candidates: [String], watchlist: [String]) -> (symbols: [String], total: Int, skipped: Int) {
        var seen = Set<String>()
        let all = (candidates + watchlist).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let selected = all.filter { StockSageMomentum.supportsMinutes($0) }
        return (selected, all.count, all.count - selected.count)
    }

    nonisolated static func momentumCandidates(current: StockSageSameDayResearch.Receipt?,
        saved: [StockSageSameDayResearch.Receipt], mode: StockSageSameDayResearch.Mode) -> [String] {
        let receipts = (current.map { [$0] } ?? []) + saved
        let screen = receipts.first { $0.mode == mode && $0.microcapScreen?.profile == mode.screenProfile }?.microcapScreen
        func priority(_ row: StockSageMicrocapScreen.Row) -> Int {
            switch row.status { case .passed: 0; case .unassessed: 1; case .unavailable: 2; case .excluded: 3 }
        }
        let rows = (screen?.rows ?? []).filter { $0.status != .excluded }.sorted {
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            let a = $0.activity.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let b = $1.activity.flatMap { $0.isFinite ? $0 : nil } ?? 0
            return a == b ? $0.symbol < $1.symbol : a > b
        }
        return rows.map(\.symbol) + (current?.mode == mode ? current?.checks.map(\.symbol) ?? [] : [])
    }

    /// Watchlist membership alone never establishes either cap classification or listing eligibility.
    nonisolated static func heavySymbols(current: StockSageSameDayResearch.Receipt?, saved: [StockSageSameDayResearch.Receipt],
        screener: StockSageStockScreener.Snapshot?, mode: StockSageSameDayResearch.Mode, at now: Date, only symbol: String? = nil) -> Set<String> {
        guard mode.isAstra, now.timeIntervalSince1970.isFinite else { return [] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        func sourceDay(_ day: String?, retrieved: Date?) -> Date? {
            guard let day, day.utf8.count == 10, let date = formatter.date(from: day), formatter.string(from: date) == day,
                  let retrieved, retrieved.timeIntervalSince1970.isFinite, retrieved <= now, retrieved >= date,
                  let age = calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: now)).day,
                  (0...7).contains(age) else { return nil }
            return date
        }
        func capMatches(_ cap: Double?) -> Bool {
            guard let cap, cap.isFinite else { return false }
            return mode == .microcap ? (50_000_000...300_000_000).contains(cap) : cap >= 10_000_000_000
        }
        let receipts = (current.map { [$0] } ?? []) + saved
        let screen = receipts.first { $0.mode == mode && $0.microcapScreen?.profile == mode.screenProfile }?.microcapScreen
        var references: [String: (day: Date, retrieved: Date, cap: Double?, venue: Bool)] = [:]
        func consider(_ ticker: String, day: String?, retrieved: Date?, cap: Double?, venue: Bool) {
            guard symbol == nil || ticker == symbol, let source = sourceDay(day, retrieved: retrieved), let retrieved else { return }
            if let prior = references[ticker] {
                guard source > prior.day || (source == prior.day && retrieved >= prior.retrieved) else { return }
                if source == prior.day, retrieved == prior.retrieved, prior.cap != cap || prior.venue != venue {
                    references[ticker] = (source, retrieved, nil, false); return
                }
            }
            references[ticker] = (source, retrieved, cap, venue)
        }
        if let screen, screen.finishedAt <= now, screen.startedAt <= screen.finishedAt, screen.cutoff <= screen.finishedAt {
            for row in screen.rows where symbol == nil || row.symbol == symbol {
                consider(row.symbol, day: row.marketCapRequestedDate, retrieved: row.referenceRetrievedAt, cap: row.marketCap, venue: true)
            }
        }
        if let screener, screener.retrievedAt <= now {
            for row in screener.rows where symbol == nil || row.symbol == symbol {
                let venue = row.primaryExchange ?? ""
                let supported = mode == .microcap ? venue == "XNAS" : ["XNAS", "XNYS", "XASE", "ARCX", "BATS", "BATY", "EDGA", "EDGX"].contains(venue)
                consider(row.symbol, day: row.date, retrieved: screener.retrievedAt, cap: row.marketCap, venue: supported)
            }
        }
        return Set(references.compactMap { key, value in value.venue && capMatches(value.cap) ? key : nil })
    }

    private func currentHeavySymbols(at now: Date, only symbol: String? = nil) -> Set<String> {
        Self.heavySymbols(current: research.receipt, saved: research.savedReceipts,
            screener: StockSageStockScreener.shared.snapshot, mode: mode, at: now, only: symbol)
    }

    private func liveSymbols(_ symbols: [String]) {
        switch mode {
        case .microcap: StockSageLiveStream.shared.microcapSymbols = Set(symbols)
        case .largecap: StockSageLiveStream.shared.largecapSymbols = Set(symbols)
        case .sameDay: break
        }
    }

    /// Confirm at most four provisional events; never sweep the entire universe with serial REST calls.
    @discardableResult func refreshMomentum(candidates: [String], watchlist: [String], at now: Date,
        access: StockSageMassive.Access, transport: StockSageMassive.Transport? = nil,
        eligibleHeavy: Set<String> = [],
        clock: @escaping @MainActor () -> Date = Date.init,
        stillValid: @escaping @MainActor () -> Bool) async -> Bool {
        let captured = access.capture()
        let refreshGeneration = generation
        func active() -> Bool { !Task.isCancelled && self.generation == refreshGeneration && captured.isCurrent() && stillValid() && Self.trackingWindow(at: clock()) != nil }
        let selection = Self.momentumSelection(candidates: candidates, watchlist: watchlist)
        guard mode.isAstra, Self.trackingWindow(at: now) != nil, active(), Self.momentumOwner == nil,
              selection.symbols.count <= 4,
              Self.lastConfirmationMode != mode || Self.confirmationWaiters.subtracting([mode]).isEmpty else { return false }
        let owner = UUID(); Self.momentumOwner = owner
        defer { if Self.momentumOwner == owner { Self.momentumOwner = nil; Self.lastConfirmationMode = mode } }
        let pinned = StockSageMassive.Access(key: { captured.key }, credentialRevision: { nil }, policyRevision: { nil }, allowed: captured.isCurrent)
        let market: StockSageMomentum.Market
        if let cache = Self.marketCache, cache.key == captured.key, cache.isCurrent(),
           (0..<120).contains(now.timeIntervalSince(cache.at)) {
            market = cache.value
        } else {
            market = await StockSageMomentum.collect(now: now, access: pinned, transport: transport, clock: clock)
            guard active() else { return false }
            Self.marketCache = (market, now, captured.key, captured.isCurrent)
        }
        var stocks: [StockSageMomentum.Stock] = []
        // Four outstanding symbol requests at most, including when both watchers are enabled.
        for start in stride(from: 0, to: selection.symbols.count, by: 4) {
            guard active() else { return false }
            let end = min(start + 4, selection.symbols.count)
            let batch = await withTaskGroup(of: (Int, StockSageMassiveTicks.Intraday?).self) { group in
                for index in start..<end {
                    let symbol = selection.symbols[index]
                    group.addTask {
                        (index, await StockSageMomentum.intraday(symbol: symbol, now: now, access: pinned, transport: transport))
                    }
                }
                var values: [(Int, StockSageMassiveTicks.Intraday?)] = []
                for await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }
            }
            let capturedAt = clock()
            stocks += batch.map { index, intraday in
                StockSageMomentum.stock(symbol: selection.symbols[index], intraday: intraday, market: market, now: capturedAt)
            }
        }
        guard active() else { return false }
        guard (0...180).contains(clock().timeIntervalSince(now)) else {
            momentumStatus = "Momentum collection exceeded its freshness window. Earlier observations remain dated; a later scheduled refresh will try again."
            nextMomentumCheck = clock().addingTimeInterval(5)
            return false
        }
        marketMomentum = market
        var retained = Dictionary(uniqueKeysWithValues: stockMomentum.map { ($0.symbol, $0) })
        for stock in stocks { retained[stock.symbol] = stock }
        stockMomentum = retained.values.sorted { $0.symbol < $1.symbol }
        eligibleHeavySymbols = eligibleHeavy
        return true
    }

    nonisolated static func setupID(symbol: String, facts: [StockSageAIAssessment.EvidenceFact], at: Date,
                                    mode: StockSageSameDayResearch.Mode = .microcap) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.year, .month, .day], from: at)
        let catalysts = Set(facts.filter { $0.key.hasPrefix("sameDay.catalyst.") }.map(\.text)).sorted()
        // Keep existing Micro cap IDs exact. Other modes cannot share its claims or Telegram delivery IDs.
        let fields = (mode == .microcap ? [] : [mode.rawValue])
            + [symbol.uppercased(), "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"] + catalysts
        let bytes = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated enum MomentumPurpose: String { case observation, review, reviewSummary }
    nonisolated static func momentumID(_ trigger: StockSageMomentum.Trigger,
        mode: StockSageSameDayResearch.Mode, purpose: MomentumPurpose) -> String? {
        guard mode.isAstra, trigger.profile == mode.screenProfile,
              trackingWindow(at: trigger.at) != nil else { return nil }
        let parts = trackingCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: trigger.at)
        let slot = ((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 30
        let fields = ["heavy-momentum-v1", purpose.rawValue, mode.rawValue, trigger.symbol.uppercased(), trigger.direction.rawValue,
                      "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)", String(slot)]
        guard let data = try? JSONEncoder().encode(fields) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func momentumAlert(_ trigger: StockSageMomentum.Trigger, mode: StockSageSameDayResearch.Mode, at now: Date) -> String? {
        guard momentumID(trigger, mode: mode, purpose: .observation) != nil,
              trackingWindow(at: now) != nil, (0...180).contains(now.timeIntervalSince(trigger.at)) else { return nil }
        let percent = String(format: "%+.2f%%", locale: Locale(identifier: "en_US_POSIX"), trigger.returnFraction * 100)
        let volume = String(format: "%.2fx", locale: Locale(identifier: "en_US_POSIX"), trigger.volumeMultiple)
        return "StockSage · \(mode.title) · \(trigger.symbol)\nHeavy momentum — observation, not a qualified trade\nCompleted five-minute return: \(percent)\nFive-minute volume: \(volume) the mean of the preceding three five-minute windows\nObserved through: \(trigger.at.ISO8601Format())\nSource: Massive completed split-adjusted minute bars. Unvalidated detection thresholds; no entry, stop, target or execution guarantee. A separate Astra review may follow when research capacity is available."
    }

    /// Commit an attempt before consuming subscription usage. Damage blocks, never erases history.
    func claim(_ id: String) -> Bool {
        claimFailure = nil
        guard mode.isAstra, id.count == 64, id.allSatisfy({ $0.isHexDigit }), let directory else {
            status = "Setup tracking is unavailable; no automatic assessment started."; claimFailure = status; return false
        }
        do {
            try requireWriter()
            for folder in [directory.deletingLastPathComponent(), directory] where FileManager.default.fileExists(atPath: folder.path) {
                let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("automatic-setups.json")
            let marker = directory.appendingPathComponent("automatic-setups.initialized")
            let activated = FileManager.default.fileExists(atPath: marker.path)
            if activated {
                let attributes = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, attributes.fileSize == 1,
                      try Data(contentsOf: marker) == Data([1]), FileManager.default.fileExists(atPath: path.path) else { throw CocoaError(.fileReadCorruptFile) }
            }
            var ids = Set<String>()
            if FileManager.default.fileExists(atPath: path.path) {
                let attributes = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                ids = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: path))
                guard ids.count <= 100_000, ids.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard !ids.contains(id) else { return false }
            guard ids.count < 100_000 else { status = "Saved setup tracking reached its limit. Existing attempts are preserved; watching cannot assess new setups."; claimFailure = status; return false }
            // A failed first write leaves a marker and blocks restart instead of forgetting an attempted setup.
            if !activated { try Data([1]).write(to: marker, options: [.withoutOverwriting, .completeFileProtection]) }
            ids.insert(id)
            try JSONEncoder().encode(ids).write(to: path, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch { status = "Setup history could not be saved or verified. No automatic assessment started; existing records are preserved."; claimFailure = status; return false }
    }

    func stop() {
        generation = UUID(); isEnabled = false; nextCheck = nil
        task?.cancel(); task = nil
        momentumTask?.cancel(); momentumTask = nil; nextMomentumCheck = nil
        #if os(macOS)
        resetMomentumWork()
        #endif
        momentumReviewsDeferred = 0
        eligibleHeavySymbols = []
        liveSymbols([])
        if let ownedRun, research.isRunning, research.receipt?.id == ownedRun { research.stop() }
        ownedRun = nil
        status = "Watching stopped. Saved research and alert attempts remain available."
        momentumStatus = "Momentum tracking is off. Earlier observations remain dated."
        momentumAlertStatus = "Automatic momentum alerts and reviews are off."
    }

    #if os(macOS)
    private func resetMomentumWork() {
        momentumSession = UUID()
        momentumConfirmationTask?.cancel(); momentumConfirmationTask = nil
        momentumDeliveryTask?.cancel(); momentumDeliveryTask = nil
        momentumReviewTask?.cancel(); momentumReviewTask = nil
        revokedEvents += nominations.count + pendingAlerts.count + pendingReviews.count
        nominations.removeAll(); attemptedNominations.removeAll()
        pendingAlerts.removeAll(); pendingReviews.removeAll(); momentumFeed = nil
        Self.confirmationWaiters.remove(mode)
        if let ownedRun, research.isRunning, research.receipt?.id == ownedRun,
           research.receipt?.checks.contains(where: { $0.momentumTrigger != nil }) == true { research.stop() }
    }

    private func updateMomentumWorkStatus() {
        let alerts = Self.prune(&pendingAlerts, at: Date()), reviews = Self.prune(&pendingReviews, at: Date())
        expiredObservations += alerts.expired; momentumReviewsDeferred += reviews.expired
        revokedEvents += alerts.revoked + reviews.revoked
        momentumWorkStatus = "Pending: \(nominations.count) confirmations, \(pendingAlerts.count) observations, \(pendingReviews.count) Astra reviews. \(expiredConfirmations) confirmations expired; \(rejectedConfirmations) did not confirm; \(expiredObservations) observations and \(momentumReviewsDeferred) reviews expired; \(revokedEvents) items revoked by a feed, classification, pairing or tracking change. No expired event is assessed."
    }

    /// The stream intake never waits for HTTP delivery or a model. Each worker retains its original feed generation.
    private func confirmMomentum(store: StockSageStore, access: StockSageMassive.Access,
        snapshot: StockSageMomentumStream.Snapshot, stillValid: @escaping @MainActor () -> Bool) {
        guard momentumConfirmationTask == nil, let profile = mode.screenProfile else { return }
        let session = momentumSession
        let captured = access.capture()
        let active: @MainActor () -> Bool = {
            guard !Task.isCancelled, self.momentumSession == session, captured.isCurrent(), stillValid(),
                  Self.trackingWindow(at: Date()) != nil, let current = self.momentumFeed,
                  current.feedID == snapshot.feedID, current.configurationID == snapshot.configurationID else { return false }
            return StockSageLiveStream.shared.isMomentumCurrent(current)
        }
        momentumConfirmationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.momentumSession == session {
                    self.momentumConfirmationTask = nil; Self.confirmationWaiters.remove(self.mode)
                    self.updateMomentumWorkStatus()
                }
            }
            // Keep proxy context available even on quiet days; its original timestamp is preserved by the shared cache.
            var needsMarket = self.marketMomentum.map { Date().timeIntervalSince($0.capturedAt) >= 120 } ?? true
            while active(), !self.nominations.isEmpty || needsMarket {
                let now = Date(), eligible = self.currentHeavySymbols(at: Date())
                self.nominations.removeAll { candidate in
                    if !eligible.contains(candidate.symbol) { self.revokedEvents += 1; return true }
                    if !(0...180).contains(now.timeIntervalSince(candidate.at)) { self.expiredConfirmations += 1; return true }
                    return false
                }
                let batch = Array(self.nominations.prefix(4))
                guard let batchSnapshot = self.momentumFeed else { return }
                let batchActive: @MainActor () -> Bool = {
                    active() && StockSageLiveStream.shared.isMomentumCurrent(batchSnapshot)
                }
                Self.confirmationWaiters.insert(self.mode)
                let refreshed = await self.refreshMomentum(candidates: batch.map(\.symbol), watchlist: [], at: now,
                    access: access, eligibleHeavy: eligible, stillValid: batchActive)
                guard active() else { return }
                guard refreshed else { try? await Task.sleep(for: .seconds(1)); continue }
                needsMarket = false
                for candidate in batch {
                    self.attemptedNominations[candidate.symbol] = candidate
                    self.nominations.removeAll { $0 == candidate }
                    guard let market = self.marketMomentum,
                          let stock = self.stockMomentum.first(where: { $0.symbol == candidate.symbol }),
                          stock.capturedAt >= now, let trigger = stock.heavyMomentum(profile: profile, now: Date()),
                          trigger.at >= candidate.at,
                          let id = Self.momentumID(trigger, mode: self.mode, purpose: .review) else {
                        self.rejectedConfirmations += 1; continue
                    }
                    let pairing = StockSageTelegram.shared.pairingRevision
                    let eventValid: @MainActor () -> Bool = {
                        batchActive() && StockSageTelegram.shared.isReady && StockSageTelegram.shared.pairingRevision == pairing
                            && self.currentHeavySymbols(at: Date(), only: stock.symbol).contains(stock.symbol)
                    }
                    guard eventValid() else { continue }
                    Self.enqueue(.init(id: id, stock: stock, market: market, trigger: trigger, stillValid: eventValid), into: &self.pendingAlerts)
                }
                self.deliverMomentum(store: store)
                self.updateMomentumWorkStatus()
                // Yield between bounded batches so the other cap mode can claim the shared four-request lease.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func deliverMomentum(store: StockSageStore) {
        guard momentumDeliveryTask == nil else { return }
        let session = momentumSession
        momentumDeliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.momentumSession == session { self.momentumDeliveryTask = nil; self.updateMomentumWorkStatus() } }
            while !Task.isCancelled, self.momentumSession == session, !self.pendingAlerts.isEmpty {
                let event = self.pendingAlerts.removeFirst()
                guard event.stillValid(), event.stock.heavyMomentum(profile: event.trigger.profile, now: Date()) == event.trigger,
                      let alertID = Self.momentumID(event.trigger, mode: self.mode, purpose: .observation),
                      let text = Self.momentumAlert(event.trigger, mode: self.mode, at: Date()) else {
                    self.revokedEvents += 1; continue
                }
                let result = await StockSageTelegram.shared.send(text: text, deliveryID: alertID, stillValid: {
                    event.stillValid() && event.stock.heavyMomentum(profile: event.trigger.profile, now: Date()) == event.trigger
                })
                guard !Task.isCancelled, self.momentumSession == session else { return }
                switch result {
                case .delivered: self.momentumAlertStatus = "Heavy-momentum observation sent. It is not a qualified trade."
                case .alreadyAttempted: self.momentumAlertStatus = "This observation already has a saved Telegram attempt; no duplicate was sent."
                case .blocked: self.momentumAlertStatus = "Telegram observation was blocked or expired; no delivery is claimed."
                case .unknown: self.momentumAlertStatus = "Observation delivery is unconfirmed. Its saved attempt will not retry automatically."
                }
                guard event.stillValid(), event.stock.heavyMomentum(profile: event.trigger.profile, now: Date()) == event.trigger else {
                    self.momentumReviewsDeferred += 1; continue
                }
                guard !self.research.savedReceipts.contains(where: { $0.checks.contains(where: { $0.setupID == event.id }) }) else { continue }
                Self.enqueue(event, into: &self.pendingReviews)
                self.reviewMomentum(store: store)
                self.updateMomentumWorkStatus()
            }
        }
    }

    private func reviewMomentum(store: StockSageStore) {
        guard momentumReviewTask == nil else { return }
        let session = momentumSession, engine = research
        momentumReviewTask = Task { [weak self] in
            guard let self else { return }
            var ownedReview: UUID?
            defer {
                if let ownedReview, self.ownedRun == ownedReview {
                    if engine.isRunning, engine.receipt?.id == ownedReview { engine.stop() }
                    self.ownedRun = nil
                }
                if self.momentumSession == session { self.momentumReviewTask = nil; self.updateMomentumWorkStatus() }
            }
            while !Task.isCancelled, self.momentumSession == session, !self.pendingReviews.isEmpty {
                // Keep queued observations visible while shared research capacity is occupied.
                self.pendingReviews.removeAll { event in
                    if !event.stillValid() { self.revokedEvents += 1; return true }
                    if event.stock.heavyMomentum(profile: event.trigger.profile, now: Date()) != event.trigger {
                        self.momentumReviewsDeferred += 1; return true
                    }
                    return false
                }
                guard !self.pendingReviews.isEmpty else { return }
                if StockSageSameDayResearch.anyRunning || StockSageHorizonResearch.shared.running != nil {
                    self.updateMomentumWorkStatus()
                    try? await Task.sleep(for: .milliseconds(250)); continue
                }
                let event = self.pendingReviews.removeFirst(), trigger = event.trigger, stock = event.stock
                let started = engine.startMomentum(store: store, trigger: trigger, stock: stock, market: event.market,
                    setupID: event.id, stillValid: event.stillValid, admitSetup: { id in
                        guard event.stillValid(), id == event.id,
                              stock.heavyMomentum(profile: trigger.profile, now: Date()) == trigger else { return false }
                        return self.claim(id)
                    })
                guard started, let receiptID = engine.receipt?.id else {
                    self.momentumAlertStatus = self.claimFailure ?? "Astra review did not start: its attempt was already saved or admission was unavailable."
                    continue
                }
                ownedReview = receiptID; self.ownedRun = receiptID
                while engine.isRunning, engine.receipt?.id == receiptID, event.stillValid() {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard event.stillValid() else {
                    if engine.isRunning, engine.receipt?.id == receiptID { engine.stop() }
                    if self.ownedRun == receiptID { self.ownedRun = nil }
                    self.revokedEvents += 1; continue
                }
                if self.ownedRun == receiptID { self.ownedRun = nil }; ownedReview = nil
                let completed = engine.receipt?.id == receiptID ? engine.receipt : engine.savedReceipts.first { $0.id == receiptID }
                guard let receipt = completed, receipt.id == receiptID, receipt.mode == self.mode,
                      receipt.finishedAt != nil, receipt.blocker == nil,
                      let check = receipt.checks.first, check.momentumTrigger == trigger,
                      check.codexAudit?.requestedModel == "gpt-6-astra", check.action != nil,
                      !check.qualified, check.scenario == nil, let reason = check.reason, let risk = check.risk,
                      let summaryID = Self.momentumID(trigger, mode: self.mode, purpose: .reviewSummary) else { continue }
                let text = "StockSage · \(self.mode.title) · \(check.symbol)\nAstra heavy-momentum review — not a qualified trade\nObservation: \(trigger.at.ISO8601Format())\nOpinion: \(check.action ?? "unavailable")\n\(reason)\nRisk: \(risk)\nDated descriptive review only; no qualified entry, stop or target. See all evidence and limitations in StockSage."
                let result = await StockSageTelegram.shared.send(text: text, deliveryID: summaryID, stillValid: {
                    event.stillValid() && (engine.receipt == receipt || engine.savedReceipts.contains(receipt))
                        && (0...180).contains(Date().timeIntervalSince(trigger.at))
                })
                guard !Task.isCancelled, self.momentumSession == session else { return }
                switch result {
                case .delivered: self.momentumAlertStatus = "Astra momentum review sent; no qualified trade or price plan."
                case .alreadyAttempted: self.momentumAlertStatus = "This Astra review already has a saved delivery attempt."
                case .blocked: self.momentumAlertStatus = "Astra review is saved; delivery was blocked or its observation expired."
                case .unknown: self.momentumAlertStatus = "Astra review is saved; Telegram delivery is unconfirmed and will not retry automatically."
                }
                self.updateMomentumWorkStatus()
            }
        }
    }

    func start(store: StockSageStore) {
        guard mode.isAstra, !isEnabled, !StockSageStore.isRunningTests else { return }
        guard ToolPolicy.isExternalAllowed, !store.isSampleData else { status = "Enable current market access before watching."; return }
        if let blocker = StockSageMassive.credentialAccessBlocker() { status = blocker; return }
        guard (try? requireWriter()) != nil else { status = "The research writer is unavailable."; return }
        let access = StockSageMassive.Access().capture(), run = UUID()
        generation = run; isEnabled = true
        let research = self.research
        let pinned = StockSageMassive.Access(key: { access.key }, credentialRevision: { nil }, policyRevision: { nil }, allowed: access.isCurrent)
        let active: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.generation == run && self.isEnabled && access.isCurrent() && !store.isSampleData
        }
        momentumTask = Task { [weak self] in
            guard let self else { return }
            while active() {
                let now = Date()
                guard Self.trackingWindow(at: now) != nil else {
                    self.liveSymbols([])
                    if self.momentumFeed != nil { self.resetMomentumWork() }
                    self.nextMomentumCheck = Self.nextTrackingStart(after: now)
                    self.momentumStatus = "Momentum paused outside Monday–Friday 11:00–23:00 Asia/Riyadh. Earlier observations remain dated."
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                let eligible = self.currentHeavySymbols(at: now)
                self.eligibleHeavySymbols = eligible
                self.liveSymbols(eligible.sorted())
                let live = StockSageLiveStream.shared
                live.start(symbols: [])
                guard let profile = self.mode.screenProfile,
                      let snapshot = await live.momentumSnapshot(symbols: eligible, profile: profile, now: now), active() else {
                    if self.momentumFeed != nil { self.resetMomentumWork() }
                    self.momentumStatus = "\(eligible.count) dated eligible symbols awaiting a current minute stream. Feed interruption or unavailable access cannot establish momentum. Load daily ratios in Stock screener if classifications are missing."
                    self.updateMomentumWorkStatus()
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                if self.momentumFeed?.feedID != snapshot.feedID || self.momentumFeed?.configurationID != snapshot.configurationID {
                    self.resetMomentumWork()
                }
                self.momentumFeed = snapshot
                self.attemptedNominations = self.attemptedNominations.filter { eligible.contains($0.key) }
                let candidates = Set(snapshot.candidates.map(\.symbol))
                self.nominations.removeAll { candidate in
                    if !candidates.contains(candidate.symbol) { self.revokedEvents += 1; return true }
                    return false
                }
                for candidate in snapshot.candidates where self.attemptedNominations[candidate.symbol] != candidate {
                    if let index = self.nominations.firstIndex(where: { $0.symbol == candidate.symbol }) { self.nominations[index] = candidate }
                    else { self.nominations.append(candidate) }
                }
                self.stockMomentum = self.stockMomentum.filter { eligible.contains($0.symbol) }
                self.momentumStatus = "Monitoring all \(eligible.count) dated eligible symbols: \(snapshot.ready) have twenty fresh complete positive-volume minutes; \(snapshot.warming) warming; \(snapshot.staleOrGapped) stale or gapped; \(snapshot.unsupported) unsupported. No 24-stock or display-row cutoff. Classifications missing from the loaded screener remain unknown; this is not the entire market. Streaming candidates require independent REST confirmation."
                self.nextMomentumCheck = now.addingTimeInterval(5)
                self.confirmMomentum(store: store, access: pinned, snapshot: snapshot, stillValid: active)
                self.updateMomentumWorkStatus()
                try? await Task.sleep(for: .seconds(5))
            }
            if self.generation == run { self.liveSymbols([]) }
        }
        task = Task { [weak self] in
            guard let self else { return }
            var admissionFailure: String?
            while active() {
                let now = Date()
                guard Self.trackingWindow(at: now) != nil else {
                    self.status = "Waiting for Monday–Friday 11:00–23:00 Asia/Riyadh. Automatic research and alerts are paused."
                    self.nextCheck = nil
                    self.liveSymbols([])
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                guard StockSageTelegram.shared.isReady else {
                    self.status = "Momentum tracking is enabled. Pair Telegram to enable automatic Astra fresh-setup and momentum assessments and alerts."
                    self.nextCheck = nil
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                guard let session = StockSageSameDayResearch.session(at: now), now >= session.open.addingTimeInterval(1800) else {
                    self.status = "Momentum tracking is enabled; automatic setups wait for a verified US regular session with thirty completed minutes. No off-session entry qualification."
                    self.nextCheck = nil
                    try? await Task.sleep(for: .seconds(30)); continue
                }
                if StockSageSameDayResearch.anyRunning || StockSageHorizonResearch.shared.running != nil {
                    self.status = "Waiting for the current research run to finish."
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                if let next = self.nextCheck, next > now {
                    try? await Task.sleep(for: .seconds(min(5, next.timeIntervalSince(now)))); continue
                }
                self.status = "Checking for a fresh qualifying setup…"
                let prior = Set(research.savedReceipts.flatMap(\.checks).compactMap(\.setupID))
                let pairing = StockSageTelegram.shared.pairingRevision
                let assessmentActive: @MainActor @Sendable () -> Bool = {
                    active() && Self.trackingWindow(at: Date()) != nil && StockSageTelegram.shared.isReady
                        && StockSageTelegram.shared.pairingRevision == pairing
                }
                let started = research.start(store: store, admitSetup: { [weak self] id in
                    guard assessmentActive(), admissionFailure == nil, !prior.contains(id), let self else { return false }
                    let claimed = self.claim(id)
                    if let failure = self.claimFailure { admissionFailure = failure }
                    return claimed
                }, stillValid: assessmentActive)
                if started {
                    let runID = research.receipt?.id
                    self.ownedRun = runID
                    while research.isRunning, research.receipt?.id == runID, assessmentActive() { try? await Task.sleep(for: .milliseconds(250)) }
                    guard active() else { break }
                    guard assessmentActive() else {
                        if research.isRunning, research.receipt?.id == runID { research.stop() }
                        if self.ownedRun == runID { self.ownedRun = nil }
                        self.status = "Automatic research paused because its tracking window or Telegram pairing changed. Momentum tracking follows the weekday schedule."
                        continue
                    }
                    if self.ownedRun == runID { self.ownedRun = nil }
                    if admissionFailure != nil { break }
                    if let receipt = research.receipt, receipt.id == runID, receipt.mode == self.mode,
                       let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }),
                       let text = Self.alert(receipt, at: Date()), let id = check.setupID {
                        let delivery = await StockSageTelegram.shared.send(text: text, deliveryID: id, stillValid: {
                            assessmentActive() && research.receipt?.id == receipt.id && StockSageSameDayResearch.current(receipt, at: Date())
                        })
                        guard active() else { break }
                        switch delivery {
                        case .delivered: self.status = "Fresh qualified pick sent to your paired Telegram chat."
                        case .alreadyAttempted: self.status = "This setup already has a recorded Telegram attempt; no duplicate was sent."
                        case .blocked: self.status = "Telegram delivery was blocked or the pick expired. The research is saved."
                        case .unknown: self.status = "Telegram delivery could not be confirmed. Check your phone; this attempt will not retry automatically."
                        }
                    } else { self.status = research.status }
                } else { self.status = research.status }
                self.nextCheck = Date().addingTimeInterval(Self.interval)
            }
            if self.generation == run {
                if let ownedRun = self.ownedRun, research.receipt?.id == ownedRun, research.isRunning { research.stop() }
                self.ownedRun = nil
                self.momentumTask?.cancel(); self.momentumTask = nil; self.nextMomentumCheck = nil
                self.momentumReviewTask?.cancel(); self.momentumReviewTask = nil
                self.liveSymbols([])
                self.isEnabled = false; self.nextCheck = nil; self.task = nil
                self.momentumStatus = "Momentum tracking paused. Earlier observations remain dated."
                self.status = admissionFailure ?? "Watching paused because access or app activity changed. Enable it again after checking setup."
            }
        }
    }
    #endif

    nonisolated static func alert(_ receipt: StockSageSameDayResearch.Receipt, at now: Date) -> String? {
        guard let mode = receipt.mode, mode.isAstra, trackingWindow(at: now) != nil,
              receipt.finishedAt != nil, receipt.blocker == nil,
              StockSageSameDayResearch.current(receipt, at: now),
              let check = receipt.checks.first(where: { $0.symbol == receipt.selectedSymbol }), check.qualified,
              check.codexAudit?.requestedModel == "gpt-6-astra", let plan = check.scenario else { return nil }
        func price(_ value: Double) -> String { String(format: "$%.4f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return "StockSage · \(mode.title) · \(check.symbol)\nGPT-6 Astra · same-day research\nObserved buy ceiling: \(price(plan.entry))\nStop reference: \(price(plan.stop))\nTarget reference: \(price(plan.target))\nQuote checked: \(check.verifiedQuote?.at.ISO8601Format() ?? "unavailable")\n\(check.reason ?? "")\nRisk: \(check.risk ?? "")\nUnvalidated screen; public Massive evidence. Dated research, not an order or a live execution guarantee. Recheck the market in StockSage before acting."
    }
}
