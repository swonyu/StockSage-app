import Foundation
import Darwin

/// Bounded local diagnostic records. Prediction evidence remains in ResearchHistory.
actor StockSageResearchDiagnostics {
    @MainActor static let shared = StockSageResearchDiagnostics(directory:
        StockSageStore.isRunningTests || (try? StockSageRecordWriter.require(.standard)) == nil ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockSage/ResearchDiagnostics", isDirectory: true))

    nonisolated struct Context: Codable, Equatable, Sendable {
        enum Purpose: String, Codable, Sendable { case assessment, ranking }
        let id: UUID
        let symbol: String?
        let horizon: Int
        let purpose: Purpose
        let startedAt: Date

        init(id: UUID = UUID(), symbol: String?, horizon: Int, purpose: Purpose, startedAt: Date = Date()) {
            self.id = id; self.symbol = symbol; self.horizon = horizon
            self.purpose = purpose; self.startedAt = startedAt
        }
    }
    nonisolated struct Outcome: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case accepted, rejected, notRequested, cancelled }
        let state: State
        let note: String
        var inferenceProfile: StockSageAIAssessment.InferenceProfile? = nil
        var qualityReport: StockSageAIAssessment.QualityReport? = nil
    }
    nonisolated struct Entry: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case started, attempt, outcome }
        let context: Context
        let at: Date
        let kind: Kind
        let attempt: StockSageLocalModelServer.ModelAttemptEvent?
        let outcome: Outcome?
        let complete: Bool?
    }

    private let directory: URL?
    private let maximumBytes: Int
    private let maximumContexts: Int
    private let maximumContextBytes: Int

    init(directory: URL? = nil, maximumBytes: Int = 128 * 1_024 * 1_024,
         maximumContexts: Int = 4_096, maximumContextBytes: Int = 1_024 * 1_024) {
        self.directory = directory
        self.maximumBytes = max(0, min(maximumBytes, 128 * 1_024 * 1_024))
        self.maximumContexts = max(0, min(maximumContexts, 4_096))
        self.maximumContextBytes = max(0, min(maximumContextBytes, 1_024 * 1_024))
    }

    private nonisolated struct FileInfo {
        let context: Context
        var bytes: Int
        var torn: Bool
    }
    private var index: [UUID: FileInfo] = [:]
    private var active: [UUID: Context] = [:]
    private var failed: Set<UUID> = []
    private var loaded = false
    private var storageUnknown = false
    private let files = FileManager.default

    @discardableResult func begin(_ context: Context) -> Bool {
        guard directory != nil, valid(context), active[context.id] == nil,
              active.count < maximumContexts else { return false }
        do {
            try prepareDirectory()
            guard index[context.id] == nil else { return false }
        } catch { return false }
        active[context.id] = context
        return append(.init(context: context, at: Date(), kind: .started,
                            attempt: nil, outcome: nil, complete: nil))
    }

    @discardableResult func record(_ event: StockSageLocalModelServer.ModelAttemptEvent, context: Context) -> Bool {
        guard active[context.id] == context else {
            if active[context.id] != nil { failed.insert(context.id) }
            return false
        }
        guard !failed.contains(context.id) else { return false }
        return append(.init(context: context, at: Date(), kind: .attempt,
                            attempt: event, outcome: nil, complete: nil))
    }

    @discardableResult func finish(_ context: Context, outcome: Outcome) -> Bool {
        guard active[context.id] == context else {
            if active[context.id] != nil { failed.insert(context.id) }
            return false
        }
        defer { active.removeValue(forKey: context.id); failed.remove(context.id) }
        let complete = !failed.contains(context.id)
        let bounded = Outcome(state: outcome.state, note: String(decoding: outcome.note.utf8.prefix(2_000), as: UTF8.self),
            inferenceProfile: outcome.inferenceProfile, qualityReport: outcome.qualityReport)
        let written = append(.init(context: context, at: Date(), kind: .outcome,
                                   attempt: nil, outcome: bounded, complete: complete))
        return written && complete
    }

    func entries(for id: UUID) -> [Entry] {
        guard let directory else { return [] }
        do {
            try checkDirectory(directory)
            return try readFile(directory.appendingPathComponent(id.uuidString + ".jsonl"), id: id).entries
        } catch { return [] }
    }

    private func valid(_ context: Context) -> Bool {
        [7, 14].contains(context.horizon) && context.startedAt.timeIntervalSince1970.isFinite &&
            context.startedAt.timeIntervalSince1970 > 0 &&
            (context.symbol.map { $0.range(of: #"\A[A-Z][A-Z0-9.-]{0,31}\z"#, options: .regularExpression) != nil }
                ?? (context.purpose == .ranking))
    }

    private func checkPath(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        var component = url.standardizedFileURL
        while component.path != "/" {
            do {
                let attributes = try files.attributesOfItem(atPath: component.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    // macOS exposes its temporary directory through these system aliases.
                    let destination = try files.destinationOfSymbolicLink(atPath: component.path)
                    // Standardizing /private/var produces /var on macOS, so compare the
                    // literal target instead of normalizing away the system alias.
                    guard let target = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"][component.path],
                          destination == target || destination == String(target.dropFirst()) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // The missing components are created only after all existing parents pass.
            }
            component.deleteLastPathComponent()
        }
    }

    private func checkDirectory(_ url: URL) throws {
        try checkPath(url)
        let info = try files.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func fileBytes(_ url: URL) throws -> Int {
        // FileManager reads fresh metadata; URL resource values can cache a pre-append size.
        let info = try files.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let number = info[.size] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
        let size = number.intValue
        guard size >= 0, size <= maximumContextBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return size
    }

    private func readFile(_ url: URL, id: UUID) throws -> (info: FileInfo, entries: [Entry]) {
        let size = try fileBytes(url)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1, metadata.st_size == off_t(size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: maximumContextBytes + 1) ?? Data()
        guard data.count == size, try fileBytes(url) == size else { throw CocoaError(.fileReadCorruptFile) }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        let entries = try lines.dropLast().map { try JSONDecoder().decode(Entry.self, from: Data($0)) }
        guard let first = entries.first, first.kind == .started,
              first.context.id == id, valid(first.context) else { throw CocoaError(.fileReadCorruptFile) }
        var finished = false
        for (offset, entry) in entries.enumerated() {
            guard entry.context == first.context, entry.at.timeIntervalSince1970.isFinite,
                  entry.at.timeIntervalSince1970 > 0, !finished else { throw CocoaError(.fileReadCorruptFile) }
            switch entry.kind {
            case .started:
                guard offset == 0, entry.attempt == nil, entry.outcome == nil, entry.complete == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            case .attempt:
                guard entry.attempt != nil, entry.outcome == nil, entry.complete == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            case .outcome:
                guard entry.attempt == nil, entry.outcome != nil, entry.complete != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                finished = true
            }
        }
        let torn = data.last != 10
        guard !(finished && torn) else { throw CocoaError(.fileReadCorruptFile) }
        return (.init(context: first.context, bytes: size, torn: torn), entries)
    }

    private func prepareDirectory() throws {
        guard !storageUnknown, let directory, directory.isFileURL,
              maximumBytes > 0, maximumContexts > 0, maximumContextBytes > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try checkPath(directory)
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        try checkDirectory(directory)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard !loaded else { return }
        var found: [UUID: FileInfo] = [:]
        var total = 0
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == id.uuidString + ".jsonl" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let info = try readFile(url, id: id).info
            guard info.bytes <= maximumBytes - total, found.count < maximumContexts else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            total += info.bytes
            found[id] = info
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        index = found
        loaded = true
    }

    private func append(_ entry: Entry) -> Bool {
        let id = entry.context.id
        do {
            try prepareDirectory()
            guard let directory, active[id] == entry.context else { throw CocoaError(.fileWriteUnknown) }
            let previous = index[id]?.bytes ?? 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(entry)
            data.append(10)
            guard data.count <= maximumContextBytes - previous else { throw CocoaError(.fileWriteOutOfSpace) }
            let url = directory.appendingPathComponent(id.uuidString + ".jsonl")
            if let old = index[id] {
                let current = try readFile(url, id: id)
                guard old.context == entry.context, current.info.context == entry.context,
                      !old.torn, !current.info.torn, current.entries.last?.kind != .outcome,
                      entry.kind != .started, current.info.bytes == previous else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else if entry.kind != .started {
                throw CocoaError(.fileReadCorruptFile)
            }
            var total = index.values.reduce(0) { $0 + $1.bytes }
            let additions = index[id] == nil ? 1 : 0
            if data.count > maximumBytes - total || additions > maximumContexts - index.count {
                // Only this actor's live contexts are protected. Old interrupted diagnostics can
                // expire; saved prediction evidence is held in a different directory.
                for (oldID, old) in index.sorted(by: { $0.value.context.startedAt < $1.value.context.startedAt })
                    where oldID != id && active[oldID] == nil {
                    if data.count <= maximumBytes - total && additions <= maximumContexts - index.count { break }
                    let oldURL = directory.appendingPathComponent(oldID.uuidString + ".jsonl")
                    let current = try readFile(oldURL, id: oldID).info
                    guard current.context == old.context, current.bytes == old.bytes else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try files.removeItem(at: oldURL)
                    index.removeValue(forKey: oldID)
                    total -= old.bytes
                }
            }
            guard data.count <= maximumBytes - total, additions <= maximumContexts - index.count else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | (index[id] == nil ? O_CREAT | O_EXCL : 0)
            let descriptor = open(url.path, flags, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_nlink == 1, info.st_size == off_t(previous), fchmod(descriptor, 0o600) == 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                guard try fileBytes(url) == previous + data.count else { throw CocoaError(.fileReadCorruptFile) }
                index[id] = .init(context: entry.context, bytes: previous + data.count, torn: false)
            } catch {
                // A failed write may still consume disk space or leave a partial JSON line.
                // Account for those bytes before any future retention decision; unknown size
                // disables writing instead of quietly undercounting the retained payload.
                if let size = try? fileBytes(url) {
                    index[id] = .init(context: entry.context, bytes: size, torn: true)
                } else { storageUnknown = true }
                throw error
            }
            return true
        } catch {
            // Metadata may have changed or even a failed creation may have left a file.
            // Reconcile all actual sizes before another capacity calculation.
            loaded = false
            failed.insert(id)
            return false
        }
    }
}
