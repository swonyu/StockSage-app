import Foundation
import Testing
@testable import StockSage

@Suite("Micro cap setup identity", .serialized)
@MainActor struct StockSageMicrocapMonitorTests {
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
    @Test func savedClaimsSurviveRestartAndCorruptionBlocksNewInference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = String(repeating: "a", count: 64)
        let monitor = StockSageMicrocapMonitor(directory: directory, requireWriter: {})
        #expect(monitor.claim(id))
        #expect(!monitor.claim(id))
        #expect(!StockSageMicrocapMonitor(directory: directory, requireWriter: {}).claim(id))
        let file = directory.appendingPathComponent("automatic-setups.json")
        let corrupted = Data("broken records".utf8)
        try corrupted.write(to: file)
        #expect(!monitor.claim(String(repeating: "b", count: 64)))
        #expect(try Data(contentsOf: file) == corrupted)
        #expect(monitor.status.contains("preserved"))
    }

    @Test func deniedWriterCannotClaimOrEraseAnExistingAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = String(repeating: "c", count: 64)
        let monitor = StockSageMicrocapMonitor(directory: directory, requireWriter: { throw CocoaError(.fileWriteNoPermission) })
        #expect(!monitor.claim(id))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func redirectedDirectoryAndMissingActivatedLedgerCannotResetDeduplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let id = String(repeating: "d", count: 64)
        #expect(!StockSageMicrocapMonitor(directory: link, requireWriter: {}).claim(id))
        #expect(StockSageMicrocapMonitor(directory: real, requireWriter: {}).claim(id))
        try FileManager.default.removeItem(at: real.appendingPathComponent("automatic-setups.json"))
        #expect(!StockSageMicrocapMonitor(directory: real, requireWriter: {}).claim(id))
    }

}
