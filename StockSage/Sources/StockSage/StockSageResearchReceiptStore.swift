import Foundation
import CryptoKit

/// Private bounded horizon receipts. Manifests stay small; model calls are separate atomic files.
@MainActor
final class StockSageResearchReceiptStore {
    nonisolated static let schemaVersion = 2
    nonisolated static let maxAttempts = StockSageHorizonResearch.scanLimit
    // One initial call plus one output retry, and the same bound for an evidence repair.
    nonisolated static let maxCallsPerAttempt = 4
    nonisolated static let maxPayloadUTF8 = 24_000
    nonisolated static let maxFacts = 96
    nonisolated static let maxCompletedScans = 30
    nonisolated static let maxCallBytes = 600_000
    nonisolated static let maxFactsBytes = 1_200_000

    nonisolated struct Selection: Codable, Sendable, Equatable {
        let session: String?
        let requestedAt: Date?
        let returnedCount: Int?
        let eligibleCount: Int?
        let directoryCount: Int?
        let partialSession: Bool?
        let fallback: Bool?
    }

    nonisolated struct ModelCall: Codable, Sendable, Equatable {
        let id: UUID
        let ordinal: Int
        let phase: String
        let stage: String
        let startedAt: Date
        let endedAt: Date?
        let system: String?
        let systemSHA256: String?
        let systemBytes: Int
        let systemTruncated: Bool
        let schema: String?
        let schemaSHA256: String?
        let schemaBytes: Int?
        let schemaTruncated: Bool
        let prompt: String?
        let promptSHA256: String?
        let promptBytes: Int
        let promptTruncated: Bool
        let response: String?
        let responseSHA256: String?
        let responseBytes: Int?
        let httpStatus: Int?
        let finishReason: String
        let failureCategory: String?
        let responseTruncated: Bool
        let model: String
        let configIdentity: String
        let elapsedMilliseconds: Int?
        let retryCount: Int
        let validationOutcome: String?
        let outcome: String
        let redactionApplied: Bool
    }

    nonisolated struct Attempt: Codable, Sendable, Equatable {
        let id: UUID
        let listingID: String
        let index: Int
        let symbol: String
        let selectionDollarVolume: Double?
        var startedAt: Date?
        var endedAt: Date?
        var terminalStatus: String
        var retryCount: Int
        var factsFile: String?
        var factCount: Int
        var model: String
        var configIdentity: String
        var elapsedMilliseconds: Int?
        var validationOutcome: String?
        var validationFailure: String? = nil
        var uiOutcome: String?
        var uiAction: String? = nil
        var modelCalls: [UUID]
    }

