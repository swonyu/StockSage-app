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

    // MARK: - W1 (2026-09-06): the new fields, defaulted via a hand-written `init(from:)`
    //
    // Verified empirically (see StockSageCatalystRecordCache.swift's doc comment) that Swift's
    // SYNTHESIZED Decodable does NOT fall back to a property's default value for a missing key —
    // it throws. These tests pin the hand-written decode init that actually delivers that
    // contract, both directions: a pipeline-1 record still decodes, and the full W1 shape
    // round-trips byte-for-byte through disk.

    @Test func pipelineOneRecordMissingEveryW1FieldStillDecodesWithDefaults() throws {
        // Exactly pipeline-1's shape: symbol/earningsDate/checkedAt/source only — NONE of
        // status/confirmed/dateRangeEnd/sourcesAsked/projectionBasis are present.
        let json = #"{"symbol":"AAPL","earningsDate":null,"checkedAt":0,"source":"yahoo"}"#
        let record = try JSONDecoder().decode(StockSageCatalystRecordCache.Record.self, from: Data(json.utf8))
        #expect(record.symbol == "AAPL")
        #expect(record.earningsDate == nil)
        #expect(record.source == "yahoo")
        #expect(record.status == .unchecked)      // defaulted
        #expect(record.confirmed == nil)           // defaulted
        #expect(record.dateRangeEnd == nil)        // defaulted
        #expect(record.sourcesAsked == [])         // defaulted
        #expect(record.projectionBasis == nil)     // defaulted
    }

    @Test func fullW1ShapeRoundTripsThroughDiskByteForByte() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalyst_records_v1.json")
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let end = t.addingTimeInterval(2 * 86_400)

        let projected = StockSageCatalystRecordCache.Record(
            symbol: "TSLA", earningsDate: t.addingTimeInterval(90 * 86_400), checkedAt: t, source: "projection",
            status: .projected, confirmed: nil, dateRangeEnd: t.addingTimeInterval(97 * 86_400),
            sourcesAsked: ["eodhd calendar", "yahoo calendarEvents", "earnings history"],
            projectionBasis: "median gap of last 3 reports = 91 d from 2026-07-30")
        let dateKnown = StockSageCatalystRecordCache.Record(
            symbol: "AAPL", earningsDate: t.addingTimeInterval(10 * 86_400), checkedAt: t, source: "yahoo calendarEvents",
            status: .dateKnown, confirmed: false, dateRangeEnd: end, sourcesAsked: ["eodhd calendar", "yahoo calendarEvents"])
        let notApplicable = StockSageCatalystRecordCache.Record(
            symbol: "^TASI.SR", earningsDate: nil, checkedAt: t, source: "—", status: .notApplicable)

        let cache = StockSageCatalystRecordCache(entries: [projected, dateKnown, notApplicable], savedAt: t)
        cache.save(to: url)
        let loaded = StockSageCatalystRecordCache.load(from: url)
        #expect(loaded == cache)

        let back = loaded?.entries.first { $0.symbol == "TSLA" }
        #expect(back?.status == .projected)
        #expect(back?.dateRangeEnd == t.addingTimeInterval(97 * 86_400))
        #expect(back?.sourcesAsked == ["eodhd calendar", "yahoo calendarEvents", "earnings history"])
        #expect(back?.projectionBasis == "median gap of last 3 reports = 91 d from 2026-07-30")
    }

    @Test func statusDefaultsToUncheckedWhenNotSpecified() {
        let r = StockSageCatalystRecordCache.Record(symbol: "X", earningsDate: nil,
                                                     checkedAt: Date(timeIntervalSince1970: 0), source: "—")
        #expect(r.status == .unchecked)
        #expect(r.sourcesAsked == [])
    }
}
