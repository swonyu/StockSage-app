import Foundation

/// Shared by journal, holdings and paper records, each under its own defaults/key.
/// One preference per deleted UUID avoids a read/modify/write race on a shared ID list.
/// Record-array writes remain nontransactional; current readers always filter markers,
/// including when an older app rewrites stale array bytes without understanding them.
/// ponytail: markers do not expire while stale writers may exist; migrate to transactional
/// storage if their unbounded count becomes material. Never prune by an arbitrary TTL.
struct StockSageRecordDeletions {
    let defaults: UserDefaults
    let recordKey: String

    private func marker(_ id: UUID) -> String { recordKey + ".deleted." + id.uuidString }
    func contains(_ id: UUID) -> Bool { StockSageRecordWriter.mayRead(defaults) && defaults.bool(forKey: marker(id)) }
    func mark(_ ids: Set<UUID>) throws {
        try StockSageRecordWriter.require(defaults)
        for id in ids { defaults.set(true, forKey: marker(id)) }
    }
    /// Only the explicit, fully validated JSON restore path may revive an old ID.
    func restore(_ ids: Set<UUID>) throws {
        try StockSageRecordWriter.require(defaults)
        for id in ids { defaults.removeObject(forKey: marker(id)) }
    }

    /// A corrupt/wrongly typed saved book is not an empty book to overwrite.
    func read<Record: Decodable>(_ type: Record.Type) throws -> [Record] {
        guard StockSageRecordWriter.mayRead(defaults) else { throw StockSageFileLock.Failure.unavailable }
        guard let stored = defaults.object(forKey: recordKey) else { return [] }
        guard let data = stored as? Data else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode([Record].self, from: data)
    }
}
