import Foundation
import Testing
import Darwin
import Synchronization
@testable import StockSage

extension StockSageFeedIngressTests {
    @Test @MainActor func extendedTradesReachDisplayWithoutChangingRawOrderingOrResearch() async throws {
        let at = try #require(ISO8601DateFormatter().date(from: "2026-09-22T21:00:00Z"))
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        await live.refreshReferences(now: at, stillValid: { true }, displayConditions: { [0, 12] },
            conditions: { [] }, exchangeList: { [:] })?.value
        #expect(ingress.offer(auth, at: at))
        _ = try await drained(ingress)
        let policy = live.displayTradePolicy(at: at)
        _ = await ingress.snapshot(symbols: ["AAPL"], now: at,
            displayConditions: policy.conditions, displayConditionGeneration: policy.generation)
        let milliseconds = Int64(at.timeIntervalSince1970 * 1_000)
        let bytes = Data("[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":105,\"t\":\(milliseconds),\"pt\":\(milliseconds),\"c\":[12],\"q\":1},{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":999,\"t\":\(milliseconds),\"pt\":\(milliseconds),\"c\":[12,13],\"q\":2}]".utf8)
        #expect(ingress.offer(bytes, at: at))
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        #expect(snapshot.trades["AAPL"]?.price == 999)
        #expect(snapshot.displayTrades["AAPL"]?.price == 105)
        let published = live.publish(snapshot, from: ingress, now: at) { ticks, _, _ in
            #expect(ticks["AAPL"]?.price == 105)
            #expect(ticks["AAPL"]?.timestamp == at)
        }
        #expect(published)
    }

    typealias M = StockSageMomentumStream
    private var minuteNow: Date { Date(timeIntervalSince1970: 1_700_006_400) }

    private func minutes(_ symbol: String = "BRK.B", lastClose: Double = 105) -> [M.Minute] {
        (0..<20).map { index in
            let start = minuteNow.addingTimeInterval(Double(index - 20) * 60)
            let close = index == 19 ? lastClose : 100
            return M.Minute(symbol: symbol, start: start, end: start.addingTimeInterval(60),
                open: 100, high: max(100, close), low: min(100, close), close: close,
                volume: index >= 15 ? 400 : 100)
        }
    }

    @Test func aggregateMinutesDecodeWithoutTradeClockAndRejectMalformedCorrections() throws {
        let row: [String: Any] = ["ev": "AM", "sym": "BRK.B", "s": 1_700_006_340_000,
            "e": 1_700_006_400_000, "o": 100, "h": 105, "l": 99, "c": 104, "v": 400]
        let data = try JSONSerialization.data(withJSONObject: [row])
        let decoded = L.decode(data)
        #expect(decoded.rejected == 0)
        guard case .minute(let minute) = try #require(decoded.events.first) else {
            Issue.record("Expected a minute aggregate, not a trade"); return
        }
        #expect(minute.symbol == "BRK.B" && minute.end == minuteNow)
        for (key, value) in [("v", true as Any), ("e", 1_700_006_399_999 as Any), ("h", 90 as Any)] {
            var invalid = row; invalid[key] = value
            let invalidData = try JSONSerialization.data(withJSONObject: [invalid])
            #expect(L.decode(invalidData).events == [.invalidMinute("BRK.B")])
        }
    }

    @Test func provisionalCandidatesUseAllTwentyMinutesAndReplaceCorrections() {
        var state = M.State()
        let configured1 = state.configure(symbols: ["BRK.B"])
        #expect(configured1)
        let original = minutes(lastClose: 101.5)
        for bar in original { state.consume(bar, now: minuteNow) }
        let small = state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(small.ready == 1 && small.candidates.isEmpty)
        let large = state.snapshot(symbols: ["BRK.B"], profile: .largecap, now: minuteNow)
        #expect(large.candidates == [.init(symbol: "BRK.B", at: minuteNow, revision: original.hashValue)])
        // Repeated frames replace the same bucket; they cannot multiply prior-window volume.
        for bar in original { state.consume(bar, now: minuteNow) }
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .largecap, now: minuteNow) == large)
        // Current unfinished minutes and older irrelevant corrections must not retrigger REST.
        for volume in [100.0, 500.0] {
            state.consume(.init(symbol: "BRK.B", start: minuteNow, end: minuteNow.addingTimeInterval(60),
                open: 100, high: 110, low: 100, close: 110, volume: volume), now: minuteNow.addingTimeInterval(30))
        }
        let oldStart = minuteNow.addingTimeInterval(-1_800)
        state.consume(.init(symbol: "BRK.B", start: oldStart, end: oldStart.addingTimeInterval(60),
            open: 100, high: 200, low: 100, close: 200, volume: 2_000), now: minuteNow)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .largecap, now: minuteNow.addingTimeInterval(30)).candidates == large.candidates)
        for bar in minutes(lastClose: 96) { state.consume(bar, now: minuteNow) }
        let corrected = state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(corrected.candidates == [.init(symbol: "BRK.B", at: minuteNow, revision: minutes(lastClose: 96).hashValue)])
        #expect(corrected.candidates != large.candidates)
        let final = original[19]
        state.consume(.init(symbol: final.symbol, start: final.start, end: final.end,
            open: 100, high: 100, low: 100, close: 100, volume: 100), now: minuteNow)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow).candidates.isEmpty)
    }

    @Test func minuteCoverageDistinguishesWarmGapStaleUnsupportedAndFuture() {
        var state = M.State()
        let configured2 = state.configure(symbols: ["BRK.B", "WARM", "GAP", "ZERO", "FUTURE"])
        #expect(configured2)
        for bar in minutes() { state.consume(bar, now: minuteNow) }
        for bar in minutes("WARM").suffix(19) { state.consume(bar, now: minuteNow) }
        for (index, bar) in minutes("GAP").enumerated() where index != 8 { state.consume(bar, now: minuteNow) }
        for (index, bar) in minutes("ZERO").enumerated() {
            state.consume(.init(symbol: bar.symbol, start: bar.start, end: bar.end, open: bar.open,
                high: bar.high, low: bar.low, close: bar.close, volume: index == 8 ? 0 : bar.volume), now: minuteNow)
        }
        for bar in minutes("FUTURE") { state.consume(bar, now: minuteNow.addingTimeInterval(-60)) }
        let result = state.snapshot(symbols: ["BRK.B", "WARM", "GAP", "ZERO", "bad", "FUTURE"], profile: .microcap, now: minuteNow.addingTimeInterval(-1))
        #expect(result.ready == 0 && result.warming == 3 && result.staleOrGapped == 2 && result.unsupported == 1)
        #expect(result.candidates.isEmpty)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow.addingTimeInterval(181)).staleOrGapped == 1)
        state.invalidate(symbol: "BRK.B")
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow).warming == 1)
    }

    @Test func minuteDetectionIsNotLimitedToTheDisplayRotationAndRemovalDropsHistory() {
        let symbols = Set((0..<5_000).map { "S\($0)" }).union(["BRK.B"])
        var state = M.State()
        let configured3 = state.configure(symbols: symbols)
        #expect(configured3)
        for bar in minutes() { state.consume(bar, now: minuteNow) }
        let snapshot = state.snapshot(symbols: symbols, profile: .microcap, now: minuteNow)
        #expect(snapshot.symbols.count == 5_001 && snapshot.ready == 1 && snapshot.warming == 5_000)
        #expect(snapshot.candidates == [.init(symbol: "BRK.B", at: minuteNow, revision: minutes().hashValue)])
        let configured4 = state.configure(symbols: [])
        #expect(configured4)
        let configured5 = state.configure(symbols: ["BRK.B"])
        #expect(configured5)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow).warming == 1)
        let configured6 = state.configure(symbols: Set((0..<32_769).map { "S\($0)" }))
        #expect(!configured6)
    }

    @Test func minuteIngressRequiresAuthorizationAndCannotSurviveSessionGap() async throws {
        let source = I(momentumSymbols: ["BRK.B"])
        defer { source.invalidate() }
        let rows: [[String: Any]] = minutes().map { bar in
            ["ev": "AM", "sym": bar.symbol, "s": bar.start.timeIntervalSince1970 * 1_000,
             "e": bar.end.timeIntervalSince1970 * 1_000, "o": bar.open, "h": bar.high,
             "l": bar.low, "c": bar.close, "v": bar.volume]
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        #expect(source.offer(data, at: minuteNow))
        _ = try await drained(source)
        let unauthorized = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(unauthorized == nil)
        #expect(source.offer(auth, at: minuteNow))
        #expect(source.offer(data, at: minuteNow))
        _ = try await drained(source)
        let captured = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        let snapshot = try #require(captured)
        #expect(snapshot.ready == 1 && snapshot.candidates.count == 1)
        #expect(source.acceptsMomentum(snapshot, now: minuteNow))
        let otherSession = I(momentumSymbols: ["BRK.B"])
        defer { otherSession.invalidate() }
        #expect(!otherSession.acceptsMomentum(snapshot, now: minuteNow))
        source.invalidate("Synthetic feed gap")
        #expect(!source.acceptsMomentum(snapshot, now: minuteNow))
        #expect(!source.offer(data, at: minuteNow))
        let invalidated = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(invalidated == nil)
    }

    @Test func minuteRetentionAndConfigurationAreBoundedWithoutSilentUniverseTruncation() async throws {
        var state = M.State()
        let configured7 = state.configure(symbols: ["BRK.B"])
        #expect(configured7)
        for bar in minutes() { state.consume(bar, now: minuteNow) }
        for index in 0..<60 {
            let start = minuteNow.addingTimeInterval(Double(index) * 60)
            state.consume(.init(symbol: "BRK.B", start: start, end: start.addingTimeInterval(60),
                open: 100, high: 100, low: 100, close: 100, volume: 100), now: start.addingTimeInterval(60))
        }
        // Old observations cannot be reconstructed out of the bounded hot minute window.
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow).warming == 1)
        let later = minuteNow.addingTimeInterval(3_600)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: later).ready == 1)
        let revision = UUID()
        let configured8 = state.configure(symbols: ["BRK.B"], configurationID: revision)
        #expect(configured8)
        #expect(state.snapshot(symbols: ["BRK.B"], profile: .microcap, now: later).ready == 1)

        var limits = I.Limits(); limits.symbols = 2
        let source = I(limits: limits, momentumSymbols: ["BRK.B"])
        defer { source.invalidate() }
        await source.configureMomentum(symbols: ["BRK.B", "SPY", "QQQ"], configurationID: UUID())
        #expect(!source.isActive && source.failureReason?.contains("momentum symbol capacity") == true)
        let failed = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(failed == nil)
    }

    @Test func malformedMinuteCorrectionAndConfigurationRevokePriorNomination() async throws {
        let source = I(momentumSymbols: ["BRK.B"])
        defer { source.invalidate() }
        let rows: [[String: Any]] = minutes().map { bar in
            ["ev": "AM", "sym": bar.symbol, "s": bar.start.timeIntervalSince1970 * 1_000,
             "e": bar.end.timeIntervalSince1970 * 1_000, "o": bar.open, "h": bar.high,
             "l": bar.low, "c": bar.close, "v": bar.volume]
        }
        #expect(source.offer(auth, at: minuteNow))
        let data = try JSONSerialization.data(withJSONObject: rows)
        #expect(source.offer(data, at: minuteNow))
        _ = try await drained(source)
        let before = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        let captured = try #require(before)
        #expect(captured.candidates.count == 1)
        var correction = try #require(rows.last); correction["v"] = true
        let invalidData = try JSONSerialization.data(withJSONObject: [correction])
        #expect(source.offer(invalidData, at: minuteNow))
        _ = try await drained(source)
        let after = await source.momentumSnapshot(symbols: ["BRK.B"], profile: .microcap, now: minuteNow)
        #expect(after?.warming == 1 && after?.candidates.isEmpty == true)
        await source.configureMomentum(symbols: [], configurationID: UUID())
        #expect(!source.acceptsMomentum(captured, now: minuteNow))
    }

    @MainActor @Test func membershipEpochsPreserveOtherCapWarmupButDetectUnpublishedDisableAndReenable() {
        let live = L()
        live.microcapSymbols = ["MICRO"]
        let firstMembership = live.momentumMemberships
        var state = M.State()
        let configured = state.configure(symbols: Set(firstMembership.keys), configurationID: UUID(),
                                         memberships: firstMembership)
        #expect(configured)
        for bar in minutes("MICRO") { state.consume(bar, now: minuteNow) }

        live.largecapSymbols = ["LARGE"]
        #expect(live.momentumMemberships["MICRO"] == firstMembership["MICRO"])
        #expect(live.momentumMemberships["SPY"] == firstMembership["SPY"])
        let enlarged = state.configure(symbols: Set(live.momentumMemberships.keys), configurationID: UUID(),
                                       memberships: live.momentumMemberships)
        #expect(enlarged)
        #expect(state.snapshot(symbols: ["MICRO"], profile: .microcap, now: minuteNow).ready == 1)
        for bar in minutes("LARGE") { state.consume(bar, now: minuteNow) }

        // The ingress sees only the final union, while setters observe both membership transitions.
        live.microcapSymbols = []
        live.microcapSymbols = ["MICRO"]
        #expect(live.momentumMemberships["MICRO"] != firstMembership["MICRO"])
        #expect(live.momentumMemberships["QQQ"] == firstMembership["QQQ"])
        let reenabled = state.configure(symbols: Set(live.momentumMemberships.keys), configurationID: UUID(),
                                        memberships: live.momentumMemberships)
        #expect(reenabled)
        #expect(state.snapshot(symbols: ["MICRO"], profile: .microcap, now: minuteNow).warming == 1)
        #expect(state.snapshot(symbols: ["LARGE"], profile: .largecap, now: minuteNow).ready == 1)
        live.microcapSymbols = []; live.largecapSymbols = []
        #expect(live.momentumMemberships.isEmpty)
    }
}

