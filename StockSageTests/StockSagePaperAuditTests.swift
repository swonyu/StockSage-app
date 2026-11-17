import Foundation
import Testing
@testable import StockSage

@Suite("Paper audit rotation", .serialized) @MainActor
struct StockSagePaperAuditTests {
    private typealias A = StockSagePaperAutomation
    private let now = Date(timeIntervalSince1970: 1_788_886_800)

    private func fixture() -> A.Book {
        var book = A.Book()
        book.activateSameDay(at: now)
        book.activateSettlement(at: now)
        book.note(action: "Market scan", reason: "Synthetic", at: now)
        book.lastResearch = now
        for i in 3..<40_001 {
            book.note(symbol: i % 2 == 0 ? "MSFT" : "AAPL", action: "Fixture", reason: "Unchanged",
                      at: now.addingTimeInterval(Double(i % 17) / 1_000))
        }
        return book
    }

    #if os(macOS)
    @Test func researchExportPreservesCompleteCommittedHistoryWithoutInventingEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("paper/account.json")
        let destination = root.appendingPathComponent("research.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = A.Book()
        for i in 0..<5 {
            original.note(symbol: "ORCL", action: "Fixture", reason: "Exact prose 🙂 \(i)",
                          at: now.addingTimeInterval(Double(5 - i) / 1_000))
        }
        var book = original, audit = A.Audit()
        var expectedFiles: [String: Data] = [:]
        for records in [Array(original.decisions.prefix(2)), Array(original.decisions[2..<4])] {
            let data = try JSONEncoder().encode(records)
            let archive = A.AuditArchive(id: UUID(), count: records.count, bytes: data.count,
                sha256: A.AuditArchive.digest(data), latestAt: records.map(\.at).max()!)
            try data.write(to: archive.url(beside: source))
            expectedFiles[archive.url(beside: source).lastPathComponent] = data
            audit.archives.append(archive); audit.control.include(records)
        }
        book.version = 2; book.audit = audit; book.decisions = Array(original.decisions.suffix(1))
        let encoded = try JSONEncoder().encode(book)
        let sourceBytes = Data("{\"lastResearch\":null,".utf8) + encoded.dropFirst()
        try sourceBytes.write(to: source)
        expectedFiles["account.json"] = sourceBytes
        let orphan = source.deletingLastPathComponent().appendingPathComponent("audit-orphan.json")
        try Data("uncommitted; never export".utf8).write(to: orphan)

        try A.saveResearchExport(account: source, to: destination, at: now)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        #expect(envelope["portfolioEconomics"] as? String == "not evaluated")
        #expect(envelope["decisionCount"] as? Int == 5)
        #expect((envelope["embeddedDateEncoding"] as? String)?.contains("2001-01-01T00:00:00Z") == true)
        let missing = try #require(envelope["missingEvidence"] as? [String])
        #expect(missing.contains("portfolio_equity_and_mark_series"))
        let files = try #require(envelope["files"] as? [[String: Any]])
        #expect(files.count == 3)
        var recovered: [A.Decision] = []
        for file in files {
            let name = try #require(file["name"] as? String)
            let bytes = Data(try #require(file["content"] as? String).utf8)
            #expect(bytes == expectedFiles[name])
            #expect(file["sha256"] as? String == A.AuditArchive.digest(bytes))
            #expect(file["bytes"] as? Int == bytes.count)
            if name != "account.json" { recovered += try JSONDecoder().decode([A.Decision].self, from: bytes) }
        }
        recovered += book.decisions
        #expect(recovered == original.decisions, "Preserve commit sequence; do not sort by timestamps or infer missing joins")
        for (name, bytes) in expectedFiles {
            #expect(try Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent(name)) == bytes)
        }
        #expect(try Data(contentsOf: orphan) == Data("uncommitted; never export".utf8))

        let exported = try Data(contentsOf: destination)
        let chunk = try #require(audit.archives.first).url(beside: source)
        try Data("corrupt".utf8).write(to: chunk)
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: destination, at: now) }
        #expect(try Data(contentsOf: destination) == exported)
        try FileManager.default.removeItem(at: chunk)
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: destination, at: now) }
        #expect(try Data(contentsOf: destination) == exported)
    }

    @Test func researchExportRejectsLiveDirectoryMissingAccountAndDuplicateHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("paper/account.json"), destination = root.appendingPathComponent("export.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: destination, at: now) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let empty = try JSONEncoder().encode(A.Book())
        try empty.write(to: source)
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: source, at: now) }
        #expect(try Data(contentsOf: source) == empty)
        var invalid = A.Book()
        invalid.note(action: "Fixture", reason: "Duplicate", at: now)
        let bytes = try JSONEncoder().encode(invalid.decisions)
        let archive = A.AuditArchive(id: UUID(), count: 1, bytes: bytes.count,
            sha256: A.AuditArchive.digest(bytes), latestAt: now)
        try bytes.write(to: archive.url(beside: source))
        var audit = A.Audit(); audit.archives = [archive]; audit.control.include(invalid.decisions)
        invalid.version = 2; invalid.audit = audit
        try JSONEncoder().encode(invalid).write(to: source)
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: destination, at: now) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func researchExportRejectsSymlinkSourcesAndDirectoryDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("paper/account.json")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try JSONEncoder().encode(A.Book())
        try bytes.write(to: source)
        let sentinel = output.appendingPathComponent("keep.txt")
        try Data("Keep".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try A.saveResearchExport(account: source, to: output, at: now) }
        #expect(try Data(contentsOf: sentinel) == Data("Keep".utf8))
        #expect(try Data(contentsOf: source) == bytes)
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: (any Error).self) {
            try A.saveResearchExport(account: alias, to: output.appendingPathComponent("export.json"), at: now)
        }
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("export.json").path))
        #expect(try Data(contentsOf: source) == bytes)
    }
    #endif

    @Test func countRotationPreservesOrderedRecordsPolicyAndResearchControl() throws {
        let original = fixture()
        let (rotated, writes, bytes) = try A.prepareAudit(original)
        var recovered: [A.Decision] = []
        for (_, data) in writes { recovered += try JSONDecoder().decode([A.Decision].self, from: data) }
        recovered += rotated.decisions
        let identical = recovered == original.decisions
        #expect(identical)
        #expect(rotated.version == 2 && rotated.valid && rotated.decisions.count <= 40_000)
        #expect(A.researchDue(book: original, at: now) == A.researchDue(book: rotated, at: now))
        var restored = try JSONDecoder().decode(A.Book.self, from: bytes)
        let oldCount = restored.decisions.count
        restored.activateSameDay(at: now); restored.activateSettlement(at: now)
        #expect(restored.decisions.count == oldCount && restored.lastResearch == original.lastResearch)
        let candidates = ["MSFT", "AAPL", "META"].map { symbol in
            StockSageMassive.MarketCandidate(quote: .init(symbol: symbol, price: 100, previousClose: 99,
                marketTime: now, priceSource: .massiveSIP), dollarVolume: 1_000)
        }
        let market = StockSageMassive.MarketSnapshot(returnedCount: 3, rows: candidates)
        #expect(A.researchTargets(market: market, book: original, at: now)
                == A.researchTargets(market: market, book: restored, at: now))
        let legacy = try JSONDecoder().decode(A.Book.self, from: JSONEncoder().encode(A.Book()))
        #expect(legacy.version == 1 && legacy.audit == nil && legacy.valid)
        var missingManifest = rotated; missingManifest.audit = nil
        #expect(!missingManifest.valid)
    }

    @Test func byteRotationPreservesUnicodeFactsWithoutTruncation() throws {
        var original = A.Book()
        let fact = String(repeating: "🙂", count: 80_000)
        for _ in 0..<100 { original.note(action: "Fixture", reason: "Byte boundary", at: now, facts: [fact]) }
        let (rotated, writes, encoded) = try A.prepareAudit(original)
        #expect(!writes.isEmpty && encoded.count <= 32_000_000)
        var recovered: [A.Decision] = []
        for (archive, data) in writes {
            #expect(data.count == archive.bytes && data.count <= 32_000_000)
            recovered += try JSONDecoder().decode([A.Decision].self, from: data)
        }
        recovered += rotated.decisions
        let identical = recovered == original.decisions
        #expect(identical)
    }

    @Test func interruptedCommitLeavesOldAccountAndOrphanDoesNotReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "audit-fault-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        #expect(state.acquire() && state.save(A.Book()))
        let before = try Data(contentsOf: url)
        let original = fixture()
        let saved = state.save(original, beforeAccountCommit: { throw CocoaError(.fileWriteOutOfSpace) })
        #expect(!saved && state.book.decisions.isEmpty)
        #expect(try Data(contentsOf: url) == before)
        let unchanged = A(url: url, defaults: defaults)
        #expect(unchanged.error == nil && unchanged.book.decisions.isEmpty)
        #expect(state.save(original))
        let reopened = A(url: url, defaults: defaults)
        #expect(reopened.error == nil && reopened.book.version == 2)
        var recovered: [A.Decision] = []
        for archive in reopened.book.audit?.archives ?? [] { recovered += try archive.read(beside: url) }
        recovered += reopened.book.decisions
        let identical = recovered == original.decisions
        #expect(identical, "Unreferenced orphan chunks must never become committed history")
        #expect(!state.save(original), "A stale v1 caller cannot erase committed v2 references")
    }

    @Test func missingAccountOrCorruptReferencedChunkFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "audit-corrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let url = root.appendingPathComponent("account.json")
        let state = A(url: url, defaults: defaults)
        defer { state.stop(); try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        #expect(state.acquire() && state.save(fixture()))
        let archive = try #require(state.book.audit?.archives.first)
        let chunk = archive.url(beside: url)
        let original = try Data(contentsOf: chunk)
        try Data("corrupt fixture".utf8).write(to: chunk)
        #expect(A(url: url, defaults: defaults).error != nil)
        #expect(try Data(contentsOf: chunk) == Data("corrupt fixture".utf8))
        try original.write(to: chunk)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("account.backup"))
        let missing = A(url: url, defaults: defaults)
        #expect(missing.error != nil && !missing.acquire())
        try FileManager.default.moveItem(at: root.appendingPathComponent("account.backup"), to: url)
    }

    @Test func duplicateDecisionsAcrossCommittedChunksAndActiveBookAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "audit-duplicates-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("account.json")
        var original = A.Book()
        original.note(symbol: "AAPL", action: "Fixture", reason: "One logical record", at: now)
        let data = try JSONEncoder().encode(original.decisions)
        var audit = A.Audit()
        audit.control.include(original.decisions)
        for duplicateInActive in [true, false] {
            audit.archives = []
            for _ in 0..<(duplicateInActive ? 1 : 2) {
                let archive = A.AuditArchive(id: UUID(), count: 1, bytes: data.count,
                    sha256: A.AuditArchive.digest(data), latestAt: now)
                try data.write(to: archive.url(beside: url))
                audit.archives.append(archive)
            }
            var invalid = original
            invalid.version = 2; invalid.audit = audit
            if !duplicateInActive { invalid.decisions = [] }
            try JSONEncoder().encode(invalid).write(to: url)
            #expect(A(url: url, defaults: defaults).error != nil)
        }
    }
}
