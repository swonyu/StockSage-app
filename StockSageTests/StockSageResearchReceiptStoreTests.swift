import Foundation
import Testing
@testable import StockSage

@Suite(.serialized)
@MainActor
struct StockSageResearchReceiptStoreTests {
    typealias ReceiptStore = StockSageResearchReceiptStore
    typealias Server = StockSageLocalModelServer

    @Test func newestInterruptedSameDayAttemptCannotRestoreAnOlderPick() throws {
        for hasPayload in [false, true] {
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = ReceiptStore(directory: folder), now = Date()
            let old = store.beginSameDay(at: now.addingTimeInterval(-60))
            _ = store.saveSameDay(.init(id: old, startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-30),
                selection: "Old completed shortlist", checks: [], selectedSymbol: "AAPL"))
            store.finish(scanID: old, status: "Completed", at: now.addingTimeInterval(-30))
            let interrupted = store.beginSameDay(at: now)
            if hasPayload {
                _ = store.saveSameDay(.init(id: interrupted, startedAt: now,
                    selection: "New unfinished shortlist", checks: []))
            }
            let restored = try #require(ReceiptStore(directory: folder).latestSameDay)
            #expect(restored.id == interrupted && restored.selectedSymbol == nil)
            #expect(restored.blocker?.contains("interrupted") == true)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-receipts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scanDirectory(_ scanID: UUID, in root: URL) -> URL {
        root.appendingPathComponent("scan-" + scanID.uuidString, isDirectory: true)
    }

    private func manifestURL(_ scanID: UUID, in root: URL) -> URL {
        scanDirectory(scanID, in: root).appendingPathComponent("manifest.json")
    }

    private func callURL(_ callID: UUID, attemptID: UUID, scanID: UUID, root: URL) -> URL {
        scanDirectory(scanID, in: root)
            .appendingPathComponent("calls", isDirectory: true)
            .appendingPathComponent("call-" + attemptID.uuidString + "-" + callID.uuidString + ".json")
    }

    private func factsURL(_ attemptID: UUID, scanID: UUID, root: URL) -> URL {
        scanDirectory(scanID, in: root).appendingPathComponent("facts-" + attemptID.uuidString + ".json")
    }

    private func decodeManifest(_ scanID: UUID, in root: URL) throws -> ReceiptStore.Scan {
        try JSONDecoder().decode(ReceiptStore.Scan.self, from: Data(contentsOf: manifestURL(scanID, in: root)))
    }

