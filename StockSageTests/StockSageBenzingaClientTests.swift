import Foundation
import Synchronization
import Testing
@testable import StockSage

@MainActor @Suite("Benzinga request ownership", .serialized)
struct StockSageBenzingaClientTests {
    typealias B = StockSageBenzinga
    typealias C = StockSageBenzingaClient

    private func query(_ product: B.Product = .news, _ subject: String = "AAPL",
                       from: String? = nil, through: String? = nil) -> B.Query {
        .init(product: product, subject: subject, from: from, through: through)
    }
    private static let empty = Data(#"{"status":"OK","results":[]}"#.utf8)
    private static func reply(_ request: URLRequest, status: Int = 200, body: Data = empty,
                              headers: [String: String] = [:]) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        try #require(condition(), "Expected the actual client boundary to be reached")
    }

    @MainActor private final class Wire {
        var calls: [URLRequest] = []
        var pending: [(URLRequest, CheckedContinuation<(Data, URLResponse), any Error>)] = []
        var peak = 0
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            calls.append(request)
            return try await withCheckedThrowingContinuation {
                pending.append((request, $0))
                peak = max(peak, pending.count)
            }
        }
        func finish(_ index: Int = 0, status: Int = 200, body: Data = StockSageBenzingaClientTests.empty) {
            guard pending.indices.contains(index) else { return }
            let item = pending.remove(at: index)
            item.1.resume(returning: StockSageBenzingaClientTests.reply(item.0, status: status, body: body))
        }
        // Intentionally cancellation-ignoring transport. Releasing is owned by each test.
        func finishAll() { while !pending.isEmpty { finish() } }
    }

    @MainActor private final class Timers {
        var pending: [(UUID, ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = []
        func sleep(until deadline: ContinuousClock.Instant) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { pending.append((id, deadline, $0)) }
            } onCancel: {
                Task { @MainActor in
                    if let i = self.pending.firstIndex(where: { $0.0 == id }) {
                        self.pending.remove(at: i).2.resume(throwing: CancellationError())
                    }
                }
            }
        }
        func fire(_ index: Int) {
            guard pending.indices.contains(index) else { return }
            pending.remove(at: index).2.resume()
        }
        func releaseAll() {
            let items = pending
            pending.removeAll()
            for item in items { item.2.resume(throwing: CancellationError()) }
        }
    }

    @Test func explicitFreshPageBypassesCacheAndPreservesAccessGate() async throws {
        var time = Date(timeIntervalSince1970: 1_789_293_600), calls = 0, allowed = true
        let client = C(key: { "synthetic" }, revision: { "epoch" }, allowed: { allowed },
            now: { time }, transport: { request in calls += 1; return Self.reply(request) })
        let first = await client.page(for: query())
        time = time.addingTimeInterval(1)
        let cached = await client.page(for: query())
        #expect(calls == 1 && cached.checkedAt == first.checkedAt)
        let fresh = await client.page(for: query(), bypassCache: true)
        #expect(calls == 2 && fresh.checkedAt > first.checkedAt)
        allowed = false
        #expect(await client.page(for: query(), bypassCache: true).status == .unavailable(.policyDenied))
        #expect(calls == 2)
    }

    @Test func freshSnapshotPassesCompanyIdentityBeforeRawBodyClipping() async throws {
        let time = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z")!
        let content = String(repeating: "Other company has ordinary news. ", count: 50)
            + "Acme Holdings revenue rose 12.5%."
        let body = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": [[
            "benzinga_id": 123, "tickers": ["AAPL"], "author": "Fixture", "title": "Many companies",
            "url": "https://www.benzinga.com/news/123", "published": "2026-09-13T11:00:00Z",
            "last_updated": "2026-09-13T11:30:00Z", "body": content]]])
        let client = C(key: { "synthetic" }, revision: { "epoch" }, allowed: { true }, now: { time },
            transport: { request in Self.reply(request, body: request.url!.path.hasSuffix("/news") ? body : Self.empty) })
        let capture = await client.snapshot(for: "AAPL", now: time, fresh: true, companyName: "Acme Holdings")
        let record = try #require(capture.pages.first { $0.query.product == .news }?.records.first)
        #expect(record.excerpt == "Acme Holdings revenue rose 12.5%.")
    }

    @Test func explicitFreshRequestCannotJoinOlderInFlightWork() async throws {
        let wire = Wire(), timers = Timers()
        let client = C(key: { "synthetic" }, revision: { "epoch" }, allowed: { true },
                       transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        let old = Task { await client.page(for: query()) }
        defer { old.cancel(); wire.finishAll(); timers.releaseAll() }
        try await waitFor { wire.pending.count == 1 }
        let fresh = Task { await client.page(for: query(), bypassCache: true) }
        defer { fresh.cancel() }
        try await waitFor { wire.pending.count == 2 }
        #expect(wire.calls.count == 2 && wire.peak <= 3)
        wire.finishAll()
        #expect(await old.value.status == .answered)
        #expect(await fresh.value.status == .answered)
    }

    @Test func singleFlightPeerCancellationAndFallbackShareThreeSlots() async throws {
        let wire = Wire(), timers = Timers()
        let client = C(key: { "synthetic" }, revision: { "revision1" }, allowed: { true },
                       transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        let a = Task { await client.page(for: query(.news, "AAPL")) }
        let peer = Task { await client.page(for: query(.news, "AAPL")) }
        let b = Task { await client.page(for: query(.earnings, "MSFT")) }
        let c = Task { await client.page(for: query(.ratings, "NVDA")) }
        defer { a.cancel(); peer.cancel(); b.cancel(); c.cancel(); wire.finishAll(); timers.releaseAll() }
        try await waitFor { wire.pending.count == 3 }
        #expect(wire.calls.count == 3)
        a.cancel()
        #expect(await a.value.status == .unavailable(.cancelled))
        #expect(wire.pending.count == 3, "One waiter cannot cancel its shared peer's transport")
        let aIndex = try #require(wire.pending.firstIndex { $0.0.url!.absoluteString.contains("AAPL") })
        wire.finish(aIndex)
        let page = await peer.value
        #expect(page.status == .answered && client.isCurrent(page.credentialGeneration))
        var request = URLRequest(url: URL(string: "https://api.massive.com/v2/reference/news?ticker=AAPL&limit=5")!)
        request.setValue("Bearer obsolete", forHTTPHeaderField: "Authorization")
        let fallback = Task { try await client.newsFallback(for: request, credentialGeneration: page.credentialGeneration) }
        let queued = Task { await client.page(for: query(.guidance, "AMZN")) }
        defer { fallback.cancel(); queued.cancel() }
        try await waitFor { wire.calls.count == 4 }
        #expect(wire.peak == 3 && wire.pending.count == 3)
        #expect(wire.calls.last?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
        for _ in 0..<30 { wire.finishAll(); await Task.yield() }
        _ = await b.value; _ = await c.value; _ = await queued.value
        let (_, response) = try await fallback.value
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(wire.peak == 3 && wire.calls.count == 5)
    }

    @Test func deadlineIncludesAdmissionAndCleanupDoesNotReleaseAStillRunningSlot() async throws {
        let wire = Wire(), timers = Timers()
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true },
                       transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        var tasks: [Task<B.Page, Never>] = []
        defer { tasks.forEach { $0.cancel() }; wire.finishAll(); timers.releaseAll() }
        for (index, symbol) in ["AAPL", "MSFT", "NVDA", "AMZN"].enumerated() {
            tasks.append(Task { await client.page(for: query(.news, symbol)) })
            try await waitFor { timers.pending.count == index + 1 && wire.pending.count == min(index + 1, 3) }
        }
        #expect(timers.pending.allSatisfy { ContinuousClock.now.duration(to: $0.1) <= .seconds(12) })
        // The fourth lookup's deadline is already armed while waiting for admission.
        timers.fire(3)
        #expect(await tasks[3].value.status == .unavailable(.timedOut))
        #expect(wire.calls.count == 3)
        timers.fire(0)
        #expect(await tasks[0].value.status == .unavailable(.timedOut))
        let replacement = Task { await client.page(for: query(.news, "META")) }
        defer { replacement.cancel() }
        for _ in 0..<10 { await Task.yield() }
        #expect(wire.calls.count == 3, "A cancelled but unreaped transport still owns its slot")
        wire.finish()
        try await waitFor { wire.calls.count == 4 }
        #expect(wire.peak == 3)
        for _ in 0..<30 { wire.finishAll(); await Task.yield() }
        _ = await replacement.value
        for task in tasks { _ = await task.value }
    }

    @Test func nativePolicyRoundTripRejectsLateTransportAndInferenceReceipt() async throws {
        let name = "BenzingaPolicy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.webAccess = true; settings.offlineOnly = false
        let wire = Wire(), timers = Timers()
        let client = C(key: { "synthetic" }, revision: { nil },
            allowed: { settings.webAccess && !settings.offlineOnly },
            policyRevision: { AppSettings.policyRevision(defaults: defaults) },
            transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        let task = Task { await client.page(for: query()) }
        defer { task.cancel(); wire.finishAll(); timers.releaseAll() }
        try await waitFor { wire.pending.count == 1 }
        settings.webAccess = false; settings.webAccess = true
        wire.finish()
        let stale = await task.value
        #expect(stale.status == .unavailable(.obsoleteCredential))
        #expect(!client.isCurrent(stale.credentialGeneration))
        let next = Task { await client.page(for: query()) }
        defer { next.cancel() }
        try await waitFor { wire.pending.count == 1 }
        wire.finishAll()
        let fresh = await next.value
        #expect(fresh.status == .answered && client.isCurrent(fresh.credentialGeneration))
        settings.offlineOnly = true; settings.offlineOnly = false
        #expect(!client.isCurrent(fresh.credentialGeneration), "A completed evidence capture cannot survive native policy revocation during inference")
    }

    @Test func revisionABACannotPublishOrLetOldCleanupRemoveNewFlight() async throws {
        let wire = Wire(), timers = Timers()
        var key = "synthetic-A", revision = "one"
        let client = C(key: { key }, revision: { revision }, allowed: { true },
                       transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        let old = Task { await client.page(for: query()) }
        defer { old.cancel(); wire.finishAll(); timers.releaseAll() }
        try await waitFor { wire.calls.count == 1 }
        key = "synthetic-B"; revision = "two"
        key = "synthetic-A"; revision = "three"
        let replacement = Task { await client.page(for: query()) }
        defer { replacement.cancel() }
        try await waitFor { wire.calls.count == 2 }
        let obsolete = await old.value
        #expect(obsolete.status == .unavailable(.obsoleteCredential))
        wire.finish(1)
        let fresh = await replacement.value
        #expect(fresh.status == .answered && client.isCurrent(fresh.credentialGeneration))
        #expect(!client.isCurrent(obsolete.credentialGeneration))
        #expect(fresh.credentialGeneration != "three" && fresh.credentialGeneration != "synthetic-A")
        wire.finish() // Late old completion must not evict/cache over the new answer.
        for _ in 0..<10 { await Task.yield() }
        #expect(await client.page(for: query()) == fresh)
        #expect(wire.calls.count == 2)
        let encoded = String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self)
        #expect(!encoded.contains("synthetic-A") && !encoded.contains("synthetic-B"))
    }

    @Test func policyRevocationAndLastWaiterCancellationWithholdLatePages() async throws {
        for cancel in [false, true] {
            let wire = Wire(), timers = Timers()
            var allowed = true
            let client = C(key: { "synthetic" }, revision: { nil }, allowed: { allowed },
                           transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
            let task = Task { await client.page(for: query()) }
            defer { task.cancel(); wire.finishAll(); timers.releaseAll() }
            try await waitFor { wire.pending.count == 1 }
            if cancel { task.cancel() } else { allowed = false }
            wire.finish()
            #expect(await task.value.status == .unavailable(cancel ? .cancelled : .policyDenied))
            allowed = true
            let retry = Task { await client.page(for: query()) }
            defer { retry.cancel() }
            try await waitFor { wire.calls.count == 2 }
            wire.finish()
            #expect(await retry.value.status == .answered)
        }
    }

    @Test func allProductTTLsAndBackwardsClock() async {
        for product in B.Product.allCases {
            var now = Date(timeIntervalSince1970: 1_789_041_600), calls = 0
            let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { now },
                           transport: { request in calls += 1; return Self.reply(request) })
            let q = query(product, product == .analysts || product == .firms ? "RefA" : "AAPL")
            let first = await client.page(for: q)
            #expect(first.status == .answered)
            now = now.addingTimeInterval(product.cacheTTL - 1)
            #expect(await client.page(for: q) == first && calls == 1)
            now = now.addingTimeInterval(1)
            _ = await client.page(for: q)
            #expect(calls == 2)
            now = first.checkedAt.addingTimeInterval(-1)
            _ = await client.page(for: q)
            #expect(calls == 3, "Clock reversal is a miss, not renewed freshness")
        }
    }

    @Test func lruIsBoundedAndQueryWindowsDoNotAlias() async {
        var calls = 0
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true },
                       transport: { request in calls += 1; return Self.reply(request) })
        for i in 0..<500 { _ = await client.page(for: query(.firms, "Firm\(i)")) }
        _ = await client.page(for: query(.firms, "Firm0"))
        _ = await client.page(for: query(.firms, "Firm500"))
        _ = await client.page(for: query(.firms, "Firm0"))
        #expect(calls == 501)
        _ = await client.page(for: query(.firms, "Firm1"))
        #expect(calls == 502, "Oldest-access entry, not oldest insertion, was evicted")
        _ = await client.page(for: query(.news, from: "2026-09-01T00:00:00Z", through: "2026-09-02T00:00:00Z"))
        _ = await client.page(for: query(.news, from: "2026-09-02T00:00:00Z", through: "2026-09-03T00:00:00Z"))
        #expect(calls == 504)
    }

    @Test func clearAuthorizationFailuresPreservesOtherCacheEntriesAndCooldown() async throws {
        var clock = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        var calls = 0, reads = 0
        var codes = ["Denied401": 401, "Denied402": 402, "Denied403": 403, "ServerError": 500, "Throttle": 429]
        let partial = Data(#"{"status":"OK","results":[],"next_url":"https://api.massive.com/unused"}"#.utf8)
        let client = C(key: { reads += 1; return "synthetic" },
                       revision: { reads += 1; return "synthetic-revision" },
                       allowed: { reads += 1; return true }, now: { clock },
            transport: { request in
                calls += 1
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "benzinga_id" }?.value ?? ""
                let body = id == "Partial" ? partial : id == "Malformed" ? Data("{}".utf8) : Self.empty
                return Self.reply(request, status: codes[id] ?? 200, body: body, headers: ["Retry-After": "300"])
            })
        // Metadata TTL exceeds the cooldown, so expiry cannot hide an overly broad cache clear.
        let keptIDs = ["Answered", "Partial", "Malformed", "ServerError"]
        var kept: [String: B.Page] = [:]
        for id in keptIDs { kept[id] = await client.page(for: query(.firms, id)) }
        #expect(kept["Answered"]?.status == .answered)
        #expect(kept["Partial"]?.status == .partial)
        #expect(kept["Malformed"]?.status == .unavailable(.malformed))
        #expect(kept["ServerError"]?.status == .unavailable(.http(500)))
        let deniedIDs = ["Denied401", "Denied402", "Denied403"]
        for id in deniedIDs {
            let denied = await client.page(for: query(.firms, id))
            #expect(denied.status == .unavailable(id == "Denied401" ? .unauthorized : .entitlement))
        }
        let throttle = await client.page(for: query(.firms, "Throttle"))
        #expect(throttle.status == .unavailable(.throttled) && calls == 8)
        codes = [:] // A subsequent admitted request would now answer.
        let beforeClear = reads
        client.clearAuthorizationFailures()
        #expect(calls == 8 && reads == beforeClear, "Clearing memory must not probe or read credentials/policy")
        #expect(client.isCurrent(kept["Answered"]?.credentialGeneration))
        for id in keptIDs {
            let page = await client.page(for: query(.firms, id))
            #expect(page == kept[id])
        }
        for id in deniedIDs {
            let page = await client.page(for: query(.firms, id))
            #expect(page.status == .unavailable(.throttled), "Denial was removed, but cooldown must still deny admission")
        }
        #expect(calls == 8)
        clock = clock.addingTimeInterval(299)
        client.clearAuthorizationFailures()
        let stillThrottled = await client.page(for: query(.firms, "Denied401"))
        #expect(stillThrottled.status == .unavailable(.throttled) && calls == 8)
        clock = clock.addingTimeInterval(1)
        for id in deniedIDs {
            let page = await client.page(for: query(.firms, id))
            #expect(page.status == .answered)
        }
        #expect(calls == 11, "Exactly the three cleared denials refetch after the unchanged cooldown")
        for id in keptIDs {
            let page = await client.page(for: query(.firms, id))
            #expect(page == kept[id])
        }
        #expect(calls == 11)
    }

    @Test func httpCategoriesThrottleAndManualRecheck() async throws {
        var now = Date(timeIntervalSince1970: 1_789_041_600), status = 401, calls = 0
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { now },
            transport: { request in
                calls += 1
                return Self.reply(request, status: status, headers: ["Retry-After": "9999"])
            })
        #expect(await client.page(for: query()).status == .unavailable(.unauthorized))
        status = 403
        #expect(await client.page(for: query()).status == .unavailable(.unauthorized) && calls == 1)
        #expect(await client.page(for: query(), recheckAuthorization: true).status == .unavailable(.entitlement))
        status = 429
        #expect(await client.page(for: query(), recheckAuthorization: true).status == .unavailable(.throttled))
        let generation = (await client.page(for: query())).credentialGeneration
        let fallback = URLRequest(url: URL(string: "https://api.massive.com/v2/reference/news?ticker=AAPL&limit=5")!)
        do {
            _ = try await client.newsFallback(for: fallback, credentialGeneration: generation)
            Issue.record("Throttle must also block generic-news fallback")
        } catch let error as B.Failure { #expect(error == .throttled) }
        #expect(calls == 3)
        now = now.addingTimeInterval(299)
        _ = await client.page(for: query(.ratings), recheckAuthorization: true)
        #expect(calls == 3)
        now = now.addingTimeInterval(1); status = 200
        #expect(await client.page(for: query(), recheckAuthorization: true).status == .answered && calls == 4)
        #expect(C.retryDelay("invalid", now: now) == 30)
        #expect(C.retryDelay(nil, now: now) == 30)
        #expect(C.retryDelay("0", now: now) == 0)
        #expect(C.retryDelay("-1", now: now) == 30)
        #expect(C.retryDelay("301", now: now) == 300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(C.retryDelay(formatter.string(from: now.addingTimeInterval(120)), now: now) == 120)
    }

    @Test func snapshotRetainsThreeRecordsAndOnlyReferencedMetadata() async throws {
        var paths: [URL] = []
        let clock = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { clock },
            transport: { request in
                let url = request.url!; paths.append(url)
                let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
                let id = fields.first { $0.name == "benzinga_id" }?.value ?? ""
                var rows: [[String: Any]] = []
                if url.path.hasSuffix("/ratings") {
                    rows = (0..<5).map { i in [
                        "benzinga_id": "R\(i)", "ticker": "AAPL", "date": "2026-09-10",
                        "last_updated": "2026-09-10T11:00:00Z", "firm": "Fixture",
                        "rating_action": "upgrades", "rating": "buy", "currency": "USD",
                        "benzinga_analyst_id": "Analyst\(i)", "benzinga_firm_id": "Firm\(i)"
                    ] }
                } else if url.path.hasSuffix("/analysts") {
                    rows = [["benzinga_id": id, "full_name": "Fixture", "benzinga_firm_id": "DoNotFetchAffiliation"]]
                } else if url.path.hasSuffix("/firms") { rows = [["benzinga_id": id, "name": "Fixture"]] }
                let body = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows])
                return Self.reply(request, body: body)
            })
        let snapshot = await client.snapshot(symbol: "AAPL")
        #expect(snapshot.pages.count == 13 && snapshot.omittedRecordCount == 2)
        let retained = snapshot.pages.filter { $0.query.product == .ratings }.flatMap(\.records)
        #expect(retained.count == 3)
        let analysts = Set(snapshot.pages.filter { $0.query.product == .analysts }.map(\.query.subject))
        let firms = Set(snapshot.pages.filter { $0.query.product == .firms }.map(\.query.subject))
        #expect(analysts == Set(retained.flatMap(\.analystIDs)))
        #expect(firms == Set(retained.flatMap(\.firmIDs)))
        #expect(!paths.contains { $0.absoluteString.contains("DoNotFetchAffiliation") })
        for product in B.Product.allCases {
            #expect(snapshot.pages.filter { $0.query.product == product }.flatMap(\.records).count <= 3)
        }
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("synthetic"))
    }

    @Test func fallbackRejectsUnsafeRequestsAndObsoleteGenerationBeforeTransport() async throws {
        var calls = 0, revision = "one"
        let client = C(key: { "synthetic" }, revision: { revision }, allowed: { true },
                       transport: { request in calls += 1; return Self.reply(request) })
        let page = await client.page(for: query())
        for raw in ["http://api.massive.com/v2/reference/news", "https://attacker.invalid/v2/reference/news",
                    "https://api.massive.com/v2/reference/news?apiKey=synthetic",
                    "https://api.massive.com/benzinga/v2/news"] {
            do {
                _ = try await client.newsFallback(for: URLRequest(url: URL(string: raw)!),
                                                  credentialGeneration: page.credentialGeneration)
                Issue.record("Unsafe fallback accepted")
            } catch let error as B.Failure { #expect(error == .invalidQuery) }
        }
        revision = "two"
        do {
            _ = try await client.newsFallback(for: URLRequest(url: URL(string: "https://api.massive.com/v2/reference/news")!),
                                              credentialGeneration: page.credentialGeneration)
            Issue.record("Obsolete generation accepted")
        } catch let error as B.Failure { #expect(error == .obsoleteCredential) }
        #expect(calls == 1)
    }

    @Test func offlineAndMissingKeyReceiptsRemainValidWithoutReadingInInit() async throws {
        for offline in [false, true] {
            var reads = 0, calls = 0, allowed = !offline, key = offline ? "synthetic" : ""
            let client = C(key: { reads += 1; return key }, revision: { reads += 1; return nil },
                           allowed: { reads += 1; return allowed },
                           transport: { request in calls += 1; return Self.reply(request) })
            #expect(reads == 0, "Initialization must not touch owner preference/policy getters")
            let snapshot = await client.snapshot(symbol: "AAPL")
            #expect(snapshot.pages.count == 7 && calls == 0)
            #expect(snapshot.pages.allSatisfy { $0.status == .unavailable(offline ? .policyDenied : .missingCredential) })
            #expect(client.isCurrent(snapshot) && client.isCurrent(snapshot.credentialGeneration))
            #expect(B.projection(snapshot, maximumUTF8Bytes: 12_000) != nil)
            if offline { allowed = true } else { key = "synthetic" }
            #expect(!client.isCurrent(snapshot), "The unavailable receipt is current only for its captured state")
        }
    }

    @Test func observedPolicyRoundTripInvalidatesOldReceiptsAndAwaits() async throws {
        let wire = Wire(), timers = Timers()
        var allowed = true
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { allowed },
                       transport: { try await wire.send($0) }, sleepUntil: { try await timers.sleep(until: $0) })
        let seed = Task { await client.page(for: query()) }
        defer { seed.cancel(); wire.finishAll(); timers.releaseAll() }
        try await waitFor { wire.calls.count == 1 }
        wire.finish()
        let old = await seed.value
        let pending = Task { await client.page(for: query(.ratings)) }
        defer { pending.cancel() }
        try await waitFor { wire.calls.count == 2 }
        allowed = false
        let offline = await client.snapshot(symbol: "AAPL")
        #expect(!client.isCurrent(old.credentialGeneration) && client.isCurrent(offline))
        #expect(await pending.value.status == .unavailable(.policyDenied))
        allowed = true
        #expect(!client.isCurrent(offline), "Observed policy off/on rotates the receipt, even with the same key")
        wire.finishAll()
    }

    @Test func snapshotUsesCompletionClockAndRetainsQueryAndProviderClocks() async throws {
        let bounds = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        var clock = bounds, newsThrough: String?
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { clock },
            transport: { request in
                clock = clock.addingTimeInterval(1)
                var rows: [[String: Any]] = []
                if request.url!.path.hasSuffix("/ratings") {
                    rows = [["benzinga_id": "dated", "ticker": "AAPL", "date": "2026-09-10",
                             "last_updated": "2026-09-10T11:00:00Z", "firm": "Fixture",
                             "rating_action": "upgrades", "rating": "buy", "currency": "USD"]]
                }
                if request.url!.path.hasSuffix("/news") {
                    newsThrough = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "published.lte" }?.value
                }
                let body = try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows])
                return Self.reply(request, body: body)
            })
        let snapshot = await client.snapshot(for: "AAPL", now: bounds)
        #expect(snapshot.capturedAt == clock && snapshot.capturedAt > bounds)
        #expect(snapshot.pages.allSatisfy { $0.checkedAt <= snapshot.capturedAt })
        #expect(newsThrough.flatMap { StockSageNewsService.publicationDate($0)?.date } == bounds)
        let projection = try #require(B.projection(snapshot, maximumUTF8Bytes: 12_000))
        #expect(projection.records.contains { $0.vendorID == "dated" && $0.lastUpdated == "2026-09-10T11:00:00Z" })
    }

    @Test func rollingNewsReusesOriginalCheckAndRevalidatesWindowAtUse() async throws {
        let start = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        var clock = start, newsCalls = 0
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { clock },
            transport: { request in
                var rows: [[String: Any]] = []
                if request.url!.path.hasSuffix("/news") {
                    newsCalls += 1
                    rows = [["benzinga_id": 1, "tickers": ["AAPL"], "title": "Boundary headline",
                             "author": "Fixture", "published": "2026-09-03T12:00:00Z",
                             "last_updated": "2026-09-03T12:00:00Z",
                             "url": "https://example.invalid/fixture"]]
                }
                return Self.reply(request, body: try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows]))
            })
        let first = await client.snapshot(for: "AAPL", now: start)
        let firstNews = try #require(first.pages.first { $0.query.product == .news })
        #expect(firstNews.records.count == 1 && newsCalls == 1)
        clock = clock.addingTimeInterval(1)
        let second = await client.snapshot(for: "AAPL", now: clock)
        let secondNews = try #require(second.pages.first { $0.query.product == .news })
        #expect(newsCalls == 1 && secondNews.checkedAt == firstNews.checkedAt && secondNews.query == firstNews.query)
        #expect(secondNews.records.isEmpty && secondNews.status == .partial && secondNews.excludedCount == 1)
        #expect(firstNews.records.count == 1, "Revalidation must not mutate the original receipt")
        clock = start.addingTimeInterval(30)
        _ = await client.snapshot(for: "AAPL", now: clock)
        #expect(newsCalls == 2)
    }

    @Test func sequentialDefaultNewsQueriesShareTransportWithoutAcceptingFutureRows() async throws {
        let start = try Date.ISO8601FormatStyle().parse("2026-09-10T12:00:00Z")
        var clock = start, calls = 0
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true }, now: { clock },
            transport: { request in
                calls += 1
                clock = clock.addingTimeInterval(0.1) // Future to the requested cutoff, not to local check.
                let rows: [[String: Any]] = [
                    ["benzinga_id": 1, "tickers": ["AAPL"], "title": "At cutoff", "author": "Fixture",
                     "published": "2026-09-10T12:00:00Z", "last_updated": "2026-09-10T12:00:00Z",
                     "url": "https://example.invalid/one"],
                    ["benzinga_id": 2, "tickers": ["AAPL"], "title": "Future by one nanosecond", "author": "Fixture",
                     "published": "2026-09-10T12:00:00.000000001Z", "last_updated": "2026-09-10T12:00:00.000000001Z",
                     "url": "https://example.invalid/two"]
                ]
                return Self.reply(request, body: try JSONSerialization.data(withJSONObject: ["status": "OK", "results": rows]))
            })
        // Same actual page(for:) call and timestamp formatter as the production NewsService wrapper.
        func defaultNewsPage() async -> B.Page {
            let sourceNow = clock
            return await client.page(for: query(.news,
                from: StockSageNewsService.instant(sourceNow.addingTimeInterval(-7 * 86_400)),
                through: StockSageNewsService.instant(sourceNow)))
        }
        let first = await defaultNewsPage()
        let second = await defaultNewsPage()
        #expect(calls == 1 && first.checkedAt == second.checkedAt && first.query == second.query)
        #expect(first.status == .partial && first.excludedCount == 1 && first.records.count == 1)
        #expect(second.records == first.records && !first.records.contains { $0.vendorID == "2" })
    }

    @Test func nativeStreamingCapAndTotalDeadlineCancelTheActualReader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BenzingaBodyProtocol.self]
        let session = URLSession(configuration: config, delegate: StockSageHTTP.NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let timers = Timers()
        let client = C(key: { "synthetic" }, revision: { nil }, allowed: { true },
                       session: session, sleepUntil: { try await timers.sleep(until: $0) })
        defer { timers.releaseAll() }
        #expect(await client.page(for: query(.firms, "Exact")).status == .answered)
        #expect(await client.page(for: query(.firms, "Overflow")).status == .unavailable(.oversized))
        let before = BenzingaBodyProtocol.started.withLock { $0 }
        let stopped = BenzingaBodyProtocol.stopped.withLock { $0 }
        let slow = Task { await client.page(for: query(.firms, "Slow")) }
        defer { slow.cancel() }
        try await waitFor { BenzingaBodyProtocol.started.withLock { $0 } > before && !timers.pending.isEmpty }
        timers.fire(timers.pending.count - 1)
        #expect(await slow.value.status == .unavailable(.timedOut))
        try await waitFor { BenzingaBodyProtocol.stopped.withLock { $0 } > stopped }
    }
}

private nonisolated final class BenzingaBodyProtocol: URLProtocol, @unchecked Sendable {
    static let started = Mutex(0), stopped = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.started.withLock { $0 += 1 }
        let url = request.url!
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "benzinga_id" }?.value
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        let head = Data(#"{"status":"OK","results":[]}"#.utf8)
        client?.urlProtocol(self, didLoad: head)
        if id == "Slow" { return } // No completion: the client's total deadline must cancel AsyncBytes.
        let total = id == "Overflow" ? 2_000_001 : 2_000_000
        client?.urlProtocol(self, didLoad: Data(repeating: 32, count: total - head.count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopped.withLock { $0 += 1 } }
}
