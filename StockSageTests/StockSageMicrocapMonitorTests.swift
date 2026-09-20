import Foundation
import CryptoKit
import Testing
@testable import StockSage

@Suite("Micro cap setup identity", .serialized)
@MainActor struct StockSageMicrocapMonitorTests {
    @Test(arguments: [
        ("2026-09-21T07:59:59Z", false), ("2026-09-21T08:00:00Z", true),
        ("2026-09-21T19:59:59Z", true), ("2026-09-21T20:00:00Z", false),
        ("2026-09-25T08:00:00Z", true), ("2026-09-26T08:00:00Z", false),
        ("2026-09-27T08:00:00Z", false), ("2026-03-06T08:00:00Z", true),
        ("2026-03-09T08:00:00Z", true), ("2026-01-01T08:00:00Z", true)
    ])
    func trackingWindowUsesFixedRiyadhWeekdaysNotUSSessionOrDST(stamp: String, expected: Bool) throws {
        let at = try #require(ISO8601DateFormatter().date(from: stamp))
        let window = StockSageMicrocapMonitor.trackingWindow(at: at)
        #expect((window != nil) == expected)
        if let window {
            #expect(window.duration == 12 * 3600)
            #expect(window.start.ISO8601Format().hasSuffix("T08:00:00Z"))
            #expect(window.end.ISO8601Format().hasSuffix("T20:00:00Z"))
        }
    }

    @Test func nextTrackingStartSkipsWeekendAndRejectsInvalidClock() throws {
        let fridayClose = try #require(ISO8601DateFormatter().date(from: "2026-09-25T20:00:00Z"))
        #expect(StockSageMicrocapMonitor.nextTrackingStart(after: fridayClose)?.ISO8601Format() == "2026-09-28T08:00:00Z")
        #expect(StockSageMicrocapMonitor.trackingWindow(at: .init(timeIntervalSince1970: .nan)) == nil)
        #expect(StockSageMicrocapMonitor.nextTrackingStart(after: .init(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test func momentumSelectionPrefersModeCandidatesAndDisclosesTheBound() {
        let candidates = (0..<30).map { "C" + String(UnicodeScalar(65 + $0 / 26)!) + String(UnicodeScalar(65 + $0 % 26)!) }
        let selection = StockSageMicrocapMonitor.momentumSelection(candidates: candidates + ["../bad", "caa"], watchlist: ["AAPL", "CBA"])
        #expect(selection.symbols == Array(candidates.prefix(24)))
        #expect(selection.total == 32, "Thirty unique candidates, one unsupported symbol, and one extra watchlist symbol must all be accounted for")
        #expect(selection.skipped == 8)
    }