@Suite("Bounded whole-market ingestion")
struct StockSageFeedIngressTests {
    typealias I = StockSageFeedIngress
    typealias L = StockSageLiveStream
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let auth = Data(#"[{"ev":"status","status":"auth_success"}]"#.utf8)

    nonisolated static func offerNext(_ source: I, sequence: Int, total: Int, at: Date,
                                     didConsume: @escaping @Sendable () -> Void) {
        let data = Data("[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":\(100 + sequence),\"t\":1700000000000,\"q\":\(sequence)}]".utf8)
        source.offer(data, at: at, consumed: {
            didConsume()
            if sequence < total { offerNext(source, sequence: sequence + 1, total: total, at: at, didConsume: didConsume) }
        })
    }

    @Test func receiveContinuationWaitsForConsumptionBeforeRearming() async throws {
        let callbacks = Mutex(0)
        let at = now
        let ingress = I(authorized: { source in
            Self.offerNext(source, sequence: 1, total: 100, at: at, didConsume: { callbacks.withLock { $0 += 1 } })
        })
        defer { ingress.invalidate() }
        #expect(ingress.offer(auth, at: now))
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        #expect(snapshot.metrics.failure == nil && ingress.isActive)
        #expect(callbacks.withLock { $0 } == 100)
        #expect(snapshot.metrics.processedEvents == 101)
        #expect(snapshot.metrics.peakFrames == 1)
        #expect(snapshot.trades["AAPL"]?.price == 200)
        print("FEED_PACED_BURST callbacks=\(callbacks.withLock { $0 }) processed=\(snapshot.metrics.processedEvents) peak_frames=\(snapshot.metrics.peakFrames)")
    }

    @Test(arguments: ["[]", "not-json", #"[{"ev":"status","status":"connected"}]"#])
    func ignoredFramesStillContinueReceiving(_ text: String) async throws {
        let callbacks = Mutex(0), ingress = I()
        defer { ingress.invalidate() }
        let accepted = ingress.offer(Data(text.utf8), consumed: { callbacks.withLock { $0 += 1 } })
        #expect(accepted)
        let snapshot = try await drained(ingress)
        #expect(snapshot.metrics.failure == nil && callbacks.withLock { $0 } == 1)
    }

    @Test(arguments: ["stop", "auth", "old", "discard", "overflow", "oversize"])
    func failedOrStoppedFrameCannotContinueReceiving(_ mode: String) async throws {
        let callbacks = Mutex(0)
        let queued = Data("[]".utf8)
        let ingress = I(authorized: { source in
            if mode == "stop" { source.invalidate() }
            if mode == "discard" || mode == "overflow" {
                for _ in 0..<(mode == "overflow" ? 9 : 1) {
                    source.offer(queued, consumed: { callbacks.withLock { $0 += 1 } })
                }
                source.invalidate()
            }
        })
        defer { ingress.invalidate() }
        let data = mode == "oversize" ? Data(repeating: 32, count: I.Limits().frameBytes + 1)
            : mode == "auth" ? Data(#"[{"ev":"status","status":"auth_failed"}]"#.utf8) : auth
        let uptime = ProcessInfo.processInfo.systemUptime - (mode == "old" ? 11 : 0)
        let accepted = ingress.offer(data, at: now, uptime: uptime, consumed: { callbacks.withLock { $0 += 1 } })
        #expect(accepted == (mode != "oversize"))
        _ = try await drained(ingress)
        #expect(!ingress.isActive && callbacks.withLock { $0 } == 0)
        let late = ingress.offer(auth, consumed: { callbacks.withLock { $0 += 1 } })
        #expect(!late)
        #expect(callbacks.withLock { $0 } == 0)

        let replacement = I()
        defer { replacement.invalidate() }
        #expect(replacement.offer(auth, at: now))
        #expect(try await drained(replacement).authorized)
        #expect(callbacks.withLock { $0 } == 0, "Discarded old-session callbacks cannot advance the replacement")
    }

    @Test func smallUnpacedBurstReportsTheActualCapacityBoundary() async throws {
        let accepted = Mutex([Bool]())
        let failures = Mutex(0)
        let frame = Data(#"[{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"t":1700000000000}]"#.utf8)
        let at = now
        let ingress = I(authorized: { source in
            // Hold the real serial parser in its auth callback. No timing/scheduler assumption.
            for _ in 0..<9 { accepted.withLock { $0.append(source.offer(frame, at: at)) } }
        }, failed: { failures.withLock { $0 += 1 } })
        defer { ingress.invalidate() }
        #expect(ingress.offer(auth, at: now))
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        #expect(accepted.withLock { $0 } == Array(repeating: true, count: 8) + [false])
        #expect(failures.withLock { $0 } == 1)
        #expect(snapshot.metrics.peakFrames == 8 && snapshot.metrics.peakBytes == frame.count * 8)
        #expect(snapshot.quotes.isEmpty && !snapshot.authorized && !ingress.isActive)
        #expect(snapshot.metrics.failure?.contains("queued-frame limit") == true)
        #expect(snapshot.metrics.failure?.contains("incoming=\(frame.count)B queued=8/\(frame.count * 8)B") == true)
        #expect(!ingress.offer(frame, at: now))
        print("FEED_TINY_BURST accepted=8 rejected=1 peak_bytes=\(snapshot.metrics.peakBytes) reason=\(snapshot.metrics.failure ?? "none")")
    }

    @Test(arguments: [false, true]) @MainActor
    func mixedQuoteFrameCannotRefreshStalePeer(_ reverse: Bool) async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let refresh = live.refreshReferences(now: now,
            stillValid: { true }, displayConditions: { [0] }, conditions: { [801] }, exchangeList: { [:] })
        let reference = try #require(refresh)
        await reference.value
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress, symbols: ["AAPL", "MSFT"])
        let rows = [
            #"{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"c":801,"t":1699999989000}"#,
            #"{"ev":"Q","sym":"MSFT","bp":199,"ap":201,"bs":100,"as":100,"c":801,"t":1700000000000}"#,
            #"{"ev":"T","sym":"AAPL","p":100,"t":1699999989000,"pt":1699999988999,"c":[0]}"#,
            #"{"ev":"T","sym":"MSFT","p":200,"t":1700000000000,"pt":1699999999999,"c":[0]}"#
        ]
        let ordered = reverse ? Array(rows.reversed()) : rows
        #expect(ingress.offer(Data(("[" + ordered.joined(separator: ",") + "]").utf8), at: now))
        let captured = try await drained(ingress, symbols: ["AAPL", "MSFT"])
        #expect(captured.metrics.processedEvents == 5 && captured.metrics.failure == nil)
        #expect(captured.newestSIP == now && captured.metrics.quoteSIPToReceive == 0)
        var ideas = ["AAPL", "MSFT"].map { SageFix.idea($0, conviction: 0.8) }
        var delivered: [String: L.Tick] = [:]
        let published = live.publish(captured, from: ingress, now: now) { ticks, quotes, at in
            delivered = StockSageStore.liveTicksForStore(ticks)
            ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
        }
        #expect(published && live.isStreaming)
        let stale = try #require(live.quotes["AAPL"]), fresh = try #require(live.quotes["MSFT"])
        #expect(stale.timestamp == now.addingTimeInterval(-11) && fresh.timestamp == now)
        #expect(stale.costConditionVerified && fresh.costConditionVerified)
        #expect(stale.spreadBps(at: now) == nil && fresh.spreadBps(at: now) != nil)
        #expect(ideas[0].nbbo == nil && ideas[1].nbbo == fresh)
        #expect(delivered["AAPL"]?.timestamp == now.addingTimeInterval(-11))
        #expect(!L.isLiveObservation(delivered["AAPL"]?.timestamp, at: now))
        #expect(L.isLiveObservation(delivered["MSFT"]?.timestamp, at: now))
    }

    @Test @MainActor func expiredReferenceRefreshesButOldQuoteNeverBecomesFresh() async throws {
        let live = L()
        var requests = 0
        let load: @MainActor () async throws -> Set<Int64> = { requests += 1; return [801] }
        // This case tests successful reference expiry; empty exchange data is now a retryable failure.
        let exchanges: @MainActor () async throws -> [Int64: StockSageMassiveTicks.Exchange] = {
            [1: .init(id: 1, mic: "XNAS", acronym: "NASDAQ")]
        }
        let initial = live.refreshReferences(now: now, stillValid: { true },
            displayConditions: { [0] }, conditions: load, exchangeList: exchanges)
        let first = try #require(initial)
        await first.value
        let early = live.refreshReferences(now: now.addingTimeInterval(86_399), stillValid: { true },
            displayConditions: { [0] }, conditions: load, exchangeList: exchanges)
        #expect(early == nil)
        let expired = now.addingTimeInterval(86_400)
        let second = live.refreshReferences(now: expired, stillValid: { true },
            displayConditions: { [0] }, conditions: load, exchangeList: exchanges)
        #expect(second != nil, "Expired references must refresh without restarting the feed")
        await second?.value
        #expect(requests == 2)

        let ingress = I()
        ingress.offer(Data(#"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"c":801,"t":1700000000000}]"#.utf8), at: now)
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        let published = live.publish(snapshot, from: ingress, now: expired, apply: { _, _, _ in })
        #expect(published)
        let quote = try #require(live.quotes["AAPL"])
        #expect(quote.costConditionVerified)
        #expect(quote.timestamp == now && !quote.isFresh(at: expired))
        #expect(!live.isStreaming)
        ingress.invalidate()
    }

    @Test @MainActor func failedReferenceRetriesAfterBackoffAndRequalifiesFreshQuotes() async throws {
        for empty in [false, true] {
            let live = L()
            var requests = 0
            let load: @MainActor () async throws -> Set<Int64> = {
                requests += 1
                if requests == 1 {
                    if empty { return [] }
                    throw URLError(.notConnectedToInternet)
                }
                return [801]
            }
            let initial = live.refreshReferences(now: now, stillValid: { true },
                displayConditions: { [0] }, conditions: load, exchangeList: { [:] })
            let first = try #require(initial)
            await first.value
            let early = live.refreshReferences(now: now.addingTimeInterval(59), stillValid: { true },
                displayConditions: { [0] }, conditions: load, exchangeList: { [:] })
            #expect(early == nil)
            let retryAt = now.addingTimeInterval(60)
            let retry = live.refreshReferences(now: retryAt, stillValid: { true },
                displayConditions: { [0] }, conditions: load, exchangeList: { [:] })
            #expect(retry != nil, "Unavailable or empty references must remain retryable")
            await retry?.value
            #expect(requests == 2)

            let ingress = I()
            ingress.offer(Data(#"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"c":801,"t":1700000060000}]"#.utf8), at: retryAt)
            let snapshot = try await drained(ingress, symbols: ["AAPL"])
            let published = live.publish(snapshot, from: ingress, now: retryAt, apply: { _, _, _ in })
            #expect(published)
            #expect(live.quotes["AAPL"]?.costConditionVerified == true)
            ingress.invalidate()
        }
    }

    @Test @MainActor func stoppedReferenceCannotPublishOrClearReplacementTask() async throws {
        let live = L()
        var oldResume: CheckedContinuation<Set<Int64>, Never>?
        var nextResume: CheckedContinuation<Set<Int64>, Never>?
        let ready = AsyncStream<Void>.makeStream()
        var starts = ready.stream.makeAsyncIterator()
        defer {
            oldResume?.resume(returning: []); nextResume?.resume(returning: [])
            ready.continuation.finish()
        }
        var oldExchangeCalls = 0
        let first = live.refreshReferences(now: now, stillValid: { true }, displayConditions: { [0] }, conditions: {
            await withCheckedContinuation { oldResume = $0; ready.continuation.yield() }
        }, exchangeList: { oldExchangeCalls += 1; return [:] })
        let firstTask = try #require(first)
        _ = await starts.next()
        live.stop(clearNBBO: {})
        let next = live.refreshReferences(now: now, stillValid: { true }, displayConditions: { [0] }, conditions: {
            await withCheckedContinuation { nextResume = $0; ready.continuation.yield() }
        }, exchangeList: { [1: .init(id: 1, mic: "XNAS", acronym: "TEST")] })
        let nextTask = try #require(next)
        _ = await starts.next()
        oldResume?.resume(returning: [801]); oldResume = nil
        await firstTask.value
        #expect(oldExchangeCalls == 0 && live.exchanges.isEmpty)
        var duplicateCalls = 0
        let duplicate = live.refreshReferences(now: now.addingTimeInterval(120), stillValid: { true },
            displayConditions: { [0] }, conditions: { duplicateCalls += 1; return [801] }, exchangeList: { [:] })
        #expect(duplicate == nil, "An old completion must not clear the replacement's in-flight guard")
        nextResume?.resume(returning: [999]); nextResume = nil
        await nextTask.value
        #expect(duplicateCalls == 0 && live.exchanges[1]?.acronym == "TEST")

        let ingress = I()
        ingress.offer(Data(#"[{"ev":"status","status":"auth_success"},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"c":999,"t":1700000000000}]"#.utf8), at: now)
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        let published = live.publish(snapshot, from: ingress, now: now, apply: { _, _, _ in })
        #expect(published && live.quotes["AAPL"]?.costConditionVerified == true)
        ingress.invalidate()
    }

    @Test @MainActor func revokedReferenceAccessStopsBetweenHopsAndAllowsLaterRecovery() async throws {
        let live = L()
        var allowed = false
        var conditionsCalls = 0, exchangeCalls = 0
        let load: @MainActor () async throws -> Set<Int64> = {
            conditionsCalls += 1; allowed = false; return [801]
        }
        let denied = live.refreshReferences(now: now, stillValid: { allowed }, displayConditions: { [0] }, conditions: load,
            exchangeList: { exchangeCalls += 1; return [:] })
        #expect(denied == nil && conditionsCalls == 0)
        allowed = true
        let revoked = live.refreshReferences(now: now, stillValid: { allowed }, displayConditions: { [0] }, conditions: load,
            exchangeList: { exchangeCalls += 1; return [:] })
        await revoked?.value
        #expect(conditionsCalls == 1 && exchangeCalls == 0)
        allowed = true
        let recovered = live.refreshReferences(now: now.addingTimeInterval(60), stillValid: { allowed },
            displayConditions: { [0] }, conditions: { [801] }, exchangeList: { exchangeCalls += 1; return [:] })
        #expect(recovered != nil, "Revoked access cannot stamp a successful reference")
        await recovered?.value
        #expect(exchangeCalls == 1)
    }

    func drained(_ ingress: I, symbols: [String] = []) async throws -> I.Snapshot {
        for _ in 0..<10_000 {
            let snapshot = await ingress.snapshot(symbols: symbols)
            if snapshot.metrics.failure != nil || snapshot.metrics.queuedFrames == 0 { return snapshot }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @Test func capturedSnapshotCannotPublishAfterOffMainInvalidation() async throws {
        for reason in [nil, "overflow", "auth failure", "socket failure"] {
            let ingress = I()
            ingress.offer(auth, at: now)
            let captured = try await drained(ingress)
            #expect(ingress.acceptsPublication(captured, at: captured.createdUptime))
            await Task.detached { ingress.invalidate(reason) }.value
            #expect(captured.authorized, "Immutable capture still describes the old session")
            #expect(!ingress.acceptsPublication(captured, at: captured.createdUptime + 0.001))
            #expect(!ingress.offer(auth, at: now))
        }
    }

    @Test func retainedMetadataIsBoundedWithoutResurrectingWithdrawnLiquidity() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress)
        for count in [64, 65, 10_000] {
            let indicators = Array(repeating: "1", count: count).joined(separator: ",")
            let text = "[{\"ev\":\"Q\",\"sym\":\"AAPL\",\"bp\":0,\"ap\":0,\"bs\":0,\"as\":0,\"c\":801,\"t\":1700000000000,\"q\":\(count),\"i\":[\(indicators)]}]"
            #expect(ingress.offer(Data(text.utf8), at: now))
            let snapshot = try await drained(ingress, symbols: ["AAPL"])
            let quote = try #require(snapshot.quotes["AAPL"])
            #expect(quote.bid == 0 && quote.ask == 0)
            #expect(quote.indicators?.count == (count <= 64 ? count : nil))
            #expect(!quote.qualifyingCosts(regularConditions: [801]).costConditionVerified)
        }
        #expect(try await drained(ingress).metrics.rejected == 2)
        ingress.invalidate()
    }

    @Test @MainActor func actualPublishedStateIncludesMergeTimeAndRejectsInvalidatedCaptures() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1700000000000,"pt":1699999999999,"c":[0]},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"t":1700000000000}]"#.utf8), at: now)
        let captured = try await drained(ingress, symbols: ["AAPL"])
        let live = L()
        await live.refreshReferences(now: now, stillValid: { true }, displayConditions: { [0] },
            conditions: { [] }, exchangeList: { [:] })?.value
        let published = live.publish(captured, from: ingress, now: now) { ticks, quotes, _ in
            #expect(ticks["AAPL"]?.price == 100 && quotes["AAPL"]?.bid == 99)
            usleep(10_000) // Deterministic store-merge work belongs inside the timing boundary.
        }
        #expect(published)
        #expect(live.isStreaming && live.quotes["AAPL"]?.ask == 101)
        #expect(live.diagnostics.receiveToPublish >= 0.01)
        print("FEED_PUBLISHED merge_delay_ms=10 receive_to_published_s=\(live.diagnostics.receiveToPublish)")
        await Task.detached { ingress.invalidate("off-main overflow") }.value
        let stalePublished = live.publish(captured, from: ingress, now: now) { ticks, quotes, _ in
            #expect(ticks.isEmpty && quotes.isEmpty)
        }
        #expect(!stalePublished)
        #expect(!live.isStreaming && live.quotes.isEmpty && live.gapCount == 1)
    }

    @Test @MainActor func authorizationResetRejectsPreviouslyCapturedPublication() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress)
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"t":1700000000000}]"#.utf8), at: now)
        let captured = try await drained(ingress, symbols: ["AAPL"])
        ingress.offer(Data(#"[{"ev":"status","status":"connected"}]"#.utf8), at: now)
        let reset = try await drained(ingress)
        #expect(!reset.authorized)
        let live = L()
        let accepted = live.publish(captured, from: ingress, now: now, apply: { _, _, _ in })
        #expect(!accepted)
        #expect(live.quotes.isEmpty && !live.isStreaming)
    }

    @Test func actualMailboxKeepsOffBoardChannelsAndProviderSuffixes() async throws {
        let ingress = I()
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress)
        let text = #"[{"ev":"T","sym":"BRK.B","p":100,"t":1700000000000,"pt":1699999999999,"q":9007199254740992},{"ev":"T","sym":"BRK.B","p":101,"t":1700000000000,"q":9007199254740993},{"ev":"Q","sym":"BRK.B","bp":99,"ap":102,"bs":100,"as":50,"t":1700000000000,"q":999},{"ev":"Q","sym":"BRK.B","bp":0,"ap":0,"bs":0,"as":0,"t":1700000000000,"q":1000},{"ev":"T","sym":"APTVpA","p":25,"t":1700000000000},{"ev":"T","sym":"APTVPA","p":26,"t":1700000000000}]"#
        #expect(ingress.offer(Data(text.utf8), at: now))
        let snapshot = try await drained(ingress, symbols: ["BRK.B", "APTVpA", "APTVPA"])
        #expect(snapshot.authorized)
        #expect(snapshot.trades["BRK.B"]?.price == 101)
        #expect(snapshot.trades["BRK.B"]?.sequence == 9_007_199_254_740_993)
        #expect(snapshot.quotes["BRK.B"]?.ask == 0)
        #expect(snapshot.quotes["BRK.B"]?.askSize == 0)
        #expect(snapshot.trades["APTVpA"]?.price == 25 && snapshot.trades["APTVPA"]?.price == 26)
        #expect(snapshot.metrics.tradeSymbols == 3 && snapshot.metrics.quoteSymbols == 1)
        #expect(snapshot.metrics.coalesced == 2)
        let other = await ingress.snapshot(symbols: ["APTVpA"])
        #expect(other.trades.count == 1 && other.authorized) // Projection is not a resubscription.
        ingress.invalidate()
    }

    @Test func limitsInvalidateSessionAndExposeGapInsteadOfShrinkingCoverage() async throws {
        for limits in [I.Limits(frameBytes: 10), I.Limits(queuedBytes: 10), I.Limits(queuedFrames: 0)] {
            let ingress = I(limits: limits)
            #expect(!ingress.offer(auth, at: now))
            let snapshot = await ingress.snapshot(symbols: ["AAPL"])
            #expect(!snapshot.authorized && snapshot.trades.isEmpty && snapshot.quotes.isEmpty)
            #expect(snapshot.metrics.failure?.contains("capacity") == true)
            #expect(!ingress.offer(auth, at: now))
            #expect(snapshot.metrics.queuedFrames == 0 && snapshot.metrics.queuedBytes == 0)
        }
        let capped = I(limits: .init(symbols: 1))
        #expect(capped.offer(Data(#"[{"ev":"status","status":"auth_success"},{"ev":"T","sym":"AAPL","p":1,"t":1700000000000},{"ev":"T","sym":"MSFT","p":2,"t":1700000000000}]"#.utf8), at: now))
        let snapshot = try await drained(capped)
        #expect(snapshot.metrics.failure?.contains("symbol capacity") == true)
        #expect(!snapshot.authorized && snapshot.trades.isEmpty)
    }

    @Test func stoppedFailedAndReplacedSessionsRejectLateCallbacks() async throws {
        let old = I()
        old.offer(auth, at: now)
        old.invalidate()
        #expect(!old.offer(auth, at: now))
        let replacement = I()
        replacement.offer(auth, at: now)
        _ = try await drained(replacement)
        old.invalidate("late receive or send failure")
        #expect(try await drained(replacement).authorized)
        let stopped = await old.snapshot(symbols: ["AAPL"])
        #expect(!stopped.authorized && stopped.trades.isEmpty && stopped.quotes.isEmpty)
        replacement.offer(Data(#"[{"ev":"status","status":"auth_failed"},{"ev":"T","sym":"AAPL","p":1,"t":1700000000000}]"#.utf8), at: now)
        let failed = try await drained(replacement, symbols: ["AAPL"])
        #expect(!failed.authorized && failed.trades.isEmpty && failed.metrics.failure != nil)
        #expect(!replacement.offer(auth, at: now))
    }

    @Test func localBacklogUsesMonotonicTimeWhileSilentAndLateSymbolsStayDistinct() async throws {
        let stale = I()
        stale.offer(auth, at: now, uptime: ProcessInfo.processInfo.systemUptime - 10.01)
        let delayed = try await drained(stale)
        #expect(delayed.metrics.failure?.contains("backlog") == true)
        let quiet = I()
        quiet.offer(auth, at: now)
        #expect(try await drained(quiet).authorized)
        quiet.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1699999900000},{"ev":"T","sym":"FUTURE","p":1,"t":1700000001000},{"ev":"T","sym":"MISSING","p":1},{"ev":"T","sym":"X:BTCUSD","p":1,"t":1700000000000}]"#.utf8), at: now)
        let snapshot = try await drained(quiet, symbols: ["AAPL", "FUTURE", "MISSING"])
        #expect(snapshot.authorized && snapshot.metrics.failure == nil)
        #expect(snapshot.metrics.sipToReceive == 100)
        #expect(snapshot.metrics.futureClocks == 1 && snapshot.metrics.rejected == 2)
        #expect(!L.isLiveObservation(snapshot.trades["AAPL"]?.timestamp, at: now))
        #expect(!L.isLiveObservation(snapshot.trades["FUTURE"]?.timestamp, at: now))
        #expect(snapshot.trades["MISSING"] == nil)
        for age in [0.0, 10] { #expect(L.isLiveObservation(now.addingTimeInterval(-age), at: now)) }
        for age in [-0.001, 10.001, Double.infinity, Double.nan] {
            #expect(!L.isLiveObservation(now.addingTimeInterval(-age), at: now))
        }
        quiet.invalidate()
    }

    @Test func publicationIsCappedAndQuietObservationAgeIsNotBacklog() async throws {
        let ingress = I(limits: .init(publicationSymbols: 1))
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":1,"t":1700000000000},{"ev":"T","sym":"MSFT","p":2,"t":1700000000000}]"#.utf8), at: now)
        let snapshot = try await drained(ingress, symbols: ["AAPL", "MSFT"])
        #expect(snapshot.trades.count == 1 && snapshot.metrics.tradeSymbols == 2)
        #expect(snapshot.receivedUptime.count == 1)
        await ingress.acknowledge(snapshot.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
        let quiet = await ingress.snapshot(symbols: ["AAPL"], now: now.addingTimeInterval(100))
        #expect(quiet.receivedUptime.isEmpty)
        #expect(quiet.metrics.failure == nil)
        ingress.invalidate()
    }

    @Test @MainActor func completeRotationPreservesUnchangedFreshCostEvidence() async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let task = live.refreshReferences(now: now, stillValid: { true },
            displayConditions: { [0] }, conditions: { [801] }, exchangeList: { [:] })
        await task?.value
        let all = ((0..<4095).map { "A\($0)" } + ["MSFT", "TSLA"]).sorted()
        let first = StockSageStore.rotatedSweepSlice(all: all, cursor: 0, limit: ingress.limits.publicationSymbols)
        let second = StockSageStore.rotatedSweepSlice(all: all, cursor: first.nextCursor, limit: ingress.limits.publicationSymbols)
        #expect(first.picked.count == 4096 && second.picked.count == 4096)
        #expect(Set(first.picked + second.picked) == Set(all))
        #expect(first.picked.contains("MSFT") && !first.picked.contains("TSLA"))
        #expect(!second.picked.contains("MSFT") && second.picked.contains("TSLA"))
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress, symbols: first.picked)
        let rows = ["MSFT", "TSLA", "ZZZ"].flatMap { symbol in [
            "{\"ev\":\"Q\",\"sym\":\"\(symbol)\",\"bp\":99,\"ap\":104,\"bs\":100,\"as\":100,\"c\":801,\"t\":1700000000000}",
            "{\"ev\":\"T\",\"sym\":\"\(symbol)\",\"p\":100,\"t\":1700000000000}"
        ] }
        #expect(ingress.offer(Data(("[" + rows.joined(separator: ",") + "]").utf8), at: now))
        var ideas = ["MSFT", "TSLA"].map { SageFix.idea($0, conviction: 0.8) }
        let initial = try await drained(ingress, symbols: first.picked)
        let firstPublished = live.publish(initial, from: ingress, now: now) { _, quotes, at in
            ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
        }
        #expect(firstPublished && initial.quotes.count == 1)
        await ingress.acknowledge(initial.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
        let original = try #require(ideas[0].nbbo)
        let cost = StockSageNetEdge.costs(forSymbol: "MSFT", nbbo: original, now: now)
        let selected = Set(all)
        let retained = live.quotes.filter { selected.contains($0.key) }
        let next = await ingress.snapshot(symbols: second.picked, now: now, retainingQuotes: retained)
        let secondPublished = live.publish(next, from: ingress, now: now, retainingQuotes: retained) { _, quotes, at in
            ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
        }
        #expect(secondPublished && next.quotes.count == 1)
        #expect(next.metrics.tradeSymbols == 3 && next.metrics.quoteSymbols == 3)
        #expect(live.quotes["ZZZ"] == nil)
        #expect(ideas[1].nbbo?.symbol == "TSLA")
        #expect(live.quotes["MSFT"] == original && ideas[0].nbbo == original,
                "Rotation alone must not discard a still-current, fresh spread")
        #expect(StockSageNetEdge.costs(forSymbol: "MSFT", nbbo: ideas[0].nbbo, now: now) == cost)
    }

    @Test @MainActor func mixedRotationPreservesPerSymbolEvidenceAcrossUpdates() async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let task = live.refreshReferences(now: now, stillValid: { true },
            displayConditions: { [0] }, conditions: { [801] }, exchangeList: { [:] })
        let reference = try #require(task)
        await reference.value
        // Unchanged, aging, missing, changed, withdrawn, condition-ineligible.
        let sentinels = ["MAFRESH", "MBAGING", "MCMISSING", "MDCHANGED", "MEWITHDRAWN", "MFCONDITION"]
        let all = ((0..<4090).map { "A\($0)" } + sentinels + (0..<6).map { "Z\($0)" }).sorted()
        let selected = Set(all)
        #expect(Array(all[4090..<4096]) == sentinels && sentinels.allSatisfy(StockSageMassive.covers))
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress)
        let initial = sentinels.enumerated().compactMap { index, symbol -> String? in
            guard index != 2 else { return nil }
            let stamp: Int64 = index == 1 ? 1_699_999_996_000 : 1_700_000_000_000
            return "{\"ev\":\"Q\",\"sym\":\"\(symbol)\",\"bp\":99,\"ap\":104,\"bs\":100,\"as\":100,\"c\":801,\"q\":1,\"t\":\(stamp)}"
        }
        #expect(ingress.offer(Data(("[" + initial.joined(separator: ",") + "]").utf8), at: now))
        _ = try await drained(ingress)
        let originalIdeas = all.map { SageFix.idea($0, conviction: 0.8) }
        var ideas = originalIdeas, cursor = 0, visited = Set<String>()
        var unchanged: StockSageNBBO?
        for pass in 0..<3 {
            if pass == 1 {
                let updates = (3...5).map { index in
                    "{\"ev\":\"Q\",\"sym\":\"\(sentinels[index])\",\"bp\":100,\"ap\":104,\"bs\":\(index == 4 ? 0 : 100),\"as\":100,\"c\":\(index == 5 ? 802 : 801),\"q\":2,\"t\":1700000001000}"
                }
                #expect(ingress.offer(Data(("[" + updates.joined(separator: ",") + "]").utf8), at: now.addingTimeInterval(1)))
                _ = try await drained(ingress)
            }
            let at = now.addingTimeInterval(pass == 0 ? 0 : Double(pass + 1))
            let slice = StockSageStore.rotatedSweepSlice(all: all, cursor: cursor, limit: ingress.limits.publicationSymbols)
            cursor = slice.nextCursor
            visited.formUnion(slice.picked)
            #expect(slice.picked.count == 4096 && Set(slice.picked).count == 4096)
            #expect(sentinels.allSatisfy { slice.picked.contains($0) == (pass != 1) })
            let retained = live.quotes.filter { selected.contains($0.key) }
            let snapshot = await ingress.snapshot(symbols: slice.picked, now: at, retainingQuotes: retained)
            let observed = Set(sentinels.filter { $0 != sentinels[2] })
            let usable: Set<String> = pass == 0 ? observed : pass == 1 ? [sentinels[0]] : [sentinels[0], sentinels[3]]
            #expect(Set(snapshot.quotes.keys) == (pass == 1 ? [] : observed))
            #expect(snapshot.retainedQuoteSymbols == (pass == 1 ? [sentinels[0]] : []))
            #expect(snapshot.authorized && snapshot.metrics.failure == nil && snapshot.metrics.queuedFrames == 0)
            #expect(snapshot.metrics.quoteSymbols == 5 && snapshot.metrics.tradeSymbols == 0)
            #expect(snapshot.metrics.processedEvents == (pass == 0 ? 6 : 9))
            #expect(snapshot.metrics.coalesced == (pass == 0 ? 0 : 3) && snapshot.metrics.rejected == 0)
            let published = live.publish(snapshot, from: ingress, now: at, retainingQuotes: retained) { ticks, quotes, time in
                #expect(ticks.isEmpty)
                ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: time)
            }
            #expect(published)
            await ingress.acknowledge(snapshot.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
            #expect(Set(live.quotes.keys) == (pass == 1 ? [sentinels[0]] : observed))
            #expect(Set(ideas.compactMap { $0.nbbo == nil ? nil : $0.symbol }) == usable)
            #expect(ideas.map { $0.withNBBO(nil) } == originalIdeas, "Quote-only arrivals cannot refresh price clocks or advice")
            for (index, symbol) in sentinels.enumerated() {
                let updated = pass > 0 && index >= 3
                if let quote = live.quotes[symbol] {
                    #expect(quote.timestamp == now.addingTimeInterval(index == 1 ? -4 : updated ? 1 : 0))
                    #expect(quote.sequence == (updated ? 2 : 1) && quote.bid == (updated ? 100 : 99) && quote.ask == 104)
                    #expect(quote.bidSize == (updated && index == 4 ? 0 : 100))
                    #expect(quote.costConditionVerified == !(updated && index == 5))
                }
                let idea = ideas[4090 + index], base = StockSageNetEdge.defaultCosts(forSymbol: symbol)
                let cost = StockSageNetEdge.costs(forSymbol: symbol, nbbo: idea.nbbo, now: at)
                if usable.contains(symbol) {
                    #expect(idea.nbbo == live.quotes[symbol] && cost.spreadBps > base.spreadBps)
                } else {
                    #expect(idea.nbbo == nil && cost == base)
                }
            }
            if pass == 0 { unchanged = try #require(live.quotes[sentinels[0]]) }
            #expect(live.quotes[sentinels[0]] == unchanged)
        }
        #expect(visited == selected && selected.count == 4102)
    }

    @Test(arguments: ["unchanged", "withdrawal", "condition", "sequence", "price", "capture-expiry",
        "publish-expiry", "future", "reference-expiry", "deselected", "empty", "invalidated"])
    @MainActor func retentionPreservesFreshnessAndInvalidation(_ scenario: String) async throws {
        let ingress = I(limits: .init(publicationSymbols: 1)), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let referencesAt = scenario == "reference-expiry" ? now.addingTimeInterval(-86_399) : now
        let task = live.refreshReferences(now: referencesAt, stillValid: { true },
            displayConditions: { [0] }, conditions: { [801] }, exchangeList: { [:] })
        await task?.value
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress, symbols: ["AAPL"])
        let rows = ["AAPL", "MSFT"].map { symbol in
            "{\"ev\":\"Q\",\"sym\":\"\(symbol)\",\"bp\":99,\"ap\":101,\"bs\":100,\"as\":100,\"c\":801,\"q\":1,\"t\":1700000000000}"
        }
        #expect(ingress.offer(Data(("[" + rows.joined(separator: ",") + "]").utf8), at: now))
        let initial = try await drained(ingress, symbols: ["AAPL"])
        var ideas = [SageFix.idea("AAPL", conviction: 0.8)]
        #expect(live.publish(initial, from: ingress, now: now) { _, quotes, at in
            ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
        })
        let original = try #require(ideas[0].nbbo)
        #expect(original.costConditionVerified)
        let retained = scenario == "deselected" ? [:] : live.quotes
        if ["withdrawal", "condition", "sequence", "price"].contains(scenario) {
            let bidSize = scenario == "withdrawal" ? 0 : 100
            let condition = scenario == "condition" ? 802 : 801
            let price = scenario == "price" ? 100 : 99
            let sequence = scenario == "price" ? 1 : 2
            let timestamp: Int64 = scenario == "price" ? 1_700_000_000_001 : 1_700_000_000_000
            let update = "[{\"ev\":\"Q\",\"sym\":\"AAPL\",\"bp\":\(price),\"ap\":101,\"bs\":\(bidSize),\"as\":100,\"c\":\(condition),\"q\":\(sequence),\"t\":\(timestamp)}]"
            #expect(ingress.offer(Data(update.utf8), at: now.addingTimeInterval(0.001)))
            let updated = try await drained(ingress, symbols: ["AAPL"])
            if scenario == "price" {
                #expect(updated.quotes["AAPL"]?.bid == 100 && updated.quotes["AAPL"]?.sequence == original.sequence)
                #expect(updated.quotes["AAPL"]?.timestamp == Date(timeIntervalSince1970: Double(timestamp) / 1000))
            }
        }
        let captureAt = now.addingTimeInterval(scenario == "capture-expiry" ? 5.001 : scenario == "future" ? -0.001 : scenario == "price" ? 0.01 : 0)
        let captured = await ingress.snapshot(symbols: scenario == "empty" ? [] : ["MSFT"],
            now: captureAt, retainingQuotes: retained)
        let approved = ["unchanged", "publish-expiry", "reference-expiry", "invalidated"].contains(scenario)
        #expect(captured.retainedQuoteSymbols.contains("AAPL") == approved)
        #expect(captured.quotes.count <= 1 && captured.receivedUptime["Q.AAPL"] == nil)
        if scenario == "invalidated" { ingress.invalidate("replay connection replaced") }
        let publicationAt = now.addingTimeInterval(scenario == "publish-expiry" ? 5.001 : scenario == "reference-expiry" ? 2 : 5)
        let published = live.publish(captured, from: ingress, now: publicationAt, retainingQuotes: retained) { _, quotes, at in
            ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
        }
        #expect(published == (scenario != "invalidated"))
        if scenario == "unchanged" {
            #expect(live.quotes["AAPL"] == original && ideas[0].nbbo == original)
        } else if scenario == "reference-expiry" {
            #expect(live.quotes["AAPL"]?.timestamp == original.timestamp)
            #expect(live.quotes["AAPL"]?.costConditionVerified == false && ideas[0].nbbo == nil)
        } else {
            #expect(live.quotes["AAPL"] == nil && ideas[0].nbbo == nil)
        }
        if scenario == "invalidated" { #expect(live.quotes.isEmpty && !live.isStreaming) }
    }

    @Test @MainActor func retainedPublicationAtFullSymbolCapacity() async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        let task = live.refreshReferences(now: now, stillValid: { true },
            displayConditions: { [0] }, conditions: { [801] }, exchangeList: { [:] })
        await task?.value
        let all = (0..<ingress.limits.symbols).map { "S\($0)" }.sorted()
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress)
        for offset in stride(from: 0, to: all.count, by: 512) {
            let rows = all[offset..<min(offset + 512, all.count)].map { symbol in
                "{\"ev\":\"Q\",\"sym\":\"\(symbol)\",\"bp\":99,\"ap\":101,\"bs\":100,\"as\":100,\"c\":801,\"t\":1700000000000}"
            }
            #expect(ingress.offer(Data(("[" + rows.joined(separator: ",") + "]").utf8), at: now))
            #expect(try await drained(ingress).metrics.failure == nil)
        }
        var ideas = all.map { SageFix.idea($0, conviction: 0.8) }
        var visited = Set<String>(), cursor = 0
        var captureTimes: [Double] = [], publishTimes: [Double] = [], mergeTimes: [Double] = []
        for pass in 0..<10 { // Eight full-cap slices, then two steady-state captures.
            let selection = StockSageStore.rotatedSweepSlice(all: all, cursor: cursor, limit: ingress.limits.publicationSymbols)
            cursor = selection.nextCursor
            visited.formUnion(selection.picked)
            let retained = live.quotes
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = await ingress.snapshot(symbols: selection.picked, now: now, retainingQuotes: retained)
            let capturedAt = ProcessInfo.processInfo.systemUptime
            let published = live.publish(snapshot, from: ingress, now: now, retainingQuotes: retained) { _, quotes, at in
                let start = ProcessInfo.processInfo.systemUptime
                ideas = StockSageStore.ideasWithNBBO(ideas, quotes: quotes, now: at)
                mergeTimes.append(ProcessInfo.processInfo.systemUptime - start)
            }
            let end = ProcessInfo.processInfo.systemUptime
            captureTimes.append(capturedAt - start); publishTimes.append(end - capturedAt)
            #expect(published && snapshot.metrics.failure == nil)
            #expect(snapshot.quotes.count == 4096 && snapshot.retainedQuoteSymbols.count <= 28_672)
            #expect(snapshot.metrics.quoteSymbols == 32_768 && snapshot.metrics.processedEvents == 32_769)
            #expect(snapshot.metrics.queuedFrames == 0 && snapshot.metrics.queuedBytes == 0 && snapshot.metrics.peakFrames <= 1)
            #expect(Set(live.quotes.keys) == visited && snapshot.retainedQuoteSymbols.isSubset(of: Set(retained.keys)))
            if pass == 7 { #expect(cursor == 0 && visited.count == 32_768) }
            await ingress.acknowledge(snapshot.receivedUptime, at: end)
        }
        #expect(live.quotes.count == 32_768)
        func measured(_ times: [Double]) -> String {
            let sorted = times.sorted(), middle = sorted.count / 2
            return String(format: "median=%.6fs max=%.6fs", (sorted[middle - 1] + sorted[middle]) / 2, sorted.last ?? 0)
        }
        print("FEED_RETAINED_REPLAY symbols=32768 raw_slice=4096 growth=8 steady=2 capture_\(measured(captureTimes)) publish_including_projection_\(measured(publishTimes)) projection_\(measured(mergeTimes)); steady_capture_\(measured(Array(captureTimes.suffix(2)))) steady_publish_\(measured(Array(publishTimes.suffix(2)))); synthetic offline; excludes selection/sorting, applyLiveTicks, Store assignment/observation and rendering")
    }

    @Test @MainActor func stalledUILeavesWorkerRunningAndPublicationExpiresAtTenSeconds() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        let producer = Task.detached {
            for sequence in 1...50 {
                let text = "[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":100,\"t\":1700000000000,\"q\":\(sequence)}]"
                ingress.offer(Data(text.utf8), at: self.now)
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let blockedAt = ProcessInfo.processInfo.systemUptime
        usleep(250_000) // Deliberate UI stall; receiver/parser must keep draining independently.
        try await producer.value
        let snapshot = try await drained(ingress, symbols: ["AAPL"])
        #expect(snapshot.metrics.processedEvents == 51 && snapshot.metrics.failure == nil)
        #expect(snapshot.metrics.peakReceiveToProcess < 0.25)
        #expect(!snapshot.publicationExpired(at: snapshot.createdUptime + 10))
        #expect(snapshot.publicationExpired(at: snapshot.createdUptime + 10.001))
        print("FEED_UI_STALL blocked_s=\(ProcessInfo.processInfo.systemUptime-blockedAt) processed_events=\(snapshot.metrics.processedEvents) peak_receive_process_s=\(snapshot.metrics.peakReceiveToProcess)")
        ingress.invalidate()
    }

    @Test func unpacedFloodFailsExplicitlyWithinQueueBound() async throws {
        let ingress = I()
        let frame = Data(("[" + Array(repeating: #"{"ev":"T","sym":"AAPL","p":100,"t":1700000000000}"#, count: 1000).joined(separator: ",") + "]").utf8)
        var offered = 0
        for _ in 0..<1000 {
            if !ingress.offer(frame, at: now) { break }
            offered += 1
        }
        let snapshot = try await drained(ingress)
        #expect(snapshot.metrics.failure != nil)
        #expect(snapshot.metrics.peakFrames <= 8 && snapshot.metrics.peakBytes <= 8_388_608)
        #expect(snapshot.metrics.queuedFrames == 0 && snapshot.metrics.queuedBytes == 0)
        print("FEED_OVERLOAD offered_frames=\(offered) peak_frames=\(snapshot.metrics.peakFrames) peak_bytes=\(snapshot.metrics.peakBytes) failure=\(snapshot.metrics.failure ?? "none")")
    }

    @Test func authAndStopGateActualSubscriptionCallback() async throws {
        let subscriptions = Mutex(0)
        let ingress = I(authorized: { _ in subscriptions.withLock { $0 += 1 } })
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":1,"t":1700000000000},{"ev":"status","status":"connected"}]"#.utf8), at: now)
        let before = try await drained(ingress, symbols: ["AAPL"])
        #expect(before.trades.isEmpty && !before.authorized && before.newestSIP == nil)
        #expect(subscriptions.withLock { $0 } == 0)
        ingress.offer(auth, at: now)
        _ = try await drained(ingress)
        ingress.offer(auth, at: now)
        _ = try await drained(ingress)
        #expect(subscriptions.withLock { $0 } == 1)
        ingress.invalidate()
        #expect(!ingress.offer(auth, at: now))
        #expect(subscriptions.withLock { $0 } == 1)
    }

    @Test func quarterSecondPublicationCoalescesWithoutAccumulatingSnapshots() async throws {
        let ingress = I()
        ingress.offer(auth, at: now)
        _ = try await drained(ingress, symbols: ["AAPL"])
        let publisher = Task { @MainActor in
            let live = L()
            var peak = 0.0, publications = 0
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(250))
                let snapshot = await ingress.snapshot(symbols: ["AAPL"])
                let published = live.publish(snapshot, from: ingress, now: self.now, apply: { _, _, _ in })
                #expect(published)
                peak = max(peak, live.diagnostics.receiveToPublish)
                await ingress.acknowledge(snapshot.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
                publications += 1
                #expect(snapshot.metrics.failure == nil)
            }
            return (peak, publications)
        }
        try await Task.sleep(for: .milliseconds(20))
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1700000000000,"q":0}]"#.utf8), at: now)
        try await Task.sleep(for: .milliseconds(280)) // A quiet update must wait for the real cadence.
        for sequence in 1...50 {
            ingress.offer(Data("[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":100,\"t\":1700000000000,\"q\":\(sequence)}]".utf8), at: now)
            try await Task.sleep(for: .milliseconds(4))
        }
        let (peak, publications) = try await publisher.value
        let final = try await drained(ingress, symbols: ["AAPL"])
        #expect(publications == 5 && final.metrics.processedEvents == 52)
        #expect(final.metrics.queuedFrames == 0 && final.metrics.failure == nil)
        #expect(peak < 1, "A 250ms publication cadence should not accumulate a queue in this synthetic load")
        print("FEED_CADENCE interval_ms=250 publications=\(publications) events=51 peak_receive_publish_s=\(peak)")
        ingress.invalidate()
    }

    @Test func sustainedOldQuotesRecoverButQuietAndLateTradeReportsDoNotTriggerBacklog() async throws {
        let delayed = I()
        delayed.offer(auth, at: now)
        _ = try await drained(delayed)
        let uptime = ProcessInfo.processInfo.systemUptime - 2
        for (index, offset) in [0.0, 0.5, 1.1].enumerated() {
            let text = "[{\"ev\":\"Q\",\"sym\":\"AAPL\",\"bp\":99,\"ap\":101,\"bs\":100,\"as\":100,\"t\":1699999989000,\"q\":\(index)},{\"ev\":\"T\",\"sym\":\"MSFT\",\"p\":100,\"t\":1700000000000,\"q\":\(index)}]"
            delayed.offer(Data(text.utf8), at: now, uptime: uptime + offset)
            _ = try await drained(delayed)
        }
        let snapshot = try await drained(delayed)
        #expect(snapshot.metrics.failure?.contains("Sustained SIP quote delay") == true)
        #expect(!snapshot.authorized && snapshot.quotes.isEmpty)
        #expect(snapshot.metrics.tradeSIPToReceive == 0 && snapshot.metrics.quoteSIPToReceive == 11)
        let lateTrades = I()
        lateTrades.offer(auth, at: now)
        _ = try await drained(lateTrades)
        for (index, offset) in [0.0, 0.5, 1.1].enumerated() {
            let text = "[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":100,\"t\":1699999989000,\"q\":\(index)}]"
            lateTrades.offer(Data(text.utf8), at: now, uptime: uptime + offset)
            _ = try await drained(lateTrades)
        }
        #expect(try await drained(lateTrades).metrics.failure == nil)
        lateTrades.invalidate()
    }

    @Test func wholeMarketReplayMeasuresActualIngestionWithBoundedMailbox() async throws {
        let ingress = I()
        ingress.offer(auth)
        _ = try await drained(ingress, symbols: ["S0", "S1"])
        var rssBefore = rusage(); getrusage(RUSAGE_SELF, &rssBefore)
        let start = ProcessInfo.processInfo.systemUptime
        var accepted = 0, maxPublish = 0.0
        // 20k symbols, both channels, five rounds = 200k market events through the real offer/decode/consume path.
        for round in 0..<5 {
            for base in stride(from: 0, to: 20_000, by: 500) {
                let at = Date(), ms = Int64(at.timeIntervalSince1970 * 1000)
                let text = "[" + (base..<(base + 500)).map { index in
                    "{\"ev\":\"T\",\"sym\":\"S\(index)\",\"p\":\(100 + round),\"s\":100,\"x\":4,\"z\":3,\"i\":\"abc\",\"c\":[0],\"pt\":\(ms-1),\"t\":\(ms),\"q\":\(round)}," +
                    "{\"ev\":\"Q\",\"sym\":\"S\(index)\",\"bp\":99,\"ap\":101,\"bs\":100,\"as\":100,\"bx\":4,\"ax\":12,\"z\":3,\"c\":0,\"i\":[],\"t\":\(ms),\"q\":\(round)}"
                }.joined(separator: ",") + "]"
                let ok = ingress.offer(Data(text.utf8), at: at)
                #expect(ok)
                if ok { accepted += 1000 }
                // Drain each bounded burst; this reports sustainable replay, not an assumed peak-market rate.
                let snapshot = try await drained(ingress, symbols: ["S0", "S1"])
                #expect(snapshot.metrics.failure == nil)
                let published = ProcessInfo.processInfo.systemUptime
                maxPublish = max(maxPublish, snapshot.receivedUptime.values.map { published - $0 }.max() ?? 0)
                await ingress.acknowledge(snapshot.receivedUptime, at: published)
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let snapshot = try await drained(ingress, symbols: ["S19999"])
        var rssAfter = rusage(); getrusage(RUSAGE_SELF, &rssAfter)
        #expect(snapshot.metrics.processedEvents == 200_001)
        #expect(snapshot.metrics.tradeSymbols == 20_000 && snapshot.metrics.quoteSymbols == 20_000)
        #expect(snapshot.metrics.coalesced == 160_000)
        #expect(snapshot.metrics.peakFrames <= 8 && snapshot.metrics.peakBytes <= 8_388_608)
        #expect(snapshot.metrics.queuedFrames == 0 && snapshot.metrics.queuedBytes == 0)
        #expect(snapshot.trades["S19999"]?.price == 104)
        print("FEED_REPLAY events=\(accepted) seconds=\(elapsed) events_per_second=\(Double(accepted)/elapsed) peak_receive_process_s=\(snapshot.metrics.peakReceiveToProcess) peak_receive_publish_s=\(maxPublish) peak_frames=\(snapshot.metrics.peakFrames) peak_bytes=\(snapshot.metrics.peakBytes) symbols=\(snapshot.metrics.tradeSymbols + snapshot.metrics.quoteSymbols) process_peak_rss_bytes=\(rssAfter.ru_maxrss) peak_rss_increase_bytes=\(rssAfter.ru_maxrss-rssBefore.ru_maxrss)")
        ingress.invalidate()
    }
}


extension StockSageFeedIngressTests {
    @Test @MainActor func rawTradeConditionsSurviveButSpecialPricesNeverPublish() async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        await live.refreshReferences(now: now, stillValid: { true }, displayConditions: { [901] },
            conditions: { [] }, exchangeList: { [:] })?.value
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress)
        let symbols = ["NORMAL", "AVERAGE", "UNKNOWN", "MISSING", "LATE", "FUTURE"]
        let policy = live.displayTradePolicy(at: now)
        #expect(policy.generation != nil)
        _ = await ingress.snapshot(symbols: symbols, now: now,
            displayConditions: policy.conditions, displayConditionGeneration: policy.generation)
        let rows = [
            #"{"ev":"T","sym":"NORMAL","p":100,"t":1700000000000,"pt":1699999999999,"c":[901]}"#,
            #"{"ev":"T","sym":"AVERAGE","p":101,"t":1700000000000,"pt":1699999999999,"c":[901,902]}"#,
            #"{"ev":"T","sym":"UNKNOWN","p":102,"t":1700000000000,"c":[999]}"#,
            #"{"ev":"T","sym":"MISSING","p":103,"t":1700000000000}"#,
            #"{"ev":"T","sym":"LATE","p":104,"t":1700000000000,"pt":1699999880000,"c":[901]}"#,
            #"{"ev":"T","sym":"FUTURE","p":105,"t":1700000000000,"pt":1700000000001,"c":[901]}"#
        ]
        #expect(ingress.offer(Data(("[" + rows.joined(separator: ",") + "]").utf8), at: now))
        let snapshot = try await drained(ingress, symbols: symbols)
        #expect(snapshot.trades.count == 6, "Retain raw trades for ordering and diagnostics")
        #expect(snapshot.trades["AVERAGE"]?.conditions == [901,902])
        #expect(snapshot.displayConditionGeneration == policy.generation)
        #expect(Set(snapshot.displayTrades.keys) == ["NORMAL"])
        let published = live.publish(snapshot, from: ingress, now: now) { ticks, _, _ in
            #expect(Set(ticks.keys) == ["NORMAL"])
            #expect(ticks["NORMAL"]?.timestamp == now, "SIP ordering clock remains unchanged")
        }
        #expect(published)
    }
}


