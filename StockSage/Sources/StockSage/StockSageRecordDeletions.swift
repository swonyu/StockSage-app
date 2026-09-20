import Foundation

/// Shared by journal, holdings and paper records, each under its own defaults/key.
/// One preference per deleted UUID avoids a read/modify/write race on a shared ID list.
/// Legacy preferences and paper records write arrays and markers separately; activated
/// journal/portfolio storage commits them together. Readers always filter markers,
/// including when an older app rewrites stale array bytes without understanding them.
/// ponytail: markers do not expire while stale writers may exist. Never prune them by
/// an arbitrary TTL; revisit storage compaction if their unbounded count becomes material.
struct StockSageRecordDeletions {
    let defaults: UserDefaults
    let recordKey: String

    private func marker(_ id: UUID) -> String { recordKey + ".deleted." + id.uuidString }
    func contains(_ id: UUID) -> Bool {
        guard StockSageRecordWriter.mayRead(defaults) else { return false }
        do { return try StockSageRecordStorage.object(forKey: marker(id), defaults: defaults) as? Bool ?? false }
        catch { return true } // unreadable authoritative storage cannot authorize resurrection
    }
    func mark(_ ids: Set<UUID>) throws {
        try StockSageRecordWriter.require(defaults)
        try StockSageRecordStorage.update(deletionChanges(ids), defaults: defaults)
    }
    /// Only the explicit, fully validated JSON restore path may revive an old ID.
    func restore(_ ids: Set<UUID>) throws {
        try StockSageRecordWriter.require(defaults)
        try StockSageRecordStorage.update(restorationChanges(ids), defaults: defaults)
    }

    func restorationChanges(_ ids: Set<UUID>) -> [StockSageRecordStorage.Change] {
        ids.sorted { $0.uuidString < $1.uuidString }.map { .init(key: marker($0), value: .absent) }
    }

    func deletionChanges(_ ids: Set<UUID>) -> [StockSageRecordStorage.Change] {
        ids.sorted { $0.uuidString < $1.uuidString }.map { .init(key: marker($0), value: .flag(true)) }
    }

    /// A corrupt/wrongly typed saved book is not an empty book to overwrite.
    func read<Record: Decodable>(_ type: Record.Type) throws -> [Record] {
        guard StockSageRecordWriter.mayRead(defaults) else { throw StockSageFileLock.Failure.unavailable }
        guard let stored = try StockSageRecordStorage.object(forKey: recordKey, defaults: defaults) else { return [] }
        guard let data = stored as? Data else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode([Record].self, from: data)
    }
}
