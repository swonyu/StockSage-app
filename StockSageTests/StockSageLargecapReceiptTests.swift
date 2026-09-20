import Foundation
import Testing
@testable import StockSage

@Suite("Large cap durable receipts", .serialized)
@MainActor struct StockSageLargecapReceiptTests {
    private typealias Store = StockSageResearchReceiptStore
    private typealias Receipt = StockSageSameDayResearch.Receipt
    private let now = Date(timeIntervalSince1970: 1_789_744_430)

    @Test func fullHistorySurvivesDiagnosticRetentionLimitsAndCannotMixModes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder, maxCompletedBytes: 0, sameDayLabel: "largecap")
        var saved: [Receipt] = []
        for index in 0...Store.maxCompletedScans {
            let at = now.addingTimeInterval(Double(index))
            let id = store.beginSameDay(at: at)
            var receipt = Receipt(id: id, startedAt: at, finishedAt: at, selection: "Complete classified rows retained", checks: [])
            receipt.mode = .largecap
            try #require(store.saveSameDay(receipt))
            store.finish(scanID: id, status: "No qualified pick", at: at)
            saved.append(receipt)
        }
        #expect(store.sameDayHistory == Array(saved.reversed()))
        let reloaded = Store(directory: folder, maxCompletedBytes: 0, sameDayLabel: "largecap")
        #expect(reloaded.sameDayHistory == Array(saved.reversed()))
        let original = try #require(saved.first)
        let file = folder.appendingPathComponent("scan-\(original.id.uuidString)/manifest.json")
        let bytes = try Data(contentsOf: file)
        for mode in [StockSageSameDayResearch.Mode.microcap, .sameDay] {
            var wrongMode = original; wrongMode.mode = mode
            #expect(!reloaded.saveSameDay(wrongMode))
        }
        var legacy = original; legacy.mode = nil
        #expect(!reloaded.saveSameDay(legacy))
        #expect(Store(directory: folder, sameDayLabel: "microcap").sameDayHistory.isEmpty)
        #expect(Store(directory: folder).sameDayHistory.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func largecapManifestUsesCapModeBudgetAndOversizeFailsWithoutReplacingSavedBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder, sameDayLabel: "largecap")
        let id = store.beginSameDay(at: now)
        var receipt = Receipt(id: id, startedAt: now, finishedAt: now,
            selection: String(repeating: "x", count: 3_100_000), checks: [])
        receipt.mode = .largecap
        try #require(store.saveSameDay(receipt), "Cap-mode full classification receipts may exceed the ordinary three-megabyte manifest cap")
        store.finish(scanID: id, status: "Completed", at: now)
        #expect(Store(directory: folder, sameDayLabel: "largecap").latestSameDay == receipt)
        let file = folder.appendingPathComponent("scan-\(id.uuidString)/manifest.json")
        let original = try Data(contentsOf: file)
        receipt.selection = String(repeating: "x", count: 16_000_001)
        #expect(!store.saveSameDay(receipt))
        #expect(store.persistenceFailed(scanID: id))
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func interruptedPreparationKeepsItsLargecapIdentity() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder, sameDayLabel: "largecap")
        let id = store.beginSameDay(at: now)
        let reloaded = Store(directory: folder, sameDayLabel: "largecap")
        #expect(reloaded.latestSameDay?.id == id)
        #expect(reloaded.latestSameDay?.mode == .largecap)
        #expect(reloaded.latestSameDay?.selectedSymbol == nil)
        #expect(reloaded.latestSameDay?.blocker?.contains("interrupted") == true)
    }
}
