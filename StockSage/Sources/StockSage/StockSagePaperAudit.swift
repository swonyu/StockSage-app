import Foundation
import CryptoKit

extension StockSagePaperAutomation {
    #if os(macOS)
    /// Export exact committed bytes, not the UI tail or reconstructed portfolio economics.
    /// Atomic account replacement + immutable referenced chunks define the snapshot boundary;
    /// later saves may append new history without changing this captured generation.
    nonisolated static func saveResearchExport(account: URL, to destination: URL, at now: Date) throws {
        let sourceDirectory = account.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let output = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard output != sourceDirectory, !output.hasPrefix(sourceDirectory + "/") else {
            throw ResearchExportError("Choose a location outside the live paper-account directory.")
        }
        func read(_ file: URL) throws -> Data {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, (1...32_000_000).contains(size) else {
                throw ResearchExportError("A required account or audit file is missing, unsupported or too large. Nothing was exported.")
            }
            let data = try Data(contentsOf: file)
            guard data.count == size else { throw ResearchExportError("The captured file changed while reading. Retry the export.") }
            return data
        }
        let accountData = try read(account)
        let captured = try JSONDecoder().decode(Book.self, from: accountData)
        guard captured.valid, now.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        let archives = captured.audit?.archives ?? []
        var total = accountData.count
        for archive in archives {
            guard (1...32_000_000).contains(archive.bytes) else { throw CocoaError(.fileReadCorruptFile) }
            total += archive.bytes
            // ponytail: bounded in-memory JSON envelope; stream an export package if a real history exceeds 128 MB.
            guard total <= 128_000_000 else { throw ResearchExportError("History exceeds the 128 MB export limit. No partial export was saved; a streaming exporter is required.") }
        }
        try captured.audit?.validate(beside: account, activeIDs: Set(captured.decisions.map(\.id)))
        var files: [[String: Any]] = []
        func include(_ name: String, _ data: Data) throws {
            guard let content = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            files.append(["name": name, "bytes": data.count, "sha256": AuditArchive.digest(data), "content": content])
        }
        try include("account.json", accountData)
        for archive in archives {
            let data = try read(archive.url(beside: account))
            // Recheck the exact bytes being exported, not only the earlier validation read.
            guard data.count == archive.bytes, AuditArchive.digest(data) == archive.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            try include(archive.url(beside: account).lastPathComponent, data)
        }
        let envelope: [String: Any] = [
            "schemaVersion": 1, "exportedAt": now.ISO8601Format(),
            "encoding": "Each files[].content is the exact original UTF-8 JSON. Encode that string as UTF-8 to verify bytes and SHA256; decode its JSON separately. Original nulls, omissions, prose and IDs are unchanged.",
            "embeddedDateEncoding": "Foundation Date: numeric seconds since 2001-01-01T00:00:00Z, including fractional seconds. Preserve precision. Outer exportedAt is ISO-8601 export-time metadata, not a market-observation or information-availability timestamp.",
            "scope": "Committed native Qwen paper account and all referenced audit chunks; unreferenced files excluded. Private local research export, not a broker statement or the separate frozen forecast pilot.",
            "recordOrder": "Concatenate archives in account.audit.archives order, then account.decisions. Commit order, not chronological sorting. No joins are inferred.",
            "hashScope": "Hashes verify the included original bytes, not historical truth, source authenticity or model quality. Export-time metadata cannot establish historical code or model versions.",
            "decisionCount": captured.decisions.count + archives.reduce(0) { $0 + $1.count },
            "portfolioEconomics": "not evaluated",
            "missingEvidence": ["structured_decision_to_intent_and_sell_fill_links", "original_protective_attempt_history",
                "structured_observation_ids_side_size_and_arrival_times", "cumulative_displayed_size_and_partial_fills",
                "measured_commission_spread_fx_breakdown", "portfolio_equity_and_mark_series",
                "complete_per_candidate_exclusion_denominator", "external_flows_dividends_and_interest",
                "historical_model_prompt_policy_versions_and_request_latency",
                "point_in_time_information_availability_and_universe"],
            "files": files
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
    }

    nonisolated struct ResearchExportError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    #endif

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
