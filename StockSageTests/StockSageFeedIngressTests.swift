import Foundation
import Testing
import Darwin
import Synchronization
@testable import StockSage

@Suite("Bounded whole-market ingestion")
struct StockSageFeedIngressTests {
    typealias I = StockSageFeedIngress
    typealias L = StockSageLiveStream
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let auth = Data(#"[{"ev":"status","status":"auth_success"}]"#.utf8)

    @Test @MainActor func expiredReferenceRefreshesButOldQuoteNeverBecomesFresh() async throws {
        let live = L()
        var requests = 0
        let load: @MainActor () async throws -> Set<Int64> = { requests += 1; return [801] }
        let initial = live.refreshReferences(now: now, stillValid: { true },
            conditions: load, exchangeList: { [:] })
        let first = try #require(initial)
        await first.value
        let early = live.refreshReferences(now: now.addingTimeInterval(86_399), stillValid: { true },
            conditions: load, exchangeList: { [:] })
        #expect(early == nil)
        let expired = now.addingTimeInterval(86_400)
        let second = live.refreshReferences(now: expired, stillValid: { true },
            conditions: load, exchangeList: { [:] })
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
                conditions: load, exchangeList: { [:] })
            let first = try #require(initial)
            await first.value
            let early = live.refreshReferences(now: now.addingTimeInterval(59), stillValid: { true },
                conditions: load, exchangeList: { [:] })
            #expect(early == nil)
            let retryAt = now.addingTimeInterval(60)
            let retry = live.refreshReferences(now: retryAt, stillValid: { true },
                conditions: load, exchangeList: { [:] })
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
        let first = live.refreshReferences(now: now, stillValid: { true }, conditions: {
            await withCheckedContinuation { oldResume = $0; ready.continuation.yield() }
        }, exchangeList: { oldExchangeCalls += 1; return [:] })
        let firstTask = try #require(first)
        _ = await starts.next()
        live.stop(clearNBBO: {})
        let next = live.refreshReferences(now: now, stillValid: { true }, conditions: {
            await withCheckedContinuation { nextResume = $0; ready.continuation.yield() }
        }, exchangeList: { [1: .init(id: 1, mic: "XNAS", acronym: "TEST")] })
        let nextTask = try #require(next)
        _ = await starts.next()
        oldResume?.resume(returning: [801]); oldResume = nil
        await firstTask.value
        #expect(oldExchangeCalls == 0 && live.exchanges.isEmpty)
        var duplicateCalls = 0
        let duplicate = live.refreshReferences(now: now.addingTimeInterval(120), stillValid: { true },
            conditions: { duplicateCalls += 1; return [801] }, exchangeList: { [:] })
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
        let denied = live.refreshReferences(now: now, stillValid: { allowed }, conditions: load,
            exchangeList: { exchangeCalls += 1; return [:] })
        #expect(denied == nil && conditionsCalls == 0)
        allowed = true
        let revoked = live.refreshReferences(now: now, stillValid: { allowed }, conditions: load,
            exchangeList: { exchangeCalls += 1; return [:] })
        await revoked?.value
        #expect(conditionsCalls == 1 && exchangeCalls == 0)
        allowed = true
        let recovered = live.refreshReferences(now: now.addingTimeInterval(60), stillValid: { allowed },
            conditions: { [801] }, exchangeList: { exchangeCalls += 1; return [:] })
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
        ingress.offer(Data(#"[{"ev":"T","sym":"AAPL","p":100,"t":1700000000000},{"ev":"Q","sym":"AAPL","bp":99,"ap":101,"bs":100,"as":100,"t":1700000000000}]"#.utf8), at: now)
        let captured = try await drained(ingress, symbols: ["AAPL"])
        let live = L()
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
