import Foundation
import CryptoKit

extension StockSagePaperAutomation {
    nonisolated struct AuditArchive: Codable, Sendable, Equatable {
        let id: UUID
        let count: Int
        let bytes: Int
        let sha256: String
        let latestAt: Date

        func url(beside account: URL) -> URL {
            account.deletingLastPathComponent().appendingPathComponent("audit-\(id.uuidString).json")
        }

        func read(beside account: URL) throws -> [Decision] {
            let path = url(beside: account)
            let values = try path.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, bytes > 0, bytes <= 32_000_000,
                  values.fileSize == bytes else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: path)
            guard Self.digest(data) == sha256 else { throw CocoaError(.fileReadCorruptFile) }
            let records = try JSONDecoder().decode([Decision].self, from: data)
            guard records.count == count, count > 0,
                  Set(records.map(\.id)).count == count,
                  records.allSatisfy({ $0.at.timeIntervalSince1970.isFinite }),
                  records.map(\.at).max() == latestAt else { throw CocoaError(.fileReadCorruptFile) }
            return records
        }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Compact control state, derived only from the unchanged archived prefix. Never a forecast.
    nonisolated struct AuditControl: Codable, Sendable, Equatable {
        var sameDayActivated = false
        var settlementActivated = false
        var marketScanned = false
        var latestAttempt: [String: Date] = [:]

        mutating func include(_ decisions: [Decision]) {
            for decision in decisions {
                sameDayActivated = sameDayActivated || decision.action == "Same-day policy activated"
                settlementActivated = settlementActivated || decision.action == "T+1 cash policy activated"
                marketScanned = marketScanned || decision.action.hasPrefix("Market scan")
                if !decision.symbol.isEmpty {
                    latestAttempt[decision.symbol] = max(latestAttempt[decision.symbol] ?? .distantPast, decision.at)
                }
            }
        }
    }

    nonisolated struct Audit: Codable, Sendable, Equatable {
        var archives: [AuditArchive] = []
        var control = AuditControl()

        func validate(beside account: URL, activeIDs: Set<UUID>) throws {
            guard Set(archives.map(\.id)).count == archives.count else { throw CocoaError(.fileReadCorruptFile) }
            var derived = AuditControl()
            var seen = activeIDs
            // ponytail: verify chunks sequentially at open, bounded per chunk. Index if a measured
            // multi-year archive makes startup slow; never skip integrity to make opening look successful.
            for archive in archives {
                let records = try archive.read(beside: account)
                guard records.allSatisfy({ seen.insert($0.id).inserted }) else { throw CocoaError(.fileReadCorruptFile) }
                derived.include(records)
            }
            guard derived == control else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// Rotate inside save, never note(): callers detect new decisions before committing.
    /// New immutable chunks precede the atomic manifest/account replacement. An interrupted
    /// write may leave an unreferenced orphan, never a referenced half-written archive.
    nonisolated static func prepareAudit(_ input: Book) throws -> (Book, [(AuditArchive, Data)], Data) {
        guard input.structurallyValid else { throw CocoaError(.fileWriteInvalidFileName) }
        var next = input
        var writes: [(AuditArchive, Data)] = []
        let encoder = JSONEncoder()
        var encoded = try encoder.encode(next)
        while next.decisions.count > 40_000 || encoded.count > 24_000_000 {
            guard next.decisions.count > 1 else { break }
            var count = min(1_000, next.decisions.count - 1)
            var data = try encoder.encode(Array(next.decisions.prefix(count)))
            while data.count > 32_000_000, count > 1 {
                count /= 2
                data = try encoder.encode(Array(next.decisions.prefix(count)))
            }
            guard data.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            let prefix = Array(next.decisions.prefix(count))
            let archive = AuditArchive(id: UUID(), count: count, bytes: data.count,
                sha256: AuditArchive.digest(data), latestAt: prefix.map(\.at).max()!)
            var audit = next.audit ?? Audit()
            audit.archives.append(archive)
            audit.control.include(prefix)
            next.audit = audit
            next.version = 2 // v1 readers must refuse, not silently drop the required archive references.
            next.decisions.removeFirst(count)
            writes.append((archive, data))
            encoded = try encoder.encode(next)
        }
        guard next.valid, encoded.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        return (next, writes, encoded)
    }
}