extension StockSageFeedIngressTests {
    @Test @MainActor func qualifiedTradeSurvivesSameSymbolSpecialTradeCoalescingAndPolicyInvalidation() async throws {
        let ingress = I(), live = L()
        defer { ingress.invalidate(); live.stop(clearNBBO: {}) }
        await live.refreshReferences(now: now, stillValid: { true }, displayConditions: { [901] },
            conditions: { [] }, exchangeList: { [:] })?.value
        #expect(ingress.offer(auth, at: now))
        _ = try await drained(ingress)
        let policy = live.displayTradePolicy(at: now)
        _ = await ingress.snapshot(symbols: ["AAPL"], now: now,
            displayConditions: policy.conditions, displayConditionGeneration: policy.generation)
        var last: I.Snapshot?
        for step in 0..<3 {
            let ms = Int64(1_700_000_000_000) + Int64(step * 1_000)
            let at = now.addingTimeInterval(Double(step))
            let frame = "[{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":\(100 + step),\"t\":\(ms),\"pt\":\(ms - 1),\"q\":\(step * 2 + 1),\"c\":[901]},{\"ev\":\"T\",\"sym\":\"AAPL\",\"p\":999,\"t\":\(ms),\"pt\":\(ms - 1),\"q\":\(step * 2 + 2),\"c\":[902]}]"
            #expect(ingress.offer(Data(frame.utf8), at: at))
            let snapshot = try await drained(ingress, symbols: ["AAPL"])
            #expect(snapshot.trades["AAPL"]?.price == 999, "Preserve raw latest trade")
            #expect(snapshot.displayTrades["AAPL"]?.price == Double(100 + step))
            #expect(snapshot.receivedUptime["D.AAPL"] != nil)
            let published = live.publish(snapshot, from: ingress, now: at) { ticks, _, _ in
                #expect(ticks["AAPL"]?.price == Double(100 + step))
                #expect(ticks["AAPL"]?.timestamp == at)
            }
            #expect(published)
            await ingress.acknowledge(snapshot.receivedUptime, at: ProcessInfo.processInfo.systemUptime)
            last = snapshot
        }
        let old = try #require(last)
        let renewedAt = now.addingTimeInterval(86_400)
        await live.refreshReferences(now: renewedAt, stillValid: { true }, displayConditions: { [901] },
            conditions: { [] }, exchangeList: { [:] })?.value
        #expect(live.displayTradePolicy(at: renewedAt).generation != old.displayConditionGeneration)
        let renewed = live.publish(old, from: ingress, now: renewedAt) { ticks, _, _ in
            #expect(ticks.isEmpty, "An older policy capture cannot publish after renewal, even with equal condition IDs")
        }
        #expect(renewed)
        ingress.invalidate("fixture access invalidation")
        let invalidated = live.publish(old, from: ingress, now: renewedAt) { ticks, quotes, _ in
            #expect(ticks.isEmpty && quotes.isEmpty)
        }
        #expect(!invalidated)
    }
}