    private func onlyManifest(in root: URL) throws -> ReceiptStore.Scan {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let directory = try #require(directories.first { $0.lastPathComponent.hasPrefix("scan-") })
        return try JSONDecoder().decode(
            ReceiptStore.Scan.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }

    private func listing(_ symbol: String) -> StockSageHorizonResearch.Listing {
        .init(
            ticker: symbol,
            name: "Company " + symbol,
            market: "stocks",
            locale: "us",
            active: true,
            type: "CS",
            currency_name: "usd",
            primary_exchange: "XNAS"
        )
    }

    private func selection(
        at date: Date,
        returnedCount: Int = 1,
        eligibleCount: Int = 1,
        directoryCount: Int = 1,
        partialSession: Bool = false,
        fallback: Bool = false
    ) -> StockSageResearchUniverse.Receipt {
        var value = StockSageResearchUniverse.Receipt(
            session: "2026-09-11",
            requestedAt: date,
            returnedCount: returnedCount,
            eligibleCount: eligibleCount,
            directoryCount: directoryCount,
            partialSession: partialSession,
            dollarVolume: ["AAPL": 42]
        )
        value.fallback = fallback
        return value
    }

    private func event(
        callID: UUID,
        stage: Server.ModelAttemptEvent.Stage,
        startedAt: Date,
        phase: String = "initial",
        system: String = "system",
        schema: String? = #"{"type":"object"}"#,
        prompt: String = "prompt",
        response: String? = nil,
        finish: Server.Finish = .absent,
        category: Server.FailureCategory? = nil,
        ordinal: Int = 1
    ) -> Server.ModelAttemptEvent {
        .init(callID: callID, ordinal: ordinal, phase: phase, stage: stage,
            startedAt: startedAt, endedAt: stage == .finished ? startedAt.addingTimeInterval(0.75) : nil,
            transportStarted: true, requestedModel: "qwen3.5-9b", returnedModel: nil,
            isOllama: false, outputLimit: 192, contextTokens: 16_384, temperature: 0.2,
            system: system, systemBytes: system.utf8.count, systemTruncated: false,
            user: prompt, userBytes: prompt.utf8.count, userTruncated: false,
            schema: schema, schemaBytes: schema?.utf8.count, schemaTruncated: false,
            responseBody: response.map { Data($0.utf8) }, responseBodyBytes: response?.utf8.count,
            responseBodyTruncated: false, httpStatus: stage == .finished ? 200 : nil,
            diagnostic: .init(category: category, finish: finish,
                elapsedMilliseconds: stage == .finished ? 750 : 0))
    }

    private func directoryBytes(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    @Test
    func startedAndFinishedEventsUpsertOneDurableModelCall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let scanStartedAt = Date(timeIntervalSinceReferenceDate: 10_000.125)
        let scanID = store.begin(horizon: .week, at: scanStartedAt)
        let attemptID = try #require(store.registerSelection(
            selection(at: Date(timeIntervalSinceReferenceDate: 10_000.25)),
            listings: [listing("AAPL")],
            for: scanID
        ).first)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_001.375)
        store.beginAttempt(attemptID, scanID: scanID, at: startedAt)

        let callID = UUID()
        store.capture(event(callID: callID, stage: .started, startedAt: startedAt), for: attemptID, scanID: scanID)
        #expect(store.receipt(scanID: scanID)?.attempts.first?.modelCalls == [callID])
        #expect(store.call(scanID: scanID, attemptID: attemptID, callID: callID)?.stage == "started")

        let response = #"{"evidence":["F1"],"action":"Hold"}"#
        store.capture(event(callID: callID, stage: .finished, startedAt: startedAt,
                            response: response, finish: .stop), for: attemptID, scanID: scanID)
        store.finishAttempt(
            .init(verdict: .init(action: .hold, reason: "Dated evidence.", risk: "Uncertainty.", evidence: ["F1"]),
                  facts: ["F1: Dated evidence."], note: "Accepted.", model: "qwen3.5-9b", validationOutcome: .validated),
            attemptID: attemptID,
            scanID: scanID,
            status: "accepted",
            at: startedAt.addingTimeInterval(1)
        )
        store.finish(scanID: scanID, status: "finished", at: startedAt.addingTimeInterval(2))

        let reopened = ReceiptStore(directory: root)
        let saved = try #require(reopened.receipt(scanID: scanID))
        #expect(saved.dateEncoding == "seconds-since-2001-01-01T00:00:00Z")
        #expect(saved.startedAt == scanStartedAt)
        #expect(saved.attempts.first?.modelCalls == [callID])
        #expect(saved.attempts.first?.terminalStatus == "accepted")
        #expect(saved.attempts.first?.validationOutcome == "validated")
        #expect(saved.attempts.first?.uiAction == "Hold")
        #expect(saved.attempts.first?.selectionDollarVolume == 42)
        let call = try #require(reopened.call(scanID: scanID, attemptID: attemptID, callID: callID))
        #expect(call.stage == "finished")
        #expect(call.startedAt == startedAt)
        #expect(call.endedAt == startedAt.addingTimeInterval(0.75))
        #expect(call.response == response)
        #expect(call.responseSHA256?.count == 64)
        #expect(call.validationOutcome == nil)
        #expect(call.outcome == "transport:stop")
        #expect(call.httpStatus == 200)
        #expect(call.finishReason == "stop")
        #expect(call.failureCategory == nil)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(scanDirectory(scanID, in: root)) == 0o700)
        #expect(try permissions(scanDirectory(scanID, in: root).appendingPathComponent("calls")) == 0o700)
        #expect(try permissions(manifestURL(scanID, in: root)) == 0o600)
        #expect(try permissions(callURL(callID, attemptID: attemptID, scanID: scanID, root: root)) == 0o600)
        #expect(try permissions(factsURL(attemptID, scanID: scanID, root: root)) == 0o600)
    }

    @Test
    func reloadMarksStartedAttemptAndStartedCallAsInterruptedEvidence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ReceiptStore(directory: root)
        let scanID = first.begin(horizon: .week)
        let attemptID = try #require(first.registerSelection(nil, listings: [listing("AAPL")], for: scanID).first)
        let startedAt = Date(timeIntervalSinceReferenceDate: 20_000.5)
        first.beginAttempt(attemptID, scanID: scanID, at: startedAt)
        let callID = UUID()
        first.capture(event(callID: callID, stage: .started, startedAt: startedAt), for: attemptID, scanID: scanID)

        let reopened = ReceiptStore(directory: root)
        let recovered = try #require(reopened.receipt(scanID: scanID))
        #expect(recovered.endedAt != nil)
        #expect(recovered.status == "interrupted: process ended before completion")
        #expect(recovered.attempts.first?.terminalStatus == "interrupted")
        #expect(recovered.attempts.first?.endedAt != nil)
        let call = try #require(reopened.call(scanID: scanID, attemptID: attemptID, callID: callID))
        #expect(call.stage == "started")
        #expect(call.outcome == "transport:started")
        #expect(call.startedAt == startedAt)
        #expect(call.endedAt == nil)
    }

    @Test
    func selectionReceiptPersistsEveryFieldAndExplicitAbsence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let requestedAt = Date(timeIntervalSinceReferenceDate: 30_000.123_456)
        let fullScan = store.begin(horizon: .fortnight, at: requestedAt.addingTimeInterval(-1))
        let receipt = selection(
            at: requestedAt,
            returnedCount: 812,
            eligibleCount: 500,
            directoryCount: 9_876,
            partialSession: true,
            fallback: true
        )
        #expect(store.registerSelection(receipt, listings: [listing("AAPL")], for: fullScan).count == 1)
        store.finish(scanID: fullScan, status: "finished")

        let full = try decodeManifest(fullScan, in: root)
        #expect(full.selection?.session == receipt.session)
        #expect(full.selection?.requestedAt == requestedAt)
        #expect(full.selection?.returnedCount == 812)
        #expect(full.selection?.eligibleCount == 500)
        #expect(full.selection?.directoryCount == 9_876)
        #expect(full.selection?.partialSession == true)
        #expect(full.selection?.fallback == true)
        #expect(full.attempts.first?.selectionDollarVolume == 42)

        let absentScan = store.begin(horizon: .week)
        #expect(store.registerSelection(nil, listings: [listing("MSFT")], for: absentScan).count == 1)
        store.finish(scanID: absentScan, status: "finished")
        let absent = try decodeManifest(absentScan, in: root)
        #expect(absent.selection != nil)
        #expect(absent.selection?.session == nil)
        #expect(absent.selection?.requestedAt == nil)
        #expect(absent.selection?.returnedCount == nil)
        #expect(absent.selection?.eligibleCount == nil)
        #expect(absent.selection?.directoryCount == nil)
        #expect(absent.selection?.partialSession == nil)
        #expect(absent.selection?.fallback == nil)
        #expect(absent.attempts.first?.selectionDollarVolume == nil)
    }

    @Test
    func preAIResultKeepsValidationOutcomeExactlyUnknown() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let scanID = store.begin(horizon: .week)
        let attemptID = try #require(store.registerSelection(nil, listings: [listing("AAPL")], for: scanID).first)
        store.beginAttempt(attemptID, scanID: scanID)
        store.finishAttempt(
            .init(facts: ["History was unavailable."], note: "No model call was made.",
                  validationOutcome: .unknown, validationFailure: nil),
            attemptID: attemptID,
            scanID: scanID,
            status: "rejected"
        )
        store.finish(scanID: scanID, status: "finished")

        let reopened = ReceiptStore(directory: root)
        let attempt = try #require(reopened.receipt(scanID: scanID)?.attempts.first)
        #expect(attempt.modelCalls.isEmpty)
        #expect(attempt.validationOutcome == "unknown")
        #expect(attempt.validationFailure == nil)
        #expect(attempt.terminalStatus == "rejected")
    }

    @Test
    func redactionAndMultibyteCapsApplyWhenTransportFlagsAreFalse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let scanID = store.begin(horizon: .week)
        let attemptID = try #require(store.registerSelection(nil, listings: [listing("AAPL")], for: scanID).first)
        store.beginAttempt(attemptID, scanID: scanID)

        let system = "Authorization=SYSTEM_SECRET "
            + String(repeating: "a", count: ReceiptStore.maxPayloadUTF8 - 27)
            + "🙂"
        let callID = UUID()
        store.capture(event(
            callID: callID,
            stage: .finished,
            startedAt: Date(timeIntervalSinceReferenceDate: 40_000.25),
            system: system,
            schema: "apikey=SCHEMA_SECRET",
            prompt: "Bearer USER_SECRET",
            response: "token=BODY_SECRET",
            finish: .stop
        ), for: attemptID, scanID: scanID)

        let call = try #require(store.call(scanID: scanID, attemptID: attemptID, callID: callID))
        for value in [call.system, call.schema, call.prompt, call.response].compactMap({ $0 }) {
            #expect(!value.contains("SECRET"))
        }
        #expect(call.system?.contains("Authorization=[REDACTED]") == true)
        #expect(call.schema == "apikey=[REDACTED]")
        #expect(call.prompt == "Bearer [REDACTED]")
        #expect(call.response == "token=[REDACTED]")
        #expect(call.system?.utf8.count ?? Int.max <= ReceiptStore.maxPayloadUTF8)
        #expect(call.system?.data(using: .utf8) != nil)
        #expect(call.system?.hasSuffix("a") == true)
        #expect(call.systemTruncated)
        #expect(!call.schemaTruncated && !call.promptTruncated && !call.responseTruncated)
        #expect(call.redactionApplied)
        #expect(call.systemSHA256?.count == 64)
        #expect(call.promptSHA256?.count == 64)
        #expect(call.responseSHA256?.count == 64)
    }

    @Test
    func finalManifestWriteFailureIsReportedAfterSuccessfulBegin() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let scanID = store.begin(horizon: .week)
        #expect(try decodeManifest(scanID, in: root).status == "running")

        let directory = scanDirectory(scanID, in: root)
        try FileManager.default.removeItem(at: directory)
        try Data("occupied".utf8).write(to: directory)
        store.finish(scanID: scanID, status: "finished")

        #expect(store.persistenceFailed(scanID: scanID))
        #expect(store.receipt(scanID: scanID)?.persistence == "save_failed")
        #expect(store.lastError == ReceiptStore.Failure.writeFailed.localizedDescription)
    }

    @Test
    func bytePruningKeepsNewestCompletedScanAndActiveScan() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root, maxCompletedBytes: 0)
        let activeID = store.begin(horizon: .week, at: Date(timeIntervalSinceReferenceDate: 1_000))
        let olderID = store.begin(horizon: .week, at: Date(timeIntervalSinceReferenceDate: 2_000))
        store.finish(scanID: olderID, status: "finished", at: Date(timeIntervalSinceReferenceDate: 3_000))
        let newestID = store.begin(horizon: .week, at: Date(timeIntervalSinceReferenceDate: 4_000))
        store.finish(scanID: newestID, status: "finished", at: Date(timeIntervalSinceReferenceDate: 5_000))

        #expect(store.receipt(scanID: activeID) != nil)
        #expect(store.receipt(scanID: newestID) != nil)
        #expect(store.receipt(scanID: olderID) == nil)
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scan-") }
        #expect(directories.count == 2)
    }

    @Test(arguments: [500, 1_500])
    func fullListingReceiptPersistsAndReloadsEveryPayload(count: Int) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let benchmarkStart = ContinuousClock.now
        let store = ReceiptStore(directory: root)
        let scanID = store.begin(horizon: .week, at: Date(timeIntervalSinceReferenceDate: 50_000))
        let listings = (0..<count).map { listing("T" + String(format: "%03d", $0)) }
        let longOutcome = String(repeating: "x", count: 1_000)
        let attemptIDs = store.registerSelection(
            selection(at: Date(timeIntervalSinceReferenceDate: 50_000),
                      returnedCount: listings.count, eligibleCount: listings.count,
                      directoryCount: listings.count),
            listings: listings,
            for: scanID
        )
        try #require(attemptIDs.count == count)
        var callIDs: [UUID] = []
        callIDs.reserveCapacity(attemptIDs.count)

        for (index, attemptID) in attemptIDs.enumerated() {
            let symbol = listings[index].ticker
            let startedAt = Date(timeIntervalSinceReferenceDate: 50_001 + Double(index))
            let prompt = "F1 " + symbol + " " + String(repeating: "p", count: 8_000)
            let response = #"{"evidence":["F1"],"action":"Hold","reason":"Mixed.","risk":"Uncertain."}"#
            let callID = UUID()
            callIDs.append(callID)
            store.beginAttempt(attemptID, scanID: scanID, at: startedAt)
            store.capture(event(callID: callID, stage: .started, startedAt: startedAt,
                                prompt: prompt), for: attemptID, scanID: scanID)
            store.capture(event(callID: callID, stage: .finished, startedAt: startedAt,
                                prompt: prompt, response: response, finish: .stop),
                          for: attemptID, scanID: scanID)
            store.finishAttempt(
                .init(facts: ["F1: " + symbol + " has dated evidence."],
                      note: count == 1_500 ? longOutcome : "Accepted " + symbol,
                      model: "qwen3.5-9b", validationOutcome: .validated),
                attemptID: attemptID,
                scanID: scanID,
                status: "accepted",
                at: startedAt.addingTimeInterval(1)
            )
        }
        let finishedAt = Date(timeIntervalSinceReferenceDate: 50_002 + Double(count))
        store.finish(scanID: scanID, status: "finished", at: finishedAt)
        #expect(!store.persistenceFailed(scanID: scanID))

        let manifestBytes = try Data(contentsOf: manifestURL(scanID, in: root)).count
        #expect(manifestBytes < 3_000_000)
        if count == 1_500 {
            #expect(manifestBytes > 1_000_000, "This fixture must exercise the former manifest-size boundary")
        } else {
            #expect(manifestBytes < 1_000_000, "The original 500-listing receipt remains readable")
        }
        let reopened = ReceiptStore(directory: root)
        #expect(!reopened.persistenceFailed(scanID: scanID))
        let scan = try #require(reopened.receipt(scanID: scanID))
        #expect(scan.persistence == "saved")
        #expect(scan.attempts.count == count && scan.endedAt == finishedAt)
        #expect(scan.attempts.allSatisfy {
            $0.endedAt != nil && $0.terminalStatus == "accepted" && $0.modelCalls.count == 1
        })
        #expect(scan.attempts.reduce(0) { $0 + $1.modelCalls.count } == count)
        #expect(scan.attempts.allSatisfy { $0.endedAt.map { $0 < finishedAt } == true })
        if count == 1_500 {
            #expect(scan.attempts.allSatisfy { $0.uiOutcome == longOutcome },
                    "Increasing scan capacity must not truncate or discard individual outcomes")
        }

        for (index, attempt) in scan.attempts.enumerated() {
            let call = try #require(reopened.call(
                scanID: scanID,
                attemptID: attempt.id,
                callID: callIDs[index]
            ))
            #expect(call.stage == "finished")
            #expect(call.prompt?.utf8.count ?? 0 >= 8_000)
            #expect(call.response?.contains(#""action":"Hold""#) == true)
            #expect(reopened.facts(scanID: scanID, attemptID: attempt.id) == [
                "F1: " + listings[index].ticker + " has dated evidence."
            ])
        }

        let elapsed = benchmarkStart.duration(to: .now).components
        let elapsedMilliseconds = Int64(elapsed.seconds) * 1_000
            + Int64(elapsed.attoseconds / 1_000_000_000_000_000)
        let benchmark: [String: Any] = [
            "case": "receipt_store_\(count)",
            "elapsed_ms": elapsedMilliseconds,
            "manifest_bytes": manifestBytes,
            "total_file_bytes": directoryBytes(root),
            "attempts": scan.attempts.count,
            "model_calls": scan.attempts.reduce(0) { $0 + $1.modelCalls.count },
            "prompt_bytes_each": 8_008
        ]
        let benchmarkData = try JSONSerialization.data(withJSONObject: benchmark, options: [.sortedKeys])
        print("BENCHMARK " + String(decoding: benchmarkData, as: UTF8.self))
    }

    @Test
    func cancellationFinalizesNeverStartedListings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let research = StockSageHorizonResearch()
        let listings = [listing("AAPL"), listing("MSFT")]
        var held: CheckedContinuation<Void, Never>?
        let didStart = research.start(
            .week,
            allowed: { true },
            universe: {
                .init(listings, receipt: selection(at: Date(), returnedCount: 2,
                                                   eligibleCount: 2, directoryCount: 2))
            },
            analyze: { _ in .init(note: "unused") },
            receiptStore: store,
            receiptAnalyzer: { _, _, _ in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    held = continuation
                }
                return .init(note: "late")
            }
        )
        #expect(didStart)
        for _ in 0..<500 where held == nil { await Task.yield() }
        research.stop()
        held?.resume()
        for _ in 0..<500 where research.running != nil { await Task.yield() }
        let saved = try onlyManifest(in: root)
        #expect(saved.attempts.count == 2)
        #expect(saved.attempts.allSatisfy { $0.endedAt != nil })
        #expect(saved.attempts.contains { $0.terminalStatus == "interrupted_notStarted" })
    }

    @Test
    func unavailableReceiptDirectoryIsVisibleAndNeverPretendsToSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stocksage-receipt-file-" + UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let scanID = store.begin(horizon: .week)
        store.finish(scanID: scanID, status: "finished")
        #expect(store.persistenceFailed(scanID: scanID))
        #expect(store.receipt(scanID: scanID)?.persistence == "save_failed")
    }

    @Test func parallelHorizonsKeepSeparateListingManifestsAndDiagnosticLinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiptStore(directory: root)
        let research = StockSageHorizonResearch()
        let diagnosticID = UUID()
        let started = research.start([.week, .fortnight], allowed: { true },
            universe: { .init([listing("AAPL"), listing("MSFT")]) }, parallelism: { 2 },
            analyze: { _, _ in
                await Task.yield()
                return .init(note: "captured", diagnosticID: diagnosticID)
            }, receiptStore: store)
        #expect(started)
        for _ in 0..<2_000 where research.running != nil { await Task.yield() }
        try #require(research.running == nil)
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scan-") }
        let scans = try directories.map {
            try JSONDecoder().decode(ReceiptStore.Scan.self, from: Data(contentsOf: $0.appendingPathComponent("manifest.json")))
        }
        #expect(scans.count == 2 && Set(scans.map(\.horizon)).count == 2)
        #expect(Set(scans.flatMap { $0.attempts.map(\.id) }).count == 4)
        #expect(scans.allSatisfy { scan in
            scan.persistence == "saved" && scan.attempts.count == 2
                && scan.attempts.allSatisfy { $0.endedAt != nil && $0.diagnosticID == diagnosticID }
        })
    }

}
