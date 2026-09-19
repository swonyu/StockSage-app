import Foundation
import CryptoKit
import Darwin

/// A full restore activates one authoritative image. Legacy preferences stay untouched;
/// thereafter every participating mutation replaces this image, never four separate keys.
/// An interrupted staged write leaves the previous image authoritative. Temporary files
/// are never promoted on launch, and an unreadable image never falls back to preferences.
@MainActor enum StockSageRecordStorage {
    nonisolated enum Value: Codable {
        case data(Data), strings([String]), flag(Bool), absent
        var object: Any? {
            switch self {
            case .data(let value): value
            case .strings(let value): value
            case .flag(let value): value
            case .absent: nil
            }
        }
    }
    struct Change {
        let key: String
        let value: Value
    }
    struct PreparedImport {
        let defaults: UserDefaults
        let added: Int
        let changes: [Change]
        let publish: (String?) -> Void

        func apply() throws {
            let warning = try update(changes, defaults: defaults, activate: false)
            publish(warning)
        }
    }
    nonisolated enum Failure: LocalizedError {
        case unreadable, invalidProfile, durabilityUnconfirmed
        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Saved records could not be verified. The saved file was preserved; recover it before editing or restoring."
            case .invalidProfile:
                "The backup destinations do not share one supported record store. Nothing was changed."
            case .durabilityUnconfirmed:
                "Records were committed together, but storage durability could not be confirmed. Keep your backup and reopen before further edits."
            }
        }
    }

    nonisolated private struct Envelope: Codable {
        let version: Int
        let payload: Data
        let sha256: String
    }
    // File identity + nanosecond modification/change times prevent re-decoding the entire
    // journal for each deletion-marker lookup while detecting external replacement/damage.
    nonisolated private struct Stamp: Equatable {
        let inode: UInt64, size: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        init(_ info: stat) {
            inode = UInt64(info.st_ino); size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec); modifiedNS = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec); changedNS = Int64(info.st_ctimespec.tv_nsec)
        }
    }
    private static var cache: [String: (Stamp, [String: Value])] = [:]
    private static let keys = ["stocksage.journal.v1", "stocksage_portfolio_v1", "stocksage_user_symbols", "stocksage_price_alerts"]
    private static let maximumBytes = 50_000_000

    static func fileURL(defaults: UserDefaults) throws -> URL { try StockSageRecordWriter.recordsURL(defaults) }

    private static func isMarker(_ key: String) -> Bool {
        for base in keys.prefix(2) {
            let prefix = base + ".deleted."
            if key.hasPrefix(prefix), UUID(uuidString: String(key.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }
    private static func participates(_ key: String) -> Bool { keys.contains(key) || isMarker(key) }

    static func object(forKey key: String, defaults: UserDefaults) throws -> Any? {
        guard participates(key), let image = try load(defaults: defaults) else { return defaults.object(forKey: key) }
        return image[key]?.object
    }

    @discardableResult static func set(_ value: Any?, forKey key: String, defaults: UserDefaults) throws -> String? {
        try update([Change(key: key, value: try stored(value))], defaults: defaults, activate: false)
    }

    /// Used by ordinary single-collection edits; only a full backup restore activates storage.
    /// A returned warning still means the new image was committed; only pre-commit errors throw.
    @discardableResult static func update(_ changes: [Change], defaults: UserDefaults, activate: Bool = false,
                       beforeReplace: (() throws -> Void)? = nil) throws -> String? {
        try StockSageRecordWriter.require(defaults)
        guard !changes.isEmpty else { return nil }
        let supported = changes.allSatisfy { participates($0.key) }
        guard !activate || supported else { throw Failure.invalidProfile }
        let existing = supported ? try load(defaults: defaults) : nil
        guard activate || existing != nil else {
            for change in changes {
                if let value = change.value.object { defaults.set(value, forKey: change.key) }
                else { defaults.removeObject(forKey: change.key) }
            }
            return nil
        }
        var image = try existing ?? legacyImage(defaults: defaults)
        for change in changes {
            if isMarker(change.key), case .absent = change.value { image.removeValue(forKey: change.key) }
            else { image[change.key] = change.value }
        }
        try validate(image)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(image)
        let bytes = try encoder.encode(Envelope(version: 1, payload: payload, sha256: digest(payload)))
        guard bytes.count <= maximumBytes else { throw Failure.unreadable }
        do {
            try replace(bytes, at: fileURL(defaults: defaults), beforeReplace: beforeReplace,
                        afterReplace: { try StockSageRecordWriter.afterRecordReplace(defaults) })
        } catch Failure.durabilityUnconfirmed {
            return Failure.durabilityUnconfirmed.localizedDescription
        }
        return nil
    }

    /// One commit point for all four prepared imports, followed by publication without awaits.
    @discardableResult static func commit(_ prepared: [PreparedImport], beforeReplace: (() throws -> Void)? = nil) throws -> String? {
        guard let defaults = prepared.first?.defaults,
              prepared.allSatisfy({ $0.defaults === defaults }) else { throw Failure.invalidProfile }
        let changes = prepared.flatMap(\.changes)
        guard Set(changes.map(\.key)).count == changes.count else { throw Failure.invalidProfile }
        let warning = try update(changes, defaults: defaults, activate: true, beforeReplace: beforeReplace)
        for entry in prepared { entry.publish(warning) }
        return warning
    }

    private static func stored(_ object: Any?) throws -> Value {
        guard let object else { return .absent }
        if let data = object as? Data { return .data(data) }
        if let strings = object as? [String] { return .strings(strings) }
        if let flag = object as? Bool { return .flag(flag) }
        throw Failure.unreadable
    }

    private static func legacyImage(defaults: UserDefaults) throws -> [String: Value] {
        var image: [String: Value] = [:]
        for key in keys { image[key] = try stored(defaults.object(forKey: key)) }
        for (key, value) in defaults.dictionaryRepresentation() where isMarker(key) { image[key] = try stored(value) }
        try validate(image)
        return image
    }

    private static func validate(_ image: [String: Value]) throws {
        guard keys.allSatisfy({ image[$0] != nil }), image.keys.allSatisfy(participates) else { throw Failure.unreadable }
        for (key, value) in image {
            if case .absent = value { continue }
            if isMarker(key) {
                guard case .flag = value else { throw Failure.unreadable }
            } else if key == keys[2] {
                guard case .strings = value else { throw Failure.unreadable }
            } else {
                guard case .data(let bytes) = value else { throw Failure.unreadable }
                do {
                    switch key {
                    case keys[0]: _ = try JSONDecoder().decode([TradeRecord].self, from: bytes)
                    case keys[1]: _ = try JSONDecoder().decode([PortfolioPosition].self, from: bytes)
                    default: _ = try JSONDecoder().decode([PriceAlert].self, from: bytes)
                    }
                } catch { throw Failure.unreadable }
            }
        }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func load(defaults: UserDefaults) throws -> [String: Value]? {
        // Parent-app import and explicitly injected read-only suites retain their legacy reads.
        guard StockSageRecordWriter.manages(defaults) else { return nil }
        let url = try fileURL(defaults: defaults)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { cache.removeValue(forKey: url.path); return nil }
            throw Failure.unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // A second process must not expose a mixture of independently loaded generations.
        try StockSageRecordWriter.require(defaults)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumBytes) else { throw Failure.unreadable }
        let stamp = Stamp(info)
        if let saved = cache[url.path], saved.0 == stamp { return saved.1 }
        do {
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw Failure.unreadable }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.sha256 == digest(envelope.payload) else { throw Failure.unreadable }
            let image = try JSONDecoder().decode([String: Value].self, from: envelope.payload)
            try validate(image)
            cache[url.path] = (stamp, image)
            return image
        } catch { throw Failure.unreadable }
    }

    private static func replace(_ data: Data, at url: URL, beforeReplace: (() throws -> Void)?,
                                afterReplace: () throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString + ".tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor); Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let parent = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parent) }
        try beforeReplace?()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        cache.removeValue(forKey: url.path)
        do { try afterReplace() }
        catch { throw Failure.durabilityUnconfirmed }
        // Some filesystems do not implement directory fsync; all other errors remain visible.
        if fsync(parent) != 0, errno != EINVAL, errno != ENOTSUP { throw Failure.durabilityUnconfirmed }
    }
}