    nonisolated struct Scan: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let dateEncoding: String
        let id: UUID
        let horizon: String
        let sourceVersion: String
        let sourceCommit: String
        let startedAt: Date
        var endedAt: Date?
        var status: String
        var selection: Selection?
        var attempts: [Attempt]
        var persistence: String
        var truncation: String?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidDirectory
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidDirectory: "Research receipt directory is unavailable."
            case .writeFailed: "Research receipt could not be saved; durable receipt coverage is unavailable."
            }
        }
    }

    private let directory: URL
    private let files: FileManager
    private let maxCompletedBytes: Int
    private(set) var lastError: String?
    private var scans: [UUID: Scan] = [:]
    private var active: Set<UUID> = []
    private var failed: Set<UUID> = []

    init(directory: URL, fileManager: FileManager = .default, maxCompletedBytes: Int = 512_000_000) {
        self.directory = directory
        files = fileManager
        self.maxCompletedBytes = max(0, maxCompletedBytes)
        load()
    }

    static var `default`: StockSageResearchReceiptStore {
        StockSageResearchReceiptStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/ResearchReceipts", isDirectory: true))
    }

    func begin(horizon: StockSageHorizonResearch.Horizon, at date: Date = Date()) -> UUID {
        let id = UUID()
        scans[id] = Scan(schemaVersion: Self.schemaVersion, dateEncoding: "seconds-since-2001-01-01T00:00:00Z", id: id, horizon: horizon.rawValue,
            sourceVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown-development-build",
            sourceCommit: Bundle.main.object(forInfoDictionaryKey: "StockSageSourceCommit") as? String ?? "unknown-development-build",
            startedAt: date, endedAt: nil, status: "running", selection: nil, attempts: [],
            persistence: "pending", truncation: nil)
        active.insert(id)
        persistManifest(id)
        return id
    }

    func registerSelection(_ value: StockSageResearchUniverse.Receipt?,
        listings: [StockSageHorizonResearch.Listing], for scanID: UUID) -> [UUID] {
        guard var scan = scans[scanID], scan.attempts.isEmpty,
            listings.count <= Self.maxAttempts else { return [] }
        scan.selection = Selection(session: value.map { bounded($0.session, 256) }, requestedAt: value?.requestedAt,
            returnedCount: value?.returnedCount, eligibleCount: value?.eligibleCount,
            directoryCount: value?.directoryCount, partialSession: value?.partialSession, fallback: value?.fallback)
        scan.attempts = listings.enumerated().map { index, item in
            Attempt(id: UUID(), listingID: bounded(item.id, 256), index: index,
                symbol: bounded(sanitize(item.ticker) ?? "", 128),
                selectionDollarVolume: (value?.dollarVolume[item.ticker]).flatMap { $0.isFinite ? $0 : nil },
                startedAt: nil, endedAt: nil,
                terminalStatus: "notStarted", retryCount: 0, factsFile: nil, factCount: 0, model: "", configIdentity: "",
                elapsedMilliseconds: nil, validationOutcome: nil, uiOutcome: nil, modelCalls: [])
        }
        scans[scanID] = scan
        persistManifest(scanID)
        return scan.attempts.map(\.id)
    }

    func beginAttempt(_ attemptID: UUID, scanID: UUID, at date: Date = Date()) {
        guard var scan = scans[scanID], let index = scan.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        scan.attempts[index].startedAt = date
        scan.attempts[index].terminalStatus = "started"
        scans[scanID] = scan
        persistManifest(scanID)
    }

    func capture(_ capture: StockSageLocalModelServer.ModelAttemptEvent,
        for attemptID: UUID, scanID: UUID) {
        guard var scan = scans[scanID], let index = scan.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        let existing = scan.attempts[index].modelCalls.contains(capture.callID)
        guard existing || scan.attempts[index].modelCalls.count < Self.maxCallsPerAttempt else {
            scan.truncation = "Model call limit exceeded; receipt coverage is incomplete."
            scans[scanID] = scan
            markFailure(scanID)
            persistManifest(scanID)
            return
        }
        let fullSystem = redact(capture.system)
        let fullSchema = redact(capture.schema)
        let fullPrompt = redact(capture.user)
        let fullResponse = redact(capture.body)
        let system = fullSystem.map { bounded($0, Self.maxPayloadUTF8) }
        let schema = fullSchema.map { bounded($0, Self.maxPayloadUTF8) }
        let prompt = fullPrompt.map { bounded($0, Self.maxPayloadUTF8) }
        let response = fullResponse.map { bounded($0, Self.maxPayloadUTF8) }
        let outcome = "transport:" + (capture.stage == .started ? "started" : (capture.category?.rawValue ?? capture.finish.rawValue))
        let config = "ollama=" + String(capture.isOllama) + "|context=" + String(capture.contextTokens)
            + "|output=" + String(capture.outputLimit) + "|temperature=" + String(capture.temperature)
        let call = ModelCall(id: capture.callID, ordinal: max(0, capture.ordinal), phase: bounded(capture.phase, 128), stage: capture.stage.rawValue,
            startedAt: capture.startedAt, endedAt: capture.endedAt, system: system,
            systemSHA256: system.map(digest), systemBytes: capture.systemBytes,
            systemTruncated: capture.systemTruncated || (fullSystem?.utf8.count ?? 0) > Self.maxPayloadUTF8,
            schema: schema, schemaSHA256: schema.map(digest),
            schemaBytes: capture.schemaBytes, schemaTruncated: capture.schemaTruncated || (fullSchema?.utf8.count ?? 0) > Self.maxPayloadUTF8, prompt: prompt,
            promptSHA256: prompt.map(digest), promptBytes: capture.userBytes,
            promptTruncated: capture.userTruncated || (fullPrompt?.utf8.count ?? 0) > Self.maxPayloadUTF8,
            response: response, responseSHA256: response.map(digest), responseBytes: capture.responseBytes,
            httpStatus: capture.statusCode, finishReason: capture.finish.rawValue,
            failureCategory: capture.category?.rawValue,
            responseTruncated: capture.bodyTruncated || (fullResponse?.utf8.count ?? 0) > Self.maxPayloadUTF8,
            model: bounded(sanitize(capture.model) ?? "", 256),
            configIdentity: bounded(config, 512), elapsedMilliseconds: capture.elapsedMilliseconds,
            retryCount: max(0, capture.ordinal), validationOutcome: nil,
            outcome: bounded(outcome, 256), redactionApplied: capture.system != fullSystem
                || capture.schema != fullSchema || capture.user != fullPrompt || capture.body != fullResponse)
        writeCall(call, scanID: scanID, attemptID: attemptID)
        if !existing { scan.attempts[index].modelCalls.append(call.id) }
        scan.attempts[index].model = call.model
        scan.attempts[index].configIdentity = call.configIdentity
        scan.attempts[index].elapsedMilliseconds = call.elapsedMilliseconds
        scan.attempts[index].retryCount = max(scan.attempts[index].retryCount, call.retryCount)
        scans[scanID] = scan
        persistManifest(scanID)
    }

    func finishAttempt(_ result: StockSageHorizonResearch.Result, attemptID: UUID,
        scanID: UUID, status: String, at date: Date = Date()) {
        guard var scan = scans[scanID], let index = scan.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
        scan.attempts[index].endedAt = date
        scan.attempts[index].terminalStatus = bounded(status, 256)
        scan.attempts[index].validationOutcome = result.validationOutcome.rawValue
        scan.attempts[index].validationFailure = result.validationFailure
        let facts = result.facts.prefix(Self.maxFacts).map { bounded(sanitize($0) ?? "", 2_000) }
        scan.attempts[index].factCount = facts.count
        scan.attempts[index].factsFile = "facts-" + attemptID.uuidString + ".json"
        writeFacts(facts, scanID: scanID, attemptID: attemptID)
        if scan.attempts[index].model.isEmpty { scan.attempts[index].model = bounded(sanitize(result.model) ?? "", 256) }
        scan.attempts[index].uiOutcome = bounded(sanitize(result.note), 1_000)
        scan.attempts[index].uiAction = result.verdict?.action.rawValue
        if let started = scan.attempts[index].startedAt {
            scan.attempts[index].elapsedMilliseconds = max(0, Int(date.timeIntervalSince(started) * 1_000))
        }
        scans[scanID] = scan
        persistManifest(scanID)
    }

    func finish(scanID: UUID, status: String, at date: Date = Date()) {
        guard var scan = scans[scanID] else { return }
        for index in scan.attempts.indices where scan.attempts[index].endedAt == nil {
            scan.attempts[index].endedAt = date
            scan.attempts[index].terminalStatus = scan.attempts[index].terminalStatus == "notStarted"
                ? "interrupted_notStarted" : "interrupted"
        }
        scan.endedAt = date
        scan.status = bounded(status, 512)
        scan.persistence = failed.contains(scanID) ? "save_failed" : "saved"
        scans[scanID] = scan
        active.remove(scanID)
        persistManifest(scanID)
        prune()
    }

    func receipt(scanID: UUID) -> Scan? { scans[scanID] }
    func persistenceFailed(scanID: UUID) -> Bool { failed.contains(scanID) }

    private func ensureDirectory() throws {
        if files.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidDirectory }
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func scanDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("scan-" + id.uuidString, isDirectory: true) }

    private func persistManifest(_ id: UUID) {
        if failed.contains(id) { scans[id]?.persistence = "save_failed" }
        guard let scan = scans[id] else { return }
        do {
            try ensureDirectory()
            let dir = scanDirectory(id)
            if files.fileExists(atPath: dir.path) {
                let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidDirectory }
            } else {
                try files.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let data = try JSONEncoder.receipt.encode(scan)
            guard data.count <= 1_000_000 else { throw Failure.writeFailed }
            let path = dir.appendingPathComponent("manifest.json")
            let tmp = dir.appendingPathComponent("manifest.json.tmp")
            try data.write(to: tmp, options: [.atomic, .completeFileProtection])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if files.fileExists(atPath: path.path) {
                try files.replaceItem(at: path, withItemAt: tmp, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: nil)
            } else {
                try files.moveItem(at: tmp, to: path)
            }
            if failed.isEmpty { lastError = nil }
        } catch { markFailure(id) }
    }

    private func writeCall(_ call: ModelCall, scanID: UUID, attemptID: UUID) {
        do {
            guard let scanDir = knownScanDirectory(scanID) else { throw Failure.invalidDirectory }
            let dir = scanDir.appendingPathComponent("calls", isDirectory: true)
            if files.fileExists(atPath: dir.path) {
                let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidDirectory }
            } else {
                try files.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let path = dir.appendingPathComponent("call-" + attemptID.uuidString + "-" + call.id.uuidString + ".json")
            let tmp = path.appendingPathExtension("tmp")
            let data = try JSONEncoder.receipt.encode(call)
            guard data.count <= Self.maxCallBytes else { throw Failure.writeFailed }
            try data.write(to: tmp, options: [.atomic, .completeFileProtection])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if files.fileExists(atPath: path.path) { try files.replaceItem(at: path, withItemAt: tmp, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: nil) }
            else { try files.moveItem(at: tmp, to: path) }
        } catch { markFailure(scanID) }
    }

    private func load() {
        if files.fileExists(atPath: directory.path) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return }
        }
        guard let dirs = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for dir in dirs {
            guard let id = scanID(from: dir), let manifest = boundedManifestURL(dir),
                let data = try? Data(contentsOf: manifest), data.count <= 1_000_000,
                let scan = try? JSONDecoder.receipt.decode(Scan.self, from: data),
                scan.id == id, scan.schemaVersion == Self.schemaVersion,
                scan.attempts.count <= Self.maxAttempts,
                Set(scan.attempts.map(\.id)).count == scan.attempts.count,
                scan.attempts.allSatisfy({ $0.modelCalls.count <= Self.maxCallsPerAttempt }) else { continue }
            if scan.endedAt == nil {
                var recovered = scan
                let ended = Date()
                recovered.endedAt = ended
                recovered.status = "interrupted: process ended before completion"
                for index in recovered.attempts.indices where recovered.attempts[index].endedAt == nil {
                    recovered.attempts[index].endedAt = ended
                    recovered.attempts[index].terminalStatus = recovered.attempts[index].terminalStatus == "notStarted" ? "interrupted_notStarted" : "interrupted"
                }
                scans[id] = recovered
                if scan.persistence == "save_failed" { failed.insert(id) }
                persistManifest(id)
            } else {
                scans[id] = scan
                if scan.persistence == "save_failed" { failed.insert(id) }
            }
        }
        prune()
    }

    func call(scanID: UUID, attemptID: UUID, callID: UUID) -> ModelCall? {
        guard let dir = knownScanDirectory(scanID) else { return nil }
        let calls = dir.appendingPathComponent("calls", isDirectory: true)
        guard let parent = try? calls.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              parent.isDirectory == true, parent.isSymbolicLink != true else { return nil }
        let url = calls.appendingPathComponent("call-" + attemptID.uuidString + "-" + callID.uuidString + ".json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isRegularFile == true,
            values.isSymbolicLink != true, let size = values.fileSize, size <= Self.maxCallBytes,
            let data = try? Data(contentsOf: url), data.count <= Self.maxCallBytes,
            let call = try? JSONDecoder.receipt.decode(ModelCall.self, from: data), call.id == callID else { return nil }
        return call
    }

    func facts(scanID: UUID, attemptID: UUID) -> [String]? {
        guard let dir = knownScanDirectory(scanID) else { return nil }
        let url = dir.appendingPathComponent("facts-" + attemptID.uuidString + ".json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= Self.maxFactsBytes, let data = try? Data(contentsOf: url), data.count <= Self.maxFactsBytes else { return nil }
        return try? JSONDecoder.receipt.decode([String].self, from: data)
    }

    private func writeFacts(_ facts: [String], scanID: UUID, attemptID: UUID) {
        do {
            guard let dir = knownScanDirectory(scanID) else { throw Failure.invalidDirectory }
            let url = dir.appendingPathComponent("facts-" + attemptID.uuidString + ".json")
            let tmp = url.appendingPathExtension("tmp")
            let data = try JSONEncoder.receipt.encode(facts)
            guard data.count <= Self.maxFactsBytes else { throw Failure.writeFailed }
            try data.write(to: tmp, options: [.atomic, .completeFileProtection])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if files.fileExists(atPath: url.path) { try files.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: nil) }
            else { try files.moveItem(at: tmp, to: url) }
        } catch { markFailure(scanID) }
    }

    private func prune() {
        guard let dirs = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let sorted = dirs.compactMap { dir -> (URL, UUID, Date, Int)? in
            guard let id = scanID(from: dir), !active.contains(id), let scan = scans[id], scan.endedAt != nil else { return nil }
            return (dir, id, scan.endedAt ?? scan.startedAt, storedBytes(in: dir))
        }.sorted { $0.2 == $1.2 ? $0.1.uuidString > $1.1.uuidString : $0.2 > $1.2 }
        var retainedBytes = 0
        for (index, item) in sorted.enumerated() {
            // Preserve the newest completed receipt even when it alone exceeds the byte budget.
            // Active scans are excluded entirely. Both one-scan payload and listing counts are capped.
            if index == 0 || (index < Self.maxCompletedScans && retainedBytes + item.3 <= maxCompletedBytes) {
                retainedBytes += item.3
            } else if (try? files.removeItem(at: item.0)) != nil {
                scans.removeValue(forKey: item.1)
                failed.remove(item.1)
            }
        }
    }

    private func storedBytes(in directory: URL) -> Int {
        var size = 0
        for folder in [directory, directory.appendingPathComponent("calls", isDirectory: true)] {
            guard let value = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  value.isDirectory == true, value.isSymbolicLink != true,
                  let children = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { continue }
            for child in children {
                if let value = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                   value.isRegularFile == true, value.isSymbolicLink != true { size += value.fileSize ?? 0 }
            }
        }
        return size
    }

    private func scanID(from url: URL) -> UUID? {
        guard url.lastPathComponent.hasPrefix("scan-"), let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return UUID(uuidString: String(url.lastPathComponent.dropFirst(5)))
    }

    private func knownScanDirectory(_ id: UUID) -> URL? { let url = scanDirectory(id); return scanID(from: url) == id ? url : nil }

    private func boundedManifestURL(_ dir: URL) -> URL? {
        let url = dir.appendingPathComponent("manifest.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 1_000_000 else { return nil }
        return url
    }

    private func markFailure(_ id: UUID) {
        failed.insert(id)
        if var scan = scans[id] {
            scan.persistence = "save_failed"
            scans[id] = scan
        }
        lastError = Failure.writeFailed.localizedDescription
    }

    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func redact(_ value: String?) -> String? {
        guard let value else { return nil }
        var text = value.replacingOccurrences(of: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)((?:[\"']?)(?:api[_-]?key|access[_-]?token|token|secret|authorization|password)(?:[\"']?)\s*[:=]\s*)(?:\"[^\"\n]*\"|'[^'\n]*'|[^&\s,}]+)"#,
            with: "$1[REDACTED]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)(https?://)[^/\s@]+@"#, with: "$1[REDACTED]@", options: .regularExpression)
        return text
    }
    private func sanitize(_ value: String?) -> String? {
        redact(value).map { bounded($0, Self.maxPayloadUTF8) }
    }
    private func bounded(_ value: String, _ n: Int) -> String {
        guard value.utf8.count > n else { return value }
        var text = String(decoding: value.utf8.prefix(n), as: UTF8.self)
        while text.utf8.count > n { text.removeLast() }
        return text
    }
    private func bounded(_ value: String?, _ n: Int) -> String { bounded(value ?? "", n) }
}

private extension JSONEncoder {
    static var receipt: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
private extension JSONDecoder {
    static var receipt: JSONDecoder { JSONDecoder() }
}