    @Test func aMomentumReviewDoesNotReplaceTheSavedModeScreenForTracking() {
        let now = Date(timeIntervalSince1970: 1_789_744_430)
        let rows: [StockSageMicrocapScreen.Row] = [
            .init(symbol: "MISSING", name: "Fixture", status: .unavailable, note: "Unknown", observedAt: now),
            .init(symbol: "READY", name: "Fixture", status: .unassessed, note: "Pending", observedAt: now),
            .init(symbol: "PASSED", name: "Fixture", status: .passed, note: "Synthetic", observedAt: now),
            .init(symbol: "EXCLUDED", name: "Fixture", status: .excluded, note: "Outside band", observedAt: now)
        ]
        var screen = StockSageSameDayResearch.Receipt(id: UUID(), startedAt: now, finishedAt: now, selection: "Screen", checks: [], mode: .largecap)
        screen.microcapScreen = .init(policyVersion: StockSageMicrocapScreen.Profile.largecap.policyVersion,
            startedAt: now, cutoff: now, finishedAt: now, directoryCount: rows.count,
            detailedCount: 1, unassessedCount: 1, rows: rows, blocker: nil)
        let review = StockSageSameDayResearch.Receipt(id: UUID(), startedAt: now, selection: "Descriptive review", checks: [
            .init(symbol: "REVIEW", name: "Fixture", at: now, note: "Review")
        ], mode: .largecap)
        var wrongMode = screen; wrongMode.mode = .microcap
        #expect(StockSageMicrocapMonitor.momentumCandidates(current: review, saved: [wrongMode, screen], mode: .largecap)
            == ["PASSED", "READY", "MISSING", "REVIEW"])
        #expect(StockSageMicrocapMonitor.momentumCandidates(current: review, saved: [wrongMode], mode: .largecap) == ["REVIEW"])
    }

    @Test func automaticMomentumNeedsDatedModeCapAndListingProof() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z"))
        func row(_ symbol: String, cap: Double?, date: String = "2026-09-18", venue: String? = "XNAS") -> StockSageStockScreener.Row {
            var row = StockSageStockScreener.Row(symbol: symbol, name: symbol, date: date, marketCap: cap, metrics: [], note: "")
            row.primaryExchange = venue
            return row
        }
        let rows = [row("MICRO", cap: 100_000_000), row("LARGE", cap: 20_000_000_000),
            row("NYSEMICRO", cap: 100_000_000, venue: "XNYS"), row("NYSELARGE", cap: 20_000_000_000, venue: "XNYS"),
            row("UNKNOWN", cap: nil), row("STALE", cap: 100_000_000, date: "2026-09-10"),
            row("SEVENDAYS", cap: 100_000_000, date: "2026-09-11"), row("FUTURE", cap: 100_000_000, date: "2026-09-19"),
            row("NOVENUE", cap: 100_000_000, venue: nil)]
        let snapshot = StockSageStockScreener.Snapshot(rows: rows, retrievedAt: now, receivedRows: rows.count,
            partial: false, note: "Synthetic verified listing join", membership: nil)
        #expect(StockSageMicrocapMonitor.heavySymbols(current: nil, saved: [], screener: snapshot, mode: .microcap, at: now)
            == Set(["MICRO", "SEVENDAYS"]))
        #expect(StockSageMicrocapMonitor.heavySymbols(current: nil, saved: [], screener: snapshot, mode: .largecap, at: now)
            == Set(["LARGE", "NYSELARGE"]))
        #expect(StockSageMicrocapMonitor.heavySymbols(current: nil, saved: [], screener: nil, mode: .microcap, at: now).isEmpty)

        let old = now.addingTimeInterval(-86400)
        var oldRow = StockSageMicrocapScreen.Row(symbol: "LARGE", name: "Fixture", status: .excluded,
            note: "Historical technical exclusion", observedAt: old)
        oldRow.marketCap = 100_000_000; oldRow.marketCapRequestedDate = "2026-09-17"; oldRow.referenceRetrievedAt = old
        var saved = StockSageSameDayResearch.Receipt(id: UUID(), startedAt: old, finishedAt: old, selection: "Old cap", checks: [], mode: .microcap)
        saved.microcapScreen = .init(policyVersion: StockSageMicrocapScreen.Profile.microcap.policyVersion,
            startedAt: old, cutoff: old, finishedAt: old, directoryCount: 1, detailedCount: 1, unassessedCount: 0, rows: [oldRow], blocker: nil)
        #expect(StockSageMicrocapMonitor.heavySymbols(current: nil, saved: [saved], screener: nil, mode: .microcap, at: now) == ["LARGE"],
                "Technical failure does not erase separately verified cap membership")
        #expect(!StockSageMicrocapMonitor.heavySymbols(current: nil, saved: [saved], screener: snapshot, mode: .microcap, at: now).contains("LARGE"),
                "Newer contradictory cap evidence overrides an older in-band screen")
    }

    @Test(arguments: [StockSageSameDayResearch.Mode.microcap, .largecap])
    func qualifiedAlertUsesTheReceiptModeAndStillRequiresFreshAstraProof(mode: StockSageSameDayResearch.Mode) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z"))
        var check = StockSageSameDayResearch.Check(symbol: "TEST", name: "Fixture", at: now, note: "Synthetic qualified result")
        check.action = "Buy"; check.reason = "Observed setup."; check.risk = "Reversal."
        check.qualified = true; check.expiresAt = now.addingTimeInterval(180)
        check.scenario = .init(entry: 100, stop: 99, target: 104, spreadBps: 10, rewardRisk: 3, at: now, barsAsOf: now)
        check.verifiedQuote = .init(.init(symbol: "TEST", bid: 99.9, ask: 100, bidSize: 10, askSize: 10,
            bidExchange: 1, askExchange: 1, timestamp: now, sequence: 1))
        check.codexAudit = .init(requestedModel: "gpt-6-astra", requestedEffort: "ultra", reportedModel: nil,
            cliVersion: "fixture", terminalStatus: "completed", systemSHA256: "fixture", userSHA256: "fixture",
            schemaSHA256: "fixture", inputTokens: nil, outputTokens: nil, elapsedMilliseconds: 1)
        var receipt = StockSageSameDayResearch.Receipt(id: UUID(), startedAt: now, finishedAt: now,
            selection: "Fixture", checks: [check], selectedSymbol: "TEST", mode: mode)
        let alert = try #require(StockSageMicrocapMonitor.alert(receipt, at: now))
        #expect(alert.hasPrefix("StockSage · \(mode.title) · TEST"))
        #expect(StockSageMicrocapMonitor.alert(receipt, at: now.addingTimeInterval(6)) == nil)
        receipt.checks[0].codexAudit = nil
        #expect(StockSageMicrocapMonitor.alert(receipt, at: now) == nil)
    }

    @Test func heavyMomentumIDsSeparateModesDirectionWindowAndPurpose() throws {
        let at = try #require(ISO8601DateFormatter().date(from: "2026-09-18T15:05:00Z"))
        func trigger(_ at: Date, profile: StockSageMicrocapScreen.Profile = .microcap,
                     direction: StockSageMomentum.Direction = .rising) -> StockSageMomentum.Trigger {
            .init(symbol: "TEST", direction: direction, returnFraction: direction == .rising ? 0.04 : -0.04,
                volumeMultiple: 4, at: at, profile: profile, start: at.addingTimeInterval(-300),
                startClose: 100, endClose: direction == .rising ? 104 : 96)
        }
        let value = trigger(at)
        let alert = try #require(StockSageMicrocapMonitor.momentumID(value, mode: .microcap, purpose: .observation))
        #expect(alert.count == 64)
        #expect(alert == StockSageMicrocapMonitor.momentumID(trigger(at.addingTimeInterval(60)), mode: .microcap, purpose: .observation))
        #expect(alert != StockSageMicrocapMonitor.momentumID(trigger(at.addingTimeInterval(1800)), mode: .microcap, purpose: .observation))
        #expect(alert != StockSageMicrocapMonitor.momentumID(trigger(at, direction: .falling), mode: .microcap, purpose: .observation))
        #expect(alert != StockSageMicrocapMonitor.momentumID(trigger(at, profile: .largecap), mode: .largecap, purpose: .observation))
        #expect(StockSageMicrocapMonitor.momentumID(value, mode: .largecap, purpose: .observation) == nil)
        let review = try #require(StockSageMicrocapMonitor.momentumID(value, mode: .microcap, purpose: .review))
        let summary = try #require(StockSageMicrocapMonitor.momentumID(value, mode: .microcap, purpose: .reviewSummary))
        let setup = StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: [], at: at)
        #expect(Set([alert, review, summary, setup]).count == 4)
        let text = try #require(StockSageMicrocapMonitor.momentumAlert(value, mode: .microcap, at: at))
        #expect(text.contains("not a qualified trade") && text.contains("+4.00%") && text.contains("4.00x"))
        #expect(!text.contains("buy ceiling") && !text.contains("Stop reference:") && !text.contains("Target reference:"))
        #expect(StockSageMicrocapMonitor.momentumAlert(value, mode: .microcap, at: at.addingTimeInterval(181)) == nil)
    }

    @MainActor private final class MomentumFixture {
        let key = "synthetic-momentum-" + UUID().uuidString
        let now = ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z")!
        var clockDate = ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z")!
        var calls = 0
        var beforeReply: (() -> Void)?
        var access: StockSageMassive.Access {
            let key = key
            return .init(key: { key }, credentialRevision: { "fixture" }, policyRevision: { "fixture" }, allowed: { true })
        }
        func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
            calls += 1; beforeReply?()
            let symbol = request.url!.path.components(separatedBy: "/")[4]
            let end = floor(now.timeIntervalSince1970 / 60) * 60
            let rows: [[String: Any]] = (1...60).reversed().map { offset in
                ["t": Int64((end - Double(offset * 60)) * 1000), "o": 100, "h": 101, "l": 99, "c": 100, "v": 1000]
            }
            let data = try JSONSerialization.data(withJSONObject: ["status": "OK", "ticker": symbol, "adjusted": true, "resultsCount": rows.count, "results": rows])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func momentumRefreshCannotFetchOutsideScheduleOrPublishAfterStop() async throws {
        let fixture = MomentumFixture()
        let monitor = StockSageMicrocapMonitor(mode: .largecap, requireWriter: {})
        let weekend = try #require(ISO8601DateFormatter().date(from: "2026-09-19T15:00:30Z"))
        let outside = await monitor.refreshMomentum(candidates: ["AAPL"], watchlist: [], at: weekend,
            access: fixture.access, transport: { try await fixture.reply($0) }, clock: { weekend }, stillValid: { true })
        #expect(!outside && fixture.calls == 0)
        fixture.beforeReply = { monitor.stop() }
        let canceled = await monitor.refreshMomentum(candidates: ["AAPL"], watchlist: [], at: fixture.now,
            access: fixture.access, transport: { try await fixture.reply($0) }, clock: { fixture.now }, stillValid: { true })
        #expect(!canceled && fixture.calls > 0)
        #expect(monitor.marketMomentum == nil && monitor.stockMomentum.isEmpty && monitor.nextMomentumCheck == nil)
        #expect(monitor.momentumStatus.contains("off"))
        fixture.beforeReply = { fixture.clockDate = fixture.clockDate.addingTimeInterval(1) }
        let fresh = await monitor.refreshMomentum(candidates: ["AAPL"], watchlist: [], at: fixture.now,
            access: fixture.access, transport: { try await fixture.reply($0) }, clock: { fixture.clockDate }, stillValid: { true })
        #expect(fresh, "The canceled refresh must release the shared lease for the next legitimate refresh")
        #expect(monitor.stockMomentum.map(\.symbol) == ["AAPL"])
        #expect(monitor.marketMomentum?.spy.status == .available)
        #expect((monitor.marketMomentum?.capturedAt ?? .distantPast) > fixture.now)
        #expect(monitor.stockMomentum.first?.vsSPY.allSatisfy { $0.status == .available } == true,
                "A real advancing request clock must not make the market capture look future-dated to its stock")
        #expect(monitor.stockMomentum.first?.vsQQQ.allSatisfy { $0.status == .available } == true)
    }

    @Test func setupIdentityIgnoresMovingQuotesButChangesForNewCatalystOrSession() {
        let now = ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z")!
        func fact(_ key: String, _ text: String) -> StockSageAIAssessment.EvidenceFact {
            .init(key: key, text: text, required: true, availability: .available)
        }
        let catalyst = fact("sameDay.catalyst.news.0", "Dated public catalyst")
        let original = StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: [catalyst, fact("quote", "ten")], at: now)
        #expect(original.count == 64)
        #expect(original == StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: [fact("quote", "eleven"), catalyst], at: now.addingTimeInterval(60)))
        #expect(original != StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: [fact("sameDay.catalyst.news.0", "New catalyst")], at: now))
        #expect(original != StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: [catalyst], at: now.addingTimeInterval(86400)))
    }
    @Test func capModesHaveSeparateSetupIDsWithoutChangingLegacyMicrocapIDs() {
        let now = ISO8601DateFormatter().date(from: "2026-09-18T15:00:30Z")!
        let facts: [StockSageAIAssessment.EvidenceFact] = [
            .init(key: "sameDay.catalyst.news.0", text: "Dated public catalyst", required: true, availability: .available)
        ]
        let legacy = StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: facts, at: now)
        let oldBytes = Data(#"["TEST","2026-9-18","Dated public catalyst"]"#.utf8)
        let oldID = SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
        let micro = StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: facts, at: now, mode: .microcap)
        let large = StockSageMicrocapMonitor.setupID(symbol: "TEST", facts: facts, at: now, mode: .largecap)
        #expect(legacy == micro)
        #expect(legacy == oldID, "Existing saved Micro cap IDs must remain byte-identical")
        #expect(large.count == 64 && large != micro)
        #expect(large == StockSageMicrocapMonitor.setupID(symbol: "test", facts: facts, at: now.addingTimeInterval(60), mode: .largecap))
        #expect(StockSageMicrocapMonitor.shared !== StockSageMicrocapMonitor.largecap)
        #expect(StockSageMicrocapMonitor.shared.mode == .microcap)
        #expect(StockSageMicrocapMonitor.largecap.mode == .largecap)
    }

    @Test(arguments: [StockSageSameDayResearch.Mode.microcap, .largecap])
    func savedClaimsSurviveRestartAndCorruptionBlocksNewInference(mode: StockSageSameDayResearch.Mode) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = String(repeating: "a", count: 64)
        let monitor = StockSageMicrocapMonitor(mode: mode, directory: directory, requireWriter: {})
        #expect(monitor.claim(id))
        #expect(!monitor.claim(id))
        #expect(!StockSageMicrocapMonitor(mode: mode, directory: directory, requireWriter: {}).claim(id))
        let file = directory.appendingPathComponent("automatic-setups.json")
        let corrupted = Data("broken records".utf8)
        try corrupted.write(to: file)
        #expect(!monitor.claim(String(repeating: "b", count: 64)))
        #expect(try Data(contentsOf: file) == corrupted)
        #expect(monitor.status.contains("preserved"))
    }

    @Test(arguments: [StockSageSameDayResearch.Mode.microcap, .largecap])
    func deniedWriterCannotClaimOrEraseAnExistingAttempt(mode: StockSageSameDayResearch.Mode) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = String(repeating: "c", count: 64)
        let monitor = StockSageMicrocapMonitor(mode: mode, directory: directory, requireWriter: { throw CocoaError(.fileWriteNoPermission) })
        #expect(!monitor.claim(id))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(arguments: [StockSageSameDayResearch.Mode.microcap, .largecap])
    func redirectedDirectoryAndMissingActivatedLedgerCannotResetDeduplication(mode: StockSageSameDayResearch.Mode) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let id = String(repeating: "d", count: 64)
        #expect(!StockSageMicrocapMonitor(mode: mode, directory: link, requireWriter: {}).claim(id))
        #expect(StockSageMicrocapMonitor(mode: mode, directory: real, requireWriter: {}).claim(id))
        try FileManager.default.removeItem(at: real.appendingPathComponent("automatic-setups.json"))
        #expect(!StockSageMicrocapMonitor(mode: mode, directory: real, requireWriter: {}).claim(id))
    }

}
