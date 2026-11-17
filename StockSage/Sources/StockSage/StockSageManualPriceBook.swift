import Foundation
import Combine

/// A personal observation, never a feed quote, executable price or licensed data claim.
/// Every edit creates a new immutable record; its original price, unit and clocks survive.
nonisolated struct StockSageManualPriceRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let symbol: String
    let rawPrice: Double
    let denomination: StockSagePriceDenomination
    let observedAt: Date
    let recordedAt: Date
    let note: String?

    init(id: UUID = UUID(), symbol: String, rawPrice: Double,
         denomination: StockSagePriceDenomination, observedAt: Date,
         recordedAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.rawPrice = rawPrice
        self.denomination = denomination
        self.observedAt = observedAt
        self.recordedAt = recordedAt
        self.note = note
    }

    var validationError: String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.^-=+")
        guard !symbol.isEmpty, symbol.count <= 20,
              symbol.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Enter a ticker of up to 20 letters, numbers or market punctuation."
        }
        guard rawPrice.isFinite, rawPrice > 0,
              denomination.majorValue(rawValue: rawPrice).map({ $0 > 0 }) == true else {
            return "Enter a positive price that can be represented in the selected units."
        }
        guard denomination.provenance == .manualEntry || denomination.provenance == .importedRecord else {
            return "A personal price record must declare manual or imported provenance."
        }
        guard observedAt.timeIntervalSince1970.isFinite, observedAt.timeIntervalSince1970 > 0,
              recordedAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970 > 0,
              observedAt <= recordedAt.addingTimeInterval(60) else {
            return "The dates must be valid; the observation cannot exceed its recording time by more than 60 seconds."
        }
        guard (note?.utf8.count ?? 0) <= 4_000 else { return "Keep the price note below 4,000 bytes." }
        return nil
    }

    var quote: StockSageQuote {
        StockSageQuote(id: id, price: rawPrice, previousPrice: rawPrice, time: recordedAt,
            marketTime: observedAt,
            priceSource: denomination.provenance == .importedRecord ? .importedRecord : .manualEntry,
            denomination: denomination)
    }
}

/// Separate from live quote caches and monitors. Recording a value never dispatches
/// a provider request, triggers an alert, submits a paper fill or rewrites a live quote.
@MainActor
final class StockSageManualPriceBook: ObservableObject {
    @Published private(set) var records: [StockSageManualPriceRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var hasLoadedRecords = false
    private let defaults: UserDefaults
    private static let key = "stocksage_manual_prices_v1"
    private var deletions: StockSageRecordDeletions { .init(defaults: defaults, recordKey: Self.key) }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        do {
            records = try readCommitted()
            hasLoadedRecords = true
        } catch {
            lastError = "Saved personal prices could not be read. Their original data was preserved."
        }
    }

    func latest(for symbol: String, now: Date = Date()) -> StockSageManualPriceRecord? {
        Self.latest(in: records, symbol: symbol, now: now)
    }

    nonisolated static func latest(in records: [StockSageManualPriceRecord], symbol: String,
                                  now: Date) -> StockSageManualPriceRecord? {
        guard now.timeIntervalSince1970.isFinite else { return nil }
        return records.filter {
            $0.symbol == symbol.uppercased() && $0.validationError == nil
                && $0.observedAt <= now.addingTimeInterval(60)
                && $0.recordedAt <= now.addingTimeInterval(60)
        }.max {
            // Latest explicit edit wins, even when it corrects an older observation.
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult func add(_ record: StockSageManualPriceRecord) -> Bool {
        if let error = record.validationError { lastError = error; return false }
        do {
            try StockSageRecordWriter.require(defaults)
            var disk = try readCommitted()
            if let prior = disk.first(where: { $0.id == record.id }) {
                guard prior == record else {
                    lastError = "A saved personal price has the same ID with different data. No record was changed."
                    return false
                }
                records = disk; hasLoadedRecords = true; lastError = nil
                return true
            }
            guard !deletions.contains(record.id) else {
                lastError = "This price record was deleted. Restore its backup to recover the original ID."
                return false
            }
            disk.append(record)
            let data = try JSONEncoder().encode(disk)
            let warning = try StockSageRecordStorage.set(data, forKey: Self.key, defaults: defaults)
            records = disk; hasLoadedRecords = true; lastError = warning
            return true
        } catch {
            lastError = "Couldn't save the personal price: \(error.localizedDescription) Existing records were preserved."
            return false
        }
    }

    @discardableResult func removeAll() -> Bool {
        do {
            try StockSageRecordWriter.require(defaults)
            let disk = try readCommitted()
            let ids = Set(disk.map(\.id))
            let warning = try StockSageRecordStorage.update(deletions.deletionChanges(ids)
                + [.init(key: Self.key, value: .data(try JSONEncoder().encode([StockSageManualPriceRecord]())))], defaults: defaults)
            records = []; hasLoadedRecords = true; lastError = warning
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func backupRecords() throws -> [StockSageManualPriceRecord] {
        do { return try readCommitted() }
        catch { throw StockSageBackup.BackupError.sourceReadFailed("personal prices") }
    }

    func prepareBackupImport(_ incoming: [StockSageManualPriceRecord]) throws -> StockSageRecordStorage.PreparedImport {
        try StockSageRecordWriter.require(defaults)
        guard incoming.allSatisfy({ $0.validationError == nil }) else {
            throw StockSageBackup.BackupError.restoreFailed("A personal price record is invalid.")
        }
        var merged = try readCommitted()
        var ids = Set(merged.map(\.id))
        let additions = incoming.filter { ids.insert($0.id).inserted }
        merged.append(contentsOf: additions)
        let data = try JSONEncoder().encode(merged)
        let committed = merged
        let changes = deletions.restorationChanges(Set(additions.map(\.id)))
            + [StockSageRecordStorage.Change(key: Self.key, value: .data(data))]
        return .init(defaults: defaults, added: additions.count, changes: changes, publish: { warning in
            self.records = committed
            self.hasLoadedRecords = true
            self.lastError = warning
        })
    }

    private func readCommitted() throws -> [StockSageManualPriceRecord] {
        do {
            let decoded = try deletions.read(StockSageManualPriceRecord.self)
            var seen: [UUID: StockSageManualPriceRecord] = [:]
            for record in decoded {
                guard record.validationError == nil, seen[record.id] == nil || seen[record.id] == record else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                seen[record.id] = record
            }
            return decoded.filter { !deletions.contains($0.id) }
        } catch {
            hasLoadedRecords = false
            throw error
        }
    }

    /// Dedicated test-host input; it never writes user data.
    func qaSeed(_ records: [StockSageManualPriceRecord]) {
        self.records = records
        hasLoadedRecords = true
        lastError = nil
    }
}
