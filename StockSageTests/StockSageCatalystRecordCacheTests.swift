import Testing
import Foundation
@testable import StockSage

// MARK: - Disk catalyst-record cache (round-trip, honesty-floor negative records)

struct StockSageCatalystRecordCacheTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockSageCatalystRecordCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsThroughDiskAtATempLocation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalyst_records_v1.json")

        let t = Date(timeIntervalSince1970: 1_700_000_000)
        // NVDA: asked, provider had nothing — the honest negative (earningsDate nil).
        // aapl: asked, provider returned a real date. Lowercase input to also exercise
        // the uppercasing behavior in the same round trip.
        let cache = StockSageCatalystRecordCache(entries: [
            .init(symbol: "NVDA", earningsDate: nil, checkedAt: t, source: "yahoo"),
            .init(symbol: "aapl", earningsDate: t.addingTimeInterval(86_400 * 30), checkedAt: t, source: "yahoo"),
        ], savedAt: t)
        cache.save(to: url)

        let loaded = StockSageCatalystRecordCache.load(from: url)
        #expect(loaded == cache)
        #expect(loaded?.entries.first { $0.symbol == "NVDA" }?.earningsDate == nil)
        #expect(loaded?.entries.first { $0.symbol == "AAPL" }?.earningsDate == t.addingTimeInterval(86_400 * 30))
    }

    // Q9-adjacent honesty check: a negative observation (earningsDate == nil) must decode
    // back as nil, never default to some invented date, and checkedAt — the thing that
    // makes the negative honest ("none known AS OF checkedAt") — must survive intact to
    // the second.
    @Test func recordWithNilEarningsDateDecodesAndKeepsCheckedAtToTheSecond() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let record = StockSageCatalystRecordCache.Record(symbol: "TSLA", earningsDate: nil, checkedAt: checkedAt, source: "yahoo")

        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(StockSageCatalystRecordCache.Record.self, from: data)

        #expect(back.earningsDate == nil)
        #expect(back.checkedAt.timeIntervalSince1970.rounded() == checkedAt.timeIntervalSince1970.rounded())
    }

    @Test func symbolIsStoredUppercasedRegardlessOfInputCase() {
        let lower = StockSageCatalystRecordCache.Record(symbol: "msft", earningsDate: nil,
                                                          checkedAt: Date(timeIntervalSince1970: 0), source: "yahoo")
        let mixed = StockSageCatalystRecordCache.Record(symbol: "TslA", earningsDate: nil,
                                                          checkedAt: Date(timeIntervalSince1970: 0), source: "yahoo")
        #expect(lower.symbol == "MSFT")
        #expect(mixed.symbol == "TSLA")
    }

    // A corrupt file (unparseable bytes) and an old/incompatible schema (missing a field
    // this version requires) must both fail closed to nil — never fall back to a default
    // cache that could be mistaken for "checked every symbol, no catalysts anywhere."
    @Test func corruptOrOldSchemaBlobReturnsNilRatherThanADefault() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corruptURL = dir.appendingPathComponent("corrupt.json")
        try Data("{not valid json at all".utf8).write(to: corruptURL)
        #expect(StockSageCatalystRecordCache.load(from: corruptURL) == nil)

        let oldSchemaURL = dir.appendingPathComponent("old-schema.json")
        // Missing the "source" field this version's Record requires.
        let oldSchema = #"{"entries":[{"symbol":"AAPL","earningsDate":null,"checkedAt":0}],"savedAt":0}"#
        try Data(oldSchema.utf8).write(to: oldSchemaURL)
        #expect(StockSageCatalystRecordCache.load(from: oldSchemaURL) == nil)
    }

    @Test func missingFileReturnsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("does-not-exist.json")
        #expect(StockSageCatalystRecordCache.load(from: url) == nil)
    }
}
