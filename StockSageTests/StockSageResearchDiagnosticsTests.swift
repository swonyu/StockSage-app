import Foundation
import Testing
@testable import StockSage

@Suite("Local research diagnostic retention", .serialized)
struct StockSageResearchDiagnosticsTests {
    typealias Store = StockSageResearchDiagnostics

    @Test func interleavedContextsRetainIndependentValidationAndReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let b = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await store.begin(a))
        #expect(await store.begin(b))
        #expect(await store.finish(b, outcome: .init(state: .rejected, note: "HTTP completed; citation rejected.")))
        #expect(await store.finish(a, outcome: .init(state: .accepted, note: "Research validation passed.")))
        let restored = Store(directory: dir)
        let first = await restored.entries(for: a.id)
        let second = await restored.entries(for: b.id)
        #expect(first.map(\.kind) == [.started, .outcome])
        #expect(second.map(\.kind) == [.started, .outcome])
        #expect(first.allSatisfy { $0.context == a })
        #expect(second.allSatisfy { $0.context == b })
        #expect(first.last?.outcome?.state == .accepted)
        #expect(second.last?.outcome?.state == .rejected)
        #expect(first.last?.complete == true && second.last?.complete == true)
    }

    @Test func interruptedContextDoesNotInventAnOutcome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await Store(directory: dir).begin(context))
        let entries = await Store(directory: dir).entries(for: context.id)
        #expect(entries.count == 1 && entries.first?.kind == .started)
        #expect(entries.allSatisfy { $0.outcome == nil })
    }

    @Test func retentionArchivesCompletedContextsButKeepsActiveOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumContexts: 2)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let b = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        let c = Store.Context(symbol: "ADI", horizon: 14, purpose: .assessment)
        #expect(await store.begin(a))
        #expect(await store.begin(b))
        #expect(await store.finish(b, outcome: .init(state: .rejected, note: "No usable response.")))
        #expect(await store.begin(c))
        #expect(!(await store.entries(for: a.id)).isEmpty)
        #expect((await store.entries(for: b.id)).last?.outcome?.state == .rejected)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(b.id.uuidString + ".jsonl").path))
        #expect(!(await store.entries(for: c.id)).isEmpty)
    }

    @Test func capsAndDiskFailureAreExplicitAndDoNotTouchHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("runs.json")
        let original = Data("untouched prediction evidence".utf8)
        try original.write(to: history)
        let context = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let capped = Store(directory: root.appendingPathComponent("capped"), maximumContextBytes: 32)
        #expect(!(await capped.begin(context)))
        #expect(!(await capped.finish(context, outcome: .init(state: .accepted, note: "Bounded failure."))))
        let blocked = Store(directory: history)
        #expect(!(await blocked.begin(context)))
        #expect(!(await blocked.finish(context, outcome: .init(state: .rejected, note: "Disk path unavailable."))))
        #expect(try Data(contentsOf: history) == original)
    }

    private func event(body: Data = Data([0, 255, 195, 40])) -> StockSageLocalModelServer.ModelAttemptEvent {
        .init(callID: UUID(), ordinal: 1, phase: "initial", stage: .finished,
              startedAt: Date(), endedAt: Date(), transportStarted: true,
              requestedModel: "local-test", returnedModel: nil, isOllama: false,
              outputLimit: 192, contextTokens: 16_384, temperature: 0.2,
              system: "Facts only", systemBytes: 10, systemTruncated: false,
              user: "F1: unavailable", userBytes: 15, userTruncated: false,
              schema: nil, schemaBytes: nil, schemaTruncated: false,
              responseBody: body, responseBodyBytes: body.count, responseBodyTruncated: false,
              httpStatus: 200, diagnostic: .init())
    }

    private func byteCount(_ directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jsonl" }
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    @Test func contextIdentityCannotBeReassignedOrClosedByAnotherContext() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let actual = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let impostor = Store.Context(id: actual.id, symbol: "META", horizon: 14, purpose: .assessment,
                                     startedAt: actual.startedAt)
        #expect(await store.begin(actual))
        #expect(!(await store.begin(impostor)))
        #expect(!(await store.record(event(), context: impostor)))
        #expect(!(await store.finish(impostor, outcome: .init(state: .accepted, note: "Wrong context."))))
        #expect((await store.entries(for: actual.id)).map(\.kind) == [.started])
        #expect(!(await store.finish(actual, outcome: .init(state: .rejected, note: "Diagnostic collection failed."))))
        let saved = await store.entries(for: actual.id)
        #expect(saved.allSatisfy { $0.context == actual })
        #expect(saved.last?.complete == false)
    }

    @Test func allActiveContextsMakeTheCountCapRejectNewWork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumContexts: 1)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let b = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await store.begin(a))
        #expect(!(await store.begin(b)))
        #expect((await store.entries(for: a.id)).count == 1)
        #expect((await store.entries(for: b.id)).isEmpty)
        #expect(await store.finish(a, outcome: .init(state: .accepted, note: "Validated.")))
        #expect(await store.begin(b))
        #expect((await store.entries(for: a.id)).last?.outcome?.state == .accepted)
    }

    @Test func oversizedAttemptFailsStickyWithoutGrowingAnActiveFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumContextBytes: 4_096)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await store.begin(a))
        let before = try byteCount(dir)
        #expect(!(await store.record(event(body: Data(repeating: 255, count: 4_096)), context: a)))
        #expect(try byteCount(dir) == before)
        #expect(!(await store.record(event(), context: a)))
        #expect(!(await store.finish(a, outcome: .init(state: .accepted, note: "Research accepted; receipt was incomplete."))))
        #expect(try byteCount(dir) <= 4_096)
        #expect((await store.entries(for: a.id)).last?.complete == false)
    }

    @Test func totalByteCapNeverEvictsActiveContexts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumBytes: 2_000, maximumContextBytes: 10_000)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let b = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await store.begin(a))
        #expect(await store.begin(b))
        #expect(!(await store.record(event(body: Data(repeating: 255, count: 2_000)), context: a)))
        #expect((await store.entries(for: a.id)).count == 1)
        #expect((await store.entries(for: b.id)).count == 1)
        #expect(try byteCount(dir) <= 2_000)
    }

    @Test func rawNonUTF8AttemptSurvivesReloadWithoutBecomingAcceptance() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let attempt = event(body: Data((0..<65_536).map { UInt8($0 % 256) }))
        #expect(await store.begin(a))
        #expect(await store.record(attempt, context: a))
        #expect(await store.finish(a, outcome: .init(state: .rejected, note: "HTTP success is not research acceptance.")))
        let entries = await Store(directory: dir).entries(for: a.id)
        #expect(entries.map(\.kind) == [.started, .attempt, .outcome])
        #expect(entries.dropFirst().first?.attempt == attempt)
        #expect(entries.last?.outcome?.state == .rejected)
    }

    @Test func inactiveRejectedRawReplySurvivesHotIndexEvictionAndReload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumContexts: 1)
        let rejected = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let raw = Data((0..<65_536).map { UInt8($0 % 256) })
        let attempt = event(body: raw)
        #expect(await store.begin(rejected))
        #expect(await store.record(attempt, context: rejected))
        #expect(await store.finish(rejected, outcome: .init(state: .rejected, note: "Unsupported model claim.")))
        let original = await store.entries(for: rejected.id)
        #expect(original.map(\.kind) == [.started, .attempt, .outcome])
        let originalBytes = try Data(contentsOf: dir.appendingPathComponent(rejected.id.uuidString + ".jsonl"))

        let next = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await store.begin(next))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(rejected.id.uuidString + ".jsonl").path))
        let restored = Store(directory: dir, maximumContexts: 1)
        let retained = await restored.entries(for: rejected.id)
        #expect(retained == original)
        #expect(retained.dropFirst().first?.attempt?.responseBody == raw)
        #expect(retained.last?.outcome?.state == .rejected)
        #expect(retained.last?.complete == true)
        #expect((await restored.entries(for: next.id)).map(\.kind) == [.started])
        let archive = dir.appendingPathComponent("Archive", isDirectory: true)
        let archivedFile = archive.appendingPathComponent(rejected.id.uuidString + ".jsonl")
        #expect(try Data(contentsOf: archivedFile) == originalBytes)
        let archiveMode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: archivedFile.path)[.posixPermissions] as? NSNumber
        #expect(archiveMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
        #expect(!(await restored.begin(rejected)))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(rejected.id.uuidString + ".jsonl").path))
    }

    @Test func byteCapArchivesInterruptedTornBytesWithoutInventingOutcome() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let interrupted = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await Store(directory: dir).begin(interrupted))
        let hot = dir.appendingPathComponent(interrupted.id.uuidString + ".jsonl")
        let handle = try FileHandle(forWritingTo: hot)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":\"response".utf8))
        try handle.close()
        let original = try Data(contentsOf: hot)
        let restored = Store(directory: dir, maximumBytes: original.count + 1)
        let next = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await restored.begin(next))
        #expect(try byteCount(dir) <= original.count + 1)
        #expect(!FileManager.default.fileExists(atPath: hot.path))
        let archived = dir.appendingPathComponent("Archive").appendingPathComponent(hot.lastPathComponent)
        #expect(try Data(contentsOf: archived) == original)
        let entries = await Store(directory: dir).entries(for: interrupted.id)
        #expect(entries.map(\.kind) == [.started])
        #expect(entries.allSatisfy { $0.outcome == nil })
    }

    @Test(arguments: ["identical", "conflicting", "corrupt", "oversized", "symlink"])
    func archiveCollisionNeverReplacesExistingEvidence(kind: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumContexts: 1, maximumContextBytes: 4_096)
        let previous = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await store.begin(previous))
        #expect(await store.finish(previous, outcome: .init(state: .rejected, note: "Original rejection.")))
        let hot = dir.appendingPathComponent(previous.id.uuidString + ".jsonl")
        let original = try Data(contentsOf: hot)
        let archive = dir.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let target = archive.appendingPathComponent(hot.lastPathComponent)
        let archivedBytes: Data
        switch kind {
        case "conflicting":
            archivedBytes = Data(String(decoding: original, as: UTF8.self)
                .replacingOccurrences(of: "Original rejection.", with: "Conflicting result.").utf8)
            #expect(archivedBytes != original)
        case "corrupt": archivedBytes = Data("not JSON\n".utf8)
        case "oversized": archivedBytes = Data(repeating: 10, count: 4_097)
        default: archivedBytes = original
        }
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: hot)
        } else { try archivedBytes.write(to: target) }
        let next = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
        #expect(await store.begin(next) == (kind == "identical"))
        #expect(try Data(contentsOf: target) == archivedBytes)
        if kind == "identical" {
            #expect(!FileManager.default.fileExists(atPath: hot.path))
            #expect((await Store(directory: dir).entries(for: previous.id)).last?.outcome?.state == .rejected)
        } else {
            #expect(try Data(contentsOf: hot) == original)
            #expect((await store.entries(for: next.id)).isEmpty)
        }
    }

    @Test func archiveLookupIsReadOnlyAndNeverMasksCorruptHotEvidence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalStore = Store(directory: dir)
        let context = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await originalStore.begin(context))
        #expect(await originalStore.finish(context, outcome: .init(state: .rejected, note: "Rejected.")))
        let originalEntries = await originalStore.entries(for: context.id)
        let hot = dir.appendingPathComponent(context.id.uuidString + ".jsonl")
        let archive = dir.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        let cold = archive.appendingPathComponent(hot.lastPathComponent)
        try FileManager.default.copyItem(at: hot, to: cold)
        let originalBytes = try Data(contentsOf: cold)
        try Data("corrupt hot evidence\n".utf8).write(to: hot)
        let reader = Store(directory: dir)
        #expect((await reader.entries(for: context.id)).isEmpty)
        #expect(try Data(contentsOf: cold) == originalBytes)
        try FileManager.default.removeItem(at: hot)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: archive.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: cold.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path) }
        #expect(await reader.entries(for: context.id) == originalEntries)
        #expect((await reader.entries(for: UUID())).isEmpty)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: cold.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o500)
        #expect(fileMode?.intValue == 0o400)
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path) == [cold.lastPathComponent])
    }

    @Test func tornTailKeepsOnlyKnownLinesAndMalformedCompleteLineFailsClosed() async throws {
        for tail in [Data("{\"kind\":\"outcome\"".utf8), Data("malformed\n".utf8)] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
            #expect(await Store(directory: dir).begin(a))
            let url = dir.appendingPathComponent(a.id.uuidString + ".jsonl")
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: tail)
            try handle.close()
            let restored = Store(directory: dir)
            let entries = await restored.entries(for: a.id)
            #expect(entries.count == (tail.last == 10 ? 0 : 1))
            #expect(entries.allSatisfy { $0.outcome == nil })
            #expect(!(await restored.finish(a, outcome: .init(state: .accepted, note: "Not resumed."))))
            let b = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
            #expect(await restored.begin(b) == (tail.last != 10))
        }
    }

    @Test func changedPartialFileIsRecountedBeforeLaterCapacityChecks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir, maximumBytes: 4_000, maximumContexts: 20, maximumContextBytes: 10_000)
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        #expect(await store.begin(a))
        let interruptedURL = dir.appendingPathComponent(a.id.uuidString + ".jsonl")
        let handle = try FileHandle(forWritingTo: interruptedURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 123, count: 3_000))
        try handle.close()
        let interruptedBytes = try Data(contentsOf: interruptedURL)
        #expect(!(await store.record(event(), context: a)))
        var accepted: [UUID] = []
        for _ in 0..<10 {
            let next = Store.Context(symbol: "META", horizon: 14, purpose: .assessment)
            if await store.begin(next) { accepted.append(next.id) }
        }
        // JSON dates vary in encoded length; prove capacity from actual retained bytes,
        // not a guessed number of start records that fits beside the partial tail.
        #expect(!accepted.isEmpty && accepted.count < 10)
        let newBytes = try accepted.reduce(0) { total, id in
            total + (try Data(contentsOf: dir.appendingPathComponent(id.uuidString + ".jsonl"))).count
        }
        #expect(try byteCount(dir) == interruptedBytes.count + newBytes)
        #expect(try byteCount(dir) <= 4_000)
        #expect(try Data(contentsOf: interruptedURL) == interruptedBytes)
        #expect((await store.entries(for: a.id)).count == 1)
    }

    @Test func unknownFilesAndSymlinkPathsFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let unknown = root.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("unknown retained data".utf8).write(to: unknown.appendingPathComponent("notes.txt"))
        #expect(!(await Store(directory: unknown).begin(context)))
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(!(await Store(directory: link).begin(context)))
        #expect(!(await Store(directory: link.appendingPathComponent("nested")).begin(context)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let linkedFiles = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: linkedFiles, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedFiles.appendingPathComponent(context.id.uuidString + ".jsonl"),
                                                  withDestinationURL: unknown.appendingPathComponent("notes.txt"))
        #expect(!(await Store(directory: linkedFiles).begin(.init(symbol: "META", horizon: 14, purpose: .assessment))))

        let hotDirectory = root.appendingPathComponent("hot")
        let writer = Store(directory: hotDirectory, maximumContexts: 1)
        #expect(await writer.begin(context))
        #expect(await writer.finish(context, outcome: .init(state: .rejected, note: "Preserve me.")))
        let hot = hotDirectory.appendingPathComponent(context.id.uuidString + ".jsonl")
        let original = try Data(contentsOf: hot)
        let archive = hotDirectory.appendingPathComponent("Archive")
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: destination)
        #expect(!(await writer.begin(.init(symbol: "META", horizon: 14, purpose: .assessment))))
        #expect(try Data(contentsOf: hot) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try FileManager.default.removeItem(at: archive)
        try Data("not a directory".utf8).write(to: archive)
        #expect(!(await writer.begin(.init(symbol: "ADI", horizon: 14, purpose: .assessment))))
        #expect(try Data(contentsOf: hot) == original)
    }

    @Test func privatePermissionsAndNilTestMode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Store.Context(symbol: "AAPL", horizon: 7, purpose: .assessment)
        let disabled = Store()
        #expect(!(await disabled.begin(a)))
        #expect(!(await disabled.record(event(), context: a)))
        #expect(!(await disabled.finish(a, outcome: .init(state: .accepted, note: "No directory."))))
        #expect((await disabled.entries(for: a.id)).isEmpty)
        #expect(await Store(directory: dir).begin(a))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(a.id.uuidString + ".jsonl").path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func invalidContextsDoNotCreateFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        for context in [Store.Context(symbol: "AAPL\n", horizon: 7, purpose: .assessment),
                        .init(symbol: "../AAPL", horizon: 7, purpose: .assessment),
                        .init(symbol: nil, horizon: 7, purpose: .assessment),
                        .init(symbol: "AAPL", horizon: 1, purpose: .assessment),
                        .init(symbol: "AAPL", horizon: 7, purpose: .assessment, startedAt: .distantPast)] {
            #expect(!(await store.begin(context)))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

}
