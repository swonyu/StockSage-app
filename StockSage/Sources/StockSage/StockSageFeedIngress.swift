import Foundation
import Synchronization

/// One serial parser; the receive callback never waits for MainActor or this actor.
/// Latest-value display cache, not a lossless tape or an execution-eligible quote source.
actor StockSageFeedIngress {
    typealias L = StockSageLiveStream
    nonisolated struct Limits: Sendable {
        var frameBytes = 1_048_576
        var queuedBytes = 8_388_608
        var queuedFrames = 8
        var symbols = 32_768
        var publicationSymbols = 4_096
    }
    nonisolated struct Metrics: Sendable, Equatable {
        var receivedFrames = 0, receivedBytes = 0, processedEvents = 0
        var coalesced = 0, rejected = 0, futureClocks = 0
        /// Healthy protocol outcomes: a duplicate or out-of-order trade, or a quote that did not
        /// supersede the stored one. Counted SEPARATELY from `rejected`, which means the provider
        /// sent something undecodable. The whole-market socket republishes the last trade for every
        /// selected symbol on every cycle, so this number is large and climbing when the feed is
        /// perfectly healthy — folding it into `rejected` made the diagnostics read as a broken
        /// feed during entirely normal operation.
        var superseded = 0
        var queuedFrames = 0, queuedBytes = 0, peakFrames = 0, peakBytes = 0
        var tradeSymbols = 0, quoteSymbols = 0
        var elapsed: TimeInterval = 0
        var receiveToProcess: TimeInterval = 0
        var peakReceiveToProcess: TimeInterval = 0
        var receiveToPublish: TimeInterval = 0
        var peakReceiveToPublish: TimeInterval = 0
        var sipToReceive: TimeInterval?
        var tradeSIPToReceive: TimeInterval?
        var quoteSIPToReceive: TimeInterval?
        var lastReceivedAt: Date?
        var failure: String?
    }
    nonisolated struct Snapshot: Sendable {
        var authorized = false
        var createdUptime = ProcessInfo.processInfo.systemUptime
        var trades: [String: L.Tick] = [:]
        /// Preserved before raw latest-value coalescing; valid only for this policy generation.
        var displayTrades: [String: L.Tick] = [:]
        var displayConditionGeneration: UUID?
        var quotes: [String: StockSageNBBO] = [:]
        /// Approves only the exact prior observations submitted with this capture.
        /// Primary records remain capped; identities let unchanged quotes survive rotation.
        var retainedQuoteSymbols: Set<String> = []
        var receivedUptime: [String: TimeInterval] = [:]
        var newestSIP: Date?
        var metrics = Metrics()
        func publicationExpired(at uptime: TimeInterval) -> Bool {
            !(0...L.maximumLiveAge).contains(uptime - createdUptime)
        }
    }
    nonisolated private struct Frame: Sendable {
        let data: Data
        let at: Date
        let uptime: TimeInterval
        let consumed: (@Sendable () -> Void)?
    }
    nonisolated private struct Mailbox: Sendable {
        var active = true, draining = false
        var frames: [Frame] = []
        var metrics = Metrics()
    }
    nonisolated let limits: Limits
    nonisolated private let mailbox = Mutex(Mailbox())
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var state: L.StreamState
    private var metrics = Metrics()
    private var tradeReceived: [String: TimeInterval] = [:]
    private var displayTradeReceived: [String: TimeInterval] = [:]
    private var latestDisplayTrades: [String: L.Tick] = [:]
    private var displayConditions: Set<Int64> = []
    private var displayConditionGeneration: UUID?
    private var quoteReceived: [String: TimeInterval] = [:]
    private var newestSIP: Date?
    private var newestQuoteSIP: Date?
    private var selected: Set<String> = []
    private var delayedQuotesSince: TimeInterval?
    private var delayedQuoteFrames = 0
    private let authorized: @Sendable (StockSageFeedIngress) -> Void
    private let failed: @Sendable () -> Void

    init(limits: Limits = Limits(), authorized: @escaping @Sendable (StockSageFeedIngress) -> Void = { _ in },
         failed: @escaping @Sendable () -> Void = {}) {
        self.limits = limits
        state = L.StreamState(symbolLimit: limits.symbols)
        self.authorized = authorized
        self.failed = failed
    }

    /// A fresh ingress object is created per socket. Invalidated objects never accept late callbacks.
    /// Consumed rearms native receiving only after processing; failed/discarded frames do not call it.
    @discardableResult
    nonisolated func offer(_ data: Data, at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                           consumed: (@Sendable () -> Void)? = nil) -> Bool {
        let result = mailbox.withLock { box -> (Bool, Bool, Bool) in
            guard box.active else { return (false, false, false) }
            box.metrics.receivedFrames += 1
            box.metrics.receivedBytes += data.count
            box.metrics.lastReceivedAt = at
            guard data.count <= limits.frameBytes, box.frames.count < limits.queuedFrames,
                  box.metrics.queuedBytes + data.count <= limits.queuedBytes else {
                box.active = false
                let boundary = data.count > limits.frameBytes ? "frame-size limit"
                    : box.frames.count >= limits.queuedFrames ? "queued-frame limit" : "queued-byte limit"
                box.metrics.failure = "Feed overloaded: raw frame capacity exceeded (\(boundary); incoming=\(data.count)B queued=\(box.frames.count)/\(box.metrics.queuedBytes)B); gap and reconnect"
                box.frames.removeAll(); box.metrics.queuedBytes = 0; box.metrics.queuedFrames = 0
                return (false, false, true)
            }
            box.frames.append(Frame(data: data, at: at, uptime: uptime, consumed: consumed))
            box.metrics.queuedFrames = box.frames.count
            box.metrics.queuedBytes += data.count
            box.metrics.peakFrames = max(box.metrics.peakFrames, box.frames.count)
            box.metrics.peakBytes = max(box.metrics.peakBytes, box.metrics.queuedBytes)
            let schedule = !box.draining
            box.draining = true
            return (true, schedule, false)
        }
        if result.1 { Task { await drain() } }
        if result.2 { failed() }
        return result.0
    }

    nonisolated func invalidate(_ reason: String? = nil) {
        let notify = mailbox.withLock { box in
            let wasActive = box.active
            box.active = false
            if let reason, box.metrics.failure == nil { box.metrics.failure = reason }
            box.frames.removeAll(); box.metrics.queuedBytes = 0; box.metrics.queuedFrames = 0
            return wasActive && reason != nil
        }
        if notify { failed() }
    }

    nonisolated var isActive: Bool { mailbox.withLock { $0.active } }
    nonisolated var failureReason: String? { mailbox.withLock { $0.metrics.failure } }

    /// Called immediately before MainActor consumption: a previously captured snapshot
    /// cannot restore liquidity after this same session was invalidated off-main.
    nonisolated func acceptsPublication(_ snapshot: Snapshot, at uptime: TimeInterval) -> Bool {
        isActive && snapshot.metrics.failure == nil && !snapshot.publicationExpired(at: uptime)
    }

    private func drain() async {
        while let frame = mailbox.withLock({ box -> Frame? in
            guard box.active, !box.frames.isEmpty else { box.draining = false; return nil }
            let frame = box.frames.removeFirst() // At most eight frames, never a growing queue.
            box.metrics.queuedFrames = box.frames.count
            box.metrics.queuedBytes -= frame.data.count
            return frame
        }) {
            autoreleasepool { process(frame) }
            // Outside the lock: registering the next asynchronous receive may immediately offer.
            // This paces our native chain, not Foundation/server buffering; SIP age checks still apply.
            if isActive { frame.consumed?() }
            await Task.yield() // Let the single pending UI snapshot run between bounded frames.
        }
    }

    private func process(_ frame: Frame) {
        let start = ProcessInfo.processInfo.systemUptime
        guard start - frame.uptime <= L.maximumLiveAge else {
            invalidate("Feed consumer backlog exceeded 10s; gap and reconnect"); return
        }
        let decoded = L.decode(frame.data)
        guard isActive else { return }
        metrics.rejected += decoded.rejected
        var frameSIP: Date?
        var frameQuoteSIP: Date?
        var frameTradeSIP: Date?
        for event in decoded.events {
            let wasAuthorized = state.isAuthorized
            let oldTrades = state.latestTrades.count, oldQuotes = state.latestQuotes.count
            let oldQuote: StockSageNBBO?
            if case .quote(let quote) = event { oldQuote = state.latestQuotes[quote.symbol] } else { oldQuote = nil }
            let tick = state.consume(event, now: frame.at)
            metrics.processedEvents += 1
            switch event {
            case .status("auth_failed"), .status("error"):
                invalidate("Feed authentication/subscription failed; gap and reconnect"); return
            case .status("connected"):
                if wasAuthorized {
                    invalidate("Feed authorization reset; gap and reconnect"); return
                }
                tradeReceived.removeAll(); displayTradeReceived.removeAll(); latestDisplayTrades.removeAll()
                quoteReceived.removeAll(); newestSIP = nil; newestQuoteSIP = nil
                metrics.sipToReceive = nil; metrics.tradeSIPToReceive = nil; metrics.quoteSIPToReceive = nil
                delayedQuotesSince = nil; delayedQuoteFrames = 0
            case .trade(let observation):
                if observation.timestamp > frame.at { metrics.futureClocks += 1 }
                if state.isAuthorized, observation.timestamp <= frame.at {
                    frameSIP = max(frameSIP ?? observation.timestamp, observation.timestamp)
                    frameTradeSIP = max(frameTradeSIP ?? observation.timestamp, observation.timestamp)
                }
                if let tick {
                    if oldTrades == state.latestTrades.count { metrics.coalesced += 1 }
                    if selected.contains(tick.symbol) { tradeReceived[tick.symbol] = frame.uptime }
                } else { metrics.superseded += 1 }
                // A later raw special-condition trade must not erase the last eligible price.
                // Display ordering is independent of the raw cache's most recent sequence.
                if state.isAuthorized, state.latestTrades[observation.symbol] != nil,
                   StockSageMassiveTicks.qualifiesDisplayTrade(conditions: observation.conditions,
                       allowed: displayConditions, sip: observation.timestamp, participant: observation.participantTime),
                   StockSageStore.acceptsLiveTick(observation.timestamp,
                       after: latestDisplayTrades[observation.symbol]?.timestamp,
                       massiveTradeSequence: observation.sequence,
                       afterMassiveTradeSequence: latestDisplayTrades[observation.symbol]?.sequence, now: frame.at) {
                    latestDisplayTrades[observation.symbol] = observation
                    if selected.contains(observation.symbol) { displayTradeReceived[observation.symbol] = frame.uptime }
                }
            case .quote(let observation):
                if observation.timestamp > frame.at { metrics.futureClocks += 1 }
                if state.isAuthorized, observation.timestamp <= frame.at {
                    frameSIP = max(frameSIP ?? observation.timestamp, observation.timestamp)
                    frameQuoteSIP = max(frameQuoteSIP ?? observation.timestamp, observation.timestamp)
                }
                if oldQuote != observation, state.latestQuotes[observation.symbol] == observation {
                    if oldQuotes == state.latestQuotes.count { metrics.coalesced += 1 }
                    if selected.contains(observation.symbol) { quoteReceived[observation.symbol] = frame.uptime }
                } else { metrics.superseded += 1 }
            case .status: break
            }
            if state.capacityExceeded {
                invalidate("Feed overloaded: symbol capacity exceeded; gap and reconnect"); return
            }
            if !wasAuthorized, state.isAuthorized { authorized(self) }
        }
        if let frameSIP {
            metrics.sipToReceive = frame.at.timeIntervalSince(frameSIP)
            newestSIP = max(newestSIP ?? frameSIP, frameSIP)
        }
        if let frameTradeSIP { metrics.tradeSIPToReceive = frame.at.timeIntervalSince(frameTradeSIP) }
        if let frameQuoteSIP {
            metrics.quoteSIPToReceive = frame.at.timeIntervalSince(frameQuoteSIP)
            newestQuoteSIP = max(newestQuoteSIP ?? frameQuoteSIP, frameQuoteSIP)
            if let newestQuoteSIP, L.isLiveObservation(newestQuoteSIP, at: frame.at) {
                delayedQuotesSince = nil; delayedQuoteFrames = 0
            } else if state.isAuthorized {
                // ponytail: sustained stale quotes suggest upstream/socket buffering, but clock
                // skew is indistinguishable here; synchronized-clock telemetry is the upgrade.
                delayedQuotesSince = delayedQuotesSince ?? frame.uptime
                delayedQuoteFrames += 1
                if delayedQuoteFrames >= 3, let since = delayedQuotesSince, frame.uptime - since >= 1 {
                    invalidate("Sustained SIP quote delay over 10s (upstream/backlog or clock skew); gap and reconnect")
                }
            }
        }
        metrics.receiveToProcess = ProcessInfo.processInfo.systemUptime - frame.uptime
        metrics.peakReceiveToProcess = max(metrics.peakReceiveToProcess, metrics.receiveToProcess)
        if metrics.receiveToProcess > L.maximumLiveAge {
            invalidate("Feed processing exceeded 10s; gap and reconnect")
        }
    }

    /// One caller awaits one snapshot; selection is capped even if the board grows unexpectedly.
    func snapshot(symbols: [String], now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                  retainingQuotes: [String: StockSageNBBO] = [:],
                  displayConditions requestedConditions: Set<Int64>? = nil,
                  displayConditionGeneration requestedGeneration: UUID? = nil) -> Snapshot {
        guard retainingQuotes.count <= limits.symbols else {
            invalidate("Feed overloaded: retained quote capacity exceeded; gap and reconnect")
            return Snapshot(metrics: Metrics(failure: failureReason))
        }
        if !symbols.isEmpty {
            selected = Set(symbols.prefix(limits.publicationSymbols))
            tradeReceived = tradeReceived.filter { selected.contains($0.key) }
            displayTradeReceived = displayTradeReceived.filter { selected.contains($0.key) }
            quoteReceived = quoteReceived.filter { selected.contains($0.key) }
        }
        let raw = mailbox.withLock { $0.metrics }
        var report = metrics
        report.elapsed = max(0, uptime - startedUptime)
        report.receivedFrames = raw.receivedFrames; report.receivedBytes = raw.receivedBytes
        report.queuedFrames = raw.queuedFrames; report.queuedBytes = raw.queuedBytes
        report.peakFrames = raw.peakFrames; report.peakBytes = raw.peakBytes
        report.lastReceivedAt = raw.lastReceivedAt; report.failure = raw.failure
        report.tradeSymbols = state.latestTrades.count; report.quoteSymbols = state.latestQuotes.count
        guard isActive else {
            state = L.StreamState(symbolLimit: limits.symbols)
            tradeReceived.removeAll(); displayTradeReceived.removeAll(); latestDisplayTrades.removeAll()
            quoteReceived.removeAll(); newestSIP = nil
            return Snapshot(metrics: report)
        }
        let oldest = mailbox.withLock { $0.frames.first?.uptime }
        if let oldest, uptime - oldest > L.maximumLiveAge {
            invalidate("Feed consumer backlog exceeded 10s; gap and reconnect")
            report.failure = mailbox.withLock { $0.metrics.failure }
            return Snapshot(metrics: report)
        }
        if let requestedConditions,
           requestedConditions != displayConditions || requestedGeneration != displayConditionGeneration {
            displayConditions = requestedConditions
            displayConditionGeneration = requestedGeneration
            latestDisplayTrades = state.latestTrades.filter {
                StockSageMassiveTicks.qualifiesDisplayTrade(conditions: $0.value.conditions,
                    allowed: requestedConditions, sip: $0.value.timestamp, participant: $0.value.participantTime)
            }
            displayTradeReceived = tradeReceived.filter { latestDisplayTrades[$0.key] != nil }
        }
        var snapshot = Snapshot(authorized: state.isAuthorized, displayConditionGeneration: displayConditionGeneration,
                                newestSIP: newestSIP, metrics: report)
        for symbol in symbols.prefix(limits.publicationSymbols) {
            snapshot.trades[symbol] = state.latestTrades[symbol]
            snapshot.displayTrades[symbol] = latestDisplayTrades[symbol]
            snapshot.quotes[symbol] = state.latestQuotes[symbol]
            // Only outstanding replacements contribute to receive-to-publish delay. A quiet
            // symbol's observation age is not local backlog. Caller acknowledges after publish.
            if let at = tradeReceived[symbol] { snapshot.receivedUptime["T." + symbol] = at }
            if let at = displayTradeReceived[symbol] { snapshot.receivedUptime["D." + symbol] = at }
            if let at = quoteReceived[symbol] { snapshot.receivedUptime["Q." + symbol] = at }
        }
        if state.isAuthorized, !symbols.isEmpty {
            for (symbol, previous) in retainingQuotes where !selected.contains(symbol) {
                guard previous.symbol == symbol, let current = state.latestQuotes[symbol], current.isFresh(at: now),
                      current.qualifyingCosts(regularConditions: []) == previous.qualifyingCosts(regularConditions: []) else { continue }
                snapshot.retainedQuoteSymbols.insert(symbol)
            }
        }
        return snapshot
    }

    func acknowledge(_ received: [String: TimeInterval], at uptime: TimeInterval) {
        for (key, at) in received {
            let symbol = String(key.dropFirst(2))
            if key.hasPrefix("T."), tradeReceived[symbol] == at { tradeReceived[symbol] = nil }
            if key.hasPrefix("D."), displayTradeReceived[symbol] == at { displayTradeReceived[symbol] = nil }
            if key.hasPrefix("Q."), quoteReceived[symbol] == at { quoteReceived[symbol] = nil }
        }
        metrics.receiveToPublish = received.values.map { max(0, uptime - $0) }.max() ?? 0
        metrics.peakReceiveToPublish = max(metrics.peakReceiveToPublish, metrics.receiveToPublish)
    }
}
