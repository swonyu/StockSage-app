import Foundation
import Darwin

/// Kernel-owned advisory lease. Never unlink/replace the file: process death closes the
/// descriptor, and a surviving filename does not mean that another writer still owns it.
nonisolated final class StockSageFileLock: Sendable {
    enum Failure: LocalizedError {
        case busy, unavailable
        var errorDescription: String? {
            switch self {
            case .busy: "Another StockSage process owns these records. Quit the other copy, then relaunch. Nothing was changed."
            case .unavailable: "Record writer lock unavailable. Existing records were preserved; check storage access and relaunch."
            }
        }
    }
    private let descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            Darwin.close(fd)
            throw busy ? Failure.busy : Failure.unavailable
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
}

/// One process-lifetime writer for the owner preference domain, shared by all three
/// legacy record stores. Failed acquisition stays failed until a fresh process reloads.
@MainActor enum StockSageRecordWriter {
    private final class Profile {
        let defaults: UserDefaults
        let lease: Result<StockSageFileLock, Error>
        let afterRecordReplace: (() throws -> Void)?
        init(defaults: UserDefaults, afterRecordReplace: (() throws -> Void)? = nil,
             acquire: () throws -> StockSageFileLock) {
            self.defaults = defaults
            self.afterRecordReplace = afterRecordReplace
            lease = Result(catching: acquire)
        }
    }
    private static let standard = Profile(defaults: .standard) {
        guard !StockSageStore.isRunningTests else { throw StockSageFileLock.Failure.unavailable }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        guard let domain = Bundle.main.bundleIdentifier else { throw StockSageFileLock.Failure.unavailable }
        return try StockSageFileLock(url: root.appendingPathComponent("StockSage/SharedRecords")
            .appendingPathComponent(domain + ".writer.lock"))
    }
    private static var fixtures: [String: Profile] = [:]
    private static let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("stocksage-record-fixtures-" + UUID().uuidString)

    /// Test-only capability: creates and registers a UUID-named isolated suite with a real
    /// temporary lease. An arbitrary UserDefaults object never implies owner-write authority.
    static func fixtureDefaults(suiteName: String, afterRecordReplace: (() throws -> Void)? = nil) -> UserDefaults? {
        guard StockSageStore.isRunningTests, !suiteName.contains("/"),
              suiteName.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                              options: .regularExpression) != nil else { return nil }
        if let fixture = fixtures[suiteName] { return fixture.defaults }
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        let profile = Profile(defaults: defaults, afterRecordReplace: afterRecordReplace) {
            try StockSageFileLock(url: fixtureRoot.appendingPathComponent(suiteName + ".lock"))
        }
        guard (try? profile.lease.get()) != nil else { return nil }
        fixtures[suiteName] = profile
        return defaults
    }

    static func mayRead(_ defaults: UserDefaults) -> Bool {
        !StockSageStore.isRunningTests || fixtures.values.contains { $0.defaults === defaults }
    }

    static func manages(_ defaults: UserDefaults) -> Bool {
        StockSageStore.isRunningTests ? fixtures.values.contains { $0.defaults === defaults }
            : defaults === UserDefaults.standard
    }

    /// An isolated fixture may interrupt after rename; production has no runtime activation.
    static func afterRecordReplace(_ defaults: UserDefaults) throws {
        guard StockSageStore.isRunningTests else { return }
        guard let fixture = fixtures.values.first(where: { $0.defaults === defaults }) else {
            throw StockSageFileLock.Failure.unavailable
        }
        try fixture.afterRecordReplace?()
    }

    /// The record image shares the writer's profile and isolated fixture directory.
    static func recordsURL(_ defaults: UserDefaults) throws -> URL {
        if StockSageStore.isRunningTests {
            guard let fixture = fixtures.first(where: { $0.value.defaults === defaults }) else {
                throw StockSageFileLock.Failure.unavailable
            }
            return fixtureRoot.appendingPathComponent(fixture.key + ".records.json")
        }
        guard defaults === UserDefaults.standard, let domain = Bundle.main.bundleIdentifier else {
            throw StockSageFileLock.Failure.unavailable
        }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
        return root.appendingPathComponent("StockSage/SharedRecords").appendingPathComponent(domain + ".records.json")
    }

    static func require(_ defaults: UserDefaults) throws {
        if StockSageStore.isRunningTests {
            guard let fixture = fixtures.values.first(where: { $0.defaults === defaults }) else {
                throw StockSageFileLock.Failure.unavailable
            }
            _ = try fixture.lease.get()
        } else {
            guard defaults === UserDefaults.standard else { throw StockSageFileLock.Failure.unavailable }
            _ = try standard.lease.get()
        }
    }
}
